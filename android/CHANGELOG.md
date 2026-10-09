# Changelog — in.keyda:keyda-bot


## 0.2.0 — unreleased

* **The chat inside one of your own screens: `KeydaBotView`.** A plain Android
  View — from Compose through `AndroidView` — for a Help tab or a support
  screen. Set `question` before it is shown or call `prefill()` later; with a
  sheet open in the chat, `canGoBack` is true and `goBack()` closes it
  (`onCanGoBackChanged` drives an `OnBackPressedCallback`); `destroy()` when the
  screen is gone. The full-screen chat is now this view inside an Activity, so
  the two cannot drift apart.
* **Open with a question:** `KeydaBot.show(activity, "Is this in stock?")` puts
  it in the message box, unsent. It travels in the URL's #fragment, so it is
  never in a server log; a second call with the chat open replaces the text.
* **`KeydaBot.listener`**: `onShow()` and `onDismiss()`, both optional.
* The file picker now runs through a headless platform fragment in the screen
  the chat is in, so it works from `KeydaBotView` too, and the read permission
  for the picked file belongs to that screen.

* **Your signed-in customer:** `KeydaBot.setVisitor(name, phone, email)` and
  `clearVisitor()`. Offered — never sent — in "talk to a person", an order, a
  booking and a welcome question for a name, phone or email; the customer
  submits them. In the URL's #fragment, never in a server log. A value the
  chat would refuse on submit is dropped whole: a name over 80 characters, a
  phone outside 8–15 digits, an email without a dot in its domain. A change
  reaches chats already open, chats still loading or reloading, and an
  embedded chat that was off its screen when you made it.
* **A reply while the chat is closed:** `KeydaBot.hasUnreadReply` (from Java,
  `KeydaBot.hasUnreadReply()`), `Listener.onReply()` and
  `KeydaBot.checkForReplies()`. Asked when the app comes to the foreground
  (once a minute at most), only for chats in which the customer asked for a
  person in the last 14 days; the list is the page's own and kept in
  `noBackupFilesDir`. A chat loaded out of sight — a background tab, a GONE
  view — does not count as seen.
* **`KeydaBotView.active`:** set it false for an embedded chat that is attached
  and visible but not the one on screen (a ViewPager2 neighbour, a tab that
  keeps its views visible), so a reply it draws still counts as unread.
* `Listener`'s methods are real Java default methods: a Java app implements
  only the one it needs. `KeydaBotView`'s constants are no longer public static
  fields.
* `KeydaBotView`: `onCanGoBackChanged(false)` now comes when an error or a
  crashed renderer closes the page under an open sheet, and after a reload.
  Retry and `reload()` really load again (they used to be a same-document jump
  when a question was set), and no longer bring a question the customer already
  sent back into the box. A `prefill()` while the retry screen is up waits for
  the next load. Retry works for a view shown before `init()`. A device with no
  usable WebView gets a message instead of a crash in your screen.
* Full-screen back with a sheet open has the same half-second limit as
  everywhere else, so a hung page cannot leave back dead.
* `show()` right after the customer closes the chat opens a new one (it used
  to be swallowed by the chat on its way out, or fill its question into it);
  `onDismiss` comes as the chat starts to close. A screen rebuilt by a
  configuration change no longer calls `onShow` twice or puts its question
  back.
* A question is cut at 500 whole characters, never through an emoji.
* 0.1.5 was never released; everything prepared for it ships in this version.

* **Back closes what the customer is looking at first.** The chat can have a
  sheet open over the conversation — an item over the menu, the cart, a
  booking — and Android's back closed the whole chat from under it. Back now
  asks the page (`KeydaBot.back()`, CONTRACT rule 10) to close the sheet on
  top, and closes the chat only when nothing was open. A page from before
  October 2026 has no `back()` and the chat closes as it always did; a page
  that does not answer within half a second does too, so back never goes dead.
* **Built for Android 16:** compileSdk 36, Android Gradle Plugin 9.4.1, Gradle
  9.8.1, Kotlin 2.4.21. Nothing changes for the app that adds it: still
  minSdk 21, still no dependency but `kotlin-stdlib`, whose version in the POM
  stays at 2.1.20, and the AAR still asks for no minimum compileSdk (AGP 9
  would otherwise have written 36 into it and refused every app compiling
  against 34 or 35). The Kotlin metadata moves from 1.9 to 2.0 — the oldest
  the 2.4 compiler writes. A Kotlin app needs a 2.0+ compiler, as it already
  did for the 2.1.20 stdlib 0.1.2–0.1.4 asked for.
* Checked in a host app targeting API 36 on an Android 16 phone, an Android 15
  tablet and an Android 16 tablet, portrait and landscape, light and dark:
  status bar, navigation bar, keyboard, rotation with text typed, back over
  one and two open sheets. Also built into an app on AGP 8.9.1 compiling
  against API 34.

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
