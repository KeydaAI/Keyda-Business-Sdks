# KeydaBot — iOS

**This is a WebView wrapper.** `KeydaBot` presents a sheet containing a `WKWebView`
pointed at `https://keyda.in/business/chat/<your client id>`. The transcript, the
composer, the welcome message and the accent colour are all the hosted chat page — the
same one that runs on your website. There is no native chat UI in this package, and
saying so up front is the point: an integrator who finds that out after shipping has
been misled.

The reason there is one renderer and not four is that owners change their settings in
the dashboard and expect their customers to see the change immediately. A native iOS
chat would mean waiting for an App Store review before a shop's new opening hours
reached the people asking about them.

* iOS 15+, Swift 5.9+ (and Swift 6)
* Zero dependencies. No analytics, no device identifiers, nothing added to your app's
  privacy report by this SDK.
* Four calls: `initialize`, `show`, `dismiss`, `isShowing`.

## Install

### Swift Package Manager

SwiftPM requires `Package.swift` at the root of a repository, so this monorepo keeps its
manifest there — the repository URL resolves directly.

In Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/KeydaAI/keyda-business-sdks`

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KeydaAI/keyda-business-sdks", from: "0.2.0")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "KeydaBot", package: "keyda-business-sdks")])
]
```

Working inside this monorepo, point at the repo root (that is where the manifest lives —
`ios/` has none): `.package(path: "../keyda-business-sdks")`

### CocoaPods

```ruby
pod 'KeydaBot', :podspec => 'https://raw.githubusercontent.com/KeydaAI/keyda-business-sdks/v0.2.0/KeydaBot.podspec'
```

Pointing at the podspec by URL works whether or not the pod is on CocoaPods trunk. Pin it to a
release tag, as above: the podspec on `main` can name a version whose tag does not exist yet.

## Use

```swift
import KeydaBot

KeydaBot.initialize(clientId: "kb_live_3f9a2c81")   // once, at launch
KeydaBot.show()                                      // from your support button
```

That is the whole integration. `show()` presents from the top-most view controller of
the active window; pass one explicitly if you would rather choose:
`KeydaBot.show(from: self)`.

| Call | What it does |
|---|---|
| `initialize(clientId:baseUrl:)` | Stores the configuration and validates the client id. `baseUrl` defaults to `https://keyda.in/business`. |
| `show(from:question:)` | Presents the chat as a sheet; `question` goes in its message box, unsent. A second call while it is up only puts its question in the box. |
| `dismiss()` | Closes it. Safe to call when nothing is showing. |
| `isShowing` | Whether the chat is on screen right now, including after a swipe-down. |
| `onShow`, `onDismiss` | Optional closures, called on the main thread when the sheet appears and when it has gone. |
| `makeChatViewController(question:)` | The chat as a view controller for one of your own screens (below). |

Your client id is under **Install** in the [Keyda Business
dashboard](https://keyda.in/business/app/).

### Open with a question

```swift
KeydaBot.show(question: "Is this in stock?")
```

The question is put in the chat's message box; the customer reads it and taps send. It
travels in the URL's #fragment, so it never reaches a server log. Up to 500 characters,
as one line: the chat joins lines and collapses runs of spaces.

### Your signed-in customer

```swift
KeydaBot.setVisitor(name: user.name, phone: user.phone, email: user.email)  // any of them
KeydaBot.clearVisitor()                                                      // on sign-out
```

The chat then does not ask what your app already knows. The details are **offered, never
sent**: they appear in "talk to a person", an order, a booking, and a welcome question for
a name, a phone number or an email, and the customer submits them. Until then nothing
leaves the phone — they travel in the URL's #fragment. They are your app's word, not a
verified identity. A value that does not look like what it claims is dropped whole,
never shortened: a name of up to 80 characters, a phone number of 8–15 digits (spaces
and `+ - ( ) .` allowed, not starting `+0`), an email address of up to 254 characters.
Both calls reach every chat open now — the sheet and embedded chats
(`makeChatViewController`, `KeydaBotView`) alike, one still loading included — and
every one after.

### A reply while the chat is closed

A customer who asks for a person leaves their details and closes the chat; you answer
from the dashboard later. The chat shows the answer the next time it opens. This tells
your app it is there:

```swift
KeydaBot.onReply = { chatButton.showBadge() }          // once per new reply, main thread
KeydaBot.onShow = { chatButton.hideBadge() }
// when your screen appears: if KeydaBot.hasUnreadReply { chatButton.showBadge() }
```

The SDK asks when your app comes to the foreground — once a minute at most, and only for
chats in which the customer asked for a person in the last 14 days.
`KeydaBot.checkForReplies()` asks now (once in 10 seconds at most). `hasUnreadReply` stays
`true` until the customer opens the chat (the sheet, or an embedded chat on screen), which
shows the reply. An embedded chat that is loaded but not on screen — in a tab that is not
selected — may draw the reply, but that does not count as seen: the SDK asks at once, and
you get `onReply` for it like any other. The list of chats to ask about is the page's
own — chat ids and times, in
a small file in Application Support excluded from backup (not `UserDefaults`, so the
privacy manifest still declares no required-reason API); nothing else is stored or sent.
There is no push: a reply is noticed when the app is opened.

### The chat inside one of your own screens

For a Help tab or a support screen, instead of the sheet:

```swift
// UIKit: push it, or add it as a child view controller
if let chat = KeydaBot.makeChatViewController(question: "Is this in stock?") {
    navigationController?.pushViewController(chat, animated: true)
}

// SwiftUI
KeydaBotView(question: "Is this in stock?")
    .navigationTitle("Help")

// SwiftUI, as a sheet with its own close button
Button("Chat with us") { showChat = true }
    .keydaBot(isPresented: $showChat)
```

Embedded, the chat has no close button — your screen's navigation is the way out. It
starts below a navigation bar, pads itself above a tab bar and the home indicator, and
moves out of the keyboard's way itself. `isShowing`, `onShow` and `onDismiss` describe
the sheet `show()` presents, not an embedded chat or a SwiftUI sheet. `onDismiss` comes
however the sheet goes — its close button, `dismiss()`, a swipe, or your app dismissing
it or the screen under it.

### A different host

```swift
KeydaBot.initialize(clientId: "kb_live_3f9a2c81", baseUrl: "https://chat.yourcompany.in")
```

For self-hosting and staging. A path is kept, so `https://yourcompany.in/support`
becomes `https://yourcompany.in/support/chat/kb_live_…`. A plain `http://` base is
accepted for a machine on your desk, but App Transport Security will block the load
unless your app's `Info.plist` allows that host.

A base that redirects on its own host — `http` to `https`, apex to `www.`, a staging
alias — is followed while the chat is first loading, and the redirected address becomes
the chat's own. A redirect to any other host is treated like a link and opens in Safari,
so point `baseUrl` at the final origin.

### Theme

The owner sets the Theme (Match the visitor / Always light / Always dark) in the
dashboard, and the hosted page resolves it — it is the page that knows. The page reports
the result to the sheet, which then matches it: dark background `#0b1220` with light
status-bar text, or light background `#f7f8fc` with dark text, on the loading cover, the
retry screen and the close button. Until the page reports, the sheet follows the
device's appearance, which is what "Match the visitor" means; a "Match the visitor" bot
also flips with the device while it is open. There is no theme property on the SDK — a
host app cannot override what the owner chose.

### A bad client id fails loudly

The id must match `kb_live_` followed by 8–48 lowercase hex characters. Anything else
trips an assertion in debug and CI, logs at fault level in release (subsystem
`in.keyda.KeydaBot`, visible in Console.app), and leaves the bot switched off. It never
throws into your code and never crashes your shipped app — but it will not open a 404
page in front of your customer either.

## Attachments: one `Info.plist` key your app must have

If the bot's chat offers an attach button, WebKit opens the picker itself — this SDK
writes no code for it and there is nothing to switch on. What it does need is a key in
**your** app's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Attach a photo to your support conversation.</string>
```

Add it whether or not you think anyone will use the camera. WebKit's upload action sheet
offers **Take Photo or Video** for any input that accepts images — the page does not ask
for the camera and cannot turn the option off — and iOS kills an app that reaches the
camera with no usage description. That is your app terminating in front of a customer,
in a code path neither this SDK nor the page can prevent; the key is the whole fix. Add
`NSMicrophoneUsageDescription` as well if the chat accepts video.

Nothing else is required. Choosing from the photo library goes through `PHPicker`, which
needs no `NSPhotoLibraryUsageDescription`, and picking a document needs nothing at all.
The keys are only ever read as the reason shown in the system prompt; adding them does
not make this SDK use the camera, and it still reads no device identifier.

## What it does that you would otherwise have to get right yourself

* **Links leave the chat.** The page carries a real "Powered by Keyda" link. Any
  navigation to another host, any `target="_blank"`, and any `tel:`/`mailto:`/`sms:`
  goes to the system browser, so the conversation is still there when the customer
  comes back. A WebView that follows such a link in place loses the conversation with
  no way to return.
* **The keyboard does not cover the input.** The web view ends at the keyboard's top
  edge, so the chat has less room rather than having part of it under the keys — the
  message box sits right above the keyboard, the header stays at the top, in portrait
  and landscape.
* **The close button never covers the chat.** It has a bar of its own above the page,
  below the status bar and the Dynamic Island, rather than sitting over the chat's own
  header buttons.
* **Safe areas.** The page already ships `viewport-fit=cover`, so it is hosted
  full-bleed and pads its own content out of the notch and the home indicator.
* **The conversation survives.** DOM storage is kept in the persistent website data
  store, so closing the sheet — or the app — does not start a new conversation.
* **Failures show a retry, never an exception.** A dead network shows a retry screen. A
  web content process killed in the background reloads instead of leaving a blank
  sheet.
* **A privacy manifest ships with it** (`PrivacyInfo.xcprivacy`, from 0.2.0): no
  tracking, no tracking domains, no required-reason API. It lists what the chat sends
  to Keyda for the business — the conversation, attached photos and documents, and the
  name, email, phone and address an order, a booking or the contact form asks for — all
  for app functionality. Xcode's privacy report for your app includes it; your App Store
  privacy label should say the same.
* **Swift 6 ready.** It builds clean in Swift 6 language mode as well as Swift 5 (the
  package itself still declares tools 5.9, so it builds wherever it did).

## Inside the chat

All of this is the hosted page's, so it reaches your app without an SDK update:

* **A welcome message with suggestion buttons**, in the language the bot is set to; the header
  says "AI assistant".
* **The conversation is kept on the device for 24 hours**, and the chat makes no visitor id.
  (On a website a conversation lasts one browser tab.)
* **Orders and bookings**, when the business takes them: a cart, booking dates and times, a
  link to call the business when an order or booking has waited too long, and "Add to
  calendar" for a confirmed booking.
* **Attachments**: photos (JPEG, PNG, WebP, GIF) and PDF, DOCX, TXT, CSV and MD files.
* **Links leave the chat**: `tel:` opens the dialer, `mailto:` the mail app, and web links the
  browser.
* **"Add to calendar" is a link to an `.ics` file.** iOS opens it in Calendar as a calendar to
  subscribe to, so the booking arrives as a small calendar of its own rather than as one event
  in yours. Android offers the phone's calendar app when that app imports `.ics` files — current
  Google Calendar does — and otherwise the browser downloads the file.

## Limits, stated plainly

* **Not offline.** It is a hosted page; with no network there is a retry screen and
  nothing else.
* **No push notifications.** A reply that arrives while your app is closed is noticed
  when the app is next opened (`onReply`, above), not before.
* **No message or user-identity API.** Not "coming soon" — absent, because nothing
  behind them works end to end yet. `setVisitor` offers details to the customer; it
  does not tell the server who they are.
* **Theming is the dashboard's.** There is no theme property on the SDK. The owner
  picks light, dark or "match the visitor" once in the dashboard; the page resolves it
  and the sheet follows the page (see Theme above). Everything else about how the chat
  looks is set in the dashboard, not from Swift.
* **App targets only.** The SDK presents UI and opens links through
  `UIApplication.shared`, so it is marked unavailable in app extensions and will not
  build into one.
* **The camera prompt's wording is yours.** Attachments work with no code here (see
  above), but the sheet's "Take Photo or Video" option needs
  `NSCameraUsageDescription` in your app — this SDK cannot supply it, and without it
  iOS terminates your app when a customer taps that option.
* **iOS and iPadOS.** Mac Catalyst is not tested and not claimed.
* **Clearing the app's website data clears the conversation on that device.**

## Tests

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Pure unit tests over client-id validation, URL building, the visitor's cleaning and the
reply check's rules (its requests go to a stand-in, not the network) — no simulator, no
host app.
An Xcode toolchain is still required: the Command Line Tools ship no XCTest, so a bare
`swift test` under `/Library/Developer/CommandLineTools` stops at `no such module 'XCTest'`.
The parts of the SDK that decide whether a customer sees their chat or a 404 are kept
free of UIKit precisely so they can be tested that way.

## Licence

MIT — see [LICENSE](LICENSE). The same licence covers every package in this
repository; the copy here is what CocoaPods reads when the pod is installed from
this directory.
