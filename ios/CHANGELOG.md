# Changelog — KeydaBot (iOS)

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
