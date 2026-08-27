# The one contract every Keyda Business SDK implements

Read this before writing or changing any package in this repo. Every SDK here
is a thin wrapper around ONE hosted chat page. That is the whole design.

## Why a WebView and not a native chat UI

There is exactly one chat interface — `widget.js`, served by the platform —
and every surface loads it. A native Android chat and a native iOS chat would
be two more places for a fix to be needed, two more places for the accent
colour to be wrong, and two more releases to ship before an owner's change to
their welcome message reaches their customers. Owners change settings in the
dashboard and expect them live everywhere immediately; that is only true if
there is one renderer.

We say this plainly in every README. An integrator who discovers "it's a
WebView" after shipping has been misled; one who is told up front can decide.

## The URL every SDK opens

    {baseUrl}/chat/{clientId}

* `baseUrl` defaults to `https://keyda.in/business`
* it is overridable — self-hosting and staging both need it
* `clientId` looks like `kb_live_` followed by 8–48 hex characters
* an id that does not match that shape must fail loudly at init, not open a
  404 page in front of a customer

## The public surface, identical in spirit on every platform

| Call | Meaning |
|---|---|
| `init(clientId, baseUrl?)` | store configuration; validate the id |
| `show(...)` | present the chat over the host app |
| `dismiss()` | close it |
| `isShowing` | is it presented right now |

Nothing else. No message APIs, no unread counts we cannot honestly source,
no user-identity call we do not yet accept server-side. An SDK method that
does not work end-to-end is worse than a missing one.

## Rules that are not negotiable

1. **JavaScript on, DOM storage on.** The chat is a web app, and DOM storage
   is what keeps a visitor's conversation attached across an app restart.
2. **Links open OUTSIDE the chat.** The chat page contains at least one real
   link ("Powered by Keyda"). If it navigates the WebView, the customer's
   conversation is replaced by a marketing site with no way back. Every
   navigation to a different origin goes to the system browser.
3. **The keyboard must not cover the input.** This is the single most common
   WebView chat defect. Android: `adjustResize` behaviour on the host window.
   iOS: the keyboard's height is published to the page as an additional bottom
   safe-area inset, so the composer rises with it.
4. **Safe areas are respected.** The page already ships
   `viewport-fit=cover`; the container must not draw the chat under a notch
   or a home indicator.
5. **No analytics, no device identifiers, no third-party dependencies.** An
   SDK that a small business drops into their app must not add trackers to
   it. Zero dependencies beyond the platform's own WebView.
6. **Never crash the host app.** A failed load shows a retry, not an
   exception. The host's users are not our users.
7. **The owner's theme reaches the native chrome.** The dashboard's Theme
   setting (Match the visitor / Always light / Always dark) is resolved by the
   hosted page — it is the page that knows it — and announced to the shell so
   the status bar, the loading cover and the close control match the chat
   instead of contradicting it. The page posts one JSON message, as early as
   its `<head>` runs and again whenever a "Match the visitor" bot flips with
   the OS:

       {"type":"keyda:theme","mode":"light"|"dark","setting":"auto"|"light"|"dark","accent":"#rrggbb"}

   to every bridge it can find: `window.ReactNativeWebView.postMessage(json)`
   (React Native), `window.KeydaBotNative.onTheme(json)` (Android
   `addJavascriptInterface` named `KeydaBotNative`),
   `window.webkit.messageHandlers.keydaBot.postMessage(json)` (iOS
   `WKScriptMessageHandler` named `keydaBot`) and
   `window.KeydaBotFlutter.postMessage(json)` (Flutter `JavaScriptChannel`
   named `KeydaBotFlutter`). Shells apply `mode` — dark: background `#0b1220`,
   light status-bar text; light: background `#f7f8fc`, dark status-bar text —
   and ignore any message whose `type` is not exactly `keyda:theme`. Until the
   message arrives (and against a backend that predates it) a shell follows
   the device, which is what "Match the visitor" means. Capacitor/Ionic opens
   the page in the system browser sheet, which has no bridge; the chat inside
   it is themed, the sheet's own chrome is the platform's.

## What we do NOT claim

* Not offline-capable — it is a hosted page.
* No push notifications yet.
* No theme API on the SDKs themselves: the owner sets the theme once in the
  dashboard and the page carries it (rule 7). A host app cannot override it.

Anything above that a package cannot do must be absent from its README, not
described optimistically.
