# Changelog — KeydaBot (iOS)

## 0.2.0 — unreleased

* **The chat inside one of your own screens:**
  `KeydaBot.makeChatViewController(question:)` for UIKit (push it or add it as a
  child) and `KeydaBotView(question:)` for SwiftUI, plus
  `.keydaBot(isPresented:question:)` to present it as a sheet from SwiftUI.
  Embedded, the chat has no close button, starts below a navigation bar and
  pads itself above a tab bar and the keyboard.
* **Open with a question:** `KeydaBot.show(question:)` puts it in the message
  box, unsent (in the URL's #fragment, never in a server log); a second call
  with the chat open replaces the text.
* **`KeydaBot.onShow` and `KeydaBot.onDismiss`**, called on the main thread.
* **Minimum iOS 15** (was 13). Xcode 27 builds nothing older — `pod lib lint`
  and every app's CocoaPods build stopped with an error — and the App Store
  has required Xcode 26, iOS 15 and up, since April 2026.

* **Your signed-in customer:** `KeydaBot.setVisitor(name:phone:email:)` and
  `clearVisitor()`. Offered — never sent — in "talk to a person", an order, a
  booking and a welcome question for a name, phone or email; the customer
  submits them. In the URL's #fragment, never in a server log. A value that
  does not look right is dropped whole: a name of up to 80 characters, a phone
  number of 8–15 digits, an email address. Embedded chats get it too, and so
  does a chat that was still loading when you called it.
* **A reply while the chat is closed:** `KeydaBot.hasUnreadReply`,
  `KeydaBot.onReply` and `KeydaBot.checkForReplies()`. Asked when the app comes
  to the foreground (once a minute at most), only for chats in which the
  customer asked for a person in the last 14 days. `hasUnreadReply` stays true
  until a chat is on screen: an embedded chat that drew the reply in a tab that
  is not selected does not count as seen, and `onReply` still comes for it. The
  list is the page's own, in a small file in Application Support excluded from
  backup — not `UserDefaults`, so the privacy manifest still declares no
  required-reason API.
* `onDismiss` now also comes when your app dismisses the sheet, or the screen
  under it, itself — once, whichever way it went.
* Retry and a terminated web content process load the chat again without
  putting a question the customer already sent back into the box.
* The keyboard's overlap is right in iPad windows that do not sit at the
  screen's origin (Stage Manager, Slide Over, Split View), and an embedded chat
  starts from no keyboard when it reappears.
* 0.1.5 was never released; everything prepared for it ships in this version.

* **The close button no longer covers the chat.** It floated over the top-right
  corner of the page, which is where the chat's header keeps its menu button —
  on every iPhone the ✕ sat on a control the customer then could not reach. It
  now has a bar of its own above the chat, in the theme's colour, below the
  status bar and the Dynamic Island (as the Flutter and React Native shells
  already do). In landscape the chat also stays inside the side safe areas.
* **The keyboard no longer pushes the message box up under the header.** The
  keyboard was reported to the page as extra bottom safe area on top of WebKit
  shrinking the page for it, so the box rose a second keyboard-height and, in
  landscape, ended up behind the keys. The web view now ends at the keyboard's
  top edge; the box sits right above the keys, the header stays put.
* **A privacy manifest** (`PrivacyInfo.xcprivacy`), in the Swift package and
  the podspec. No tracking, no tracking domains, no required-reason API. It
  lists what the chat sends to Keyda for the business: the conversation,
  attached photos and documents, and the name, email, phone number and address
  an order, a booking or the contact form asks for — all for app functionality,
  none for tracking — so the app's privacy report, and its App Store label,
  can say so.
* **Builds clean in Swift 6 language mode** (Xcode 27) as well as Swift 5. The
  two navigation-delegate methods now match WebKit's current signatures — in
  Swift 6 mode they only "nearly matched", and WebKit would never have called
  them, which would have let links load inside the chat. The public API is
  unchanged and is deliberately not `@MainActor`: that would stop existing
  call sites outside a main-actor context from compiling, Swift 5 apps
  included.
* Checked on an iPhone 17 Pro and an iPad Pro 11-inch simulator (iOS 26.5),
  portrait and landscape, light and dark, with the on-screen keyboard.

## 0.1.4 — 2026-09-03

* No code change. Version aligned with the rest of the Keyda SDKs, which grew
  file-chooser support this release (CONTRACT rule 9); WebKit has always
  presented its own picker for the chat's attach button, so this SDK needed
  none.
* **README: the one `Info.plist` key an integrator must add.** WebKit's upload
  action sheet offers "Take Photo or Video" for any input that accepts images
  — the page does not ask for the camera and cannot remove the option — and
  iOS terminates an app that reaches the camera without
  `NSCameraUsageDescription`. That is the host app crashing in a path neither
  this SDK nor the page can intercept, so it is now stated in its own section
  and again under Limits, with `NSMicrophoneUsageDescription` for video. The
  photo library needs no key (`PHPicker`).

## 0.1.3 — 2026-08-27

* The sheet follows the owner's theme. The hosted page reports its resolved
  Theme setting (Match the visitor / Always light / Always dark) through a
  `keydaBot` script message handler, and the sheet applies it: `#0b1220` with
  light status-bar text in dark, `#f7f8fc` with dark text in light — on the
  loading cover, the retry screen and the close button. Until the page reports
  (or against a backend that predates the bridge) the sheet follows the device.
  No theme API on the SDK; the owner sets it once in the dashboard.
* A base URL that redirects on its own host (`http` → `https`, apex → `www.`)
  is followed while the chat is first loading instead of being thrown into
  Safari before it ever rendered, and the redirected address becomes the
  chat's own for the rest of the session.
* README: tests need an Xcode toolchain (`DEVELOPER_DIR=…`), not the bare
  Command Line Tools, which ship no XCTest.

## 0.1.2 — 2026-08-26

Versions across every Keyda SDK aligned on 0.1.2. Default `baseUrl` moved from
the retired `business.keyda.in` host to `https://keyda.in/business`; CocoaPods
podspec added alongside SPM.
