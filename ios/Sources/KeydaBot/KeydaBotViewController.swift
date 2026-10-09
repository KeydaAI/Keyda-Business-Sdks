#if canImport(UIKit)
import UIKit
import WebKit

/// Forwards `keydaBot` script messages to the controller without retaining it.
///
/// `WKUserContentController` holds its message handlers strongly, and the controller
/// holds the web view, so registering the controller itself would be a retain cycle
/// that keeps every dismissed sheet — and its web content process — alive for the life
/// of the app. The proxy is what the content controller retains; the controller behind
/// it is weak, and once it is gone the message is simply dropped.
@available(iOSApplicationExtension, unavailable)
private final class KeydaBotScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: KeydaBotViewController?

    init(target: KeydaBotViewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.receive(scriptMessage: message)
    }
}

/// Hosts the hosted chat page — as the sheet `KeydaBot.show()` presents (with its own
/// close bar), or embedded in one of the host's screens (`KeydaBot.makeChatViewController`,
/// SwiftUI's `KeydaBotView`), where the screen around it owns the way out.
///
/// Internal on purpose: the public surface hands it out as a plain `UIViewController`,
/// so this stays free to change.
@available(iOSApplicationExtension, unavailable)
final class KeydaBotViewController: UIViewController {

    private let botConfiguration: KeydaBotConfiguration

    /// The sheet has a close bar; an embedded chat does not — the host's screen has its
    /// own navigation.
    private let showsCloseButton: Bool

    /// A question to start with: in the URL's fragment at the first load (never in a
    /// server log), or put in the composer once the page is up (`prefill`).
    private var question: String?
    private var pendingPrefill: String?

    /// Called when the close button is tapped. `KeydaBot` owns dismissal so that its
    /// `isShowing` never disagrees with what is on screen.
    var onCloseRequested: (() -> Void)?

    /// Called after an interactive (swipe-down) dismissal, which never goes through
    /// `KeydaBot.dismiss()`.
    var onDidDismiss: (() -> Void)?

    /// Once the chat has rendered, no later navigation failure is allowed to replace
    /// it with a retry screen. See `handle(_:)`.
    private var hasRenderedChat = false

    /// The start (question, visitor) has reached a page that rendered. Every load after
    /// that — Retry, a terminated web content process — takes the plain chat URL: the
    /// same URL plus a #fragment is a same-document jump that loads nothing, and a
    /// question the customer already sent must not come back into the box.
    private var startDelivered = false
    private var loadAttempted = false

    /// `onDidDismiss` is called once, whichever route the sheet left by.
    private var dismissReported = false

    /// On screen as far as the reply check knows (`KeydaBotReplies`).
    private var countedOnScreen = false

    /// Posted on the main queue when `KeydaBot.setVisitor` changes the details.
    static let visitorChanged = Notification.Name("in.keyda.bot.visitorChanged")

    /// The URL the chat is judged against. Starts as the configured chat URL and moves
    /// only when the host redirects the FIRST load (apex → `www.`, `http` → `https`);
    /// see `decidePolicyFor navigationAction`.
    private var chatURL: URL

    /// The `WKScriptMessageHandler` name the hosted page posts its theme to:
    /// `window.webkit.messageHandlers.keydaBot.postMessage(json)`. Fixed by the
    /// contract (rule 7); renaming it here silently turns the theme bridge off.
    private static let scriptMessageHandlerName = "keydaBot"

    /// The container colour, per the contract: `#0b1220` in dark, `#f7f8fc` in light.
    /// Dynamic rather than fixed so that it follows the device until the page reports
    /// (`overrideUserInterfaceStyle == .unspecified`) and the page's verdict afterwards
    /// — the same colour object serves both without being reassigned.
    private static let containerBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x0b / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0, alpha: 1)
            : UIColor(red: 0xf7 / 255.0, green: 0xf8 / 255.0, blue: 0xfc / 255.0, alpha: 1)
    }

    init(configuration: KeydaBotConfiguration, question: String? = nil, showsCloseButton: Bool = true) {
        self.botConfiguration = configuration
        self.chatURL = configuration.chatURL
        self.question = Self.cleaned(question)
        self.showsCloseButton = showsCloseButton
        super.init(nibName: nil, bundle: nil)
    }

    /// A question worth sending: trimmed, at most 500 characters (the page's own cap),
    /// nil when empty.
    private static func cleaned(_ question: String?) -> String? {
        guard let text = question?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(500))
    }

    /// Puts `question` in the chat's message box, unsent — the customer still taps
    /// send. Before the page has loaded it waits for it.
    func prefill(_ question: String) {
        guard let text = Self.cleaned(question) else { return }
        guard hasRenderedChat else {
            pendingPrefill = text
            return
        }
        // A JSON string is a valid JavaScript string literal: no hand-escaping.
        guard let data = try? JSONEncoder().encode(text), let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "(function(){try{window.KeydaBot&&window.KeydaBot.prefill&&window.KeydaBot.prefill(\(literal));}catch(e){}})()"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeydaBotViewController is created by KeydaBot.show(), never from a storyboard.")
    }

    deinit {
        // A chat let go without `viewDidDisappear` (a host that drops a child without the
        // appearance calls) must not hold the count up: no reply would ever be asked
        // for again. The count is lock-guarded, so any thread will do.
        if countedOnScreen { KeydaBotReplies.shared.chatWentAway() }

        // The proxy already keeps this from being a cycle; removing the handler is
        // hygiene so the content controller does not keep forwarding into a dead
        // proxy. Guarded on `isViewLoaded` because `webView` is lazy: touching it here
        // on a controller that never loaded would build a web view just to tear it down.
        //
        // A deinit is not main-actor isolated, though UIKit releases its view
        // controllers on the main thread. Off it, the handler is left: hygiene is not
        // worth touching WebKit from the wrong thread.
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            if isViewLoaded {
                webView.configuration.userContentController
                    .removeScriptMessageHandler(forName: Self.scriptMessageHandlerName)
            }
        }
    }

    /// `.default` is not "always dark text" on iOS 13+: it resolves against this
    /// controller's trait collection, so once `overrideUserInterfaceStyle` is set from
    /// the page's theme the status bar flips with it — light text over `#0b1220`, dark
    /// text over `#f7f8fc` — and before that it follows the device, like everything
    /// else. Returning `.lightContent`/`.darkContent` by hand would only duplicate that
    /// logic and drift from it.
    override var preferredStatusBarStyle: UIStatusBarStyle { .default }

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

    /// The bar the close button lives in, ABOVE the chat rather than over it.
    ///
    /// It used to float over the top-right corner of the page — which is exactly
    /// where the chat's header keeps its own buttons (the menu), so on every
    /// iPhone the ✕ sat on top of a control the customer could then not reach.
    /// A bar of its own, in the container colour, is what the Flutter and React
    /// Native shells already do; the sheet's grabber sits in it too.
    private lazy var closeBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = Self.containerBackground
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    /// The bar's height below the safe area: a 44pt button with room around it.
    private static let closeBarHeight: CGFloat = 52

    private lazy var failureView: UIView = makeFailureView()

    /// The web view's bottom edge, moved up to the keyboard's top while it is on
    /// screen (see `keyboardFrameWillChange`).
    private lazy var webViewBottom: NSLayoutConstraint = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.containerBackground

        // The web view is pinned to the view's edges, not to the safe area. The page
        // ships `viewport-fit=cover` and pads its own content with
        // `env(safe-area-inset-*)`, so full-bleed means its background runs under the
        // notch and the home indicator while its text and its composer do not. Inset
        // the web view instead and you get two bands of container colour that will not
        // match whatever accent the owner picked.
        view.addSubview(webView)
        view.addSubview(failureView)
        view.addSubview(activityIndicator)

        // Before the embedded branch returns: a chat in the host's own screen takes
        // `setVisitor` / `clearVisitor` as the sheet does.
        NotificationCenter.default.addObserver(
            self, selector: #selector(visitorDidChange), name: Self.visitorChanged, object: nil
        )

        guard showsCloseButton else {
            // Embedded: no bar of our own. The chat starts below whatever the screen has
            // at its top (a navigation bar, the status bar) and runs to the bottom edge,
            // where the page pads itself above a tab bar or the home indicator.
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
                webViewBottom,

                failureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                failureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            observeKeyboard()
            load()
            return
        }

        view.addSubview(closeBar)
        closeBar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            // The bar runs under the status bar or Dynamic Island when the sheet is
            // full screen (iPhone landscape, some iPad sizes) and ends a fixed height
            // below the safe area, so the button never sits under either.
            closeBar.topAnchor.constraint(equalTo: view.topAnchor),
            closeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            closeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            closeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.closeBarHeight),

            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            closeButton.bottomAnchor.constraint(equalTo: closeBar.bottomAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Under the bar, and inside the side safe areas so a landscape notch
            // never covers the chat's header or its composer. The BOTTOM stays at the
            // view's edge: the page pads itself above the home indicator
            // (env(safe-area-inset-bottom)), so its own background runs under it.
            webView.topAnchor.constraint(equalTo: closeBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webViewBottom,

            failureView.topAnchor.constraint(equalTo: closeBar.bottomAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        observeKeyboard()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A keyboard that went away while this screen was not in a window (a tab switch
        // with the keyboard up) never told us: start from no keyboard, the next frame
        // change corrects it.
        if webViewBottom.constant != 0 { webViewBottom.constant = 0 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !countedOnScreen {
            countedOnScreen = true
            KeydaBotReplies.shared.chatAppeared()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if countedOnScreen {
            countedOnScreen = false
            KeydaBotReplies.shared.chatWentAway()
        }
        // Gone for good, by any route: our close button, `KeydaBot.dismiss()`, a swipe,
        // or the host dismissing this sheet — or the screen it sits on — itself. A
        // screen merely covered by another (a full-screen picker) is still presented.
        let presenterGone = presentingViewController == nil || presentingViewController?.isBeingDismissed == true
        if isBeingDismissed || presenterGone { reportDismissed() }
    }

    fileprivate func reportDismissed() {
        guard !dismissReported, onDidDismiss != nil else { return }
        dismissReported = true
        onDidDismiss?()
    }

    @objc private func visitorDidChange() {
        applyVisitor()
    }

    /// `KeydaBot.setVisitor` reaching a page that is already up.
    private func applyVisitor() {
        guard hasRenderedChat else { return }
        let json = KeydaBot.visitor?.json ?? "{}"
        webView.evaluateJavaScript(
            "(function(){try{window.KeydaBot&&window.KeydaBot.setVisitor&&window.KeydaBot.setVisitor(\(json));}catch(e){}})()"
        )
    }

    // MARK: - Loading

    private func load() {
        failureView.isHidden = true
        activityIndicator.startAnimating()
        if !startDelivered && loadAttempted, pendingPrefill == nil {
            // The first load failed before the page took its question: by script this
            // time, once the page is up.
            pendingPrefill = question
        }
        let url = loadAttempted || startDelivered ? botConfiguration.chatURL : urlWithStart()
        loadAttempted = true
        webView.load(URLRequest(url: url))
    }

    /// The chat URL with its start in the #fragment — the question, and
    /// `KeydaBot.setVisitor`'s details. The page reads it as it loads and takes it off
    /// the address. A fragment never reaches a server.
    private func urlWithStart() -> URL {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "&=+#")
        let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var items: [String] = []
        if let question = question { items.append("q=" + encode(question)) }
        if let visitor = KeydaBot.visitor { items += visitor.fragmentItems(encode: encode) }
        guard !items.isEmpty,
              var parts = URLComponents(url: botConfiguration.chatURL, resolvingAgainstBaseURL: false) else {
            return botConfiguration.chatURL
        }
        parts.percentEncodedFragment = items.joined(separator: "&")
        return parts.url ?? botConfiguration.chatURL
    }

    /// A startup redirect is followed only while the first load is still in flight and
    /// only when it stays on the chat's own host (or moves between apex and `www.`).
    /// Mirrors `startupRedirect` in the Android SDK: a base URL that redirects would
    /// otherwise have its own chat thrown into Safari before it ever rendered, leaving
    /// a stopped spinner and an empty sheet behind — `handle(_:)` cannot show a retry
    /// for it because the cancellation arrives as -999, which it must ignore. Gated on
    /// `.other` so a link tapped inside a live conversation can never move the sheet.
    private func isStartupRedirect(_ url: URL, _ action: WKNavigationAction) -> Bool {
        guard !hasRenderedChat, action.navigationType == .other,
              let host = url.host?.lowercased(),
              let chatHost = chatURL.host?.lowercased() else { return false }
        return host == chatHost || host == "www." + chatHost || "www." + host == chatHost
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

    // MARK: - Theme

    /// Applies the theme the hosted page reports, and nothing else.
    ///
    /// The page is the only party that knows the owner's dashboard setting, so the
    /// shell never guesses: until a `keyda:theme` message arrives the override stays
    /// `.unspecified` and the chrome follows the device, which is exactly what "Match
    /// the visitor" means and what a backend that predates the bridge gets. Parsing is
    /// deliberately forgiving — anything that is not a JSON object with
    /// `type == "keyda:theme"` and a recognised `mode` is dropped without a trace.
    /// This runs inside the host's process; a malformed message must never bring it
    /// down (rule 6).
    fileprivate func receive(scriptMessage message: WKScriptMessage) {
        guard message.name == Self.scriptMessageHandlerName else { return }

        // WebKit hands a JS string through as `String` and a JS object as a dictionary;
        // the page sends a string, but accept both so a future page that posts the
        // object directly still works.
        let payload: [String: Any]?
        if let text = message.body as? String {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return }
            payload = object as? [String: Any]
        } else {
            payload = message.body as? [String: Any]
        }

        // The chats waiting for the business's reply (`KeydaBotReplies`), validated there.
        // A chat that is loaded but not on screen still draws a reply; that is not the
        // customer seeing it.
        if payload?["type"] as? String == "keyda:waits" {
            KeydaBotReplies.shared.onWaits(
                payload?["waits"] as? [Any],
                fromOnScreen: countedOnScreen,
                chat: botConfiguration.chatURL.absoluteString
            )
            return
        }

        guard let theme = payload, theme["type"] as? String == "keyda:theme" else { return }

        let style: UIUserInterfaceStyle
        switch theme["mode"] as? String {
        case "dark": style = .dark
        case "light": style = .light
        default: return
        }
        apply(style)
    }

    /// One switch flips the whole chrome: `overrideUserInterfaceStyle` re-resolves
    /// `containerBackground` (the view and the close bar), the close button's
    /// `.label` tint, and `preferredStatusBarStyle` (`.default`) reads the same
    /// trait — so there is nothing to recolour by hand.
    private func apply(_ style: UIUserInterfaceStyle) {
        // Main thread: WebKit delivers script messages there, and this controller is
        // main-actor isolated, which Swift 6 checks at every caller.
        guard overrideUserInterfaceStyle != style else { return }
        overrideUserInterfaceStyle = style
        setNeedsStatusBarAppearanceUpdate()
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

    /// Ends the web view at the keyboard's top edge while the keyboard is up.
    ///
    /// The page then simply has less room: nothing of it is under the keys, and its
    /// own layout (composer at the bottom, header at the top) holds. Up to 0.1.4 this
    /// fed the keyboard to the page as extra bottom safe area instead, on top of
    /// WebKit's own shrinking of the page's visible area — the composer rose a
    /// second keyboard-height, up under the header, and in landscape the two
    /// disagreed and it ended up behind the keys. The Flutter and React Native shells
    /// shrink their web view the same way, and both fit exactly.
    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        // While we are off screen, the keyboard belongs to somebody else's screen.
        guard view.window != nil else { return }
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        // The keyboard's frame is in the screen's coordinates. `from: nil` would read it
        // as the window's, which is only the same while the window sits at the screen's
        // origin — not in Stage Manager, Slide Over or Split View on an iPad.
        guard let screen = view.window?.windowScene?.screen else { return }
        let keyboardFrame = view.convert(endFrame, from: screen.coordinateSpace)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        setKeyboardOverlap(overlap, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard view.window != nil else { return }
        setKeyboardOverlap(0, notification: notification)
    }

    private func setKeyboardOverlap(_ overlap: CGFloat, notification: Notification) {
        guard webViewBottom.constant != -overlap else { return }

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        // The curve is a UIView.AnimationCurve, which lives in the top half of an
        // AnimationOptions bit field; matching it is what keeps the page in step with
        // the keyboard instead of trailing behind it.
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.webViewBottom.constant = -overlap
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
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // A voice note or a video in an answer plays where the conversation is instead
        // of taking over the screen and hiding it.
        configuration.allowsInlineMediaPlayback = true
        // Nothing starts making noise inside somebody else's app on its own.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        // Rule 7: the page announces the owner's resolved theme through this handler
        // as early as its <head> runs, and again when a "Match the visitor" bot flips
        // with the OS. Registered through a weak proxy — see
        // `KeydaBotScriptMessageProxy` for why not `self`.
        configuration.userContentController.add(
            KeydaBotScriptMessageProxy(target: self),
            name: Self.scriptMessageHandlerName
        )

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

    private func makeFailureView() -> UIView {
        let container = UIView()
        // Opaque: it covers a blank web view rather than sitting over it. The same
        // colour as the container so the retry screen does not contradict the theme
        // the page last reported.
        container.backgroundColor = Self.containerBackground
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
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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
        let staysInChat = KeydaBotConfiguration.staysInChat(url, chatURL: chatURL)

        if staysInChat && !isNewWindow {
            decisionHandler(.allow)
        } else if !isNewWindow && isStartupRedirect(url, navigationAction) {
            KeydaBotLog.error("KeydaBot: the chat host redirected to \(url.host ?? "?"); following it in place.")
            chatURL = url
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            openOutsideTheChat(url)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
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
        startDelivered = true
        activityIndicator.stopAnimating()
        failureView.isHidden = true
        // Every load, the first included: a reload has no fragment, and a `setVisitor` or
        // `clearVisitor` made while the page loaded never reached it. `{}` for none, so a
        // sign-out during the first load takes back what its fragment offered.
        applyVisitor()
        // A question that arrived while the page was loading; the page keeps it until
        // its composer exists.
        if let waiting = pendingPrefill {
            pendingPrefill = nil
            prefill(waiting)
        }
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
        reportDismissed()
    }
}
#endif
