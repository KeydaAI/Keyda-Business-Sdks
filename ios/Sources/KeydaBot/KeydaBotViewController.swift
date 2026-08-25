#if canImport(UIKit)
import UIKit
import WebKit

/// Hosts the hosted chat page.
///
/// Internal on purpose: the contract every Keyda SDK implements exposes four calls and
/// no view controller, so this stays free to change.
@available(iOSApplicationExtension, unavailable)
final class KeydaBotViewController: UIViewController {

    private let botConfiguration: KeydaBotConfiguration

    /// Called when the close button is tapped. `KeydaBot` owns dismissal so that its
    /// `isShowing` never disagrees with what is on screen.
    var onCloseRequested: (() -> Void)?

    /// Called after an interactive (swipe-down) dismissal, which never goes through
    /// `KeydaBot.dismiss()`.
    var onDidDismiss: (() -> Void)?

    /// Once the chat has rendered, no later navigation failure is allowed to replace
    /// it with a retry screen. See `handle(_:)`.
    private var hasRenderedChat = false

    init(configuration: KeydaBotConfiguration) {
        self.botConfiguration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeydaBotViewController is created by KeydaBot.show(), never from a storyboard.")
    }

    // MARK: - Views

    private lazy var webView: WKWebView = makeWebView()

    private lazy var activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        if let image = UIImage(systemName: "xmark") {
            button.setImage(image, for: .normal)
        } else {
            button.setTitle("\u{2715}", for: .normal)
        }
        button.tintColor = .label
        button.accessibilityLabel = "Close chat"
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// A blur circle behind the close button. The page picks its own background colour
    /// from the owner's dashboard settings, so a flat colour here would eventually be
    /// invisible against one of them.
    private lazy var closeButtonBackground: UIVisualEffectView = {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        effect.layer.cornerRadius = 22
        effect.clipsToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        return effect
    }()

    private lazy var failureView: UIView = makeFailureView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // The web view is pinned to the view's edges, not to the safe area. The page
        // ships `viewport-fit=cover` and pads its own content with
        // `env(safe-area-inset-*)`, so full-bleed means its background runs under the
        // notch and the home indicator while its text and its composer do not. Inset
        // the web view instead and you get two bands of container colour that will not
        // match whatever accent the owner picked.
        view.addSubview(webView)
        view.addSubview(failureView)
        view.addSubview(activityIndicator)
        view.addSubview(closeButtonBackground)
        closeButtonBackground.contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            failureView.topAnchor.constraint(equalTo: view.topAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            // Anchored to the safe area so it never sits under the status bar or a
            // Dynamic Island.
            closeButtonBackground.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButtonBackground.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButtonBackground.widthAnchor.constraint(equalToConstant: 44),
            closeButtonBackground.heightAnchor.constraint(equalToConstant: 44),

            closeButton.topAnchor.constraint(equalTo: closeButtonBackground.contentView.topAnchor),
            closeButton.leadingAnchor.constraint(equalTo: closeButtonBackground.contentView.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: closeButtonBackground.contentView.trailingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: closeButtonBackground.contentView.bottomAnchor)
        ])

        observeKeyboard()
        load()
    }

    // MARK: - Loading

    private func load() {
        failureView.isHidden = true
        activityIndicator.startAnimating()
        webView.load(URLRequest(url: botConfiguration.chatURL))
    }

    @objc private func retryTapped() {
        // `reload()` on a web view whose provisional load never completed reloads
        // nothing, so start the request again from the URL.
        load()
    }

    @objc private func closeTapped() {
        onCloseRequested?()
    }

    private func showFailure() {
        activityIndicator.stopAnimating()
        failureView.isHidden = false
    }

    /// Never let a failure blank out a working conversation.
    private func handle(_ error: Error) {
        activityIndicator.stopAnimating()

        let nsError = error as NSError
        // Every time the visitor taps "Powered by Keyda" the navigation policy below
        // cancels the load, and WebKit reports that cancellation here as -999. Showing
        // a retry screen for it would throw an error over a conversation that is
        // perfectly fine and has just opened a link in Safari.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }

        KeydaBotLog.error("KeydaBot could not load the chat: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")

        // A sub-resource that fails after the chat is up (an image, a request an
        // on-device content blocker ate) must not take the transcript down with it.
        guard !hasRenderedChat else { return }
        showFailure()
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    /// Feeds the keyboard's height to the page as extra bottom safe area.
    ///
    /// `additionalSafeAreaInsets` changes this view's safe area, subviews inherit it,
    /// and `WKWebView` publishes its own safe area to the page as
    /// `env(safe-area-inset-bottom)`. So a composer pinned to the bottom of the page
    /// rises with the keyboard using the padding rule it already has.
    ///
    /// Without this the container keeps reporting only the home-indicator inset while
    /// the keyboard is up, and the composer sits behind the keys — the single most
    /// common defect in WebView chat. `keyboardDisplayRequiresUserAction` is unrelated:
    /// it is about whether script may focus a field, not about what covers it.
    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        // While we are off screen, the keyboard belongs to somebody else's screen.
        guard view.window != nil else { return }
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)

        // `additionalSafeAreaInsets` is added to the real inset, and the real inset
        // (the home indicator) is already inside `overlap` — the keyboard is drawn over
        // it. Passing `overlap` straight through would lift the composer by an extra
        // 34pt and leave a gap under it.
        let systemBottomInset = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        setBottomInset(max(0, overlap - systemBottomInset), notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard view.window != nil else { return }
        setBottomInset(0, notification: notification)
    }

    private func setBottomInset(_ inset: CGFloat, notification: Notification) {
        guard additionalSafeAreaInsets.bottom != inset else { return }

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        // The curve is a UIView.AnimationCurve, which lives in the top half of an
        // AnimationOptions bit field; matching it is what keeps the page in step with
        // the keyboard instead of trailing behind it.
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.additionalSafeAreaInsets.bottom = inset
            self.view.layoutIfNeeded()
        })
    }

    // MARK: - Factories

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // The visitor's conversation is held in DOM storage by the chat page. A
        // non-persistent store would hand them an empty conversation every time they
        // reopened the sheet, and every reply they were waiting on would be gone.
        // There is no `domStorageEnabled` switch on iOS; a persistent store is the
        // whole of it.
        configuration.websiteDataStore = .default()

        // The chat is a web app; with JavaScript off there is no chat at all. Both
        // switches default to on, and both are set anyway so that a future WebKit
        // default cannot quietly turn the product off.
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            enableJavaScriptOnLegacyOS(configuration.preferences)
        }

        // A voice note or a video in an answer plays where the conversation is instead
        // of taking over the screen and hiding it.
        configuration.allowsInlineMediaPlayback = true
        // Nothing starts making noise inside somebody else's app on its own.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self

        // A back-swipe would walk the visitor out of their own conversation with
        // nothing on screen to get back.
        webView.allowsBackForwardNavigationGestures = false

        // The page already pads itself with `env(safe-area-inset-*)`. Leaving UIKit's
        // automatic adjustment on applies the same inset a second time as scroll-view
        // content inset: a dead strip above the home indicator and a composer floating
        // too high.
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Dragging the transcript puts the keyboard away, the way every native chat does.
        webView.scrollView.keyboardDismissMode = .interactive

        // Shows the container colour for the instant before the page paints instead of
        // a white flash inside a dark app.
        webView.isOpaque = false
        webView.backgroundColor = .clear

        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }

    /// `WKPreferences.javaScriptEnabled` is the only switch that exists on iOS 13 and
    /// is deprecated from iOS 14. Marking this wrapper deprecated too is what keeps the
    /// call from emitting a warning in every integrator's build.
    @available(iOS, deprecated: 14.0, message: "Use WKWebpagePreferences.allowsContentJavaScript.")
    private func enableJavaScriptOnLegacyOS(_ preferences: WKPreferences) {
        preferences.javaScriptEnabled = true
    }

    private func makeFailureView() -> UIView {
        let container = UIView()
        // Opaque: it covers a blank web view rather than sitting over it.
        container.backgroundColor = .systemBackground
        container.isHidden = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Chat didn't load"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let message = UILabel()
        // The underlying error goes to the log, not to the screen: "The request timed
        // out" is not something a customer in a shop can act on.
        message.text = "Check your connection and try again."
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        let retry = UIButton(type: .system)
        retry.setTitle("Try again", for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let stack = UIStackView(arrangedSubviews: [title, message, retry])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(20, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
        return container
    }
}

// MARK: - Navigation

@available(iOSApplicationExtension, unavailable)
extension KeydaBotViewController: WKNavigationDelegate {

    /// Decides what stays in the chat and what leaves for Safari.
    ///
    /// The chat page carries at least one real link ("Powered by Keyda"). If it
    /// navigated here, the conversation would be replaced by a marketing site with no
    /// back button and no way to return to it — the visitor's messages are simply gone.
    /// So anything bound for another host, and anything asking for a new window, is
    /// cancelled and handed to the system browser, where the customer can close the tab
    /// and find the chat exactly as they left it.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Sub-frame loads are the page's own machinery, not somebody tapping a link.
        // Sending those to Safari would tear the page apart.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased()

        // WebKit loads `about:blank` into frames itself; it is not a navigation away.
        if scheme == "about" {
            decisionHandler(.allow)
            return
        }

        // blob:, data:, javascript: are the page talking to itself, not a place a
        // person can be taken. Block them and hand the host NOTHING: `UIApplication`
        // has no opener for any of them, so passing one out only produces a failed
        // open and a "could not open outside the chat" line that points at the wrong
        // problem — and a `javascript:` URL is a script, which must never leave the
        // WebView that contains it.
        if let scheme = scheme, KeydaBotConfiguration.isInternalScheme(scheme) {
            decisionHandler(.cancel)
            return
        }

        // tel:, mailto:, sms:, whatsapp: — a WebView cannot load any of these, and they
        // are exactly how a customer reaches the shop they are chatting with. Hand them
        // to the system, which knows what to do with them.
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            openOutsideTheChat(url)
            return
        }

        // `targetFrame == nil` is target="_blank" or window.open(): a new window, which
        // this sheet does not have.
        let isNewWindow = navigationAction.targetFrame == nil
        // Compared by PATH, not just host. The chat's "Powered by Keyda" link points at
        // the same host as the chat itself, so a host-only check would let the marketing
        // site load in place and take the customer's conversation with it. That link
        // happens to carry target="_blank" and so escapes through the branch above — but
        // any same-host link WITHOUT it (an answer that links to a pricing page, a
        // redirect) would not, and would silently destroy the conversation.
        let staysInChat = KeydaBotConfiguration.staysInChat(url, chatURL: botConfiguration.chatURL)

        if staysInChat && !isNewWindow {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            openOutsideTheChat(url)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // A well-formed client id that the platform does not know still passes
        // validation, so the only signal is the status code. Log it loudly for the
        // developer and let the server's own page render: it says what is wrong, and a
        // "Try again" button would be a lie — retrying a 404 gets another 404.
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            KeydaBotLog.fault("KeydaBot: \(botConfiguration.chatURL.absoluteString) returned HTTP \(http.statusCode). Check the client id in Install in the Keyda Business dashboard.")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failureView.isHidden = true
        activityIndicator.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasRenderedChat = true
        activityIndicator.stopAnimating()
        failureView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    /// The web content process was killed, almost always by memory pressure while the
    /// host app was in the background. The web view is left blank and stays blank, so
    /// reload rather than hand the visitor an empty white sheet.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        KeydaBotLog.error("KeydaBot: the web content process was terminated; reloading the chat.")
        hasRenderedChat = false
        load()
    }

    private func openOutsideTheChat(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                KeydaBotLog.error("KeydaBot could not open \(url.absoluteString) outside the chat.")
            }
        }
    }
}

// MARK: - Interactive dismissal

@available(iOSApplicationExtension, unavailable)
extension KeydaBotViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDidDismiss?()
    }
}
#endif
