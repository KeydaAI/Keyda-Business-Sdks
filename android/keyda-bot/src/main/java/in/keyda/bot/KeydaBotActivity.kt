package `in`.keyda.bot

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
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
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import kotlin.math.max

/**
 * Full-screen host for the chat page. Launched only by [KeydaBot.show].
 *
 * There is no XML layout and no resource of any kind in this AAR: a library that ships resources
 * ships id, colour and string collisions into every app that adds it.
 */
class KeydaBotActivity : Activity() {

    private lateinit var root: FrameLayout
    private lateinit var web: WebView
    private lateinit var progress: ProgressBar
    private lateinit var errorPanel: LinearLayout
    private lateinit var errorText: TextView

    private var chatUrl: String = ""

    /** Parsed once. Every navigation is compared against this to decide in-app versus browser. */
    private var chatPage: Uri? = null

    private var errorShowing = false

    /**
     * False until the chat has rendered once. Until then the WebView may still be walking whatever
     * redirects sit between the configured base URL and the page itself.
     */
    private var chatEverLoaded = false

    /** Typed [Any] deliberately - see [Api33]. */
    private var backCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // The Intent first, the singleton second. After process death Android restores this
        // Activity before a line of the app's own code runs, so KeydaBot.init() may not have
        // happened yet in the new process while the Intent extra survived in the saved task.
        val url = intent?.getStringExtra(KeydaBot.EXTRA_CHAT_URL) ?: KeydaBot.chatUrlOrNull()
        if (url == null) {
            // Nothing to load and no way to find out what to load. Closing beats leaving a blank
            // screen the customer has to fight their way out of.
            Log.e(KeydaBot.TAG, "Chat opened with no configuration; call KeydaBot.init() first.")
            finish()
            return
        }

        chatUrl = url
        chatPage = Uri.parse(url)

        KeydaBot.onChatCreated(this)

        root = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
            setBackgroundColor(Color.WHITE)
        }

        web = buildWebView()
        progress = buildProgress()
        errorPanel = buildErrorPanel()

        root.addView(web)
        root.addView(progress)
        root.addView(errorPanel)

        setContentView(root)

        applyWindowInsets(root)
        registerBackHandling()

        load()
    }

    override fun onResume() {
        super.onResume()
        if (::web.isInitialized) web.onResume()
    }

    override fun onPause() {
        super.onPause()
        // Suspends the page's timers and rendering while the customer is somewhere else. A chat
        // left open otherwise keeps polling and animating in the background, on their battery.
        if (::web.isInitialized) web.onPause()
    }

    override fun onDestroy() {
        unregisterBackHandling()

        if (::web.isInitialized) {
            // Order matters. A WebView still attached to a window when it is destroyed leaves its
            // renderer connection behind, and a WebView that is never destroyed holds this whole
            // Activity - every bitmap on screen included - for the life of the app.
            if (::root.isInitialized) root.removeView(web)
            web.stopLoading()
            web.removeAllViews()
            web.destroy()
        }

        KeydaBot.onChatDestroyed(this)
        super.onDestroy()
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        // Still the only back callback that fires in a host app that has not opted into predictive
        // back (android:enableOnBackInvokedCallback="true"), which is most of them. The API 33
        // registration below covers the ones that have.
        handleBack()
    }

    private fun handleBack() {
        when {
            // From the retry screen, back means leave. Walking WebView history from an error page
            // lands the customer on whatever failed last, which is not a chat.
            errorShowing -> finish()
            ::web.isInitialized && web.canGoBack() -> web.goBack()
            else -> finish()
        }
    }

    // ---------------------------------------------------------------- loading and error states

    private fun load() {
        errorShowing = false
        errorPanel.visibility = View.GONE
        web.visibility = View.VISIBLE
        progress.visibility = View.VISIBLE

        // loadUrl and not reload(): after a first load that never arrived there is nothing to
        // reload, and reload() on an error page replays the error instead of fetching the chat.
        web.loadUrl(chatUrl)
    }

    /**
     * The whole failure story. CONTRACT rule 6: a load that fails shows a retry, it never throws
     * into the host app. Customer-facing copy stays plain here; the diagnosis goes to Logcat,
     * where the developer is, and not to the customer, who cannot act on it.
     */
    private fun showError(message: String) {
        errorShowing = true
        progress.visibility = View.GONE

        // INVISIBLE rather than GONE: GONE re-lays-out the WebView at zero height, which resets
        // the page's viewport and scroll position for the retry that follows.
        web.visibility = View.INVISIBLE

        errorText.text = message
        errorPanel.visibility = View.VISIBLE
    }

    // ------------------------------------------------------------------------------ view setup

    // The chat IS a web app (CONTRACT rule 1), so JavaScript is not optional here. What keeps
    // that safe is the rest of this method: one fixed origin, no JavaScript bridge into the app,
    // no file or content access, and no mixed content.
    @SuppressLint("SetJavaScriptEnabled")
    private fun buildWebView(): WebView = WebView(this).apply {
        layoutParams = FrameLayout.LayoutParams(MATCH, MATCH)
        webViewClient = ChatWebViewClient()

        // The page paints its own background, but not until it has parsed. Without this the window
        // shows through as a flash of something else during the first paint on a slow connection.
        setBackgroundColor(Color.WHITE)

        settings.apply {
            // CONTRACT rule 1, both of these. The chat is a web app, and DOM storage is what keeps
            // a visitor's conversation attached to them across an app restart.
            javaScriptEnabled = true
            domStorageEnabled = true

            // Honour the page's own <meta name="viewport">. Without a wide viewport the WebView
            // ignores it and lays the chat out at a desktop width.
            useWideViewPort = true
            loadWithOverviewMode = true

            // Leave multiple windows off so that a target="_blank" link arrives at
            // shouldOverrideUrlLoading like any other navigation. Turning it on would route those
            // links to onCreateWindow instead, where nothing is listening, and the tap would
            // silently do nothing.
            setSupportMultipleWindows(false)

            // Nothing in a chat needs the device's filesystem or content providers. Both default
            // to true below API 30, and both are the classic way a compromised page reads files
            // out of the host app's sandbox.
            allowFileAccess = false
            allowContentAccess = false

            // CONTRACT rule 5. No location, ever.
            setGeolocationEnabled(false)

            // An https chat that silently pulls http assets is not an https chat.
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW

            // Lets the page and our server logs tell an in-app session from a mobile browser one.
            // It carries a version and nothing else: no device id, no advertising id, no user.
            userAgentString = "$userAgentString KeydaBot/${BuildConfig.SDK_VERSION} (Android)"
        }
    }

    private fun buildProgress(): ProgressBar = ProgressBar(this).apply {
        isIndeterminate = true
        // On a 3G connection the page can take several seconds. A blank white screen for those
        // seconds reads as a broken app; a spinner reads as a slow network, which is the truth.
        layoutParams = FrameLayout.LayoutParams(WRAP, WRAP, Gravity.CENTER)
    }

    private fun buildErrorPanel(): LinearLayout {
        errorText = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
        }

        val retry = Button(this).apply {
            text = LABEL_RETRY
            setOnClickListener { load() }
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val pad = dp(24)
            setPadding(pad, pad, pad, pad)

            // Opaque and full-screen so it covers the WebView's built-in "webpage not available"
            // page, which names our domain and helps nobody. Clickable so taps stop here instead
            // of reaching the dead page underneath.
            setBackgroundColor(Color.WHITE)
            isClickable = true
            visibility = View.GONE
            layoutParams = FrameLayout.LayoutParams(MATCH, MATCH)

            addView(errorText, LinearLayout.LayoutParams(MATCH, WRAP))
            addView(
                retry,
                LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(16) }
            )
        }
    }

    // --------------------------------------------------------------------------- system insets

    /**
     * CONTRACT rules 3 and 4, for the window layouts where the manifest cannot do it alone.
     *
     * When the window is not edge-to-edge - every host app below targetSdk 35 - the decor view has
     * already applied the system bars, this listener receives zeroes, and `adjustResize` does the
     * keyboard work. When the app targets 35+ on Android 15+, Android draws edge-to-edge whatever
     * the manifest says and `adjustResize` no longer moves anything: then these paddings are the
     * only thing keeping the chat out from under the status bar, the gesture bar and the keyboard.
     */
    private fun applyWindowInsets(target: View) {
        target.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bars = insets.getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                )
                val ime = insets.getInsets(WindowInsets.Type.ime())

                // max, not a sum: when the keyboard is up it already covers the gesture bar, and
                // adding the two would leave a keyboard-sized band of dead space above it.
                view.setPadding(
                    max(bars.left, ime.left),
                    bars.top,
                    max(bars.right, ime.right),
                    max(bars.bottom, ime.bottom)
                )
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(
                    insets.systemWindowInsetLeft,
                    insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight,
                    insets.systemWindowInsetBottom
                )
            }
            insets
        }

        // The first insets pass can happen before a listener attached in onCreate is in place.
        // Without this the chat opens under the status bar and only corrects itself on rotation.
        target.requestApplyInsets()
    }

    // ------------------------------------------------------------------------------ back button

    private fun registerBackHandling() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        backCallback = Api33.registerBack(this) { handleBack() }
    }

    private fun unregisterBackHandling() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val callback = backCallback ?: return
        backCallback = null
        Api33.unregisterBack(this, callback)
    }

    // ------------------------------------------------------------------------------- routing

    /**
     * True only for the chat page itself: the exact scheme + host + port it is served from, AND
     * its own path.
     *
     * The origin alone is not enough, and this is not hypothetical. The "Powered by Keyda" link
     * CONTRACT rule 2 is written about points at the marketing site on the SAME host the chat is
     * served from (`keyda.in/business/chat/...` and `keyda.in/business/`). An origin-only
     * test calls that link "our own page", keeps it in the WebView, and the customer's
     * conversation is replaced by a marketing page. Coming back does not bring it back either -
     * the widget replays nothing on mount, so every message on screen is simply gone.
     */
    private fun isChatPage(uri: Uri): Boolean {
        val page = chatPage ?: return false
        if (!uri.scheme.equals(page.scheme, ignoreCase = true)) return false
        if (!uri.host.equals(page.host, ignoreCase = true)) return false
        if (effectivePort(uri) != effectivePort(page)) return false

        // A query or a #fragment on the chat page is still the chat page; anything else on the
        // host - the marketing site, a docs page, a pricing page - is not.
        val here = uri.path.orEmpty()
        val chat = page.path.orEmpty()
        return here == chat || here.startsWith("$chat/")
    }

    private fun effectivePort(uri: Uri): Int {
        if (uri.port != -1) return uri.port
        return if (uri.scheme.equals("http", ignoreCase = true)) 80 else 443
    }

    /**
     * CONTRACT rule 2. The chat page carries at least one real link ("Powered by Keyda"). If it
     * navigated this WebView, the customer's conversation would be replaced by a marketing site
     * with no back button in sight, and everything they had typed would be gone.
     */
    private fun openOutsideTheChat(uri: Uri) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (noApp: ActivityNotFoundException) {
            // No browser, or no app for a tel:, mailto: or upi: link. The chat is untouched, which
            // is the important part; the toast is so the tap does not feel dead.
            Log.w(KeydaBot.TAG, "Nothing on this device can open a ${uri.scheme}: link", noApp)
            Toast.makeText(this, MSG_NO_APP_FOR_LINK, Toast.LENGTH_SHORT).show()
        } catch (refused: RuntimeException) {
            // ActivityNotFoundException is not the only way startActivity throws, and the URI here
            // comes from a web page rather than from us. A file: link raises FileUriExposedException
            // on API 24+, and a permission-guarded target raises SecurityException. Both would be
            // thrown out of a WebViewClient callback and take the host app down with them, which
            // CONTRACT rule 6 says is never ours to do: the host's users are not our users.
            Log.w(KeydaBot.TAG, "Refused to open a ${uri.scheme}: link", refused)
            Toast.makeText(this, MSG_NO_APP_FOR_LINK, Toast.LENGTH_SHORT).show()
        }
    }

    private fun route(uri: Uri, startupRedirect: Boolean): Boolean {
        // The WebView's own internal navigations. Sending about:blank or a data: URL to the system
        // browser opens a blank tab on top of the customer's chat for no reason.
        when (uri.scheme?.lowercase()) {
            null, "about", "data", "blob", "javascript" -> return false
        }

        if (isChatPage(uri)) return false // the WebView handles its own page

        if (startupRedirect) {
            // A host that redirects - apex to www, http to https, a staging alias to its real name
            // - would otherwise have its own chat thrown into the browser before it ever rendered,
            // leaving a spinner behind in the app. Accepted only while the first load is still in
            // flight, and only for the main frame, so a link tapped inside a live conversation can
            // never move the WebView off the chat.
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
            // Android calls this for subframes too, and a subframe cannot replace the
            // conversation - it is inside it. Throwing one to the browser would break the embed
            // AND drop a browser window on top of a live chat, so it stays in the WebView.
            // CONTRACT rule 2 is about the page the customer is reading: the main frame.
            if (!request.isForMainFrame) return false

            // isRedirect is API 24, and API 24 is exactly when Android starts calling this
            // overload instead of the String one below. There is no version of Android that can
            // reach this line without it.
            val startupRedirect = request.isRedirect && !chatEverLoaded
            return route(request.url, startupRedirect)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView, url: String?): Boolean {
            // API 21-23 only; API 24+ calls the WebResourceRequest overload above, which is also
            // the first version that can tell a redirect from a tap. Here, before the chat has
            // rendered once, treat a move to another host as the redirect it almost always is.
            if (url == null) return false
            return route(Uri.parse(url), !chatEverLoaded)
        }

        override fun onPageFinished(view: WebView, url: String?) {
            progress.visibility = View.GONE
            // Not after an error: the WebView's own error page finishes loading too, and treating
            // that as "the chat rendered" would close the redirect window before the retry.
            if (!errorShowing) chatEverLoaded = true
        }

        @TargetApi(Build.VERSION_CODES.M)
        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError
        ) {
            // This overload, and WebResourceError with it, arrived in API 23. Below that Android
            // calls the four-argument version underneath.
            // An avatar or a font that failed must not replace a working conversation with a
            // retry screen. Only the main frame counts as the chat failing to load.
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
            // API 21-22 only. On API 23+ the framework calls the overload above and this one would
            // report the same failure a second time.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) return

            // The old callback has no isForMainFrame, so approximate it: anything that is not the
            // page we asked for, or the page currently on screen, is a subresource.
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

            // The customer gets one plain sentence. The status code, which tells the developer
            // whether this is a wrong client id (404) or an outage (5xx), goes to Logcat.
            Log.e(
                KeydaBot.TAG,
                "Chat page returned HTTP ${errorResponse.statusCode} for ${request.url}. " +
                    "A 404 here usually means the client id is wrong, disabled, or from another " +
                    "environment than the base URL."
            )
            showError(MSG_UNAVAILABLE)
        }

        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            // Never proceed(). The usual cause is a cafe or airport captive portal; the other
            // cause is someone reading the connection, and a support chat carries order numbers,
            // phone numbers and addresses.
            handler.cancel()
            Log.e(KeydaBot.TAG, "SSL error ${error.primaryError} on ${error.url}")
            showError(MSG_INSECURE)
        }

        @TargetApi(Build.VERSION_CODES.O)
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // Returning false - the default - lets the framework kill the host app when the
            // WebView's render process dies, which it does on low-memory devices for reasons that
            // have nothing to do with this chat. CONTRACT rule 6: that costs the customer their
            // chat screen, not the app they were using.
            Log.e(
                KeydaBot.TAG,
                "WebView render process gone (didCrash=${detail.didCrash()}); rebuilding the chat view."
            )

            // A WebView whose renderer died can never be used again, not even to show an error.
            if (view === web) replaceDeadWebView()
            showError(MSG_RESTARTED)
            return true
        }
    }

    private fun replaceDeadWebView() {
        val dead = web
        root.removeView(dead)
        dead.destroy()

        web = buildWebView()
        // Index 0: behind the spinner and the error panel, which stay on top of it.
        root.addView(web, 0)
    }

    // ------------------------------------------------------------------------------- helpers

    private fun dp(value: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP,
        value.toFloat(),
        resources.displayMetrics
    ).toInt()

    private companion object {
        val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        // Hardcoded because this AAR ships no resources, and therefore no translations. See the
        // README: these six strings are the only English the SDK puts on screen. Everything the
        // customer reads inside the chat comes from the page, in the language it is configured in.
        const val MSG_OFFLINE = "Chat isn't connecting. Check your internet connection and try again."
        const val MSG_UNAVAILABLE = "Chat is unavailable right now. Please try again in a moment."
        const val MSG_INSECURE = "Chat couldn't be opened securely on this network."
        const val MSG_RESTARTED = "Chat had to restart on this device. Please try again."
        const val MSG_NO_APP_FOR_LINK = "No app on this phone can open that link."
        const val LABEL_RETRY = "Try again"
    }
}

/**
 * Everything that touches an API 33 type lives here, so that verifying [KeydaBotActivity] on an
 * older device never has to resolve a class that device does not have. Confining new-API calls to
 * a separate holder class is the same trick androidx uses, for the same reason.
 */
@TargetApi(Build.VERSION_CODES.TIRAMISU)
private object Api33 {

    fun registerBack(activity: Activity, onBack: () -> Unit): Any {
        val callback = OnBackInvokedCallback { onBack() }
        activity.onBackInvokedDispatcher.registerOnBackInvokedCallback(
            OnBackInvokedDispatcher.PRIORITY_DEFAULT,
            callback
        )
        return callback
    }

    fun unregisterBack(activity: Activity, token: Any) {
        activity.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(token as OnBackInvokedCallback)
    }
}
