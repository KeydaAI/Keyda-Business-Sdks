import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'client_id.dart';
import 'replies.dart';
import 'sdk_version.dart';
import 'visitor.dart';

/// Called when the chat page tries to leave its own origin — a "Powered by
/// Keyda" tap, a `mailto:`, a `tel:`, a WhatsApp or UPI deep link.
///
/// The navigation is always blocked inside the chat first. By default the SDK
/// then hands [url] to the system browser; supplying a handler REPLACES that,
/// for a host app that would rather route links itself — into its own in-app
/// browser, or nowhere at all.
typedef KeydaExternalLinkHandler = Future<void> Function(Uri url);

/// Full-screen host for the hosted chat page.
///
/// Internal: it is presented through `KeydaBot.show`, which owns the route and
/// the `isShowing` bookkeeping.
class KeydaChatPage extends StatefulWidget {
  /// Creates the page for an already-validated [chatUrl].
  const KeydaChatPage({
    required this.chatUrl,
    this.onExternalLink,
    this.question,
    this.embedded = false,
    this.onCanGoBackChanged,
    this.focused = true,
    super.key,
  });

  /// The `{baseUrl}/chat/{clientId}` URL built at init.
  final Uri chatUrl;

  /// Optional host handler for links that leave [chatUrl]'s origin.
  final KeydaExternalLinkHandler? onExternalLink;

  /// A question for the composer, unsent: in the URL's #fragment at the first
  /// load (never in a server log); a new value later goes into the live chat.
  final String? question;

  /// Embedded in a screen of the host's (`KeydaBotChat`): no close bar, no
  /// status-bar styling, and Android back closes a sheet the chat has open and
  /// is otherwise the host's.
  final bool embedded;

  /// Told when a sheet opens over the conversation (true) and when the last
  /// one closes (false).
  final ValueChanged<bool>? onCanGoBackChanged;

  /// Embedded only: is this screen the one in front? While false, back is the
  /// host's (the chat would otherwise close a sheet nobody can see) and the
  /// chat counts as off screen, so the SDK checks for replies itself.
  final bool focused;

  @override
  State<KeydaChatPage> createState() => KeydaChatPageState();
}

/// CONTRACT.md rule 7: the two backgrounds a shell paints. They are the hosted
/// page's own page colours, so the loading cover, the close bar and the retry
/// screen are indistinguishable from the chat that replaces them.
const Color _darkBackground = Color(0xFF0B1220);
const Color _lightBackground = Color(0xFFF7F8FC);

/// The JavaScript channel name the hosted page looks for
/// (`window.KeydaBotFlutter.postMessage`). Renaming it silently breaks rule 7.
const String _themeChannel = 'KeydaBotFlutter';

/// Extensions a page may list instead of MIME types (`accept=".jpg,.png"`),
/// so an accept list written that way still counts as asking for images.
const Set<String> _imageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
  '.heif',
};

/// CONTRACT.md rule 10: closes the page's top sheet and answers whether there
/// was one. Wrapped so that a page without `back()`, or one that throws,
/// answers false: the chat closes, as it always did.
const String _backScript =
    "(function(){try{return !!(window.KeydaBot&&typeof window.KeydaBot.back==='function'&&window.KeydaBot.back());}catch(e){return false;}})()";

/// How long back waits for the page's answer before closing the chat anyway.
const Duration _backAnswerTimeout = Duration(milliseconds: 500);

/// The page takes up to 500 characters; anything longer is cut, not refused.
const int _questionMax = 500;

/// Trimmed, without lone UTF-16 halves, and cut at 500 characters — whole
/// ones: a cut by UTF-16 unit can leave half an emoji. A half is never sent:
/// `Uri.encodeComponent` and the platform channel turn one into U+FFFD, a
/// character the customer never typed.
@visibleForTesting
String cleanQuestion(String? question) {
  final String q = withoutLoneSurrogates((question ?? '').trim());
  return q.runes.length > _questionMax ? String.fromCharCodes(q.runes.take(_questionMax)) : q;
}

/// The chat page's state. Public in name only (the library does not export
/// it): `KeydaBot` reaches the full-screen one to put a question in its box.
class KeydaChatPageState extends State<KeydaChatPage> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _failed = false;

  /// The page's sheet count (`keyda:sheets`, CONTRACT.md rule 10).
  int _sheets = 0;

  /// The question this chat was opened with or last given.
  String _asked = '';

  /// A question that arrived before the page could take it.
  String? _pendingPrefill;

  /// The fallback for a back press the page has not answered yet.
  Timer? _pendingBack;

  /// A page has rendered here, so the start (question, visitor) was delivered.
  /// Every later load — Retry — takes the plain chat URL: the same URL plus a
  /// #fragment is a same-document jump that loads nothing, and a question the
  /// customer already sent must not come back into the box.
  bool _startDelivered = false;
  bool _loadAttempted = false;

  /// Counted as on screen by the reply check (KeydaReplies).
  bool _countedOnScreen = false;

  /// The scheme the chrome is drawn in. Null until something decides it: the
  /// device scheme on the first build, then whatever the page announces
  /// (rule 7). Kept nullable rather than defaulted so a page message that
  /// arrives before the first build is not overwritten by the device fallback.
  Brightness? _brightness;

  /// True once the page has reported its theme. From then on the device scheme
  /// is ignored — the page is the one that knows the owner's setting, and it
  /// re-posts when a "Match the visitor" bot flips with the OS.
  bool _pageDecidedTheme = false;

  @override
  void initState() {
    super.initState();
    keydaVisitor.addListener(_applyVisitor);
    // A chat on screen shows the business's replies itself; the SDK asks only
    // while none is.
    _setOnScreen(!widget.embedded || widget.focused);
    // No DOM storage call, deliberately: the shared WebViewController API has
    // no switch for it, both endorsed implementations enable it, and the
    // visitor's conversation survives an app restart because they do; nothing
    // here turns it off.
    _controller = WebViewController()
      // The chat is a web app; with JavaScript off there is no chat at all.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Registered BEFORE loadRequest: the page posts its theme from <head>,
      // and a channel added after the load starts can miss that first message.
      ..addJavaScriptChannel(_themeChannel, onMessageReceived: _onThemeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
        ),
      );
    _installFileSelector();
    unawaited(_stampVersionThenLoad());
  }

  /// CONTRACT.md rule 9. The page's attach button ends in `<input type=file>`,
  /// which Android hands to the WebView's chrome client. The shared
  /// [WebViewController] has no hook for it and webview_flutter's stock chrome
  /// client answers "not handled", so on Android the tap did nothing in every
  /// version before 0.1.4 — the only way in is the Android implementation's
  /// own [AndroidWebViewController.setOnShowFileSelector]. iOS needs nothing:
  /// WebKit presents its own picker for the same input.
  void _installFileSelector() {
    final Object platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setOnShowFileSelector(_selectFiles));
    }
  }

  /// Answers the page's file request: photos from the system photo picker
  /// when the page asks for images only, the system's file picker (photos and
  /// documents) otherwise.
  ///
  /// Both pickers are the Flutter team's own (rule 5 rules out third-party
  /// ones) and neither needs a permission. Up to 0.1.4 this answered
  /// everything with photos only, and the chat's attach button — which takes
  /// PDF, DOCX, TXT, CSV and MD as well — could not send a document. The
  /// camera is not offered even when the page asks for capture: that would
  /// put the host app's CAMERA permission semantics in play, which no README
  /// here promises to handle. Nothing is ever thrown out of here — a tap that
  /// cannot be served is a cancel, not an exception in someone else's app
  /// (rule 6).
  Future<List<String>> _selectFiles(FileSelectorParams params) async {
    final bool multiple = params.mode == FileSelectorMode.openMultiple;
    List<XFile> picked = const <XFile>[];
    try {
      if (_onlyImages(params.acceptTypes)) {
        final ImagePicker picker = ImagePicker();
        if (multiple) {
          picked = await picker.pickMultiImage();
        } else {
          final XFile? one =
              await picker.pickImage(source: ImageSource.gallery);
          picked = one == null ? const <XFile>[] : <XFile>[one];
        }
      } else {
        final List<XTypeGroup> groups = _typeGroups(params.acceptTypes);
        if (multiple) {
          picked = await openFiles(acceptedTypeGroups: groups);
        } else {
          final XFile? one = await openFile(acceptedTypeGroups: groups);
          picked = one == null ? const <XFile>[] : <XFile>[one];
        }
      }
    } catch (error, stack) {
      // "already_active" when a second tap lands while a picker is up, or a
      // device with no picker app at all. Reported the way Flutter reports
      // any other failure; the page gets a cancel.
      _report(error, stack, 'picking a file for the Keyda chat');
    }
    // The Android implementation parses each entry with Uri.parse and the
    // WebView reads the file from the app's own cache, where both pickers put
    // their copy (under its own name, which is how the page tells a PDF from
    // a photo). An empty list is the cancel.
    return picked
        .map((XFile file) => Uri.file(file.path).toString())
        .toList(growable: false);
  }

  /// Whether the accept list names images and nothing else, which is when
  /// the photo picker — the better place to find a photo — is the answer.
  bool _onlyImages(List<String> acceptTypes) {
    bool any = false;
    for (final String raw in acceptTypes) {
      final String type = raw.trim().toLowerCase();
      if (type.isEmpty) {
        continue;
      }
      if (type.startsWith('image/') || _imageExtensions.contains(type)) {
        any = true;
      } else {
        return false;
      }
    }
    return any;
  }

  /// The page's accept list as the file picker's filter: MIME types as they
  /// are, `.ext` entries as extensions. An empty list (or `*/*`) is any file.
  List<XTypeGroup> _typeGroups(List<String> acceptTypes) {
    final List<String> mimeTypes = <String>[];
    final List<String> extensions = <String>[];
    for (final String raw in acceptTypes) {
      final String type = raw.trim().toLowerCase();
      if (type.isEmpty) {
        continue;
      }
      if (type == '*/*') {
        return const <XTypeGroup>[];
      }
      if (type.startsWith('.')) {
        extensions.add(type.substring(1));
      } else if (type.contains('/')) {
        mimeTypes.add(type);
      }
    }
    if (mimeTypes.isEmpty && extensions.isEmpty) {
      return const <XTypeGroup>[];
    }
    return <XTypeGroup>[
      XTypeGroup(
        label: 'Files',
        mimeTypes: mimeTypes,
        extensions: extensions,
      ),
    ];
  }

  /// Adds `KeydaBot/<version> (Flutter)` to the User-Agent, then loads.
  ///
  /// The page can tell it is inside this shell (the `KeydaBotFlutter` channel
  /// exists) but not which version, and 0.1.3 could not open a file picker on
  /// Android. The native Android SDK already answers that question with its
  /// User-Agent; this is the same signal, so the page can show its attach
  /// button to shells that will answer it and keep it from the ones that will
  /// not. A version and nothing else — no device identifier rides along. The
  /// platform's own User-Agent is read and appended to rather than replaced,
  /// because the page and its server logs rely on it to tell phones apart.
  Future<void> _stampVersionThenLoad() async {
    try {
      final String? stock = await _controller.getUserAgent();
      if (stock != null && stock.isNotEmpty && !stock.contains('KeydaBot/')) {
        await _controller.setUserAgent(
          '$stock KeydaBot/$kKeydaSdkVersion (Flutter)',
        );
      }
    } on Object catch (_) {
      // Silent, and deliberately so. On iOS this reads the User-Agent by
      // evaluating JavaScript, which a WKWebView that has not loaded anything
      // yet may refuse — a routine condition, not a fault, and reporting it
      // would put a non-fatal into the host app's crash reporter every time a
      // customer opens the chat (rule 6 is about not making the host's users
      // pay for us; the same courtesy applies to the host's error budget).
      // The chat then loads with the stock User-Agent, which is exactly what
      // every version before 0.1.4 sent, and the page falls back to treating
      // this shell as unversioned. That costs nothing on iOS, where WebKit
      // opens the picker whatever the page believes.
    }
    if (!mounted) {
      return;
    }
    await _controller.loadRequest(_startUrl());
  }

  /// The chat URL with its start in the #fragment — the question and
  /// `KeydaBot.setVisitor`'s details: the page reads it as it loads and takes
  /// it off the address. A fragment never reaches a server.
  Uri _startUrl() {
    final String q = cleanQuestion(widget.question);
    _asked = q;
    if (_startDelivered || _loadAttempted) {
      // Not delivered yet (the first load failed): by script, once the page is up.
      if (!_startDelivered && q.isNotEmpty) {
        _pendingPrefill ??= q;
      }
      _loadAttempted = true;
      return widget.chatUrl;
    }
    _loadAttempted = true;
    final List<String> items = <String>[
      if (q.isNotEmpty) 'q=${Uri.encodeComponent(q)}',
      ...?keydaVisitor.value?.fragmentItems(),
    ];
    if (items.isEmpty) {
      return widget.chatUrl;
    }
    return widget.chatUrl.replace(fragment: items.join('&'));
  }

  /// `KeydaBot.setVisitor` reaching a page that is up — `{}` for none.
  void _applyVisitor() {
    if (_isLoading || _failed || !_startDelivered) {
      return;
    }
    final String json = keydaVisitor.value?.toJson() ?? '{}';
    unawaited(
      _controller
          .runJavaScript(
            '(function(){try{window.KeydaBot&&window.KeydaBot.setVisitor&&'
            'window.KeydaBot.setVisitor($json);}catch(e){}})()',
          )
          .catchError((Object _) {}),
    );
  }

  void _setOnScreen(bool onScreen) {
    if (onScreen == _countedOnScreen) {
      return;
    }
    _countedOnScreen = onScreen;
    if (onScreen) {
      KeydaReplies.instance.chatAppeared();
    } else {
      KeydaReplies.instance.chatWentAway();
    }
  }

  /// Puts [question] in the chat's message box, unsent — the customer still
  /// taps send. Before the page has loaded it waits for it.
  void prefill(String question) {
    final String q = cleanQuestion(question);
    if (q.isEmpty) {
      return;
    }
    _asked = q;
    if (_isLoading || _failed) {
      _pendingPrefill = q;
      return;
    }
    unawaited(
      _controller
          .runJavaScript(
            '(function(){try{window.KeydaBot&&window.KeydaBot.prefill&&'
            'window.KeydaBot.prefill(${jsonEncode(q)});}catch(e){}})()',
          )
          .catchError((Object _) {}),
    );
  }

  @override
  void didUpdateWidget(KeydaChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a CHANGED question: a navigator rebuild hands back the route's
    // original one, which must not land over a newer one or what the customer
    // has typed since.
    if (widget.question != oldWidget.question) {
      final String q = cleanQuestion(widget.question);
      if (q.isNotEmpty && q != _asked) {
        prefill(q);
      }
    }
    if (widget.focused != oldWidget.focused) {
      _setOnScreen(!widget.embedded || widget.focused);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rule 7's fallback: until the page reports, follow the device — that is
    // what "Match the visitor" means, and it is also all a backend that
    // predates the message will ever give us. Re-run on every dependency
    // change so an OS flip is honoured while we are still waiting; once the
    // page has spoken, its word stands.
    if (_pageDecidedTheme) {
      return;
    }
    final Brightness device = MediaQuery.maybePlatformBrightnessOf(context) ??
        Theme.of(context).brightness;
    if (device != _brightness) {
      _brightness = device;
      _applyWebViewBackground(device);
    }
  }

  /// Rule 7: the page announces the owner's resolved theme as
  /// `{"type":"keyda:theme","mode":"light"|"dark",...}`. Anything else on the
  /// channel — another type, malformed JSON, a non-object — is ignored; the
  /// page is content we do not control, and a bad message must never crash
  /// the host app (rule 6).
  void _onThemeMessage(JavaScriptMessage message) {
    Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    if (decoded['type'] == 'keyda:sheets') {
      final Object? open = decoded['open'];
      if (open is num && open >= 0 && open <= 64 && mounted) {
        _setSheets(open.toInt());
      }
      return;
    }
    if (decoded['type'] == 'keyda:waits') {
      // The chats waiting for the business's reply; validated there. A chat
      // out of sight (focused: false) draws a reply nobody sees.
      KeydaReplies.instance.onWaits(
        decoded['waits'],
        chatUrl: widget.chatUrl,
        fromOnScreen: _countedOnScreen,
      );
      return;
    }
    if (decoded['type'] != 'keyda:theme') {
      return;
    }
    final Object? mode = decoded['mode'];
    final Brightness brightness;
    if (mode == 'dark') {
      brightness = Brightness.dark;
    } else if (mode == 'light') {
      brightness = Brightness.light;
    } else {
      return;
    }
    if (!mounted) {
      return;
    }
    // onMessageReceived is already delivered on the platform thread, so
    // setState here is safe; no post-frame hop needed.
    setState(() {
      _pageDecidedTheme = true;
      _brightness = brightness;
    });
    _applyWebViewBackground(brightness);
  }

  void _applyWebViewBackground(Brightness brightness) {
    // The WebView's own default is transparent, which renders as a black
    // rectangle for the moment before the page paints; painting the page's
    // own background instead makes that moment invisible in either scheme.
    _controller.setBackgroundColor(
      brightness == Brightness.dark ? _darkBackground : _lightBackground,
    );
  }

  void _onPageStarted(String url) {
    if (!mounted) {
      return;
    }
    _changing(() {
      _isLoading = true;
      _failed = false;
    });
  }

  void _onPageFinished(String url) {
    if (!mounted) {
      return;
    }
    _changing(() {
      _isLoading = false;
    });
    if (!_failed) {
      _startDelivered = true;
    }
    // The widget script has run by now; KeydaBot.prefill keeps the question
    // until the composer exists.
    final String? waiting = _pendingPrefill;
    if (waiting != null && !_failed) {
      _pendingPrefill = null;
      prefill(waiting);
    }
    // Every page finish gets the current visitor, `{}` for none: the first
    // load's fragment carried the details as they were when it started, a
    // reload has none, and one set, changed or cleared while the page loaded
    // has not reached it.
    _applyVisitor();
  }

  bool get _canGoBack => _sheets > 0 && !_isLoading && !_failed;

  /// Runs [change] in setState and tells onCanGoBackChanged if it flipped
  /// [_canGoBack] — the one place, so a load or a failure is reported too.
  void _changing(VoidCallback change) {
    final bool was = _canGoBack;
    setState(change);
    if (was != _canGoBack) {
      widget.onCanGoBackChanged?.call(_canGoBack);
    }
  }

  void _setSheets(int open) {
    _changing(() {
      _sheets = open;
    });
  }

  void _onWebResourceError(WebResourceError error) {
    // A failed avatar or font must not bury a working conversation under a
    // retry screen. Only the main document failing means there is nothing on
    // screen to talk to. (isForMainFrame is null on some platforms; null is
    // treated as "the document", which is the safe reading.)
    if (error.isForMainFrame == false) {
      return;
    }
    if (!mounted) {
      return;
    }
    _changing(() {
      _failed = true;
      _isLoading = false;
    });
  }

  /// Declared with a plain synchronous return type so it satisfies the
  /// delegate whether the installed webview_flutter expects a decision or a
  /// `FutureOr` of one.
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!request.isMainFrame) {
      // A sub-frame cannot replace the conversation, and blocking sub-frames
      // would leave an empty box wherever the page embeds something.
      return NavigationDecision.navigate;
    }

    final Uri? target = Uri.tryParse(request.url);
    if (target == null) {
      return NavigationDecision.prevent;
    }
    // Path-aware, not origin-aware: the chat's own "Powered by Keyda" link is
    // on the same origin as the chat, and an origin check would let it load in
    // place and take the conversation with it. See staysInChat.
    if (staysInChat(target, widget.chatUrl)) {
      return NavigationDecision.navigate;
    }
    if (!target.hasScheme || isInternalScheme(target.scheme)) {
      // Schemes the WebView only uses to talk to itself, and any scheme-less
      // URL, are not something a person could be shown: blocked silently, with
      // nothing handed to the host and nothing copied.
      return NavigationDecision.prevent;
    }

    // Everything else would navigate the customer's conversation away with no
    // route back to it, so it never happens in this WebView.
    _handleExternalLink(target);
    return NavigationDecision.prevent;
  }

  Future<void> _handleExternalLink(Uri url) async {
    final KeydaExternalLinkHandler? handler = widget.onExternalLink;
    if (handler != null) {
      try {
        await handler(url);
      } catch (error, stack) {
        // The handler is the host app's code. If it throws, the customer still
        // has a live conversation on screen and is owed it; report the failure
        // the way Flutter reports any other, and carry on.
        _report(error, stack, 'opening a link from the Keyda chat');
      }
      return;
    }

    // CONTRACT.md rule 2: blocking the navigation is only half the job — the
    // link still has to open somewhere. url_launcher is Flutter's equivalent
    // of Linking.openURL, which is what the React Native SDK uses for exactly
    // this, and externalApplication is the mode that works for every scheme
    // the chat can produce: https, mailto, tel, wa.me, upi.
    bool opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (error, stack) {
      // No dialer for a `tel:`, no mail app for a `mailto:`, no browser at
      // all: a link that cannot open is not a reason to take the conversation
      // down with it.
      _report(error, stack, 'opening a link from the Keyda chat');
    }
    if (opened || !mounted) {
      return;
    }
    // maybeOf: a host running CupertinoApp has no ScaffoldMessenger, and a
    // missing toast is not worth an exception in someone else's app.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('No app on this device can open that link')),
    );
  }

  /// The host app's error channel, with what this package was doing at the
  /// time. Never a throw: the host's users are not our users (rule 6).
  void _report(Object error, StackTrace stack, String doing) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'keyda_bot',
        context: ErrorDescription(doing),
      ),
    );
  }

  void _retry() {
    _changing(() {
      _failed = false;
      _isLoading = true;
      _sheets = 0;
    });
    _controller.loadRequest(_startUrl());
  }

  /// The close button: leaves whatever the page has open.
  void _close() => _leave();

  /// Takes this chat off the stack — only while it is the screen on top:
  /// whatever else the host has on the stack is theirs, and popping blindly
  /// could take one of their screens with it.
  void _leave() {
    _pendingBack?.cancel();
    _pendingBack = null;
    if (!mounted) {
      return;
    }
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      Navigator.of(context).pop();
    }
  }

  /// Android back over the chat (rule 10). The page can have a sheet open
  /// over the conversation — an item over the menu, the cart, a booking — and
  /// back is the customer closing THAT. The page's `KeydaBot.back()` takes off
  /// the top sheet and answers whether there was one; only "no", a page too
  /// old to answer, or no answer in time closes the chat.
  Future<void> _onBack() async {
    // Nothing the page drew can be open while it loads or after it failed.
    if (_failed || _isLoading) {
      _leave();
      return;
    }
    // A second press while the page is answering the first: that answer
    // decides.
    if (_pendingBack != null) {
      return;
    }
    final Timer timeout = Timer(_backAnswerTimeout, _leave);
    _pendingBack = timeout;
    bool handled = false;
    try {
      final Object result =
          await _controller.runJavaScriptReturningResult(_backScript);
      handled = result == true || result.toString() == 'true';
    } on Object catch (_) {
      // A page that cannot answer has nothing open that it could close.
    }
    if (!identical(_pendingBack, timeout)) {
      return; // the timeout already decided, or the chat was closed
    }
    timeout.cancel();
    _pendingBack = null;
    if (!handled) {
      _leave();
    }
  }

  @override
  void dispose() {
    _pendingBack?.cancel();
    keydaVisitor.removeListener(_applyVisitor);
    _setOnScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The host's Theme is deliberately NOT consulted for colours: the owner
    // chose the chat's theme in the dashboard, and a light host app must not
    // paint a light close bar over a dark chat (rule 7). The chrome takes its
    // colours from the same two backgrounds the page uses.
    final Brightness brightness = _brightness ?? Brightness.light;
    final bool dark = brightness == Brightness.dark;
    final Color background = dark ? _darkBackground : _lightBackground;
    final Color foreground = dark ? Colors.white : const Color(0xFF0B1220);

    final Widget chat = Stack(
      children: <Widget>[
        WebViewWidget(controller: _controller),
        if (_isLoading && !_failed)
          Center(
            child: CircularProgressIndicator(color: foreground),
          ),
        if (_failed)
          // Positioned.fill so the panel is given tight constraints and covers
          // the half-drawn page underneath it, instead of shrinking to its own
          // text.
          Positioned.fill(
            child: _LoadFailed(
              onRetry: _retry,
              background: background,
              foreground: foreground,
            ),
          ),
      ],
    );

    if (widget.embedded) {
      // In a screen of the host's: back closes a sheet the chat has open
      // (the page reports how many), and is the host's own back otherwise —
      // canPop is true then, so its navigator, predictive back included, is
      // untouched. No status-bar styling and no insets: the host lays this
      // out like any other widget.
      return PopScope<Object?>(
        // Not while another screen is in front: PopScope speaks for the whole
        // route, and the sheet it would close is in a chat nobody can see.
        canPop: !_canGoBack || !widget.focused,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop && _canGoBack && widget.focused) {
            unawaited(
              _controller
                  .runJavaScript(
                    '(function(){try{window.KeydaBot&&window.KeydaBot.back&&window.KeydaBot.back();}catch(e){}})()',
                  )
                  .catchError((Object _) {}),
            );
          }
        },
        child: ColoredBox(color: background, child: chat),
      );
    }

    // Status-bar icon brightness is the one piece of chrome the Scaffold
    // cannot paint: dark chat, light status-bar text and vice versa. The
    // AnnotatedRegion scopes it to this route, so the host's own status bar
    // style returns the moment the chat is dismissed.
    //
    // PopScope: system back asks the page first (_onBack). canPop stays false
    // so the route never pops on its own; KeydaBot.dismiss() and the close
    // button pop it directly.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          unawaited(_onBack());
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        child: Scaffold(
          // Without this the soft keyboard covers the message input: the WebView
          // keeps its full height, the page never learns the viewport shrank,
          // and the field it scrolls to sits under the keys.
          resizeToAvoidBottomInset: true,
          backgroundColor: background,
          body: SafeArea(
            // The page ships viewport-fit=cover and paints its own background to
            // the edges; these insets keep the input and the close button clear
            // of a notch, a punch-hole and the home indicator.
            child: Column(
              children: <Widget>[
                _CloseBar(onClose: _close, foreground: foreground),
                Expanded(child: chat),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseBar extends StatelessWidget {
  const _CloseBar({required this.onClose, required this.foreground});

  final VoidCallback onClose;

  /// Icon colour, from the chat's scheme rather than the host's IconTheme.
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    // The chat is presented full-screen: on iOS there is no back gesture off a
    // fullscreenDialog route, so without this button a customer who opens the
    // chat cannot get out of it.
    return SizedBox(
      height: 48,
      child: Align(
        alignment: Alignment.centerRight,
        child: IconButton(
          icon: const Icon(Icons.close),
          color: foreground,
          tooltip: 'Close chat',
          onPressed: onClose,
        ),
      ),
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({
    required this.onRetry,
    required this.background,
    required this.foreground,
  });

  final VoidCallback onRetry;
  final Color background;

  /// Text and icon colour matching [background]; the host's text theme would
  /// otherwise pick its own scheme's colour and vanish on the other one.
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    // Opaque, not translucent: a failed load leaves a half-drawn page behind,
    // and a customer must not be reading two states at once.
    return Container(
      color: background,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_off, size: 40, color: foreground),
          const SizedBox(height: 12),
          Text(
            'Chat could not load',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: foreground),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Check your internet connection and try again.',
            style: TextStyle(color: foreground),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onRetry,
            // Inverted on purpose: the one button on the panel should read as
            // the action, in either scheme, without leaning on the host theme.
            style: ElevatedButton.styleFrom(
              backgroundColor: foreground,
              foregroundColor: background,
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
