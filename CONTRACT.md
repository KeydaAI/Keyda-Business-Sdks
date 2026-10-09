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

Inside an app the page keeps a conversation for 24 hours and makes no visitor
id; on a website a conversation lasts one browser tab. The page tells the two
apart by the bridges below (rule 7) and the User-Agent marks (rule 9). An SDK
that opens the page where there is neither — the Ionic SDK's full screen, in
the phone's browser — says so in the link instead: `?via=capacitor`, the one
value the page accepts (from 0.2.0). Without it each open was a new tab and a
new conversation.

## The public surface, identical in spirit on every platform

| Call | Meaning |
|---|---|
| `init(clientId, baseUrl?)` | store configuration; validate the id |
| `show(..., question?)` | present the chat over the host app; `question` goes in its message box, unsent (0.2.0) |
| `dismiss()` | close it |
| `isShowing` | is it presented right now |
| embed | the chat as a view of the host's own screen: Android `KeydaBotView`, iOS `makeChatViewController` / SwiftUI `KeydaBotView`, React Native `<KeydaBotChat />`, Flutter `KeydaBotChat`, Ionic `embedWidget()` (0.2.0) |
| show / dismiss callbacks | where the platform has no way to tell otherwise: Android `KeydaBot.listener`, iOS `onShow` / `onDismiss` (0.2.0) |
| visitor | the host's signed-in customer, offered — never sent — in the chat's forms: `setVisitor(name?, phone?, email?)` / `clearVisitor()` on Android, iOS and Flutter; React Native's `visitor` prop; Ionic's embedded widget's `setVisitor` — not its full screen, which is the system browser (0.2.0) |
| replies | a person's reply the chat has not shown yet (rule 11): `hasUnreadReply`, `onReply`, `checkForReplies()` on Android, iOS and Flutter; React Native's `useKeydaBotReplies` (0.2.0) |

A question is never sent for the customer: it is put in the composer and
they tap send. It travels in the chat URL's fragment — `#q=<url-encoded>`,
at most 500 characters, as one line (the page joins lines and collapses
spaces) — which never reaches a server log. For a chat already on screen a
shell calls `window.KeydaBot.prefill(text)`.

The visitor rides the same fragment — `&name=…&phone=…&email=…` — and is
offered in the contact form, the checkout, a booking and a welcome question
for a name, phone or email; nothing is stored or sent until the customer
submits. The values are the host's word, not a verified identity. A value the
server would refuse when it is sent is dropped — never cut — by the page and
by every shell alike: a name of up to 80 characters on one line; a phone of
digits, spaces and `+ - ( ) .` with 8 to 15 digits, not `+0…`; an email of up
to 254 characters whose domain ends in two or more letters. For a chat already
on screen, and after every load, a shell calls
`window.KeydaBot.setVisitor({name, phone, email})` — `{}` when there is none,
so a sign-out during a load is not lost. The page reads `name`, `phone` and
`email` from the fragment only inside an app: a link anyone can send must not
be able to put an address in someone's contact form. Ionic's full screen does
not carry the visitor at all: it is the system browser, which keeps the
address, fragment included, in its history.

The page reads the fragment as widget.js loads — so a `prefill` a shell makes
after the page has loaded always lands after it — and takes it off the address
once the chat is up. A shell sends the fragment on the FIRST load only. A
later load (Retry, a crashed renderer) uses the plain URL: the same URL plus
a fragment is a same-document jump that loads nothing, and a question the
customer already sent must not come back into the box. A start the first load
never delivered goes in by `prefill` / `setVisitor` instead.

An embedded chat has no close control of its own (the host's screen is the
way out) and pads for nothing but what the platform needs it to — the host
lays it out clear of the system bars.

Nothing else. No message APIs, no unread counts we cannot honestly source
(the one unread signal, rule 11, is sourced from the server), no
user-identity call — the visitor above is offered to the customer, never
asserted to the server. An SDK method that does not work end-to-end is worse
than a missing one.

## Rules that are not negotiable

1. **JavaScript on, DOM storage on.** The chat is a web app, and DOM storage
   is what keeps a visitor's conversation attached across an app restart.
2. **Links open OUTSIDE the chat.** The chat page contains at least one real
   link ("Powered by Keyda"). If it navigates the WebView, the customer's
   conversation is replaced by a marketing site with no way back. Every
   navigation to a different origin goes to the system browser.
3. **The keyboard must not cover the input.** This is the single most common
   WebView chat defect. The shell makes the WebView END at the keyboard's top
   edge, so the page simply has less room: Android through `adjustResize` on
   the host window and, where the window is edge-to-edge and no longer
   resizes, by padding for the keyboard itself (the Android SDK's window
   insets, the React Native modal); iOS by moving the web view's bottom
   constraint. A shell must NOT also report
   the keyboard to the page as safe area: WebKit already shrinks the page's
   visible area for it, and the two together lifted the composer a second
   keyboard-height, up under the header (the iOS SDK up to 0.1.4). The page
   takes the keyboard's share off the bottom safe area itself (`--kb-sb`).
4. **Safe areas are respected — status bar, notch, home indicator and
   navigation bar.** The page ships `viewport-fit=cover`. The hosted chat
   page pads its footer, and on a phone on its side its left and right, with
   `env(safe-area-inset-*)`; it leaves the top to the shell, whose own bar
   sits there. A shell that draws its
   own control above the page (the close button) gives it a bar of its own:
   laid over the page's top corner it covered the chat's menu button. On
   Android, a host app targeting 15+ is edge-to-edge; the shell must keep the
   chat out of the status and navigation bars itself, on every edge. Android
   WebViews cannot be trusted with `env()` either way — WebView 150 reports
   the bars even where the shell has kept the chat clear of them (32px at the
   bottom of a tablet, measured), WebView 133 reports 0 where the chat IS
   under a side navigation bar — so the hosted page ignores the bottom and
   side insets inside an Android shell: one with the `KeydaBotNative` or
   `KeydaBotFlutter` bridge, or React Native's with its User-Agent mark
   (0.2.0+). iOS web views report only what they overlap.
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
   and ignore any message whose `type` they do not know: `keyda:theme` here,
   `keyda:sheets` (rule 10) and `keyda:waits` (rule 11). Until the
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
   | Flutter (`keyda_bot`) | this package on Android — `AndroidWebViewController.setOnShowFileSelector`, answered from the Flutter team's `image_picker` (the photo picker) for an images-only input and `file_selector` (the system file picker) for anything else; WebKit on iOS | 0.1.4 (photos), 0.2.0 (documents) |
   | Ionic / Capacitor (`@keyda/bot-capacitor`) | Capacitor's own `BridgeWebChromeClient` on the embedded path, the system browser on the full-screen one | always |
   | WordPress and any website | the browser | always |

   An installed app can be a year behind, so the page has to be able to tell
   which of these it is inside before it draws an attach button. The two
   shells that had to grow one say so in the User-Agent —
   `KeydaBot/<version> (Android)` and `KeydaBot/<version> (Flutter)`, a
   version and nothing else. The other three have always answered and need no
   signal for this; React Native adds `KeydaBot/<version> (ReactNative)` from
   0.2.0 for rule 4.

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

10. **Back closes what the customer is looking at first.** The chat opens
   sheets over the conversation — the menu, an item over it, the cart, a
   booking — and keeps them in a stack. On Android, back over an open sheet is
   the customer closing that sheet, not the chat. The page exposes
   `window.KeydaBot.back()`: it closes the sheet on top and returns `true`, or
   returns `false` when none is open. A shell calls it on back and closes the
   chat only on `false`. The page also announces its sheet count —
   `{"type":"keyda:sheets","open":n}`, at load and on every change, through
   the same four bridges as the theme (Android's `onTheme` carries it; a
   shell ignores a type it does not know). An embedded chat has to answer
   back AT ONCE — its sheet or the host's screen — and uses the count for
   that; a full-screen shell asks `back()`, which also works with a page that
   predates the count. It must also close the chat when the page is too old
   to have `back()` (call it so that a missing function or a throw answers
   `false`), when the page is not loaded or has failed, and when no answer
   comes within half a second — back must never go dead. Its own close control
   still closes the chat at once.

   | Shell | How back reaches the page | Since |
   |---|---|---|
   | Android | `OnBackInvokedCallback` / `onBackPressed` → `evaluateJavascript`; `KeydaBotView.goBack()` from the sheet count | 0.2.0 |
   | React Native (Android) | `Modal onRequestClose` → `injectJavaScript`, answered with a `keyda:back` message; `<KeydaBotChat />` takes `BackHandler` only while a sheet is open | 0.2.0 |
   | Flutter (Android) | `PopScope` → `runJavaScriptReturningResult`; `KeydaBotChat` sets `canPop` from the sheet count | 0.2.0 |
   | iOS | no system back; the sheet's own back control | — |
   | Ionic full screen | the browser's own back | — |
   | Ionic embedded | your app's: route Capacitor's `backButton` to `window.KeydaBot.back()` first | — |

   An embedded chat that is mounted but not in front — a tab that is not
   selected, a screen under another — must leave back alone: a sheet closed
   in a chat nobody can see is a back press that did nothing. React Native's
   `<KeydaBotChat focused>` and Flutter's `KeydaBotChat(focused:)` say so
   (`BackHandler` and `PopScope` are global to the app and the route); a
   native `KeydaBotView` takes back only when the host calls `goBack()`.

11. **The only unread signal is a reply the customer has not seen.** A
   customer who asks for a person leaves their details and closes the chat;
   the owner answers in the dashboard later, into that conversation. The page
   keeps the chats it is waiting on — up to 3, for 14 days, each with the
   time of the last row it showed (`at`) — and announces the list through the
   bridges, at load and on every change:

       {"type":"keyda:waits","waits":[{"c":"<conversation uuid>","at":"<ISO time, or \"\">","t":<ms when added>}]}

   (`at` is empty when the form was sent before the page had read any row.)

   A shell keeps a copy on the device (Android a file in `noBackupFilesDir`;
   iOS a file in Application Support, excluded from backup — not
   `UserDefaults`, a required-reason API; Flutter `shared_preferences`;
   React Native memory, or the `storage` the host passes). When the app comes
   to the foreground with no chat on screen it asks the public route the page
   itself polls — `GET {origin}/api/business/v1/widget/{clientId}/messages?conversationId=c&after=at`,
   no cookie, no identifier — at most once a minute (`checkForReplies()`:
   once in 10 seconds). A row with `"from":"human"` after `at` makes
   `hasUnreadReply` true and calls `onReply` once per new reply. Opening the
   chat clears it: the page draws the reply, moves `at` past it and sends the
   list back. A failed request changes nothing. A shell never moves `at`
   itself, never asks while a chat is on screen, and never asks for a chat
   the page did not list.

   Drawn is not seen. A chat the host keeps loaded but out of sight — a Help
   tab in the background, a pager's neighbour — still polls, draws the reply
   and announces the moved `at`. So a shell only takes `at` from a chat that
   is on screen at that moment; from one that is not, it keeps the page's
   place aside, and catches up to it when that chat (or any chat) comes on
   screen. "On screen" is each shell's own signal: Android's aggregated
   visibility and `KeydaBotView.active`, iOS's appearance calls, React
   Native's and Flutter's `focused`. Ionic's full screen is the system browser, which
   the app cannot read: there the reply simply shows when the chat reopens.

## What we do NOT claim

* Not offline-capable — it is a hosted page.
* No push notifications yet. A reply is noticed when the app comes to the
  foreground (rule 11), not while it is closed.
* No theme API on the SDKs themselves: the owner sets the theme once in the
  dashboard and the page carries it (rule 7). A host app cannot override it.

Anything above that a package cannot do must be absent from its README, not
described optimistically.
