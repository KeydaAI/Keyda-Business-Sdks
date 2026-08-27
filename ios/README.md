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

* iOS 13+, Swift 5.9+
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
    .package(url: "https://github.com/KeydaAI/keyda-business-sdks", from: "0.1.3")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "KeydaBot", package: "keyda-business-sdks")])
]
```

Working inside this monorepo, point at the repo root (that is where the manifest lives —
`ios/` has none): `.package(path: "../keyda-business-sdks")`

### CocoaPods

```ruby
pod 'KeydaBot', :podspec => 'https://raw.githubusercontent.com/KeydaAI/keyda-business-sdks/main/KeydaBot.podspec'
```

Pointing at the podspec by URL works whether or not the pod is on CocoaPods trunk.

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
| `show(from:)` | Presents the chat as a sheet. A second call while it is up does nothing. |
| `dismiss()` | Closes it. Safe to call when nothing is showing. |
| `isShowing` | Whether the chat is on screen right now, including after a swipe-down. |

Your client id is under **Install** in the [Keyda Business
dashboard](https://keyda.in/business/app/).

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

## What it does that you would otherwise have to get right yourself

* **Links leave the chat.** The page carries a real "Powered by Keyda" link. Any
  navigation to another host, any `target="_blank"`, and any `tel:`/`mailto:`/`sms:`
  goes to the system browser, so the conversation is still there when the customer
  comes back. A WebView that follows such a link in place loses the conversation with
  no way to return.
* **The keyboard does not cover the input.** The keyboard's height is published to the
  page as bottom safe-area inset, so the composer rises with it.
* **Safe areas.** The page already ships `viewport-fit=cover`, so it is hosted
  full-bleed and pads its own content out of the notch and the home indicator.
* **The conversation survives.** DOM storage is kept in the persistent website data
  store, so closing the sheet — or the app — does not start a new conversation.
* **Failures show a retry, never an exception.** A dead network shows a retry screen. A
  web content process killed in the background reloads instead of leaving a blank
  sheet.

## Limits, stated plainly

* **Not offline.** It is a hosted page; with no network there is a retry screen and
  nothing else.
* **No push notifications.** A reply is seen when the chat is open. There is no
  background delivery and no badge.
* **No message, unread or user-identity API.** Not "coming soon" — absent, because
  nothing behind them works end to end yet.
* **Theming is the dashboard's.** There is no theme property on the SDK. The owner
  picks light, dark or "match the visitor" once in the dashboard; the page resolves it
  and the sheet follows the page (see Theme above). Everything else about how the chat
  looks is set in the dashboard, not from Swift.
* **App targets only.** The SDK presents UI and opens links through
  `UIApplication.shared`, so it is marked unavailable in app extensions and will not
  build into one.
* **iOS and iPadOS.** Mac Catalyst is not tested and not claimed.
* **Clearing the app's website data clears the conversation on that device.**

## Tests

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Pure unit tests over client-id validation and URL building — no simulator, no host app.
An Xcode toolchain is still required: the Command Line Tools ship no XCTest, so a bare
`swift test` under `/Library/Developer/CommandLineTools` stops at `no such module 'XCTest'`.
The parts of the SDK that decide whether a customer sees their chat or a 404 are kept
free of UIKit precisely so they can be tested that way.

## Licence

MIT — see [LICENSE](LICENSE). The same licence covers every package in this
repository; the copy here is what CocoaPods reads when the pod is installed from
this directory.
