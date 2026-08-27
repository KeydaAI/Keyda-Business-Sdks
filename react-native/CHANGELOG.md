# Changelog — @keyda/bot-react-native

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
