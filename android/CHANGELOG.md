# Changelog — in.keyda:keyda-bot

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
