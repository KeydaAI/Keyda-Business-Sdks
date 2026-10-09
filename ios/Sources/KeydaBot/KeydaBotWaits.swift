import Foundation

// Nothing in this file touches UIKit, so the reply check's rules — what the customer
// has seen, which file read counts as "nothing is waiting", which redirect a look may
// follow, how big an answer may be — run under `swift test` on a Mac.
// `KeydaBotReplies` is the part that lives in an app.

/// One chat the page is waiting on for a person's reply (CONTRACT rule 11), as this
/// device keeps it.
struct KeydaBotWait: Codable, Equatable, Sendable {
    /// The conversation.
    let c: String
    /// How far the CUSTOMER has seen the chat: the page's place, taken only from a chat
    /// that was on screen. A look asks for replies after it.
    var at: String
    /// The page's own last place. A chat that is loaded but not on screen (a tab not
    /// selected, a screen under another) keeps polling, draws new rows and moves it,
    /// though nobody saw them. `nil` in a file written before it was kept; read as `at`.
    var page: String?
    /// When the page started waiting, in ms.
    let t: Double
    /// The newest reply known: one a chat on screen drew, or a person's reply a look
    /// found (and `onReply` told the app of).
    var told: String

    static let maxCount = 3
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    /// A `keyda:waits` list from the page: its first three, each well formed and under
    /// 14 days old.
    static func parse(_ list: [Any]?, now: Date) -> [KeydaBotWait] {
        let ms = now.timeIntervalSince1970 * 1000
        return (list ?? []).prefix(maxCount).compactMap { item in
            guard let w = item as? [String: Any],
                  let c = w["c"] as? String, isConversation(c),
                  let at = w["at"] as? String, isTime(at),
                  let t = (w["t"] as? NSNumber)?.doubleValue,
                  t > 0, ms - t < lifetime * 1000 else { return nil }
            return KeydaBotWait(c: c, at: at, page: at, t: t, told: at)
        }
    }

    /// The page's list replacing ours. What the page announces is its own place; it is
    /// what the customer has seen only when the chat that announced it was on screen.
    /// From a hidden chat neither the customer's place nor `told` moves: the page moves
    /// its place past a row of ANY kind (an order update, the bot), and only a person's
    /// reply is news. `pageMovedOn` says when to look for one. What the customer was
    /// told about survives, so a reply is never announced twice.
    static func merged(_ prior: [KeydaBotWait], with incoming: [KeydaBotWait], fromOnScreen: Bool) -> [KeydaBotWait] {
        incoming.map { w in
            let p = prior.first { $0.c == w.c }
            var next = w
            next.page = w.at
            if fromOnScreen {
                next.told = max(p?.told ?? "", w.at)
            } else {
                if let p = p { next.at = min(p.at, w.at) }
                next.told = max(p?.told ?? "", next.at)
            }
            return next
        }
    }

    /// A hidden chat drew something new in a chat we already knew of. A look then finds
    /// out whether a person wrote it.
    static func pageMovedOn(_ prior: [KeydaBotWait], to incoming: [KeydaBotWait]) -> Bool {
        incoming.contains { w in
            guard let p = prior.first(where: { $0.c == w.c }) else { return false }
            return w.at > (p.page ?? p.at)
        }
    }

    /// A chat came on screen: whatever the page has drawn is in front of the customer now.
    static func seen(_ waits: [KeydaBotWait]) -> [KeydaBotWait] {
        waits.map { w in
            var next = w
            next.at = max(w.at, w.page ?? w.at)
            return next
        }
    }

    /// A person wrote past what the customer has seen.
    static func anyUnseen(_ waits: [KeydaBotWait]) -> Bool {
        waits.contains { $0.told > $0.at }
    }

    /// The device's copy, checked as the page's list is, with `page` filled in for a
    /// file written before it was kept.
    static func checked(_ stored: [KeydaBotWait]) -> [KeydaBotWait] {
        stored.prefix(maxCount)
            .filter { isConversation($0.c) && isTime($0.at) && isTime($0.told) && ($0.page.map(isTime) ?? true) }
            .map { w in
                var next = w
                next.page = w.page ?? w.at
                return next
            }
    }

    static func isConversation(_ s: String) -> Bool {
        s.count == 36 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }
    }

    /// The server's ISO time, as the page stores it. Compared as strings, as the page does.
    static func isTime(_ s: String) -> Bool {
        s.count <= 40 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789T:.+-Z").contains($0) }
    }

    /// What reading the device's copy found.
    enum FileRead: Equatable {
        /// No file: nothing is waiting.
        case missing
        /// There, but not readable. Before the first unlock after a restart data
        /// protection keeps the file closed, and that is not an empty list: nothing may
        /// be written over it or deleted until a read succeeds.
        case unreadable
        case data(Data)
    }

    static func read(_ file: URL) -> FileRead {
        do {
            return .data(try Data(contentsOf: file))
        } catch {
            let e = error as NSError
            let missing = (e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError))
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT))
            return missing ? .missing : .unreadable
        }
    }
}

/// One look at the messages route, for `KeydaBotReplies`: no cookie, no cache, no
/// redirect off the chat's own site, and no answer over `maxBodyBytes`.
///
/// Each look has a short-lived session of its own so that this object can be its
/// delegate: the delegate is where a redirect and an answer's size are seen before the
/// body is read. Three requests a minute at most, so a session each costs nothing.
final class KeydaBotReplyFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// A page of 100 rows is far below this; anything bigger is not the route we know.
    static let maxBodyBytes = 1 << 20

    /// Touched only from the session's delegate queue, which is serial.
    private let done: @Sendable (Data?) -> Void
    private var body = Data()
    private var ok = false

    private init(done: @escaping @Sendable (Data?) -> Void) {
        self.done = done
    }

    /// `done` gets the body of a 200 answer, or `nil` for anything else — no network, a
    /// captive portal, a redirect to another site, an answer too big. Called once, on a
    /// background queue.
    static func get(_ request: URLRequest,
                    configuration: URLSessionConfiguration = KeydaBotReplyFetch.configuration(),
                    done: @escaping @Sendable (Data?) -> Void) {
        let session = URLSession(configuration: configuration, delegate: KeydaBotReplyFetch(done: done), delegateQueue: nil)
        session.dataTask(with: request).resume()
        // The session, and this delegate with it, go once the request is over.
        session.finishTasksAndInvalidate()
    }

    /// Ephemeral, with no cookie and no cache: the route asks for nothing else.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// A look follows a redirect only within the chat's own site — the same host or its
    /// `www.`/apex twin, keeping its scheme or going from http to https. URLSession
    /// would otherwise follow any redirect, to any host, with the conversation id.
    static func followsRedirect(from origin: URL?, to target: URL?) -> Bool {
        guard let a = origin?.host?.lowercased(), let b = target?.host?.lowercased(),
              let from = origin?.scheme?.lowercased(), let to = target?.scheme?.lowercased() else { return false }
        let sameSite = a == b || b == "www." + a || a == "www." + b
        return sameSite && (from == to || (from == "http" && to == "https"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if Self.followsRedirect(from: task.originalRequest?.url, to: request.url) {
            completionHandler(request)
        } else {
            // A failed look, which changes nothing.
            task.cancel()
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // An answer that says it is too big is not read at all.
        ok = (response as? HTTPURLResponse)?.statusCode == 200
            && response.expectedContentLength <= Int64(Self.maxBodyBytes)
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        // One that did not say how big it is meets the same limit as it arrives.
        if body.count > Self.maxBodyBytes {
            ok = false
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        done(error == nil && ok ? body : nil)
    }
}
