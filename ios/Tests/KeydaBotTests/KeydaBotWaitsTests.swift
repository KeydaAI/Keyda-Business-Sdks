import XCTest
@testable import KeydaBot

/// The reply check's rules: what the customer has seen, what a file read means, and what
/// a look may follow and read. No network: the looks go to a `URLProtocol` stand-in.
final class KeydaBotWaitsTests: XCTestCase {

    private let c = "0b6f3c1e-2d4a-4b8e-9f10-1a2b3c4d5e6f"
    private let a0 = "2026-10-09T10:00:00.000Z"
    private let a1 = "2026-10-09T11:00:00.000Z"
    private let a2 = "2026-10-09T12:00:00.000Z"

    private func wait(at: String, page: String? = nil, told: String? = nil) -> KeydaBotWait {
        KeydaBotWait(c: c, at: at, page: page ?? at, t: 1, told: told ?? at)
    }

    private func incoming(_ at: String) -> [KeydaBotWait] {
        KeydaBotWait.parse([["c": c, "at": at, "t": Date().timeIntervalSince1970 * 1000]], now: Date())
    }

    // MARK: - What the customer has seen

    func testParseKeepsThreeWellFormedRecentWaits() {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        let old = ms - KeydaBotWait.lifetime * 1000 - 1
        let list: [Any] = [
            ["c": c, "at": a0, "t": ms],
            ["c": "not-a-uuid", "at": a0, "t": ms],
            ["c": c, "at": "10 o'clock", "t": ms],
            ["c": c, "at": a0, "t": old],
            ["c": c, "at": a1, "t": ms]
        ]
        XCTAssertEqual(KeydaBotWait.parse(list, now: now).map(\.at), [a0], "the first three only, the bad ones dropped")
        XCTAssertEqual(KeydaBotWait.parse(nil, now: now), [])
    }

    func testAHiddenChatMovingOnLightsNothingByItselfButCallsForALook() {
        let prior = [wait(at: a0)]
        XCTAssertTrue(KeydaBotWait.pageMovedOn(prior, to: incoming(a1)))
        let hidden = KeydaBotWait.merged(prior, with: incoming(a1), fromOnScreen: false)
        XCTAssertEqual(hidden.first?.at, a0, "nobody saw it")
        XCTAssertEqual(hidden.first?.page, a1)
        XCTAssertEqual(hidden.first?.told, a0, "an order update or a bot row moves the page too; only a look says it was a person")
        XCTAssertFalse(KeydaBotWait.anyUnseen(hidden))

        // The same list again, or a chat we did not know of, is nothing new to look for.
        XCTAssertFalse(KeydaBotWait.pageMovedOn(hidden, to: incoming(a1)))
        XCTAssertFalse(KeydaBotWait.pageMovedOn([], to: incoming(a1)))

        // The look found a person's reply at a1: unread until a chat is on screen.
        var replied = hidden
        replied[0].told = a1
        XCTAssertTrue(KeydaBotWait.anyUnseen(replied))
        let shown = KeydaBotWait.seen(replied)
        XCTAssertEqual(shown.first?.at, a1, "on screen, what the page drew is in front of the customer")
        XCTAssertFalse(KeydaBotWait.anyUnseen(shown))
    }

    func testAHiddenChatDoesNotRaiseWhatWasTold() {
        let hidden = KeydaBotWait.merged([wait(at: a0, page: a1, told: a1)], with: incoming(a2), fromOnScreen: false)
        XCTAssertEqual(hidden.first?.told, a1, "kept, never raised to the page's place")
        XCTAssertEqual(hidden.first?.page, a2)
    }

    func testAChatOnScreenMovesWhatTheCustomerHasSeen() {
        let onScreen = KeydaBotWait.merged([wait(at: a0)], with: incoming(a1), fromOnScreen: true)
        XCTAssertEqual(onScreen.first?.at, a1)
        XCTAssertFalse(KeydaBotWait.anyUnseen(onScreen))
    }

    func testANewWaitStartsSeenWherever() {
        let fresh = KeydaBotWait.merged([], with: incoming(a1), fromOnScreen: false)
        XCTAssertEqual(fresh.map { [$0.at, $0.page, $0.told] }, [[a1, a1, a1]])
        XCTAssertFalse(KeydaBotWait.anyUnseen(fresh))
    }

    func testWhatTheCustomerWasToldSurvivesThePagesList() {
        // `onReply` told the app about a2; the page, loading, still says a0.
        let told = KeydaBotWait.merged([wait(at: a0, told: a2)], with: incoming(a0), fromOnScreen: true)
        XCTAssertEqual(told.first?.told, a2, "so the next look does not announce it again")
        XCTAssertTrue(KeydaBotWait.anyUnseen(told))
        // Then it draws the reply.
        let drawn = KeydaBotWait.merged(told, with: incoming(a2), fromOnScreen: true)
        XCTAssertFalse(KeydaBotWait.anyUnseen(drawn))
    }

    func testAFileFromBeforePageWasKeptReadsPageAsAt() throws {
        let json = #"[{"c":"\#(c)","at":"\#(a0)","t":1,"told":"\#(a1)"},{"c":"x","at":"\#(a0)","t":1,"told":"\#(a0)"}]"#
        let stored = try JSONDecoder().decode([KeydaBotWait].self, from: Data(json.utf8))
        XCTAssertEqual(KeydaBotWait.checked(stored), [wait(at: a0, page: a0, told: a1)])
        let written = try JSONEncoder().encode(KeydaBotWait.checked(stored))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains(#""page":"\#(a0)""#), "page is kept from now on")
    }

    // MARK: - Reading the device's copy

    func testAFileThatCannotBeReadIsNotAnEmptyList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(KeydaBotWait.read(directory.appendingPathComponent("waits_none.json")), .missing)

        let file = directory.appendingPathComponent("waits_x.json")
        try Data("[]".utf8).write(to: file)
        XCTAssertEqual(KeydaBotWait.read(file), .data(Data("[]".utf8)))

        // Data protection before the first unlock looks like this to the reader.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if case .data = KeydaBotWait.read(file) { throw XCTSkip("running as a user who can read anything") }
        XCTAssertEqual(KeydaBotWait.read(file), .unreadable)
    }

    // MARK: - A look

    func testRedirectsStayOnTheChatsOwnSite() {
        let origin = URL(string: "https://keyda.in/api/business/v1/widget/kb_live_3f9a2c81/messages?conversationId=x")
        let follows = { (to: String) in KeydaBotReplyFetch.followsRedirect(from: origin, to: URL(string: to)) }
        XCTAssertTrue(follows("https://keyda.in/other"))
        XCTAssertTrue(follows("https://www.keyda.in/api"))
        XCTAssertTrue(follows("https://KEYDA.in/api"))
        XCTAssertFalse(follows("http://keyda.in/api"), "never down to plain http")
        XCTAssertFalse(follows("https://evil.example/api"))
        XCTAssertFalse(follows("https://keyda.in.evil.example/api"))
        XCTAssertFalse(follows("https://notkeyda.in/api"))
        XCTAssertFalse(follows("https://api.keyda.in/api"))
        XCTAssertTrue(KeydaBotReplyFetch.followsRedirect(from: URL(string: "http://www.keyda.in/a"), to: URL(string: "https://keyda.in/a")))
    }

    func testALookReadsAnOkAnswer() {
        Stub.answer("https://keyda.in/m", body: Data(#"{"messages":[]}"#.utf8))
        XCTAssertEqual(look("https://keyda.in/m"), Data(#"{"messages":[]}"#.utf8))
        Stub.answer("https://keyda.in/m", status: 404, body: Data("{}".utf8))
        XCTAssertNil(look("https://keyda.in/m"))
    }

    func testALookReadsNothingTooBig() {
        let limit = KeydaBotReplyFetch.maxBodyBytes
        Stub.answer("https://keyda.in/said", headers: ["Content-Length": String(limit + 1)], body: Data("{}".utf8))
        XCTAssertNil(look("https://keyda.in/said"), "turned away on the length it states")
        Stub.answer("https://keyda.in/unsaid", body: Data(count: limit + 1))
        XCTAssertNil(look("https://keyda.in/unsaid"), "and on what arrives")
        Stub.answer("https://keyda.in/fits", body: Data(count: limit))
        XCTAssertEqual(look("https://keyda.in/fits")?.count, limit)
    }

    func testALookFollowsARedirectOnlyOnItsOwnSite() {
        Stub.answer("https://keyda.in/m", status: 301, headers: ["Location": "https://www.keyda.in/m"])
        Stub.answer("https://www.keyda.in/m", body: Data("{}".utf8))
        XCTAssertEqual(look("https://keyda.in/m"), Data("{}".utf8))

        Stub.answer("https://keyda.in/away", status: 302, headers: ["Location": "https://evil.example/m"])
        Stub.answer("https://evil.example/m", body: Data("{}".utf8))
        XCTAssertNil(look("https://keyda.in/away"))
        XCTAssertFalse(Stub.asked.contains("https://evil.example/m"), "the conversation id never left")
    }

    override func setUp() {
        super.setUp()
        Stub.reset()
    }

    private func look(_ url: String) -> Data? {
        let configuration = KeydaBotReplyFetch.configuration()
        configuration.protocolClasses = [Stub.self]
        let finished = expectation(description: url)
        let result = Box()
        KeydaBotReplyFetch.get(URLRequest(url: URL(string: url)!), configuration: configuration) { data in
            result.set(data)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return result.get()
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func set(_ data: Data?) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Answers by URL, and remembers what it was asked.
private final class Stub: URLProtocol {
    private struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var answers: [String: Answer] = [:]
    private static var askedURLs: [String] = []

    static var asked: [String] {
        lock.lock(); defer { lock.unlock() }
        return askedURLs
    }

    static func reset() {
        lock.lock(); answers = [:]; askedURLs = []; lock.unlock()
    }

    static func answer(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        lock.lock(); answers[url] = Answer(status: status, headers: headers, body: body); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Stub.lock.lock()
        Stub.askedURLs.append(url.absoluteString)
        let answer = Stub.answers[url.absoluteString]
        Stub.lock.unlock()
        guard let answer, let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let location = answer.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
