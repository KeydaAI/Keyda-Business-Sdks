# keyda_bot

**This package is a WebView wrapper.** It opens one hosted page —
`https://keyda.in/business/chat/{your-client-id}` — full-screen over your
Flutter app. There is no native Dart chat UI in here, and there will not be
one.

That is the design, not a shortcut. Every Keyda surface (the website widget,
Android, iOS, this) loads the same page, so when an owner changes their
welcome message or their accent colour in the dashboard it is live everywhere
at once, with no app release. A native chat screen per platform would be
another place for a fix to land and another release to wait for. The cost is
real and it is yours to weigh: this is a web page, so it needs a connection,
and it will never feel like hand-built Flutter. Decide that before you ship,
not after — which is why it is the first line of this README.

The full reasoning, shared by every SDK in this repository, is in
[CONTRACT.md](../CONTRACT.md).

## Install

Not on pub.dev yet. Add it from this repository — the package is the
`flutter/` directory:

```yaml
dependencies:
  keyda_bot:
    git:
      url: <the clone URL of this repository>
      path: flutter
```

Then `flutter pub get`. That resolves two packages — `webview_flutter` to
render the chat and `url_launcher` to hand a tapped link to the system
browser — plus the Android and iOS implementation packages they endorse.
Every one of them is published by flutter.dev from the Flutter team's own
`flutter/packages` repository; there is no third-party code in this SDK's
dependency tree. Nothing else: no HTTP client, no analytics, no crash
reporter, nothing that reads a device identifier.

Android and iOS only. `webview_flutter` has no Flutter web implementation, so
Flutter web is out; desktop depends entirely on whether `webview_flutter`
supports it, and nothing in this package has been tested there.

Get your client id from **Install** in the
[Keyda Business dashboard](https://keyda.in/business/app/). It looks like
`kb_live_` followed by 8–48 lowercase hex characters.

## Use

```dart
import 'package:keyda_bot/keyda_bot.dart';

void main() {
  // Throws immediately if the id is malformed — better here than in front of
  // a customer.
  KeydaBot.init('kb_live_9f2c41ab7d3e');
  runApp(const MyApp());
}
```

Then, wherever your "Chat with us" affordance lives:

```dart
FloatingActionButton(
  onPressed: () => KeydaBot.show(context),
  child: const Icon(Icons.chat_bubble_outline),
)
```

That is the whole API:

| Call | What it does |
|---|---|
| `KeydaBot.init(clientId, baseUrl: ...)` | Stores and validates the configuration. Throws `KeydaBotConfigError` on a malformed id or base URL. |
| `KeydaBot.show(context, onExternalLink: ...)` | Presents the chat full-screen. The future completes when it closes. A second call while it is open does nothing. |
| `KeydaBot.dismiss()` | Closes it. A no-op if nothing is showing. |
| `KeydaBot.isShowing` | Whether it is on screen — including after the customer left with the back gesture. |

There is no `sendMessage`, no unread count and no `identify`. Those would need
server support that does not exist yet, and a method that half-works is worse
than one that is missing.

## baseUrl

`init` defaults to `https://keyda.in/business`. Override it for staging or a
self-hosted install:

```dart
KeydaBot.init('kb_live_9f2c41ab7d3e', baseUrl: 'http://10.0.2.2:8080');
```

Give an origin, optionally with a path prefix
(`https://acme.example/support`). A query string or `#fragment` is rejected,
because appending the chat path would silently drop it.

Point it at the **final** origin. The SDK treats anything outside that exact
scheme + host + port as a link out of the chat, so a `baseUrl` that redirects
across origins (apex → `www.`, for instance) will be blocked rather than
followed.

An `http://` base URL is accepted here but blocked by both platforms: Android
refuses cleartext traffic from apps targeting API 28 and above, and iOS
refuses it under App Transport Security. The chat will show its retry screen
and never load. If you need a plain-HTTP staging server, the exemption is
yours to add and yours to keep out of a release build —
`android:usesCleartextTraffic="true"` (or a `network_security_config`) on
Android, an ATS exception in `Info.plist` on iOS. `https://` needs neither.

## Links out of the chat

The chat page carries real links: a "Powered by Keyda" link, and whatever the
owner put in their answers — a `mailto:`, a `tel:`, a `wa.me` or UPI link if
that is how their customers reach them.

**Any navigation to a different origin is blocked inside the chat WebView.**
If it were followed in place, the customer's conversation would be replaced by
a marketing site with no way back to it.

Blocking is only half an answer, so **the URL is opened in the system browser
instead** — the same thing the Android, iOS and React Native SDKs do. The
conversation stays exactly where it was, and the customer comes back to it.

If nothing on the device can open the link (a `tel:` on a tablet with no
dialer, say), the customer is told so and the chat stays up. Nothing is ever
thrown into your app, and nothing is written to their clipboard.

To route links yourself — into your own in-app browser, or nowhere at all —
pass a handler. It replaces the default entirely:

```dart
KeydaBot.show(
  context,
  onExternalLink: (Uri url) async {
    // your in-app browser, your allow list, or an empty body to ignore links
  },
);
```

Sub-frames are left alone — an iframe cannot replace the conversation, and
blocking those would only leave empty boxes.

## Keyboard and safe areas

The chat page is hosted in a `Scaffold` with `resizeToAvoidBottomInset: true`
inside a `SafeArea`, which is what keeps the soft keyboard off the message
input and the input off the home indicator.

One thing that is outside this package's reach: if your `AndroidManifest.xml`
sets `android:windowSoftInputMode="adjustPan"`, the window slides instead of
resizing, the WebView never learns the viewport shrank, and the keyboard will
cover the input. Flutter's default (`adjustResize`) is what you want.

## Limitations

Stated plainly, because finding these out later is worse:

- **Not offline.** It is a hosted page. No connection, no chat — a failed load
  shows a retry button, never an exception into your app.
- **No push notifications.** A reply that arrives while the chat is closed is
  waiting when it reopens; nothing notifies the customer.
- **No native theming.** The accent the dashboard controls is the theming. The
  only Flutter chrome here is a close button and the retry screen.
- **Conversation continuity depends on DOM storage** — the page remembers the
  visitor there. `webview_flutter`'s Android and iOS WebViews enable it by
  default and this package never disables it, but clearing the app's data
  starts a new conversation.
- **A tapped link leaves your app.** Other-origin links open in the system
  browser, not in a sheet over the chat. The conversation is untouched and
  waiting when the customer switches back, but the switch is theirs to make.
- **One chat at a time**, presented on the root navigator.
- **Android back closes the chat** rather than stepping through the page's own
  history. The conversation is restored on the next `show`.
- **No analytics, no device identifiers**, nothing sent anywhere except the
  chat page's own requests to your `baseUrl`.

## Tests

`flutter test` covers the parts that decide what a customer sees: client id
validation, chat URL building, and the same-origin rule that keeps a
"Powered by Keyda" tap from replacing a live conversation.

## Licence

MIT — see [LICENSE](../LICENSE) at the root of this repository.
