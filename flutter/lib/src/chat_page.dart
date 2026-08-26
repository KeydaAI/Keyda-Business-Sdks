import 'package:flutter/material.dart';
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

class _KeydaChatPageState extends State<KeydaChatPage> {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _failed = false;

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
      // The WebView's own default is transparent, which renders as a black
      // rectangle for the moment before the page paints. Chat pages are light.
      ..setBackgroundColor(Colors.white)
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
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      // Without this the soft keyboard covers the message input: the WebView
      // keeps its full height, the page never learns the viewport shrank, and
      // the field it scrolls to sits under the keys.
      resizeToAvoidBottomInset: true,
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        // The page ships viewport-fit=cover and paints its own background to
        // the edges; these insets keep the input and the close button clear of
        // a notch, a punch-hole and the home indicator.
        child: Column(
          children: <Widget>[
            _CloseBar(onClose: _close),
            Expanded(
              child: Stack(
                children: <Widget>[
                  WebViewWidget(controller: _controller),
                  if (_isLoading && !_failed)
                    const Center(child: CircularProgressIndicator()),
                  if (_failed)
                    // Positioned.fill so the panel is given tight constraints
                    // and covers the half-drawn page underneath it, instead of
                    // shrinking to its own text.
                    Positioned.fill(
                      child: _LoadFailed(
                        onRetry: _retry,
                        background: theme.colorScheme.surface,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseBar extends StatelessWidget {
  const _CloseBar({required this.onClose});

  final VoidCallback onClose;

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
          tooltip: 'Close chat',
          onPressed: onClose,
        ),
      ),
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry, required this.background});

  final VoidCallback onRetry;
  final Color background;

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
          const Icon(Icons.cloud_off, size: 40),
          const SizedBox(height: 12),
          Text(
            'Chat could not load',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            'Check your internet connection and try again.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
