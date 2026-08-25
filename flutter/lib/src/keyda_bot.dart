import 'package:flutter/material.dart';

import 'chat_page.dart';
import 'client_id.dart';

/// The whole public surface of the Keyda Business SDK for Flutter.
///
/// Configure once, present when the customer asks for help, close it again:
///
/// ```dart
/// KeydaBot.init('kb_live_9f2c41ab');            // once, e.g. in main()
/// KeydaBot.show(context);                       // on a "Chat with us" tap
/// ```
///
/// There is no message API, no unread count and no identify call, because
/// there is nothing behind them yet — see CONTRACT.md.
class KeydaBot {
  // Static-only: the chat is a single presentation over the host app, and an
  // instance would suggest two of them could exist.
  KeydaBot._();

  static Uri? _chatUrl;
  static NavigatorState? _navigator;
  static Route<void>? _route;
  static bool _isShowing = false;

  /// Whether the chat is on screen right now.
  ///
  /// Stays truthful when the customer leaves with the Android back gesture,
  /// not only when [dismiss] is called.
  static bool get isShowing => _isShowing;

  /// Stores the configuration and validates it immediately.
  ///
  /// [clientId] is the `kb_live_...` id from **Install** in the Keyda Business
  /// dashboard. [baseUrl] only changes for staging or a self-hosted install —
  /// give it as an origin (`https://staging.example.com`), optionally with a
  /// path prefix.
  ///
  /// Throws [KeydaBotConfigError] straight away if either is malformed. That
  /// is deliberate: a bad id discovered here costs a rebuild, and discovered
  /// in production shows a customer a 404 where the chat should be. Calling
  /// [init] again replaces the configuration; it does not affect a chat that
  /// is already on screen.
  static void init(String clientId, {String baseUrl = kKeydaDefaultBaseUrl}) {
    _chatUrl = buildChatUrl(clientId: clientId, baseUrl: baseUrl);
  }

  /// Presents the chat full-screen over the host app.
  ///
  /// The returned future completes when the chat is closed — by [dismiss], by
  /// the close button, or by the system back gesture. Awaiting it is optional.
  ///
  /// Links that leave the chat's own origin (the "Powered by Keyda" link,
  /// `mailto:`, `tel:`, WhatsApp or UPI deep links) are never followed inside
  /// the WebView — that would replace the customer's conversation with a page
  /// they have no way back from. By default they are opened in the system
  /// browser. [onExternalLink] takes that over, for a host app that wants to
  /// route links itself.
  ///
  /// Throws [StateError] if [init] has not been called.
  static Future<void> show(
    BuildContext context, {
    KeydaExternalLinkHandler? onExternalLink,
  }) async {
    final Uri? chatUrl = _chatUrl;
    if (chatUrl == null) {
      throw StateError(
        'KeydaBot.show() was called before KeydaBot.init(). Call '
        "KeydaBot.init('kb_live_...') once at startup.",
      );
    }
    if (_isShowing) {
      // A second tap on the launcher while the chat is opening would stack a
      // second WebView on the first, and closing once would look like nothing
      // happened.
      return;
    }

    // rootNavigator: a chat pushed inside a tab's nested navigator keeps the
    // host's tab bar drawn over it, which is exactly where the keyboard and
    // the message input want to be.
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    final MaterialPageRoute<void> route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (BuildContext _) => KeydaChatPage(
        chatUrl: chatUrl,
        onExternalLink: onExternalLink,
      ),
    );

    _navigator = navigator;
    _route = route;
    _isShowing = true;
    try {
      await navigator.push(route);
    } finally {
      // Cleared here rather than inside dismiss(), because the customer can
      // also leave with the back gesture; state is reset on every exit path.
      // The identity check keeps a slow teardown from clearing a newer chat.
      if (identical(_route, route)) {
        _isShowing = false;
        _route = null;
        _navigator = null;
      }
    }
  }

  /// Closes the chat if it is open.
  ///
  /// Safe to call when nothing is showing; that is a no-op, not an error.
  /// The conversation itself survives — it lives in the page's DOM storage and
  /// comes back on the next [show].
  static void dismiss() {
    final NavigatorState? navigator = _navigator;
    final Route<void>? route = _route;
    if (navigator == null || route == null) {
      return;
    }
    if (route.isCurrent) {
      navigator.pop();
    } else if (route.isActive) {
      // The host pushed one of their own screens over the chat. Popping would
      // close theirs; removing takes only ours out of the stack.
      navigator.removeRoute(route);
    }
  }
}
