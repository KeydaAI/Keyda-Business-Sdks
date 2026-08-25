#if canImport(UIKit)
import UIKit

/// The whole public surface of the SDK.
///
/// `KeydaBot` presents one screen: a sheet containing a `WKWebView` pointed at
/// `{baseUrl}/chat/{clientId}`. There is no message API, no unread count and no
/// identity call here, because there is nothing behind them yet — a method that does
/// not work end to end is worse than a missing one.
///
/// Call these from the main thread. Calls that arrive on another thread are hopped to
/// the main queue rather than being allowed to corrupt UIKit state; the hop is a
/// safety net, not a supported calling convention.
@available(iOSApplicationExtension, unavailable,
           message: "KeydaBot presents UI over the host app and opens links in Safari, neither of which an app extension can do.")
public enum KeydaBot {

    // MARK: - State

    /// `nil` until `initialize` succeeds. A failed `initialize` deliberately leaves it
    /// `nil` so that a later `show()` refuses instead of opening a 404 in front of
    /// somebody's customer.
    private static var configuration: KeydaBotConfiguration?

    /// Weak on purpose. While the sheet is up UIKit holds it; if the host tears down
    /// its modal stack without telling us, this goes `nil` on its own and `isShowing`
    /// stops lying.
    private static weak var presentedController: KeydaBotViewController?

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
            configuration = try KeydaBotConfiguration(clientId: clientId, baseUrl: baseUrl)
        } catch {
            configuration = nil
            fail("KeydaBot.initialize failed and the bot is disabled. \(error)")
        }
    }

    /// Presents the chat over the host app.
    ///
    /// - Parameter presenter: the view controller to present from. When `nil`, the
    ///   top-most view controller of the active window is used, which is what a button
    ///   handler almost always wants.
    public static func show(from presenter: UIViewController? = nil) {
        onMain {
            guard let configuration = configuration else {
                fail("KeydaBot.show() was called before a successful initialize(clientId:). Nothing was presented.")
                return
            }
            // Two taps on a support button must not stack two chats.
            guard presentedController == nil else { return }

            guard let host = (presenter ?? topMostViewController())?.topOfPresentationStack else {
                KeydaBotLog.error("KeydaBot.show() found no visible view controller to present from. Nothing was presented.")
                return
            }

            let controller = KeydaBotViewController(configuration: configuration)
            controller.onCloseRequested = { KeydaBot.dismiss() }
            // Swipe-to-dismiss bypasses `dismiss()` entirely, so without this
            // `isShowing` would stay `true` for a sheet that is already gone.
            controller.onDidDismiss = { KeydaBot.presentedController = nil }

            controller.modalPresentationStyle = .pageSheet
            controller.presentationController?.delegate = controller
            if #available(iOS 15.0, *), let sheet = controller.sheetPresentationController {
                sheet.detents = [.large()]
                // The grabber is the only hint that the sheet can be swiped away; the
                // close button covers everyone who never tries.
                sheet.prefersGrabberVisible = true
            }

            presentedController = controller
            host.present(controller, animated: true)
        }
    }

    /// Closes the chat. Safe to call when nothing is showing.
    public static func dismiss() {
        onMain {
            guard let controller = presentedController else { return }
            presentedController = nil
            controller.presentingViewController?.dismiss(animated: true)
        }
    }

    /// Whether the chat is presented right now.
    ///
    /// Reads `false` once the sheet is gone by any route, including a swipe down or a
    /// dismissal the host performed itself.
    public static var isShowing: Bool {
        presentedController != nil
    }

    // MARK: - Internals

    /// Loud in development, survivable in production. `assertionFailure` is compiled
    /// out of release builds, so a shipping app gets a fault-level log and a disabled
    /// bot instead of a crash in front of its users.
    private static func fail(_ message: String) {
        KeydaBotLog.fault(message)
        assertionFailure(message)
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

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
