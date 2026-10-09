# Changelog


## 0.2.0 — unreleased

- **`KeydaBotChat`: the chat inside one of your own screens.** A widget with no
  close bar; lay it out in a `SafeArea` like any other. With a sheet open in the
  chat (an item, the cart, a booking) back closes the sheet; otherwise it is
  your navigator's back, predictive back included. `onCanGoBackChanged` says
  when one is open.
- **Open with a question:** `KeydaBot.show(context, question: 'Is this in
  stock?')` puts it in the message box, unsent (in the URL's #fragment, never in
  a server log); a second call with the chat open replaces the text.

- **Your signed-in customer:** `KeydaBot.setVisitor(name:, phone:, email:)` and
  `clearVisitor()`. Offered — never sent — in "talk to a person", an order, a
  booking and a welcome question for a name, phone or email; the customer
  submits them. In the URL's #fragment, never in a server log; a change — even
  one made while the chat loads, or a Retry — reaches a chat already open. A
  value that does not look right is dropped whole, never cut: name 1–80
  characters, phone 8–15 digits, email up to 254 characters.
- **A reply while the chat is closed:** `KeydaBot.hasUnreadReply` (a
  `ValueListenable<bool>`), `KeydaBot.onReply` and `KeydaBot.checkForReplies()`.
  Asked when the app comes to the foreground (once a minute at most), only for
  chats in which the customer asked for a person in the last 14 days. Adds
  `shared_preferences` (flutter.dev) to remember the list across restarts.
  Opening the chat clears it at once. A `KeydaBotChat(focused: false)` in a tab
  that is not selected does not count as seen: a reply it draws out of sight
  keeps the badge on and calls `onReply`.
- `KeydaBotChat(focused:)`: a chat kept alive in a tab that is not selected
  leaves back to your navigator instead of closing a sheet nobody can see.
- A second `show(question:)` is no longer undone by a rebuild of your
  navigator putting the first question back over it.
- `onCanGoBackChanged` now also reports a load, a failure and a retry. Retry
  really loads again and does not bring back a question already sent.
- A question is cut at 500 whole characters, never through an emoji, and a
  lone half of one is left out rather than sent as "�".
- 0.1.5 was never released; everything prepared for it ships in this version.

- **Documents can be attached on Android.** The chat takes PDF, DOCX, TXT, CSV
  and MD as well as photos, and until now every request was answered with the
  photo gallery or nothing. An input that accepts only images still opens the
  photo picker (`image_picker`); one that accepts anything else opens the
  system's file picker through `file_selector` — published by flutter.dev from
  the same `flutter/packages` repository as the other four, needing no
  permission. iOS is unchanged: WebKit opens its own picker.
- **Android back closes what the customer is looking at first** — the sheet the
  chat has open (an item, the cart, a booking) — and pops the chat only when
  nothing was open (CONTRACT.md rule 10). A page from before October 2026 has
  no `back()`; the chat then closes as it always did. The close button still
  closes the chat at once.
- Requires Flutter 3.24 / Dart 3.5 (was 3.10 / 3.0), for `PopScope`'s
  `onPopInvokedWithResult`.
- Checked with Flutter 3.47 on an Android 16 phone, Android 15 and 16 tablets,
  an iPhone 17 Pro and an iPad Pro (iOS 26.5): portrait, landscape, dark, the
  keyboard, back over one and two sheets, and a PDF picked and sent.

## 0.1.4 — 2026-09-03

- **The chat's attach button opens a picker on Android** (CONTRACT.md rule 9).
  The shared `WebViewController` has no hook for a page's file chooser and
  webview_flutter's stock chrome client refuses it, so the tap did nothing at
  all before this release. The page's request is now answered through
  `AndroidWebViewController.setOnShowFileSelector` with photos from the system
  gallery. iOS needed no change — WebKit presents its own picker.
- Two dependencies added for that, both published by flutter.dev from the same
  `flutter/packages` repository the framework ships from, so the "no
  third-party code" promise stands: `webview_flutter_android` (already
  resolved transitively; naming it makes the import legal) and `image_picker`.
- Photos only, and deliberately: an input that accepts no image type is
  answered as a cancel rather than with the wrong file, and the camera is not
  offered, because reaching it would put the host app's CAMERA permission in
  play. A picker that will not open is reported through `FlutterError` and
  answered as a cancel; nothing is thrown into the host app (rule 6).
- The chat's User-Agent now carries `KeydaBot/<version> (Flutter)`, the same
  signal the Android SDK sends, so the hosted page can tell a shell that will
  answer its file chooser from one that will not. A version and nothing else —
  no device identifier — appended to the platform's own User-Agent rather than
  replacing it.
- README: an Attachments section, including the `NSCameraUsageDescription` key
  an iOS host app must add or be killed when a customer taps "Take Photo or
  Video" in WebKit's own sheet.

## 0.1.3 — 2026-08-27

- Light and dark: the chrome follows the owner's dashboard Theme setting
  (CONTRACT.md rule 7). The hosted page reports its resolved theme over a
  `KeydaBotFlutter` JavaScript channel, and the status-bar icons, the close
  button, the loading cover and the retry screen switch with it — including
  live, when a "Match the visitor" bot flips with the OS. Until the page
  reports (or against a backend that predates the message) the chrome follows
  the device scheme. Malformed or foreign messages on the channel are ignored.
- The retry screen and close button no longer take colours from the host
  app's `Theme`, so a light host over a dark chat (or the reverse) no longer
  paints contradicting chrome.
- Example app: shape-valid placeholder client id so it runs as shipped.

## 0.1.2

- Version alignment across every Keyda Business SDK; no code changes.
- All chat features ship server-side (rendered answers with working links,
  the in-thread "Talk to a person" form, the improved greeting) and reach
  this package without an update — this release aligns versions and docs.

## 0.1.0

First release.

- `KeydaBot.init`, `show`, `dismiss`, `isShowing`.
- Opens `{baseUrl}/chat/{clientId}` full-screen in a WebView; `baseUrl`
  defaults to `https://keyda.in/business` and is overridable.
- Client ids are validated at `init` and a malformed one throws there.
- Navigation off the chat's origin never happens inside the WebView; the URL
  is opened in the system browser instead. `onExternalLink` replaces that
  default for a host app that wants to route links itself.
- Failed loads show a retry, not an exception.
