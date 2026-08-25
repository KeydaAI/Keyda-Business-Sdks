import XCTest
@testable import KeydaBot

/// Deliberately platform-free: these cover the two rules that decide whether a
/// customer sees their chat or a 404, and they run under `swift test` on any machine
/// with no simulator involved.
final class KeydaBotConfigurationTests: XCTestCase {

    // MARK: - Client id

    func testAcceptsWellFormedClientIds() {
        let valid = [
            "kb_live_3f9a2c81",                                     // 8 hex, the minimum
            "kb_live_0123456789abcdef",
            "kb_live_" + String(repeating: "a", count: 48)          // 48 hex, the maximum
        ]
        for clientId in valid {
            XCTAssertTrue(KeydaBotConfiguration.isValidClientId(clientId), "expected \(clientId) to be valid")
        }
    }

    func testRejectsMalformedClientIds() {
        let invalid = [
            "",
            "kb_live_",
            "kb_live_3f9a2c8",                                      // 7 hex, one short
            "kb_live_" + String(repeating: "a", count: 49),         // 49 hex, one long
            "kb_test_3f9a2c81",                                     // wrong environment prefix
            "3f9a2c81",                                             // no prefix
            "KB_LIVE_3f9a2c81",                                     // prefix is case sensitive
            "kb_live_3F9A2C81",                                     // uppercase hex is not in the contract
            "kb_live_3f9a2c8g",                                     // g is not hex
            "kb_live_3f9a2c81 ",                                    // trailing space
            " kb_live_3f9a2c81",
            "kb_live_3f9a2c81\n",                                   // a paste out of the dashboard
            "kb_live_3f9a2c81/../admin",                            // no path smuggling into the URL
            "kb_live_\u{0663}\u{0663}\u{0663}\u{0663}\u{0663}\u{0663}\u{0663}\u{0663}" // Arabic-Indic digits
        ]
        for clientId in invalid {
            XCTAssertFalse(KeydaBotConfiguration.isValidClientId(clientId), "expected \(clientId) to be rejected")
        }
    }

    func testInitThrowsOnMalformedClientId() {
        XCTAssertThrowsError(try KeydaBotConfiguration(clientId: "nope")) { error in
            guard case KeydaBotConfigurationError.invalidClientId = error else {
                return XCTFail("expected .invalidClientId, got \(error)")
            }
        }
    }

    // MARK: - URL building

    func testDefaultBaseUrlMatchesTheContract() {
        // Repeated as a literal in KeydaBot.initialize's default argument; if this
        // changes, that changes.
        XCTAssertEqual(KeydaBotConfiguration.defaultBaseUrl, "https://business.keyda.in")
    }

    func testBuildsTheContractUrl() throws {
        let configuration = try KeydaBotConfiguration(clientId: "kb_live_3f9a2c81")
        XCTAssertEqual(configuration.chatURL.absoluteString, "https://business.keyda.in/chat/kb_live_3f9a2c81")
    }

    func testTrailingSlashesInBaseUrlAreDropped() throws {
        for baseUrl in ["https://business.keyda.in/", "https://business.keyda.in///", "  https://business.keyda.in/  "] {
            let configuration = try KeydaBotConfiguration(clientId: "kb_live_3f9a2c81", baseUrl: baseUrl)
            XCTAssertEqual(configuration.chatURL.absoluteString, "https://business.keyda.in/chat/kb_live_3f9a2c81")
        }
    }

    func testBaseUrlPathIsPreservedForSelfHosting() throws {
        let configuration = try KeydaBotConfiguration(clientId: "kb_live_3f9a2c81", baseUrl: "https://shop.example.in/support")
        XCTAssertEqual(configuration.chatURL.absoluteString, "https://shop.example.in/support/chat/kb_live_3f9a2c81")
    }

    func testPlainHttpIsAllowedForLocalAndStagingHosts() throws {
        let configuration = try KeydaBotConfiguration(clientId: "kb_live_3f9a2c81", baseUrl: "http://192.168.1.5:3000")
        XCTAssertEqual(configuration.chatURL.absoluteString, "http://192.168.1.5:3000/chat/kb_live_3f9a2c81")
    }

    func testRejectsBaseUrlsThatCannotBeLoadedOrHostChecked() {
        for baseUrl in ["", "   ", "/", "business.keyda.in", "ftp://business.keyda.in", "file:///tmp", "https://"] {
            XCTAssertThrowsError(try KeydaBotConfiguration(clientId: "kb_live_3f9a2c81", baseUrl: baseUrl)) { error in
                guard case KeydaBotConfigurationError.invalidBaseUrl = error else {
                    return XCTFail("expected .invalidBaseUrl for \(baseUrl), got \(error)")
                }
            }
        }
    }

    // MARK: - Internal schemes

    /// These are blocked outright rather than handed to `UIApplication.open`, which
    /// cannot open any of them. `javascript:` is the one that matters: a URL that is
    /// really a script must not be passed out of the WebView that contains it.
    func testInternalSchemesAreNotSomewhereAPersonCanBeTaken() {
        for scheme in ["blob", "data", "javascript", "JavaScript", "BLOB", "Data"] {
            XCTAssertTrue(KeydaBotConfiguration.isInternalScheme(scheme), "expected \(scheme) to be internal")
        }
    }

    /// `about:` is excluded on purpose — WebKit loads `about:blank` into frames as
    /// part of normal operation, so the navigation policy allows it rather than
    /// cancelling it. The rest are real destinations that belong in the browser or
    /// another app.
    func testSchemesThatMustNotBeTreatedAsInternal() {
        for scheme in ["http", "https", "tel", "mailto", "sms", "whatsapp", "about"] {
            XCTAssertFalse(KeydaBotConfiguration.isInternalScheme(scheme), "expected \(scheme) to be external")
        }
    }
}

// MARK: - Staying in the chat
//
// These exist because of a specific, verified trap: the chat page's own
// "Powered by Keyda" link points at the SAME HOST as the chat. A host-only
// comparison lets it load in place, and the customer's conversation is gone —
// the widget re-greets on mount and keeps nothing but a session id.
extension KeydaBotConfigurationTests {
    private var chat: URL { URL(string: "https://business.keyda.in/chat/kb_live_835686cd7c9bf18b9f70c34f")! }

    func testTheChatPageItselfStays() {
        XCTAssertTrue(KeydaBotConfiguration.staysInChat(chat, chatURL: chat))
    }

    func testQueryAndFragmentAreStillTheChat() {
        XCTAssertTrue(KeydaBotConfiguration.staysInChat(
            URL(string: chat.absoluteString + "?preview=abc.def")!, chatURL: chat))
        XCTAssertTrue(KeydaBotConfiguration.staysInChat(
            URL(string: chat.absoluteString + "#top")!, chatURL: chat))
    }

    func testTheSameHostMarketingSiteLeaves() {
        // The exact link the widget renders in its footer.
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: "https://business.keyda.in/business/")!, chatURL: chat))
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: "https://business.keyda.in/pricing")!, chatURL: chat))
    }

    func testAnotherBotsChatLeaves() {
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: "https://business.keyda.in/chat/kb_live_0000000000000000000000ff")!, chatURL: chat))
    }

    func testDifferentSchemeOrHostLeaves() {
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: "http://business.keyda.in/chat/kb_live_835686cd7c9bf18b9f70c34f")!, chatURL: chat))
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: "https://evil.example/chat/kb_live_835686cd7c9bf18b9f70c34f")!, chatURL: chat))
    }

    func testAPathThatMerelyStartsWithTheChatPathLeaves() {
        // "/chat/kb_live_835686cd7c9bf18b9f70c34fEXTRA" is a different page.
        XCTAssertFalse(KeydaBotConfiguration.staysInChat(
            URL(string: chat.absoluteString + "EXTRA")!, chatURL: chat))
    }
}
