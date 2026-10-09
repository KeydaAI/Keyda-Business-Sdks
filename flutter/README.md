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

From [pub.dev](https://pub.dev/packages/keyda_bot):

```yaml
dependencies:
  keyda_bot: ^0.2.0
```

To build against an unreleased commit instead, point at this repository — the
package is its `flutter/` directory:

```yaml
dependencies:
  keyda_bot:
    git:
      url: https://github.com/KeydaAI/keyda-business-sdks.git
      path: flutter
```

Then `flutter pub get`. That resolves five packages — `webview_flutter` to
render the chat, `url_launcher` to hand a tapped link to the system browser,
`webview_flutter_android` for the one Android hook the shared WebView API does
not expose (the page's file chooser, see [Attachments](#attachments)), and
`image_picker` and `file_selector` to answer it — plus the Android and iOS implementation packages
they endorse. Every one of them is published by flutter.dev from the Flutter
team's own `flutter/packages` repository; there is no third-party code in this
SDK's dependency tree. Nothing else: no HTTP client, no analytics, no crash
reporter, nothing that reads a device identifier.

Needs Flutter 3.24 (Dart 3.5) or later. Android and iOS only. `webview_flutter` has no Flutter web implementation, so
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
| `KeydaBot.show(context, question: ..., onExternalLink: ...)` | Presents the chat full-screen, `question` in its message box (unsent). The future completes when it closes. A second call while it is open only puts its question in the box. |
| `KeydaBot.dismiss()` | Closes it. A no-op if nothing is showing. |
| `KeydaBot.isShowing` | Whether it is on screen — including after the customer left with the back gesture. |
| `KeydaBotChat(question: ..., focused: ...)` | The chat as a widget of your own screen (below). |
| `KeydaBot.setVisitor(name: ..., phone: ..., email: ...)` / `clearVisitor()` | Your signed-in customer, offered in the chat's forms (below). |
| `KeydaBot.hasUnreadReply` / `onReply` / `checkForReplies()` | A reply from the business the customer has not seen (below). |

`question` travels in the URL's #fragment, so it never reaches a server log;
the customer still taps send. Up to 500 characters, as one line: the chat
joins lines and collapses runs of spaces.

### The chat inside one of your own screens: `KeydaBotChat`

For a Help tab or a support screen, instead of the full-screen route:

```dart
Scaffold(
  appBar: AppBar(title: const Text('Help')),
  body: const SafeArea(top: false, child: KeydaBotChat(question: 'Is this in stock?')),
)
```

No close bar — your navigation is the way out — and no insets of its own: lay
it out in a `SafeArea`; a `Scaffold`'s `resizeToAvoidBottomInset` keeps it clear
of the keyboard. With a sheet open in the chat (an item, the cart, a booking)
back closes the sheet; otherwise it is your navigator's back, predictive back
included. `onCanGoBackChanged` says when a sheet is open. In a tab that stays
alive while another is selected (`IndexedStack`, a kept-alive `TabBarView`),
pass `focused: false` while it is not the selected one: `PopScope` speaks for
the whole route, so the chat would otherwise take back to close a sheet nobody
can see, and the chat then counts as off screen for `hasUnreadReply`.

### Your signed-in customer

```dart
KeydaBot.setVisitor(name: user.name, phone: user.phone, email: user.email); // any of them
KeydaBot.clearVisitor();                                                     // on sign-out
```

The chat then does not ask what your app already knows. The details are
**offered, never sent**: they appear in "talk to a person", an order, a
booking, and a welcome question for a name, a phone number or an email, and the
customer submits them. Until then nothing leaves the phone — they travel in the
URL's #fragment. They are your app's word, not a verified identity. A value
that does not look like what it claims is dropped whole, never cut: a name of
1–80 characters on one line, a phone number with 8–15 digits (and only spaces
and `+ - ( ) .` besides), an email address up to 254 characters. It applies to
the chats open now — including one still loading — and every one after.

### A reply while the chat is closed

A customer who asks for a person leaves their details and closes the chat; you
answer from the dashboard later. The chat shows the answer the next time it
opens. This tells your app it is there:

```dart
KeydaBot.onReply = () => debugPrint('new reply');   // once per new reply
ValueListenableBuilder<bool>(
  valueListenable: KeydaBot.hasUnreadReply,
  builder: (_, bool unread, __) => Badge(isLabelVisible: unread, child: const Icon(Icons.chat)),
)
```

The SDK asks when your app comes to the foreground — once a minute at most,
and only for chats in which the customer asked for a person in the last 14
days. `KeydaBot.checkForReplies()` asks now (once in 10 seconds at most).
`hasUnreadReply` stays true until the customer opens the chat, which shows the
reply. A `KeydaBotChat(focused: false)` still draws a reply in its hidden tab,
and that does not count as seen: the badge stays on, and `onReply` is called,
until the tab is selected. The list of chats to ask about is the page's own —
chat ids and times, kept with `shared_preferences`; nothing else is stored or
sent. There is no push: a reply is noticed when the app is opened.

There is no `sendMessage` and no `identify`. Those would need server support
that does not exist yet, and a method that half-works is worse than one that
is missing.

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

## Theme

The chat's theme — Match the visitor, Always light or Always dark — is set
once by the owner in the dashboard. The hosted page resolves it and reports it
to this package, which repaints its own chrome to match: the status-bar icons,
the close button, the loading cover and the retry screen (dark `#0b1220` /
light `#f7f8fc`, the page's own backgrounds). Until the page reports, the
chrome follows the device scheme, which is what "Match the visitor" means
anyway. There is no theme parameter on `KeydaBot.show` and no plan for one:
the host app does not get to contradict the owner.

## Attachments

If the bot's chat offers an attach button, tapping it opens a picker.

On **Android** that took code, and it is why this package names
`webview_flutter_android`, `image_picker` and `file_selector` in its pubspec:
the shared `WebViewController` has no hook for a page's file chooser, and
without one the tap did nothing at all in every version before 0.1.4. An input
that takes only images opens the system photo picker; one that takes documents
too — the chat's own attach button does, PDF, DOCX, TXT, CSV and MD — opens
the system's file picker, where the customer can reach photos and documents
alike (from 0.2.0; 0.1.4 offered photos only). No permission is requested, on
any supported version. The camera is not offered: reaching it would put your
app's CAMERA permission in play, which this package will not do behind your
back.

On **iOS** WebKit presents the picker itself and there is nothing here to
switch on — but there is one key your app must carry:

```xml
<key>NSCameraUsageDescription</key>
<string>Attach a photo to your support conversation.</string>
```

Add it whether or not you expect the camera to be used. WebKit's upload sheet
offers **Take Photo or Video** for any input that accepts images, the page
cannot suppress the option, and iOS terminates an app that reaches the camera
with no usage description — mid-conversation, in front of the customer. Add
`NSMicrophoneUsageDescription` too if the chat accepts video. The photo library
itself needs no key.

Nothing in this package reads a chosen file. It goes straight from the picker
to the hosted page's own upload, exactly as it would in a browser.

## Inside the chat

All of this is the hosted page's, so it reaches your app without an SDK update:

* **A welcome message with suggestion buttons**, in the language the bot is set to; the header
  says "AI assistant".
* **The conversation is kept on the device for 24 hours**, and the chat makes no visitor id.
  (On a website a conversation lasts one browser tab.)
* **Orders and bookings**, when the business takes them: a cart, booking dates and times, a
  link to call the business when an order or booking has waited too long, and "Add to
  calendar" for a confirmed booking.
* **Attachments**: photos (JPEG, PNG, WebP, GIF) and PDF, DOCX, TXT, CSV and MD files (documents
  on Android from 0.2.0).
* **Links leave the chat**: `tel:` opens the dialer, `mailto:` the mail app, and web links the
  browser.
* **"Add to calendar" is a link to an `.ics` file.** iOS opens it in Calendar as a calendar to
  subscribe to, so the booking arrives as a small calendar of its own rather than as one event
  in yours. Android offers the phone's calendar app when that app imports `.ics` files — current
  Google Calendar does — and otherwise the browser downloads the file.

## Limitations

Stated plainly, because finding these out later is worse:

- **Not offline.** It is a hosted page. No connection, no chat — a failed load
  shows a retry button, never an exception into your app.
- **No push notifications.** A reply that arrives while your app is closed is
  noticed when the app is next opened (`onReply`, above), not before.
- **No theme API.** The theme and accent the dashboard controls are the
  theming; the package's own chrome follows the page (see Theme above) and
  cannot be overridden from the host app.
- **Conversation continuity depends on DOM storage** — the page remembers the
  visitor there. `webview_flutter`'s Android and iOS WebViews enable it by
  default and this package never disables it, but clearing the app's data
  starts a new conversation.
- **A tapped link leaves your app.** Other-origin links open in the system
  browser, not in a sheet over the chat. The conversation is untouched and
  waiting when the customer switches back, but the switch is theirs to make.
- **On Android the file picker reads the chosen file into memory** before the
  chat sees it (that is how `file_selector` hands it over). The chat takes
  files up to 10 MB; a much larger one is slow to refuse and, on a phone short
  of memory, can fail.
- **No camera in the Android picker.** Photos and documents come from the
  photo picker and the file picker. See [Attachments](#attachments) — and note
  the one `Info.plist` key an iOS host must add, without which iOS kills the
  app when a customer taps "Take Photo or Video" in WebKit's own sheet.
- **One chat at a time**, presented on the root navigator.
- **Back on Android closes the sheet on top first** — an item, the cart, a
  booking — and the chat only when none is open. A page too old to answer, or
  one that does not answer within half a second, closes the chat. The close
  button always closes it at once, and the conversation is restored on the
  next `show`.
- **No analytics, no device identifiers**, nothing sent anywhere except the
  chat page's own requests to your `baseUrl` and the reply check, which asks
  the same server for new rows in the chats the page is waiting on (a
  conversation id and a time; no cookie, no identifier).

## Tests

`flutter test` covers the parts that decide what a customer sees: client id
validation, chat URL building, the same-origin rule that keeps a
"Powered by Keyda" tap from replacing a live conversation, the visitor's
rules, and the reply check against a stand-in server.

## Licence

MIT — see [LICENSE](../LICENSE) at the root of this repository.
