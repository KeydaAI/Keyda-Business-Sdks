# Changelog — @keyda/bot-capacitor


## 0.2.0 — unreleased

* **Open with a question:** `KeydaBot.open({ clientId, question })` puts it in
  the message box, unsent (in the URL's #fragment, never in a server log).
* The embedded widget's controls (`getEmbeddedWidget()`) are typed with its
  newer `prefill(question)` and `back()` — route Capacitor's Android
  `backButton` to `back()` first, so back closes a sheet before it leaves the
  page.
* The `?via=capacitor` mark is added only in the native app: the same code
  built for the web opens an ordinary browser tab, which may be on a shared
  computer, where a chat kept for a day would show the next person the last
  one's details.

* **Fixed: `open()` could throw** on a question whose 500th UTF-16 unit was
  half an emoji (`encodeURIComponent` threw), though it promises to resolve.
  Cut at 500 whole characters now, and the encoding can no longer throw.
* **Your signed-in customer, on the embedded widget:**
  `getEmbeddedWidget()?.setVisitor?.({ name, phone, email })`. Offered — never
  sent — in the chat's forms; the customer submits them. A value that does not
  look right is dropped whole, never cut: name 1–80 characters, phone 8–15
  digits, email up to 254 characters. The full-screen `open()` does not take
  them: it opens the system browser, which can keep the link — #fragment
  included — in its history (and Chrome syncs it). Use the embedded widget for
  that.
* `open()` keeps what `init()` stored: `open({ question })` after
  `init(id, stagingUrl)` goes to staging, and `clientId` is optional once
  `init()` has run.
* 0.1.5 was never released; everything prepared for it ships in this version.

* **The full-screen chat keeps its conversation.** `open()` shows the chat in
  the phone's browser sheet, where the page found no sign of an app around it
  and treated the visit as a website's — whose chat lasts one browser tab. Each
  `open()` is a new tab, so every open started a new conversation (measured on
  iOS and Android). `open()` now adds `?via=capacitor` to the chat link and the
  hosted page keeps the chat for 24 hours, as in every other SDK. `chatUrl()`
  still returns the bare link. Needs the hosted page from October 2026; an
  older one ignores the parameter.
* Checked with Capacitor 8 on iOS and Android, full screen and embedded, phone
  and tablet.

## 0.1.4 — 2026-09-03

* No code change. Version aligned with the rest of the Keyda SDKs, which grew
  file-chooser support this release (CONTRACT rule 9). Both paths already
  answer the chat's attach button: the embedded one through Capacitor's own
  `BridgeWebChromeClient` on Android and WKWebView on iOS, the full-screen one
  through the system browser, which owns its picker and its prompts.
* README: an "Attachments, on the embedded path" section. The embedded widget
  runs in *your* web view, so the picker is your app's — and an iOS app
  without `NSCameraUsageDescription` is terminated when a customer picks "Take
  Photo or Video" from WebKit's upload sheet, which appears for any input that
  accepts images whether or not the page asked to capture. Also noted under
  Limitations.

## 0.1.3 — 2026-08-27

* `baseUrl` with a query string or a `#fragment` is now rejected at `init()`
  / `open()`, matching the React Native SDK. Previously `chatUrl()` built the
  unusable `https://host?x=1/chat/kb_live_…` and the failure was a 404 in
  front of a customer.
* Theme: the hosted page now resolves the owner's dashboard Theme setting
  (Match the visitor / Always light / Always dark) itself, so both surfaces
  follow it with no change to this package. On the embedded path the widget
  is themed fully. On the full-screen path the chat inside the system browser
  sheet is themed; the sheet's own chrome stays the platform's, because a
  system browser view has no bridge for the page to announce its theme
  through. There is no theme option on this package, by design — see
  CONTRACT.md rule 7.
* README: a "Theme" section saying the above; "No native theming" under
  Limitations now points at it.
* `CHANGELOG.md` ships inside the package.

## 0.1.2 — 2026-08-26

First release on npm. Versions across every Keyda SDK aligned on 0.1.2.

* Default `baseUrl` moved from the retired `business.keyda.in` host to
  `https://keyda.in/business`. Integrators on 0.1.0 source get a dead URL.
* `npm publish` would have shipped a package whose `main`/`module`/`types`
  all pointed into a deleted `dist/`; the build runs against an installed
  TypeScript now and `npm pack` carries `dist/esm` and `dist/cjs`.
* `LICENSE` ships inside the package.
* README: links in answers, the embedded path's escape-to-browser behaviour,
  and the troubleshooting pointer for shells that drop `target=_blank`.

## 0.1.0 — 2026-08-25

First release, source only (not published to npm): `KeydaBot.init/open/show/
close`, `embedWidget`, `chatUrl`.
