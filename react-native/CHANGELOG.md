# Changelog — @keyda/bot-react-native

## 0.1.4 — 2026-09-03

* No code change. Version aligned with the rest of the Keyda SDKs, which grew
  file-chooser support this release (CONTRACT rule 9); `react-native-webview`
  has implemented Android's `onShowFileChooser` for years and WebKit answers
  on iOS, so the chat's attach button already opens a picker here.
* **README: "Text only… asks for no camera, microphone or storage permission"
  is gone**, because it stopped being true the moment the hosted chat grew an
  attach button — and it would have gone stale with no release of this package
  at all. In its place, an Attachments section with the host app's real
  obligations: `NSCameraUsageDescription` in the iOS `Info.plist` (WebKit's
  upload sheet offers "Take Photo or Video" for image inputs, and iOS
  terminates an app that reaches the camera without the key),
  `NSMicrophoneUsageDescription` for video, an Android `<queries>` entry for
  `android.media.action.IMAGE_CAPTURE` if the page asks to capture, and the
  declared-but-ungranted `CAMERA` trap. This package still declares no
  permission, requests none, and never reads a chosen file.

## 0.1.3 — 2026-08-27

* Theme bridge (CONTRACT.md rule 7): the hosted page resolves the owner's
  dashboard Theme setting (Match the visitor / Always light / Always dark) and
  posts `{"type":"keyda:theme","mode":…}` to the shell; the status-bar text,
  close button, loading cover and retry screen now follow the page instead of
  the OS. Until the page reports — and against a backend that predates the
  message — the container follows `useColorScheme()`. The override is dropped
  when the modal closes so a stale scheme cannot leak into the next open.
  Anything on the message channel that is not a well-formed `keyda:theme`
  message is ignored; malformed JSON never reaches the host.
* Dark cover colour is now `#0b1220`, the page's own dark `<html>` background,
  so the loading cover matches the page's first paint rather than the panel
  colour behind it.
* Light and dark at all: the container previously ran light only. The README
  no longer claims "light only".
* Peer floor raised to `react-native-webview >=13.3.0`, the first release that
  has `onOpenWindow`, which this SDK relies on for `target="_blank"` links.
* Documented the core `SafeAreaView` deprecation warning and why it stays.

## 0.1.2 — 2026-08-26

First release on npm. Versions across every Keyda SDK aligned on 0.1.2.

* Default `baseUrl` moved from the retired `business.keyda.in` host to
  `https://keyda.in/business`. Integrators on 0.1.0 source get a dead URL.
* `LICENSE` ships inside the package (the root licence never reached npm).

## 0.1.0 — 2026-08-25

First release, source only (not published to npm): `<KeydaBot />`,
`useKeydaBot`, `buildChatUrl`, `isValidClientId`.
