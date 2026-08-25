// swift-tools-version:5.9
import PackageDescription

// This manifest sits at the REPOSITORY ROOT, not in ios/, and it has to.
//
// Swift Package Manager resolves a package by cloning a repository and reading
// Package.swift at its top level. There is no way to point it at a
// subdirectory — so a manifest living in ios/ would build fine on a developer's
// machine and then fail for every consumer who followed our own install
// instructions. The target paths reach into ios/ instead.
//
// No `dependencies:` anywhere in this file, and there never will be. An SDK a
// small business drops into their app must not drag trackers or a networking
// library in behind it; WKWebView is the only thing this package needs.
let package = Package(
    name: "KeydaBot",
    platforms: [
        // UIKit + WKWebView presented as a sheet. Everything used here exists on iOS 13.
        .iOS(.v13)
    ],
    products: [
        .library(name: "KeydaBot", targets: ["KeydaBot"])
    ],
    targets: [
        .target(name: "KeydaBot", path: "ios/Sources/KeydaBot"),
        // Pure unit tests over client-id validation, URL building and the
        // stays-in-chat rule — no simulator, no host app. `swift test` runs
        // them on the machine you are sitting at.
        .testTarget(name: "KeydaBotTests", dependencies: ["KeydaBot"], path: "ios/Tests/KeydaBotTests")
    ]
)
