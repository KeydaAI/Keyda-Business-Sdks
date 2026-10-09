# Changelog — @keyda/bot-react-native

## 0.2.0 — unreleased

* **`<KeydaBotChat />`: the chat inside one of your own screens.** A view, not
  a modal — no close button, keyboard handled from where it sits on screen. On
  Android, back closes a sheet the chat has open before your app's own back
  sees it; `onCanGoBackChange` says when one is open.
* **Open with a question:** a `question` prop on `<KeydaBot />` and
  `useKeydaBot().show("Is this in stock?")`. It goes in the message box,
  unsent (in the URL's #fragment, never in a server log); a new question with
  the chat open replaces the text.
* Android, landscape phones: the chat and its close button keep 48dp clear on
  both sides — where a three-button navigation bar or a camera cutout can be;
  core React Native reports neither. The navigation bar's height is learned only
  from a keyboard as wide as the screen (beside a side bar it read 0), and a
  keyboard still up when the chat closed no longer leaves a blank band under
  the next one.

* **Fixed: a long question could crash the app.** A question cut at 500 UTF-16
  units could end in half an emoji, and `encodeURIComponent` threw from inside
  render, taking the host's React tree down. Cut at 500 whole characters now,
  lone halves dropped, and the encoding can no longer throw.
* **Your signed-in customer:** a `visitor` prop on `<KeydaBot />` and
  `<KeydaBotChat />`. Offered — never sent — in "talk to a person", an order, a
  booking and a welcome question for a name, phone or email; the customer
  submits them. In the URL's #fragment; a change — even one made while the chat
  loads, or a Retry — reaches a chat already open. A value that does not look
  right is dropped whole, never cut: name 1–80 characters, phone 8–15 digits,
  email up to 254 characters.
* **A reply while the chat is closed:** `useKeydaBotReplies(clientId, {storage,
  onReply})` returns `{hasUnreadReply, checkForReplies}`. Asked when the app
  comes to the foreground (once a minute at most), only for chats in which the
  customer asked for a person in the last 14 days. No dependency added: pass
  AsyncStorage (or anything with its `getItem`/`setItem`) to keep watching
  across restarts. A chat in a tab that is not selected
  (`<KeydaBotChat focused={false}>`) does not count as seen: a reply it draws
  out of sight keeps the dot on and calls `onReply`.
* `<KeydaBotChat focused>`: a chat mounted in a tab that is not selected, or
  under another screen, leaves Android's back to your app instead of closing a
  sheet nobody can see.
* `useKeydaBot().show()` with the same question again puts it back in the box.
  A retry no longer brings back a question the customer already sent.
* The navigation bar's height is no longer taken as 0 when the app was launched
  in landscape.
* 0.1.5 was never released; everything prepared for it ships in this version.

* **Android 15+ edge-to-edge apps: nothing under the status bar, the navigation
  bar or the keyboard.** React Native 0.81+ draws a `Modal` under both system
  bars in an app that targets Android 15 or later — every app Google Play
  accepts now targets 16 — and the window stops resizing for the keyboard. On
  an Android 16 phone the close button sat in the status bar, "Powered by
  Keyda" under the gesture bar, and the keyboard covered the message box. The
  container now pads for all three; measured, so an app that is not
  edge-to-edge is unchanged. No dependency added.
* **Android back closes what the customer is looking at first** — the sheet
  the chat has open (an item, the cart, a booking) — and closes the chat only
  when nothing was open (CONTRACT rule 10). A page from before October 2026
  has no `back()`; the chat then closes as it always did.
* **The app's status bar comes back as it was.** When the chat closed, React
  Native re-applied its default bar style, which on Android is light icons: in
  an edge-to-edge app that never styled its bar, the time and battery went
  white on white. Restored to the app's own look; an app that sets a style
  itself is left alone.
* **No deprecation warning over the message box in Android development
  builds.** Core `SafeAreaView` is only read on iOS now (on Android it pads
  nothing). iOS development builds still show React Native's one-time warning
  about it; see Limitations in the README.
* The WebView's User-Agent carries `KeydaBot/<version> (ReactNative)`, as the
  Android and Flutter SDKs mark theirs — a version and nothing else. On
  Android the page reads it to know this shell keeps the chat clear of the
  system bars.
* **The loading cover covers again on React Native 0.87**, which removed
  `StyleSheet.absoluteFillObject`; spread from undefined, the cover lost its
  position and a white first frame showed through.
* Works with `react-native-webview` 13 and 14 alike: the WebView ref is typed by
  the one method it uses, as the two lines type it differently.
* Checked with React Native 0.87.1 (New Architecture) on an Android 16 phone,
  Android 15 and 16 tablets, an iPhone 17 Pro and an iPad Pro (iOS 26.5); and
  in Expo SDK 57 — Expo Go and a development build — on iOS and Android, with
  `react-native-webview` 13.16.1.

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
