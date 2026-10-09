package `in`.keyda.bot

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.AttributeSet
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * The chat as a view of your own screen — a "Help" tab, a support screen — instead of the
 * full-screen chat [KeydaBot.show] opens. It is the same hosted page in the same WebView, with the
 * same rules (CONTRACT.md); the full-screen chat is this view inside an Activity.
 *
 * ```
 * val chat = KeydaBotView(context)            // after KeydaBot.init()
 * chat.question = "Is this in stock?"         // optional, before it is shown
 * container.addView(chat)
 * ```
 *
 * From Compose: `AndroidView(factory = { KeydaBotView(it) }, onRelease = { it.destroy() })`.
 *
 * Your screen owns what is around it, so four things are yours:
 *  * **Back.** With a sheet open in the chat (an item, the cart, a booking) back should close it:
 *    check [canGoBack] and call [goBack]; [onCanGoBackChanged] tells you when it changes, which is
 *    what an `OnBackPressedCallback.isEnabled` wants.
 *  * **Insets and the keyboard.** The view pads for nothing. Lay it out clear of the system bars,
 *    and let the window resize for the keyboard (`adjustResize`, or `imePadding()` in Compose).
 *  * **[active]** false while the view is attached and visible but not what the customer is
 *    looking at — a ViewPager2 neighbour, a tab that keeps its views visible.
 *  * **[destroy]** when the screen is gone for good.
 */
class KeydaBotView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    /**
     * A question to put in the message box when the chat loads — the customer still taps send.
     * Set it before the view is shown; for a chat already on screen use [prefill]. It travels in
     * the URL's #fragment, so it is never in a server log. Up to 500 characters, as one line: the
     * chat joins lines and collapses runs of spaces.
     */
    var question: String? = null

    /**
     * Called with true when the chat opens a sheet over the conversation and with false when the
     * last one closes — on the main thread. Drive your back handling from it.
     */
    var onCanGoBackChanged: ((Boolean) -> Unit)? = null

    /**
     * True while the chat has a sheet open that back should close (an item, the cart, a
     * booking). Known from the page itself; a page from before October 2026 never reports one.
     */
    val canGoBack: Boolean
        get() = sheetsOpen > 0 && !errorShowing && !destroyed

    /**
     * Whether this chat is the one the customer is looking at. True by default; set it false while
     * the view stays attached and visible but out of sight — a ViewPager2 page that is not
     * selected, a tab that keeps its views visible — and true again when it is selected. Main
     * thread.
     *
     * It matters for [KeydaBot.hasUnreadReply]: a chat the customer can see shows a reply from the
     * business, so the app does not ask for it and the unread mark goes out; one they cannot see
     * must not put it out. The view tracks its own visibility (a GONE view or a hidden window is
     * off screen already), except below Android 7.0, where only the window is tracked: there a
     * GONE view in a hidden tab still counts as seen unless this is false.
     */
    var active: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            // Below API 24 nothing reports a parent going GONE: look now, the host just said so.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                visibleToPlatform = isAttachedToWindow && windowVisibility == View.VISIBLE && isShown
            }
            updateOnScreen()
        }

    /** Unset only when the device has no usable WebView at all; see [destroyed]. */
    private lateinit var web: WebView
    private val progress: ProgressBar
    private val errorPanel: LinearLayout
    private lateinit var errorText: TextView
    private lateinit var retryButton: Button

    /**
     * Set when the chat URL is known: from [KeydaBot.init] here, from its Intent in the Activity.
     * Volatile: the bridge's thread reads it to tell which client a page's message belongs to.
     */
    @Volatile
    private var chatUrl: String = ""

    /** The chat this view loads, `{baseUrl}/chat/{clientId}`; empty before it knows. */
    internal val pageUrl: String
        get() = chatUrl

    /** Parsed once. Every navigation is compared against this to decide in-app versus browser. */
    private var chatPage: Uri? = null

    private var loadRequested = false
    private var destroyed = false
    private var errorShowing = false

    /**
     * False until the chat has rendered once. Until then the WebView may still be walking whatever
     * redirects sit between the configured base URL and the page itself.
     */
    private var chatEverLoaded = false

    /** The page's sheet count (`keyda:sheets`), and whether it has ever reported one. */
    private var sheetsOpen = 0
    private var sheetsReported = false

    /** A question for the composer that arrived before the page could take it. */
    private var pendingPrefill: String? = null

    /**
     * True once a page has rendered here, so the start question (and its #fragment) has been
     * delivered. Every later load — Retry, [reload], a crashed renderer — loads the plain chat URL:
     * the same URL plus a #fragment is a same-document jump that fetches nothing, and a question
     * already sent must not come back into the box.
     */
    private var startDelivered = false

    /**
     * On screen right now, for the reply check (KeydaBotReplies): visible to the platform, [active]
     * and not destroyed. Written on the main thread with KeydaBotReplies.lock held; read from the
     * bridge's thread to tell whether the customer could see what the page reports.
     */
    @Volatile
    internal var onScreen = false
        private set

    /** What the platform last said: this view, its parents and its window all visible. */
    private var visibleToPlatform = false

    /** The [KeydaBot.visitorVersion] this page was last given; see [applyVisitor]. */
    private var visitorSent = -1

    /** The fallback for a back press the page has not answered yet; see [backOrLeave]. */
    private var pendingBack: Runnable? = null

    /**
     * CONTRACT rule 7. The theme this view is painted in right now. Starts from the device, which
     * is what "Match the visitor" means, and is overwritten by whatever the page reports.
     */
    internal var darkTheme = false
        private set

    /** True once a `keyda:theme` message has arrived; from then on the page decides. */
    private var themeFromPage = false

    /** The owner's accent, when the page sent one that parsed. Null means "use the theme's ink". */
    internal var accent: Int? = null
        private set

    /**
     * The full-screen Activity listens here to paint its window and system bars. An embedded view
     * leaves the bars to the screen it sits in.
     */
    internal var onThemeApplied: (() -> Unit)? = null

    /**
     * Messages from the page arrive on the WebView's JavaBridge thread; every view call below
     * belongs on this one. Cleared in [destroy] so a message that lands during teardown does not
     * run against a dead view.
     */
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        darkTheme = deviceIsDark()
        progress = buildProgress()
        errorPanel = buildErrorPanel()
        try {
            web = buildWebView()
            addView(web)
        } catch (missing: RuntimeException) {
            // No WebView provider, or one being updated right now. Thrown from inside the host's
            // own screen this would take it down (rule 6): the view says so instead, for good.
            Log.e(KeydaBot.TAG, "No usable Android System WebView on this device", missing)
            destroyed = true
        }
        addView(progress)
        addView(errorPanel)
        applyTheme()
        if (destroyed) {
            retryButton.visibility = View.GONE
            showError(MSG_NO_WEBVIEW)
        }
    }

    // ------------------------------------------------------------------------------- public API

    /**
     * Puts [question] in the chat's message box, unsent. On a chat that has not loaded yet it is
     * kept and put there once it has.
     */
    fun prefill(question: String) {
        if (destroyed || question.isBlank()) return
        // Not into a page that is not there: the retry screen's dead page, or one still loading.
        if (!chatEverLoaded || errorShowing) {
            pendingPrefill = question
            return
        }
        web.evaluateJavascript(
            "(function(){try{window.KeydaBot&&window.KeydaBot.prefill&&" +
                "window.KeydaBot.prefill(${JSONObject.quote(question)});}catch(e){}})()",
            null
        )
    }

    /**
     * Closes the sheet the chat has open and returns true; returns false — and does nothing — when
     * there is none, so your screen handles back as it would without the chat.
     */
    fun goBack(): Boolean {
        if (!canGoBack) return false
        web.evaluateJavascript(BACK_SCRIPT, null)
        return true
    }

    /** Loads the chat again from the start of the page (the conversation itself is kept). */
    fun reload() {
        if (destroyed) return
        loadRequested = false
        startLoading()
    }

    /**
     * Releases the WebView. Call it when the screen that holds this view is gone for good — a
     * WebView that is never destroyed holds its whole screen in memory for the life of the app.
     * The view is unusable afterwards.
     */
    fun destroy() {
        if (destroyed) return
        destroyed = true
        updateOnScreen()
        KeydaBot.viewGone(this)
        mainHandler.removeCallbacksAndMessages(null)
        pendingBack = null
        // A file request belongs to this WebView; answering it keeps the page from waiting forever.
        finishFileChooser(null)
        // Order matters. A WebView still attached when it is destroyed leaves its renderer
        // connection behind.
        removeView(web)
        web.removeJavascriptInterface(BRIDGE)
        web.stopLoading()
        web.removeAllViews()
        web.destroy()
    }

    // ------------------------------------------------------------------------ for the Activity

    /** The full-screen Activity hands the URL over from its Intent (which survives process death). */
    internal fun loadChat(url: String, startQuestion: String?) {
        chatUrl = url
        chatPage = Uri.parse(url)
        if (!startQuestion.isNullOrBlank()) question = startQuestion
        startLoading()
    }

    /**
     * Back over the full-screen chat. With a sheet open it closes the sheet; with none it calls
     * [leave]. A page that has never reported its sheets (older than this SDK) is asked through
     * `KeydaBot.back()` instead, and one that does not answer within half a second gets [leave]
     * too, so back never goes dead.
     */
    internal fun backOrLeave(leave: () -> Unit) {
        when {
            destroyed || errorShowing || !chatEverLoaded -> leave()
            // Asked with the same half-second limit as a silent page: a renderer that hangs with a
            // sheet open must not leave back dead (rule 10).
            sheetsOpen > 0 -> askPageToGoBack(leave)
            sheetsReported -> leave()
            else -> askPageToGoBack(leave)
        }
    }

    /** True when the WebView has history of its own to walk (a redirect at startup). */
    internal fun historyBack(): Boolean {
        if (destroyed || !web.canGoBack()) return false
        web.goBack()
        return true
    }

    internal fun pauseWebView() {
        if (!destroyed) web.onPause()
    }

    internal fun resumeWebView() {
        if (!destroyed) web.onResume()
    }

    // ------------------------------------------------------------------------------- lifecycle

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (!destroyed) KeydaBot.viewAlive(this)
        // An embedded view loads the moment it is on a screen; the Activity loads explicitly.
        if (!loadRequested && !destroyed) startLoading()
        // setVisitor() reaches attached chats only. One whose fragment had it off the window then
        // catches up now, if its page is up (a page still loading gets it when it finishes).
        if (visitorSent != KeydaBot.visitorVersion) applyVisitor()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        visibleToPlatform = false
        updateOnScreen()
        KeydaBot.viewGone(this)
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        // Suspends the page's timers and rendering while the screen is not visible: a chat left
        // in a background tab otherwise keeps polling and animating on the customer's battery.
        if (visibility == View.VISIBLE) resumeWebView() else pauseWebView()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            visibleToPlatform = visibility == View.VISIBLE && isShown
            updateOnScreen()
        }
    }

    /** API 24+: this view, every parent and the window all visible — a hidden tab is not. */
    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        visibleToPlatform = isVisible && isAttachedToWindow
        updateOnScreen()
    }

    /**
     * A chat on screen shows the business's replies itself, so the app does not ask for them
     * meanwhile; one that goes away hands the asking back. Under the replies' lock, so a message
     * the page sends at the same moment is judged on one side of the change or the other.
     */
    private fun updateOnScreen() {
        val now = visibleToPlatform && active && !destroyed
        synchronized(KeydaBotReplies.lock) {
            if (now == onScreen) return
            onScreen = now
            if (now) KeydaBotReplies.chatAppeared() else KeydaBotReplies.chatWentAway()
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration?) {
        super.onConfigurationChanged(newConfig)
        // Until the page has spoken, the device is the theme. Once it has, the page decides: a
        // "Match the visitor" bot re-announces itself on the flip and an "Always light/dark" bot
        // must not move.
        if (themeFromPage) return
        val dark = deviceIsDark()
        if (dark == darkTheme) return
        darkTheme = dark
        applyTheme()
    }

    // ---------------------------------------------------------------- loading and error states

    private fun startLoading() {
        if (destroyed) return
        // A view shown before KeydaBot.init() has no URL; Retry looks again rather than never.
        if (chatUrl.isEmpty()) {
            val url = KeydaBot.chatUrlOrNull()
            if (url == null) {
                Log.e(KeydaBot.TAG, "KeydaBotView was shown before KeydaBot.init(); nothing to load.")
                loadRequested = true
                showError(MSG_UNAVAILABLE)
                return
            }
            chatUrl = url
            chatPage = Uri.parse(url)
        }
        loadRequested = true
        changingBack {
            errorShowing = false
            // A new page reports its own sheets; the old count belongs to a page that is gone.
            sheetsOpen = 0
            sheetsReported = false
        }
        errorPanel.visibility = View.GONE
        web.visibility = View.VISIBLE
        progress.visibility = View.VISIBLE
        // loadUrl and not reload(): after a first load that never arrived there is nothing to
        // reload, and reload() on an error page replays the error instead of fetching the chat.
        if (startDelivered) {
            web.loadUrl(chatUrl)
        } else {
            // Not delivered yet (the first load failed): this time by script, once the page is up,
            // over the plain URL — which, unlike the same URL with a #fragment, really loads.
            if (loadAttempted) question?.trim()?.takeIf { it.isNotEmpty() }?.let { pendingPrefill = pendingPrefill ?: it }
            web.loadUrl(if (loadAttempted) chatUrl else urlWithStart())
        }
        loadAttempted = true
    }

    private var loadAttempted = false

    /**
     * The chat URL with its start in the #fragment — the question, and [KeydaBot.setVisitor]'s
     * details. The page reads it as it loads and takes it off the address. A fragment is never
     * sent to a server.
     */
    private fun urlWithStart(): String {
        val q = question?.trim().orEmpty()
        val start = buildString {
            if (q.isNotEmpty()) append("&q=").append(Uri.encode(cut(q, QUESTION_MAX)))
            KeydaBot.visitor?.let { append(it.fragment()) }
        }
        return if (start.isEmpty()) chatUrl else chatUrl + "#" + start.substring(1)
    }

    /** The first [max] characters — whole characters, never half an emoji. */
    private fun cut(text: String, max: Int): String {
        if (text.codePointCount(0, text.length) <= max) return text
        return text.substring(0, text.offsetByCodePoints(0, max))
    }

    /**
     * [KeydaBot.setVisitor] reaching a page that is already up (main thread): the current details,
     * or `{}` to forget them.
     */
    internal fun applyVisitor() {
        if (destroyed || !chatEverLoaded || errorShowing) return
        // The number before the details: setVisitor writes them the other way round, so a change
        // racing this one is at worst sent twice, never missed.
        visitorSent = KeydaBot.visitorVersion
        val json = KeydaBot.visitor?.json() ?: "{}"
        web.evaluateJavascript(
            "(function(){try{window.KeydaBot&&window.KeydaBot.setVisitor&&" +
                "window.KeydaBot.setVisitor($json);}catch(e){}})()",
            null
        )
    }

    /**
     * The whole failure story. CONTRACT rule 6: a load that fails shows a retry, it never throws
     * into the host app. Customer-facing copy stays plain here; the diagnosis goes to Logcat.
     */
    private fun showError(message: String) {
        // One change of back state, reported once: computed before errorShowing flips it.
        changingBack {
            errorShowing = true
            sheetsOpen = 0
        }
        progress.visibility = View.GONE
        // INVISIBLE rather than GONE: GONE re-lays-out the WebView at zero height, which resets
        // the page's viewport and scroll position for the retry that follows.
        if (::web.isInitialized) web.visibility = View.INVISIBLE
        errorText.text = message
        errorPanel.visibility = View.VISIBLE
    }

    // ------------------------------------------------------------------------------ view setup

    // The chat IS a web app (CONTRACT rule 1), so JavaScript is not optional here. What keeps
    // that safe is the rest of this method: one fixed origin, no file or content access, no mixed
    // content, and a JavaScript bridge that exposes exactly one method, which can do nothing but
    // repaint this chrome and record how many sheets the page has open (see Bridge).
    @SuppressLint("SetJavaScriptEnabled")
    private fun buildWebView(): WebView = WebView(context).apply {
        layoutParams = LayoutParams(MATCH, MATCH)
        webViewClient = ChatWebViewClient()

        // CONTRACT rule 9. Without a chrome client there is no onShowFileChooser, and a tap on the
        // chat's attach button does nothing at all.
        webChromeClient = ChatWebChromeClient()

        // The page paints its own background, but not until it has parsed. The colour is the
        // theme's, not white: framing a dark chat in a white flash is what rule 7 exists to remove.
        setBackgroundColor(backgroundColor())

        // CONTRACT rule 7: window.KeydaBotNative.onTheme(json). The name is fixed by the contract;
        // renaming it silently turns the bridge off. Registered before loadUrl so the call the page
        // makes from its <head> finds the object already there.
        addJavascriptInterface(Bridge(this@KeydaBotView), BRIDGE)

        settings.apply {
            // CONTRACT rule 1, both of these. DOM storage keeps the conversation across restarts.
            javaScriptEnabled = true
            domStorageEnabled = true

            // Honour the page's own <meta name="viewport">.
            useWideViewPort = true
            loadWithOverviewMode = true

            // Off, so that a target="_blank" link arrives at shouldOverrideUrlLoading like any other
            // navigation instead of at onCreateWindow, where nothing is listening.
            setSupportMultipleWindows(false)

            // Nothing in a chat needs the device's filesystem or content providers.
            allowFileAccess = false
            allowContentAccess = false

            // CONTRACT rule 5. No location, ever.
            setGeolocationEnabled(false)

            // An https chat that silently pulls http assets is not an https chat.
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW

            // A version and nothing else: no device id, no advertising id, no user.
            userAgentString = "$userAgentString KeydaBot/${BuildConfig.SDK_VERSION} (Android)"
        }
    }

    private fun buildProgress(): ProgressBar = ProgressBar(context).apply {
        isIndeterminate = true
        layoutParams = LayoutParams(WRAP, WRAP, Gravity.CENTER)
    }

    private fun buildErrorPanel(): LinearLayout {
        errorText = TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
        }
        retryButton = Button(context).apply {
            text = LABEL_RETRY
            setOnClickListener { reload() }
        }
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val pad = dp(24)
            setPadding(pad, pad, pad, pad)
            // Opaque, and clickable so taps stop here instead of reaching the dead page beneath.
            isClickable = true
            visibility = View.GONE
            layoutParams = LayoutParams(MATCH, MATCH)
            addView(errorText, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(retryButton, LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(16) })
        }
    }

    // ------------------------------------------------------------------------------------ theme

    private fun deviceIsDark(): Boolean =
        (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    internal fun backgroundColor(): Int = if (darkTheme) BG_DARK else BG_LIGHT

    private fun inkColor(): Int = if (darkTheme) INK_DARK else INK_LIGHT

    /** Paints everything this view owns in the current theme, then tells the Activity. */
    private fun applyTheme() {
        val bg = backgroundColor()
        val ink = inkColor()
        // The accent is the owner's; the spinner and the retry button carry it the way the page's
        // own send button does.
        val tint = accent ?: ink
        setBackgroundColor(bg)
        if (::web.isInitialized) web.setBackgroundColor(bg)
        errorPanel.setBackgroundColor(bg)
        errorText.setTextColor(ink)
        progress.indeterminateTintList = ColorStateList.valueOf(tint)
        retryButton.backgroundTintList = ColorStateList.valueOf(tint)
        retryButton.setTextColor(if (accent != null) Color.WHITE else bg)
        onThemeApplied?.invoke()
    }

    /** Main thread, with already-validated values. */
    private fun onPageTheme(dark: Boolean, pageAccent: Int?) {
        if (destroyed) return
        themeFromPage = true
        accent = pageAccent
        darkTheme = dark
        applyTheme()
    }

    private fun setSheets(open: Int) {
        changingBack { sheetsOpen = open }
    }

    /** Runs [change] and tells [onCanGoBackChanged] if it flipped [canGoBack] — the one place. */
    private inline fun changingBack(change: () -> Unit) {
        val was = canGoBack
        change()
        val now = canGoBack
        if (was != now) onCanGoBackChanged?.invoke(now)
    }

    /**
     * The one object the page can reach: `window.KeydaBotNative`, one method, one string in. It
     * carries three message types: `keyda:theme` (rule 7), `keyda:sheets` (rule 10) and
     * `keyda:waits` — the chats waiting for the business's reply (KeydaBotReplies).
     *
     * A nested (static) class holding the view weakly, because the WebView holds this bridge
     * strongly and the view holds the WebView. Everything here runs on the JavaBridge thread, on
     * input a web page wrote: nothing may throw (rule 6), anything unrecognised is ignored, and
     * only validated values cross to the main thread.
     */
    private class Bridge(view: KeydaBotView) {
        private val target = WeakReference(view)

        @JavascriptInterface
        fun onTheme(json: String?) {
            val view = target.get() ?: return
            if (json == null) return
            try {
                val message = JSONObject(json)
                when (message.optString("type")) {
                    "keyda:theme" -> {
                        val dark = when (message.optString("mode")) {
                            "dark" -> true
                            "light" -> false
                            else -> return
                        }
                        val pageAccent = parseAccent(message.optString("accent"))
                        view.mainHandler.post { view.onPageTheme(dark, pageAccent) }
                    }
                    "keyda:sheets" -> {
                        val open = message.optInt("open", -1)
                        if (open < 0 || open > 64) return
                        view.mainHandler.post {
                            if (view.destroyed) return@post
                            view.sheetsReported = true
                            view.setSheets(open)
                        }
                    }
                    // Validated there, field by field; nothing reaches the view. The view goes along
                    // to say whether the customer could see the page that sent it.
                    "keyda:waits" -> KeydaBotReplies.onWaits(message.optJSONArray("waits"), view)
                }
            } catch (malformed: Exception) {
                // A surprise from a web page is still not a crash.
                Log.w(KeydaBot.TAG, "Ignored an unreadable message from the chat page")
            }
        }

        /** `#rrggbb` only. Anything else - named colours, alpha, garbage - is "no accent". */
        private fun parseAccent(value: String): Int? {
            if (!ACCENT_SHAPE.matches(value)) return null
            return try {
                Color.parseColor(value)
            } catch (bad: IllegalArgumentException) {
                null
            }
        }

        private companion object {
            val ACCENT_SHAPE = Regex("^#[0-9a-fA-F]{6}$")
        }
    }

    // ------------------------------------------------------------------------------ back button

    /**
     * Back for a page that does not report its sheets: ask `KeydaBot.back()`, leave on false, on a
     * page too old to have it (the script answers false), and when no answer comes within
     * [BACK_ANSWER_MS].
     */
    private fun askPageToGoBack(leave: () -> Unit) {
        // A second press while the page is answering the first: that answer decides.
        if (pendingBack != null) return
        val timeout = Runnable {
            pendingBack = null
            if (!destroyed) leave()
        }
        pendingBack = timeout
        mainHandler.postDelayed(timeout, BACK_ANSWER_MS)
        web.evaluateJavascript(BACK_SCRIPT) { result ->
            // Late: the timeout already decided, or the view is gone.
            if (pendingBack !== timeout || destroyed) return@evaluateJavascript
            mainHandler.removeCallbacks(timeout)
            pendingBack = null
            if (result != "true") leave()
        }
    }

    // ------------------------------------------------------------------------------- routing

    /**
     * True only for the chat page itself: the exact scheme + host + port it is served from, AND
     * its own path. The origin alone is not enough: the "Powered by Keyda" link CONTRACT rule 2 is
     * written about points at the marketing site on the SAME host the chat is served from, and an
     * origin-only test would keep it in the WebView and replace the conversation.
     */
    private fun isChatPage(uri: Uri): Boolean {
        val page = chatPage ?: return false
        if (!uri.scheme.equals(page.scheme, ignoreCase = true)) return false
        if (!uri.host.equals(page.host, ignoreCase = true)) return false
        if (effectivePort(uri) != effectivePort(page)) return false
        // A query or a #fragment on the chat page is still the chat page.
        val here = uri.path.orEmpty()
        val chat = page.path.orEmpty()
        return here == chat || here.startsWith("$chat/")
    }

    private fun effectivePort(uri: Uri): Int {
        if (uri.port != -1) return uri.port
        return if (uri.scheme.equals("http", ignoreCase = true)) 80 else 443
    }

    /** CONTRACT rule 2: links open outside the chat, never in place of the conversation. */
    private fun openOutsideTheChat(uri: Uri) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, uri)
            // From a non-Activity context (an embedded view in some hosts) a new task is required.
            if (findActivity() == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (noApp: ActivityNotFoundException) {
            Log.w(KeydaBot.TAG, "Nothing on this device can open a ${uri.scheme}: link", noApp)
            Toast.makeText(context, MSG_NO_APP_FOR_LINK, Toast.LENGTH_SHORT).show()
        } catch (refused: RuntimeException) {
            // A file: link raises FileUriExposedException, a guarded target SecurityException; out
            // of a WebViewClient callback either would take the host app down (rule 6).
            Log.w(KeydaBot.TAG, "Refused to open a ${uri.scheme}: link", refused)
            Toast.makeText(context, MSG_NO_APP_FOR_LINK, Toast.LENGTH_SHORT).show()
        }
    }

    private fun route(uri: Uri, startupRedirect: Boolean): Boolean {
        // The WebView's own internal navigations; a blank browser tab helps nobody.
        when (uri.scheme?.lowercase()) {
            null, "about", "data", "blob", "javascript" -> return false
        }
        if (isChatPage(uri)) return false
        if (startupRedirect) {
            // A host that redirects (apex to www, http to https, a staging alias) during the first
            // load, main frame only, so a link tapped later can never move the WebView off the chat.
            Log.i(KeydaBot.TAG, "Chat host redirected to ${uri.host}; following it in place.")
            chatPage = uri
            return false
        }
        openOutsideTheChat(uri)
        return true
    }

    private inner class ChatWebViewClient : WebViewClient() {

        @TargetApi(Build.VERSION_CODES.N)
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            // A subframe cannot replace the conversation - it is inside it.
            if (!request.isForMainFrame) return false
            val startupRedirect = request.isRedirect && !chatEverLoaded
            return route(request.url, startupRedirect)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView, url: String?): Boolean {
            // API 21-23 only; before the chat has rendered once, a move to another host is treated
            // as the redirect it almost always is.
            if (url == null) return false
            return route(Uri.parse(url), !chatEverLoaded)
        }

        override fun onPageFinished(view: WebView, url: String?) {
            progress.visibility = View.GONE
            // Not after an error: the WebView's own error page finishes loading too.
            if (errorShowing) return
            chatEverLoaded = true
            startDelivered = true
            // The widget script has run by now (the load event waits for it); KeydaBot.prefill
            // keeps the question until the panel exists.
            pendingPrefill?.let { q ->
                pendingPrefill = null
                prefill(q)
            }
            // Every time, details or none. The fragment carried the details of the moment the first
            // load began; a reload has no fragment; and a setVisitor() or clearVisitor() made while
            // a page was loading reached a page that was not there yet.
            applyVisitor()
        }

        @TargetApi(Build.VERSION_CODES.M)
        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError
        ) {
            // An avatar or a font that failed must not replace a working conversation.
            if (!request.isForMainFrame) return
            Log.w(KeydaBot.TAG, "Chat load failed: ${error.errorCode} ${error.description} (${request.url})")
            showError(MSG_OFFLINE)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onReceivedError(
            view: WebView,
            errorCode: Int,
            description: String?,
            failingUrl: String?
        ) {
            // API 21-22 only; API 23+ reports through the overload above.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) return
            val mainFrame = failingUrl == null || failingUrl == chatUrl || failingUrl == view.url
            if (!mainFrame) return
            Log.w(KeydaBot.TAG, "Chat load failed: $errorCode $description ($failingUrl)")
            showError(MSG_OFFLINE)
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse
        ) {
            if (!request.isForMainFrame) return
            Log.e(
                KeydaBot.TAG,
                "Chat page returned HTTP ${errorResponse.statusCode} for ${request.url}. " +
                    "A 404 here usually means the client id is wrong, disabled, or from another " +
                    "environment than the base URL."
            )
            showError(MSG_UNAVAILABLE)
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            // Never proceed(): a support chat carries order numbers, phones and addresses.
            handler.cancel()
            Log.e(KeydaBot.TAG, "SSL error ${error.primaryError} on ${error.url}")
            showError(MSG_INSECURE)
        }

        @TargetApi(Build.VERSION_CODES.O)
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // Returning false would let the framework kill the host app (rule 6).
            Log.e(
                KeydaBot.TAG,
                "WebView render process gone (didCrash=${detail.didCrash()}); rebuilding the chat view."
            )
            if (view === web) replaceDeadWebView()
            showError(MSG_RESTARTED)
            return true
        }
    }

    // ------------------------------------------------------------------------- file chooser

    /**
     * CONTRACT rule 9. Answered through [KeydaBotPickerFragment], a headless fragment added to the
     * Activity this view is in: a view cannot receive an Activity result itself, asking every host
     * app to forward onActivityResult would make the attach button the integrator's bug, and the
     * read permission for the picked file has to belong to an Activity that outlives the read (see
     * the fragment). No camera path, deliberately (see the README).
     */
    private var pendingFileChooser: ValueCallback<Array<Uri>>? = null

    private inner class ChatWebChromeClient : WebChromeClient() {

        override fun onShowFileChooser(
            view: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: FileChooserParams
        ): Boolean {
            // A chooser left over from a previous tap: answer it before replacing it.
            finishFileChooser(null)
            pendingFileChooser = filePathCallback
            val chooser = try {
                fileChooserParams.createIntent()
            } catch (refused: RuntimeException) {
                Log.w(KeydaBot.TAG, "Could not build the file picker", refused)
                null
            }
            val host = findActivity()
            if (host == null) Log.w(KeydaBot.TAG, "KeydaBotView is not in an Activity; it cannot open a file picker.")
            val opened = chooser != null && host != null &&
                KeydaBotPickerFragment.launch(host, chooser) { uris -> finishFileChooser(uris) }
            if (!opened) {
                finishFileChooser(null)
                Toast.makeText(context, MSG_NO_FILE_PICKER, Toast.LENGTH_SHORT).show()
            }
            // True on every path: the callback has been (or will be) answered here.
            return true
        }
    }

    /** Answers the page's pending file request - `null` means "nothing chosen" - and clears it. */
    private fun finishFileChooser(uris: Array<Uri>?) {
        val pending = pendingFileChooser ?: return
        pendingFileChooser = null
        pending.onReceiveValue(uris)
    }

    private fun replaceDeadWebView() {
        val dead = web
        // A file request and a back press belong to the WebView that made them, and this one is
        // gone. The retry screen shown next is back's to close.
        finishFileChooser(null)
        pendingBack?.let(mainHandler::removeCallbacks)
        pendingBack = null
        removeView(dead)
        dead.destroy()
        chatEverLoaded = false
        web = buildWebView()
        // Index 0: behind the spinner and the error panel.
        addView(web, 0)
    }

    // ------------------------------------------------------------------------------- helpers

    private fun findActivity(): Activity? {
        var c: Context? = context
        while (c is ContextWrapper) {
            if (c is Activity) return c
            c = c.baseContext
        }
        return null
    }

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics
    ).toInt()

    // Each private: a const is compiled to a static field with the property's own visibility,
    // whatever the companion's, and a public one is API Java callers would see.
    private companion object {
        private val MATCH = LayoutParams.MATCH_PARENT
        private val WRAP = LayoutParams.WRAP_CONTENT

        /** The JavaScript name the page looks for. Fixed by CONTRACT rule 7. */
        private const val BRIDGE = "KeydaBotNative"

        /**
         * CONTRACT rule 10: closes the page's top sheet and answers whether there was one. Wrapped
         * so that a page without `back()`, or one that throws, answers false.
         */
        private const val BACK_SCRIPT = "(function(){try{return !!(window.KeydaBot&&" +
            "typeof window.KeydaBot.back==='function'&&window.KeydaBot.back());}" +
            "catch(e){return false;}})()"

        /** How long back waits for the page's answer before closing the chat anyway. */
        private const val BACK_ANSWER_MS = 500L

        /** The page takes up to 500 characters; anything longer is cut, not refused. */
        private const val QUESTION_MAX = 500

        // CONTRACT rule 7's two backgrounds, and an ink that reads on each (the page's own text).
        private const val BG_DARK = 0xFF0B1220.toInt()
        private const val BG_LIGHT = 0xFFF7F8FC.toInt()
        private const val INK_DARK = 0xFFE6EAF2.toInt()
        private const val INK_LIGHT = 0xFF111827.toInt()

        // Hardcoded because this AAR ships no resources, and therefore no translations.
        private const val MSG_OFFLINE = "Chat isn't connecting. Check your internet connection and try again."
        private const val MSG_UNAVAILABLE = "Chat is unavailable right now. Please try again in a moment."
        private const val MSG_INSECURE = "Chat couldn't be opened securely on this network."
        private const val MSG_RESTARTED = "Chat had to restart on this device. Please try again."
        private const val MSG_NO_WEBVIEW = "Chat can't open on this phone: Android System WebView is missing or being updated."
        private const val MSG_NO_APP_FOR_LINK = "No app on this phone can open that link."
        private const val MSG_NO_FILE_PICKER = "No app on this phone can pick a file."
        private const val LABEL_RETRY = "Try again"
    }
}
