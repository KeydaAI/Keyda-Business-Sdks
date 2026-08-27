import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'client_id.dart';

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
    // no switch for it, and the only way to reach one is to import
    // webview_flutter_android directly — a second dependency this package will
    // not take. Both endorsed implementations enable it, and the visitor's
    // conversation survives an app restart because they do; nothing here turns
    // it off.
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
      )
      ..loadRequest(widget.chatUrl);
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
        _report(error, stack);
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
      _report(error, stack);
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

  void _report(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'keyda_bot',
        context: ErrorDescription('opening a link from the Keyda chat'),
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
