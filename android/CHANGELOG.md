# Changelog — in.keyda:keyda-bot

## 0.1.4 — 2026-09-03

* **The chat's attach button opens a picker** (CONTRACT rule 9). Until now
  there was no `WebChromeClient` on the WebView at all, so Android had nobody
  to hand an `<input type="file">` to and the tap did nothing — no picker, no
  error, nothing the customer could tell apart from a frozen app.
  `KeydaBotActivity` now answers `onShowFileChooser` with the system chooser
  built from the page's own `accept` list and `multiple` attribute
  (`FileChooserParams.createIntent()`), and reads the result from the Intent's
  `ClipData` so a multiple selection arrives whole —
  `FileChooserParams.parseResult()` would have returned the first file and
  dropped the rest silently.
* Every exit path answers the page's file request, including a cancel, a
  second tap while a chooser is open, a chooser that will not start, and the
  Activity being destroyed. An unanswered request leaves the WebView believing
  a chooser is still open, and it then ignores the attach button for the rest
  of the conversation.
* A device with nothing that can pick a file gets the same treatment as a
  device with no browser: a toast, and the conversation left untouched.
  Nothing is thrown out of a WebView callback into the host app (rule 6).
* No new permission, no `<queries>`, no content provider and no resources —
  the gallery and documents providers need none of that. There is deliberately
  no camera path: it would need a FileProvider inside this AAR and would drag
  the host app's CAMERA permission in with it. README's "No file picker"
  limitation is replaced by "No camera in the picker", and the compiled-in
  English strings go from six to seven.
* iOS, React Native and Capacitor hosts need no update for this; their web
  views have always answered. An iOS app **must** carry
  `NSCameraUsageDescription`, though — see CONTRACT rule 9.

## 0.1.3 — 2026-08-27

* Theme (CONTRACT rule 7): the chrome around the chat follows the owner's
  dashboard Theme setting. The hosted page announces its resolved theme
  through a one-method JavaScript bridge, `window.KeydaBotNative.onTheme`,
  and `KeydaBotActivity` paints its window, the WebView's first-paint
  colour, the status and navigation bars (with legible icons per version),
  the spinner and the retry screen to match — `#0b1220` dark, `#f7f8fc`
  light, the retry button in the owner's accent. Until the page reports, the
  screen follows the device's dark mode. Messages that are not exactly
  `keyda:theme` are ignored; a malformed one is logged and dropped, never
  thrown into the host. The three hard-coded white backgrounds are gone.
* On Android 10+ the Activity switches itself to the platform
  `Theme.DeviceDefault.DayNight` at runtime (the manifest keeps the Light
  theme, the only one every supported version has, and the AAR still ships
  no resources). Without it the WebView reports `prefers-color-scheme:
  light` to a "Match the visitor" bot on a dark phone.
* `consumer-rules.pro` keeps `@JavascriptInterface` methods, so R8 in the
  consuming app cannot strip the bridge.
* Kotlin `apiVersion`/`languageVersion` pinned to 1.9 so an app on a Kotlin
  1.9 compiler can read the AAR's metadata (uncommitted since 0.1.2).
* README: the JitPack coordinate resolves; a "Theme" section; the
  `kotlin-stdlib` POM dependency stated plainly.

## 0.1.2 — 2026-08-26

Versions across every Keyda SDK aligned on 0.1.2. Default `baseUrl` moved
from the retired `business.keyda.in` host to `https://keyda.in/business`.

## 0.1.0 — 2026-08-25

First release: `KeydaBot.init`, `show`, `dismiss`, `isShowing`; full-screen
WebView with links routed to the system browser, keyboard and safe-area
handling, and a retry screen for every failure mode.
