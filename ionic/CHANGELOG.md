# Changelog — @keyda/bot-capacitor

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
