import Foundation
import os.log

// Nothing in this file touches UIKit or WebKit. That is deliberate: the two rules
// most likely to be got wrong quietly — which client ids are accepted and which URL
// gets opened — are the two things that can then be unit-tested with `swift test` on
// any machine, with no simulator and no Xcode.

/// A validated client id plus the exact URL the WebView will open.
///
/// Constructing this is the only way to get a chat URL, so an unchecked id cannot
/// reach the WebView by some other path.
struct KeydaBotConfiguration: Equatable {

    /// Kept in sync by hand with the default argument of
    /// `KeydaBot.initialize(clientId:baseUrl:)` — a public function's default value
    /// cannot reference an internal constant, so the literal appears in both places.
    /// `KeydaBotConfigurationTests` pins this one.
    static let defaultBaseUrl = "https://keyda.in/business"

    let clientId: String
    let chatURL: URL

    init(clientId: String, baseUrl: String = KeydaBotConfiguration.defaultBaseUrl) throws {
        guard KeydaBotConfiguration.isValidClientId(clientId) else {
            throw KeydaBotConfigurationError.invalidClientId(clientId)
        }
        guard let url = KeydaBotConfiguration.chatURL(baseUrl: baseUrl, clientId: clientId) else {
            throw KeydaBotConfigurationError.invalidBaseUrl(baseUrl)
        }
        self.clientId = clientId
        self.chatURL = url
    }

    // MARK: - Client id

    private static let clientIdPrefix = "kb_live_"

    /// `^kb_live_[0-9a-f]{8,48}$`, checked by hand rather than with
    /// `NSRegularExpression`.
    ///
    /// Two reasons, both of which have shipped as bugs elsewhere: `$` in
    /// `NSRegularExpression` matches before a trailing newline, so an id pasted out
    /// of a dashboard with a stray `\n` would pass here and 404 on the server; and
    /// `Character.isHexDigit` is true for uppercase and for full-width and
    /// Arabic-Indic digits, none of which the platform accepts.
    static func isValidClientId(_ clientId: String) -> Bool {
        guard clientId.hasPrefix(clientIdPrefix) else { return false }
        let hex = clientId.dropFirst(clientIdPrefix.count)
        guard (8...48).contains(hex.count) else { return false }
        return hex.allSatisfy(isLowercaseHexDigit)
    }

    private static func isLowercaseHexDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(ascii)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(ascii)
    }

    // MARK: - URL

    /// Builds `{baseUrl}/chat/{clientId}`.
    ///
    /// A base URL that carries a path is kept (`https://example.in/support` becomes
    /// `https://example.in/support/chat/kb_live_…`), which is what self-hosting
    /// behind a path prefix needs. The client id is validated before it gets here,
    /// so it is already URL-safe and needs no percent-encoding.
    static func chatURL(baseUrl: String, clientId: String) -> URL? {
        var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing slash would otherwise produce `https://host//chat/…`, which some
        // reverse proxies redirect and others 404.
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/chat/" + clientId) else { return nil }

        // A host and an http(s) scheme are not cosmetic requirements: the navigation
        // policy below compares hosts to decide what stays in the chat and what goes
        // to the browser, and a scheme-less or host-less URL would make every
        // navigation look foreign.
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Schemes

    /// Schemes a WebView only ever uses to talk to itself.
    ///
    /// None of these can be handed to the system: `UIApplication.open` has nothing to
    /// open them with, so passing one out produces a failed open and a misleading
    /// "could not open outside the chat" line in the log while the customer sees
    /// nothing happen. `javascript:` matters most — a URL that is really a script must
    /// never be passed out of the WebView that contains it.
    ///
    /// Kept here, next to the other rules, so `swift test` covers it without a
    /// simulator. The same set is `isInternalScheme` in the Flutter package.
    private static let internalSchemes: Set<String> = ["blob", "data", "javascript"]

    /// Whether `scheme` is the page's own machinery rather than somewhere a person
    /// could be taken. Such a navigation is blocked and nothing is handed to the host.
    ///
    /// `about:` is deliberately NOT here: WebKit loads `about:blank` into frames as
    /// part of its normal operation, so the navigation policy allows it rather than
    /// cancelling it.
    /// Is this navigation still the chat page itself?
    ///
    /// Host comparison is not enough, and the reason is specific: the chat
    /// page carries a real "Powered by Keyda" link, and on the default
    /// deployment it points at `https://keyda.in/business/` — the
    /// SAME host as `https://keyda.in/business/chat/{clientId}`. A same-host
    /// check therefore lets the marketing site load in place and replaces the
    /// customer's conversation with no way back; the widget re-greets on
    /// mount and persists nothing but a session id, so every message on
    /// screen is gone.
    ///
    /// A query or a #fragment on the chat page is still the chat page.
    /// Anything else on that host — pricing, docs, the marketing site — is
    /// not, and belongs in the system browser.
    static func staysInChat(_ url: URL, chatURL: URL) -> Bool {
        guard url.scheme?.lowercased() == chatURL.scheme?.lowercased(),
              url.host?.lowercased() == chatURL.host?.lowercased(),
              effectivePort(url) == effectivePort(chatURL) else {
            return false
        }
        let here = url.path
        let chat = chatURL.path
        return here == chat || here.hasPrefix(chat + "/")
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }

    static func isInternalScheme(_ scheme: String) -> Bool {
        internalSchemes.contains(scheme.lowercased())
    }
}

enum KeydaBotConfigurationError: Error, CustomStringConvertible {
    case invalidClientId(String)
    case invalidBaseUrl(String)

    var description: String {
        switch self {
        case .invalidClientId(let value):
            return "\"\(value)\" is not a Keyda client id. Expected kb_live_ followed by 8 to 48 "
                + "lowercase hex characters, for example kb_live_3f9a2c81. Copy it from Install in "
                + "the Keyda Business dashboard (https://keyda.in/business/app/)."
        case .invalidBaseUrl(let value):
            return "\"\(value)\" is not a usable baseUrl. It must be an absolute http or https URL "
                + "with a host, for example https://keyda.in/business."
        }
    }
}

/// Logging goes through the unified log rather than `print`, because a misconfigured
/// build is usually discovered from a TestFlight device where `print` output does not
/// exist and Console.app does.
enum KeydaBotLog {
    private static let log = OSLog(subsystem: "in.keyda.KeydaBot", category: "KeydaBot")

    /// For mistakes that stop the bot from working at all — a bad client id, a call
    /// before `initialize`. `.fault` is the level that shows up without the
    /// integrator having to turn anything on.
    static func fault(_ message: String) {
        os_log("%{public}@", log: log, type: .fault, message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }
}
