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

8. **The page speaks the owner's language on its own.** The dashboard's
   *Language your bot speaks* setting is resolved by the hosted page: it sets
   `<html lang dir>` (Arabic and Urdu are `rtl`) and draws the whole chat in
   that language from its own config response. A shell does nothing for this —
   no locale to pass, no strings to ship — and must not force a direction or
   language on the WebView that contradicts the page.

9. **Answer the page's file chooser.** The chat can offer an attach button,
   and it ends in an ordinary `<input type="file">`. A shell that does not
   answer the file request that comes out of it gives the customer a tap that
   does nothing at all — no picker, no error, nothing to tell them apart from
   a frozen app. Who has to write code for it is the platform's decision, not
   ours: WebKit presents its own picker, so every iOS surface works untouched,
   while Android hands the request to the WebView's `WebChromeClient` and a
   shell without one refuses every attachment in silence.

   | Shell | Who opens the picker | Since |
   |---|---|---|
   | Android (`in.keyda:keyda-bot`) | this SDK — `WebChromeClient.onShowFileChooser` handing the page's own `accept` list to `FileChooserParams.createIntent()`: the gallery and the documents providers, no camera | 0.1.4 |
   | iOS (`KeydaBot`) | WebKit, with no code here | always |
   | React Native (`@keyda/bot-react-native`) | `react-native-webview`'s own chrome client | always |
   | Flutter (`keyda_bot`) | this package on Android — `AndroidWebViewController.setOnShowFileSelector` answered from the Flutter team's `image_picker` (photos from the gallery); WebKit on iOS | 0.1.4 |
   | Ionic / Capacitor (`@keyda/bot-capacitor`) | Capacitor's own `BridgeWebChromeClient` on the embedded path, the system browser on the full-screen one | always |
   | WordPress and any website | the browser | always |

   An installed app can be a year behind, so the page has to be able to tell
   which of these it is inside before it draws an attach button. The two
   shells that had to grow one say so in the User-Agent —
   `KeydaBot/<version> (Android)` and `KeydaBot/<version> (Flutter)`, a
   version and nothing else. The other three have always answered and need no
   signal.

   Two obligations follow that no SDK can discharge for the host app, so they
   belong in every README rather than in anyone's code. On **every iOS
   surface** — this SDK, React Native, Flutter and the Capacitor embedded
   path alike — WebKit's own action sheet offers "Take Photo or Video" for an
   image input whether or not the page asked to capture, and an app whose
   `Info.plist` has no `NSCameraUsageDescription` is killed the moment a
   customer picks it. That is rule 6 breaking on a key only the host can add
   (`NSMicrophoneUsageDescription` too, if the input accepts video). On
   **Android** the gallery and documents providers need no permission and no
   `<queries>` entry; a camera path would need a FileProvider and the host's
   CAMERA permission, which is why this SDK does not have one.

## What we do NOT claim

* Not offline-capable — it is a hosted page.
* No push notifications yet.
* No theme API on the SDKs themselves: the owner sets the theme once in the
  dashboard and the page carries it (rule 7). A host app cannot override it.

Anything above that a package cannot do must be absent from its README, not
described optimistically.
