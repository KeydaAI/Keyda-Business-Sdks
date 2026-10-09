#if canImport(UIKit)
import UIKit

/// The whole public surface of the SDK.
///
/// `KeydaBot` presents one screen: a sheet containing a `WKWebView` pointed at
/// `{baseUrl}/chat/{clientId}`. There is no message API and no identity call here. The
/// one unread signal, `hasUnreadReply`, is a reply from a person at the business that
/// the chat has not shown yet — something the server can answer honestly.
///
/// Call these from the main thread. Calls that arrive on another thread are hopped to
/// the main queue rather than being allowed to corrupt UIKit state; the hop is a
/// safety net, not a supported calling convention. (Deliberately not `@MainActor`:
/// that would stop every existing call site outside a main-actor context from
/// compiling, Swift 5 apps included.)
@available(iOSApplicationExtension, unavailable,
           message: "KeydaBot presents UI over the host app and opens links in Safari, neither of which an app extension can do.")
public enum KeydaBot {

    // MARK: - State

    /// The configuration and the sheet on screen, behind a lock: `initialize` and
    /// `isShowing` may be called from any thread, and Swift 6 refuses unguarded
    /// global state.
    private static let state = KeydaBotState()

    // MARK: - Public API

    /// Stores the configuration and validates the client id.
    ///
    /// Call once, typically in `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// A malformed client id fails loudly: it trips an assertion in debug and CI, and
    /// logs at fault level in a release build. It never throws into your app and never
    /// crashes a shipped one — but the bot stays switched off until the id is fixed,
    /// because the alternative is a 404 page wearing your support button.
    ///
    /// - Parameters:
    ///   - clientId: from **Install** in the Keyda Business dashboard. `kb_live_`
    ///     followed by 8–48 lowercase hex characters.
    ///   - baseUrl: override only for self-hosting or staging. Must match
    ///     `KeydaBotConfiguration.defaultBaseUrl` when omitted; the literal is repeated
    ///     here because a public default argument cannot reference an internal constant.
    public static func initialize(clientId: String, baseUrl: String = "https://keyda.in/business") {
        do {
            let configuration = try KeydaBotConfiguration(clientId: clientId, baseUrl: baseUrl)
            state.configuration = configuration
            KeydaBotReplies.shared.start(configuration)
        } catch {
            state.configuration = nil
            fail("KeydaBot.initialize failed and the bot is disabled. \(error)")
        }
    }

    /// Presents the chat over the host app.
    ///
    /// - Parameters:
    ///   - presenter: the view controller to present from. When `nil`, the top-most view
    ///     controller of the active window is used, which is what a button handler almost
    ///     always wants.
    ///   - question: optional: put in the chat's message box for the customer to send —
    ///     they still tap send. It travels in the URL's #fragment, never in a server log.
    ///     With the chat already showing, it replaces what is in the box.
    public static func show(from presenter: UIViewController? = nil, question: String? = nil) {
        onMain {
            guard let configuration = state.configuration else {
                fail("KeydaBot.show() was called before a successful initialize(clientId:). Nothing was presented.")
                return
            }
            // Two taps on a support button must not stack two chats; a question for a
            // chat already showing goes into its message box instead.
            if let showing = state.presented {
                if let question = question { showing.prefill(question) }
                return
            }

            guard let host = (presenter ?? topMostViewController())?.topOfPresentationStack else {
                KeydaBotLog.error("KeydaBot.show() found no visible view controller to present from. Nothing was presented.")
                return
            }

            let controller = KeydaBotViewController(configuration: configuration, question: question)
            controller.onCloseRequested = { KeydaBot.dismiss() }
            // The one place a gone sheet is reported, however it went: the close button,
            // `dismiss()`, a swipe down, or the host dismissing it (or the screen under
            // it) itself. The controller calls this once. Identity-checked: a sheet
            // closed by `dismiss()` reports after a new one may already be up.
            controller.onDidDismiss = { [weak controller] in
                if KeydaBot.state.presented === controller { KeydaBot.state.presented = nil }
                KeydaBot.state.onDismiss?()
            }

            controller.modalPresentationStyle = .pageSheet
            controller.presentationController?.delegate = controller
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.large()]
                // The grabber is the only hint that the sheet can be swiped away; the
                // close button covers everyone who never tries.
                sheet.prefersGrabberVisible = true
            }

            state.presented = controller
            host.present(controller, animated: true) {
                KeydaBot.state.onShow?()
            }
        }
    }

    /// Closes the chat. Safe to call when nothing is showing.
    public static func dismiss() {
        onMain {
            guard let controller = state.presented else { return }
            state.presented = nil
            // `onDismiss` comes from the controller once it has gone (`onDidDismiss`).
            controller.presentingViewController?.dismiss(animated: true)
        }
    }

    /// Called on the main thread once the chat sheet is on screen.
    public static var onShow: (() -> Void)? {
        get { state.onShow }
        set { state.onShow = newValue }
    }

    /// Called on the main thread once the chat sheet has gone — by its close button, a
    /// swipe down, `dismiss()`, or your app dismissing it or the screen under it.
    public static var onDismiss: (() -> Void)? {
        get { state.onDismiss }
        set { state.onDismiss = newValue }
    }

    /// Called on the main thread when a person from the business has answered a
    /// customer who asked for one, while no chat was on screen — so they have not seen
    /// it. Once per new reply. Show a badge or a dot on your chat button;
    /// `hasUnreadReply` stays `true` until the customer opens the chat, which shows the
    /// reply. The SDK asks when your app comes to the foreground (once a minute at
    /// most), and when you call `checkForReplies()`.
    public static var onReply: (() -> Void)? {
        get { state.onReply }
        set { state.onReply = newValue }
    }

    /// `true` when the business has replied to this customer while no chat was on
    /// screen, until the customer opens the chat. Only a reply the chat itself has not
    /// shown yet counts. A chat that is loaded but not on screen — an embedded chat in a
    /// tab that is not selected — may draw the reply, but that is not the customer
    /// seeing it: it stays unread until a chat is on screen. Any thread.
    public static var hasUnreadReply: Bool {
        KeydaBotReplies.shared.hasUnreadReply
    }

    /// Asks now whether the business has replied, rather than at the next foreground.
    /// At most one request every 10 seconds; none at all unless the customer asked for
    /// a person in the last 14 days. The answer arrives as `onReply`.
    public static func checkForReplies() {
        KeydaBotReplies.shared.look(forced: true)
    }

    /// Your signed-in customer, so the chat does not ask them what your app already
    /// knows. Offered — never sent — in the forms that ask for them: "talk to a person",
    /// an order, a booking, and a welcome question for a name, a phone number or an
    /// email. The customer sees the values and submits them; until then nothing leaves
    /// the phone (they travel in the URL's #fragment, which no server sees). They are
    /// your app's word, not a verified identity, and are treated as typed by the
    /// customer. Each is optional; one that does not look like what it claims is
    /// dropped whole, never shortened: a name of up to 80 characters, a phone number of
    /// 8–15 digits (with spaces and `+ - ( ) .`, not starting `+0`), an email address of
    /// up to 254. Applies to every chat open now, embedded ones included, and every one
    /// after.
    public static func setVisitor(name: String? = nil, phone: String? = nil, email: String? = nil) {
        state.visitor = KeydaBotVisitor(name: name, phone: phone, email: email)
        onMain {
            NotificationCenter.default.post(name: KeydaBotViewController.visitorChanged, object: nil)
        }
    }

    /// Forgets `setVisitor`'s details — call it when the customer signs out.
    public static func clearVisitor() {
        setVisitor(name: nil, phone: nil, email: nil)
    }

    /// The details from `setVisitor`, cleaned; `nil` for none.
    static var visitor: KeydaBotVisitor? {
        state.visitor
    }

    /// From the reply check, on the main thread.
    static func deliverReply() {
        state.onReply?()
    }

    /// The chat as a view controller for one of your own screens — a Help tab, a support
    /// screen — instead of the sheet `show()` presents. Push it, or add it as a child.
    ///
    /// It has no close button: your screen's navigation is the way out. The chat starts
    /// below the top safe area (a navigation bar, the status bar) and pads itself above a
    /// tab bar or the home indicator, and it moves out of the keyboard's way itself. In
    /// SwiftUI, use `KeydaBotView`.
    ///
    /// - Parameter question: optional, as in `show(from:question:)`.
    /// - Returns: `nil` before a successful `initialize(clientId:)`.
    @MainActor
    public static func makeChatViewController(question: String? = nil) -> UIViewController? {
        makeController(question: question, showsCloseButton: false)
    }

    @MainActor
    static func makeController(question: String?, showsCloseButton: Bool) -> KeydaBotViewController? {
        guard let configuration = state.configuration else {
            fail("KeydaBot: the chat was asked for before a successful initialize(clientId:).")
            return nil
        }
        return KeydaBotViewController(configuration: configuration, question: question, showsCloseButton: showsCloseButton)
    }

    /// Whether the chat is presented right now.
    ///
    /// Reads `false` once the sheet is gone by any route, including a swipe down or a
    /// dismissal the host performed itself.
    public static var isShowing: Bool {
        state.presented != nil
    }

    // MARK: - Internals

    /// Loud in development, survivable in production. `assertionFailure` is compiled
    /// out of release builds, so a shipping app gets a fault-level log and a disabled
    /// bot instead of a crash in front of its users.
    private static func fail(_ message: String) {
        KeydaBotLog.fault(message)
        assertionFailure(message)
    }

    /// Runs `work` on the main thread: now when already there, else next on the main
    /// queue. The box carries the closure across; it is only ever run on main.
    private static func onMain(_ work: @escaping @MainActor () -> Void) {
        let box = MainWork(work)
        if Thread.isMainThread {
            MainActor.assumeIsolated { box.run() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.run() }
            }
        }
    }

    @MainActor
    private static func topMostViewController() -> UIViewController? {
        // `UIApplication.windows` is deprecated and returns windows from background
        // scenes; presenting into one of those puts the chat on a screen nobody is
        // looking at.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.filter { $0.activationState == .foregroundActive }
        let window = (foreground.isEmpty ? scenes : foreground)
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? foreground.flatMap { $0.windows }.first
        return window?.rootViewController
    }
}

/// `KeydaBot`'s two pieces of state. A lock rather than the main actor, so that
/// `isShowing` can still be read synchronously from any thread.
private final class KeydaBotState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: KeydaBotConfiguration?
    private weak var storedPresented: KeydaBotViewController?

    /// `nil` until `initialize` succeeds. A failed `initialize` deliberately leaves it
    /// `nil` so that a later `show()` refuses instead of opening a 404 in front of
    /// somebody's customer.
    var configuration: KeydaBotConfiguration? {
        get { lock.lock(); defer { lock.unlock() }; return storedConfiguration }
        set { lock.lock(); storedConfiguration = newValue; lock.unlock() }
    }

    /// Weak on purpose. While the sheet is up UIKit holds it; if the host tears down
    /// its modal stack without telling us, this goes `nil` on its own and `isShowing`
    /// stops lying.
    var presented: KeydaBotViewController? {
        get { lock.lock(); defer { lock.unlock() }; return storedPresented }
        set { lock.lock(); storedPresented = newValue; lock.unlock() }
    }

    private var storedOnShow: (() -> Void)?
    private var storedOnDismiss: (() -> Void)?

    /// The host's callbacks; read and written from any thread, called on main.
    var onShow: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnShow }
        set { lock.lock(); storedOnShow = newValue; lock.unlock() }
    }

    var onDismiss: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnDismiss }
        set { lock.lock(); storedOnDismiss = newValue; lock.unlock() }
    }

    private var storedOnReply: (() -> Void)?
    private var storedVisitor: KeydaBotVisitor?

    var onReply: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnReply }
        set { lock.lock(); storedOnReply = newValue; lock.unlock() }
    }

    var visitor: KeydaBotVisitor? {
        get { lock.lock(); defer { lock.unlock() }; return storedVisitor }
        set { lock.lock(); storedVisitor = newValue; lock.unlock() }
    }
}

/// A main-actor closure on its way to the main queue (see `KeydaBot.onMain`).
private struct MainWork: @unchecked Sendable {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}

private extension UIViewController {
    /// UIKit silently ignores `present` on a controller that is already presenting
    /// something, so walk to whatever is actually on top first.
    var topOfPresentationStack: UIViewController {
        var controller = self
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}
#endif
