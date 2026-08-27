# Changelog

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
