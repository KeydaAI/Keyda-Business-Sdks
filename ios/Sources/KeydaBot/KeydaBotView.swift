#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// The chat as a SwiftUI view, for a Help tab or a support screen of your own.
///
/// ```swift
/// KeydaBotView()                                // after KeydaBot.initialize(clientId:)
/// KeydaBotView(question: "Is this in stock?")
/// ```
///
/// No close button: the screen it sits in is the way out. It starts below the top safe
/// area, pads itself above a tab bar or the home indicator, and moves out of the
/// keyboard's way itself (so SwiftUI's own keyboard avoidance is switched off for it).
/// A new `question` on a view already showing goes into the chat's message box.
///
/// To present the chat as a sheet instead, use `.keydaBot(isPresented:question:)`.
@available(iOSApplicationExtension, unavailable)
public struct KeydaBotView: View {
    private let question: String?
    private let onClose: (() -> Void)?

    /// - Parameter question: optional: put in the chat's message box for the customer to
    ///   send. It travels in the URL's #fragment, never in a server log.
    public init(question: String? = nil) {
        self.question = question
        self.onClose = nil
    }

    init(question: String?, onClose: @escaping () -> Void) {
        self.question = question
        self.onClose = onClose
    }

    public var body: some View {
        KeydaBotRepresentable(question: question, onClose: onClose)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

@available(iOSApplicationExtension, unavailable)
private struct KeydaBotRepresentable: UIViewControllerRepresentable {
    let question: String?
    let onClose: (() -> Void)?

    final class Coordinator {
        var lastQuestion: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.lastQuestion = question
        // Before initialize(clientId:) there is no chat to show; KeydaBot has already
        // said so in the log, and an empty controller is all there is to render.
        guard let controller = KeydaBot.makeController(question: question, showsCloseButton: onClose != nil) else {
            return UIViewController()
        }
        controller.onCloseRequested = onClose
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let chat = controller as? KeydaBotViewController else { return }
        chat.onCloseRequested = onClose
        if question != context.coordinator.lastQuestion {
            context.coordinator.lastQuestion = question
            if let question = question { chat.prefill(question) }
        }
    }
}

@available(iOSApplicationExtension, unavailable)
public extension View {
    /// Presents the chat as a sheet while `isPresented` is true, with its own close
    /// button; closing it (the button or a swipe down) sets `isPresented` back to false.
    ///
    /// SwiftUI owns this sheet: `KeydaBot.isShowing`, `onShow` and `onDismiss` describe
    /// the sheet `KeydaBot.show()` presents, not this one.
    func keydaBot(isPresented: Binding<Bool>, question: String? = nil) -> some View {
        sheet(isPresented: isPresented) {
            KeydaBotView(question: question, onClose: { isPresented.wrappedValue = false })
                .ignoresSafeArea()
        }
    }
}
#endif
