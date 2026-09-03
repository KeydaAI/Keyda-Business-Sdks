import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'client_id.dart';
import 'sdk_version.dart';

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
    super.key,
  });

  /// The `{baseUrl}/chat/{clientId}` URL built at init.
  final Uri chatUrl;

  /// Optional host handler for links that leave [chatUrl]'s origin.
  final KeydaExternalLinkHandler? onExternalLink;

  @override
  State<KeydaChatPage> createState() => _KeydaChatPageState();
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

class _KeydaChatPageState extends State<KeydaChatPage> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _failed = false;

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

  /// Answers the page's file request with photos from the system gallery.
  ///
  /// Photos only. image_picker is the picker the Flutter team publishes (rule
  /// 5 rules out the third-party ones) and it picks images; a request whose
  /// accept list names no image type — a documents-only input — is answered
  /// "nothing chosen", which the page treats as a cancel. The camera is not
  /// offered even when the page asks for capture: that would put the host
  /// app's CAMERA permission semantics in play, which no README here promises
  /// to handle. Nothing is ever thrown out of here — a tap that cannot be
  /// served is a cancel, not an exception in someone else's app (rule 6).
  Future<List<String>> _selectFiles(FileSelectorParams params) async {
    if (!_acceptsImages(params.acceptTypes)) {
      return const <String>[];
    }
    List<XFile> picked = const <XFile>[];
    try {
      final ImagePicker picker = ImagePicker();
      if (params.mode == FileSelectorMode.openMultiple) {
        picked = await picker.pickMultiImage();
      } else {
        final XFile? one = await picker.pickImage(source: ImageSource.gallery);
        picked = one == null ? const <XFile>[] : <XFile>[one];
      }
    } catch (error, stack) {
      // "already_active" when a second tap lands while the gallery is up, or
      // a device with no gallery app at all. Reported the way Flutter reports
      // any other failure; the page gets a cancel.
      _report(error, stack, 'picking a photo for the Keyda chat');
    }
    // The Android implementation parses each entry with Uri.parse and the
    // WebView reads the file from the app's own cache, where image_picker
    // put its copy. An empty list is the cancel.
    return picked
        .map((XFile file) => Uri.file(file.path).toString())
        .toList(growable: false);
  }

  /// Whether an accept list admits an image at all: an empty list, `*/*`, any
  /// `image/…` type or an image extension does; a list of document types
  /// alone does not.
  bool _acceptsImages(List<String> acceptTypes) {
    if (acceptTypes.isEmpty) {
      return true;
    }
    for (final String raw in acceptTypes) {
      final String type = raw.trim().toLowerCase();
      if (type.isEmpty || type == '*/*' || type.startsWith('image/')) {
        return true;
      }
      if (_imageExtensions.contains(type)) {
        return true;
      }
    }
    return false;
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
    await _controller.loadRequest(widget.chatUrl);
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
    setState(() {
      _isLoading = true;
      _failed = false;
    });
  }

  void _onPageFinished(String url) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
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
    setState(() {
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
    setState(() {
      _failed = false;
      _isLoading = true;
    });
    _controller.loadRequest(widget.chatUrl);
  }

  void _close() {
    // maybePop rather than pop: whatever else the host has on the stack is
    // theirs, and popping blindly could take one of their screens with it.
    Navigator.of(context).maybePop();
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

    // Status-bar icon brightness is the one piece of chrome the Scaffold
    // cannot paint: dark chat, light status-bar text and vice versa. The
    // AnnotatedRegion scopes it to this route, so the host's own status bar
    // style returns the moment the chat is dismissed.
    return AnnotatedRegion<SystemUiOverlayStyle>(
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
              Expanded(
                child: Stack(
                  children: <Widget>[
                    WebViewWidget(controller: _controller),
                    if (_isLoading && !_failed)
                      Center(
                        child: CircularProgressIndicator(color: foreground),
                      ),
                    if (_failed)
                      // Positioned.fill so the panel is given tight
                      // constraints and covers the half-drawn page underneath
                      // it, instead of shrinking to its own text.
                      Positioned.fill(
                        child: _LoadFailed(
                          onRetry: _retry,
                          background: background,
                          foreground: foreground,
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
