# Changelog

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
