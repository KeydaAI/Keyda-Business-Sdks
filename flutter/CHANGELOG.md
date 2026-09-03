# Changelog

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
