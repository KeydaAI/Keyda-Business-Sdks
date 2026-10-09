package `in`.keyda.bot

import android.annotation.TargetApi
import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import kotlin.math.max

/**
 * The full-screen chat: a [KeydaBotView] filling a window of its own. Launched only by
 * [KeydaBot.show].
 *
 * The view does the chat (the WebView, links, the theme bridge, the retry screen, the file
 * picker). This Activity does what only a window can: the platform DayNight theme the WebView
 * reads "Match the visitor" from, the status and navigation bars painted in the chat's theme, the
 * system-bar and keyboard insets of an edge-to-edge window, and back.
 *
 * There is no XML layout and no resource of any kind in this AAR: a library that ships resources
 * ships id, colour and string collisions into every app that adds it.
 */
class KeydaBotActivity : Activity() {

    private lateinit var root: FrameLayout
    private lateinit var chat: KeydaBotView

    /** Typed [Any] deliberately - see [Api33]. */
    private var backCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // The Intent first, the singleton second. After process death Android restores this
        // Activity before a line of the app's own code runs, so KeydaBot.init() may not have
        // happened yet in the new process while the Intent extra survived in the saved task.
        val url = intent?.getStringExtra(KeydaBot.EXTRA_CHAT_URL) ?: KeydaBot.chatUrlOrNull()
        if (url == null) {
            // Nothing to load and no way to find out what to load. Closing beats a blank screen.
            Log.e(KeydaBot.TAG, "Chat opened with no configuration; call KeydaBot.init() first.")
            finish()
            return
        }

        // Before any view exists: a theme set after the decor is built is ignored.
        applyDayNightWindowTheme()

        chat = KeydaBotView(this).apply {
            layoutParams = FrameLayout.LayoutParams(MATCH, MATCH)
            onThemeApplied = { if (::root.isInitialized) applyTheme() }
        }
        root = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
            addView(chat)
        }
        setContentView(root)

        // Rebuilt (a configuration change, process death) rather than opened: no second onShow.
        KeydaBot.onChatCreated(this, restored = savedInstanceState != null)

        // After setContentView: the system-bar calls need the decor view to exist.
        applyTheme()
        applyWindowInsets(root)
        registerBackHandling()

        // The question once: a rebuilt screen would otherwise put a question the customer already
        // sent back into the box.
        val question = if (savedInstanceState == null) intent?.getStringExtra(KeydaBot.EXTRA_QUESTION) else null
        chat.loadChat(url, question)
    }

    override fun onResume() {
        super.onResume()
        if (::chat.isInitialized) chat.resumeWebView()
    }

    override fun onPause() {
        super.onPause()
        // Suspends the page's timers and rendering while the customer is somewhere else.
        if (::chat.isInitialized) chat.pauseWebView()
        // Closed from here, not from onDestroy, which can come seconds later: a show() in between
        // opens a new chat instead of being swallowed by this one.
        if (isFinishing) KeydaBot.onChatLeaving(this)
    }

    override fun onDestroy() {
        unregisterBackHandling()
        if (::chat.isInitialized) {
            // Detached first: a WebView destroyed while attached leaves its renderer behind.
            if (::root.isInitialized) root.removeView(chat)
            chat.destroy()
            KeydaBot.onChatDestroyed(this)
        }
        super.onDestroy()
    }

    /** [KeydaBot.show] with a question while the chat is already on screen. */
    internal fun prefill(question: String) {
        if (::chat.isInitialized) chat.prefill(question)
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        // Still the only back callback that fires in a host app that has not opted into predictive
        // back. The API 33 registration below covers the ones that have, which on Android 16 is
        // every app targeting 36.
        handleBack()
    }

    /**
     * CONTRACT rule 10: back closes the sheet the customer has open (an item, the cart, a booking)
     * before it closes the chat. The view decides; leaving walks the WebView's own history first
     * (a startup redirect), then finishes.
     */
    private fun handleBack() {
        if (!::chat.isInitialized) {
            finish()
            return
        }
        chat.backOrLeave {
            if (!isFinishing && !isDestroyed && !chat.historyBack()) finish()
        }
    }

    // ------------------------------------------------------------------------------------ theme

    /**
     * Why the theme is set in code and not in the manifest. The manifest names
     * Theme.DeviceDefault.Light.NoActionBar, and on API 29+ this swaps in the platform's DayNight
     * theme. On Android 13+ the WebView resolves the page's `prefers-color-scheme` from the app
     * theme's `isLightTheme`, so under a Light theme a "Match the visitor" bot reports light on a
     * dark phone. DayNight cannot go in the manifest: it exists from API 29 only, minSdk is 21, and
     * a values-v29 style is a resource, which this AAR ships none of.
     */
    private fun applyDayNightWindowTheme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        setTheme(android.R.style.Theme_DeviceDefault_DayNight)
        // DayNight has no NoActionBar variant in the platform. Must precede setContentView.
        requestWindowFeature(Window.FEATURE_NO_TITLE)
    }

    /** The window behind the chat and the system bars, in the theme the view is painted in. */
    private fun applyTheme() {
        val bg = chat.backgroundColor()
        root.setBackgroundColor(bg)
        applySystemBars(bg, chat.darkTheme)
    }

    /**
     * Status and navigation bars in the theme's background, with icons that can be seen on it.
     * Dark icons over a light bar arrived with API 23 for the status bar and API 26 for the
     * navigation bar; before each, the bar keeps a dark colour rather than becoming a light bar with
     * white icons nobody can read. On API 35+ apps forced edge-to-edge the bar colours are ignored
     * and the root's own background shows through its inset padding, which is the same colour.
     */
    @Suppress("DEPRECATION")
    private fun applySystemBars(bg: Int, dark: Boolean) {
        val w: Window = window ?: return
        w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        w.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS)
        w.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION)

        val lightStatusBarPossible = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
        val lightNavBarPossible = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

        if (dark || lightStatusBarPossible) w.statusBarColor = bg
        if (dark || lightNavBarPossible) w.navigationBarColor = bg

        val lightBars = !dark
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> Api30.setLightBars(w, lightBars)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                var flags = w.decorView.systemUiVisibility
                flags = setFlag(flags, View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR, lightBars)
                if (lightNavBarPossible) {
                    flags = setFlag(flags, View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR, lightBars)
                }
                w.decorView.systemUiVisibility = flags
            }
            // API 21-22: icons are always light and cannot be changed; the bar stayed dark above.
        }
    }

    private fun setFlag(flags: Int, flag: Int, on: Boolean): Int =
        if (on) flags or flag else flags and flag.inv()

    // --------------------------------------------------------------------------- system insets

    /**
     * CONTRACT rules 3 and 4, for the window layouts where the manifest cannot do it alone. When
     * the window is not edge-to-edge (host apps below targetSdk 35) the decor view has applied the
     * system bars already, this receives zeroes, and `adjustResize` does the keyboard. When the app
     * targets 35+ on Android 15+, these paddings are the only thing keeping the chat out from under
     * the status bar, the gesture bar and the keyboard.
     */
    private fun applyWindowInsets(target: View) {
        target.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bars = insets.getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                )
                val ime = insets.getInsets(WindowInsets.Type.ime())
                // max, not a sum: the keyboard already covers the gesture bar.
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

    private companion object {
        val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}

/**
 * Everything that touches an API 33 type lives here, so that verifying [KeydaBotActivity] on an
 * older device never has to resolve a class that device does not have.
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

/** Same trick as [Api33], for [WindowInsetsController] (API 30). */
@TargetApi(Build.VERSION_CODES.R)
private object Api30 {

    fun setLightBars(window: Window, light: Boolean) {
        val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
            WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
        // Null until the decor view exists, which is why applyTheme() runs after setContentView.
        window.insetsController?.setSystemBarsAppearance(if (light) mask else 0, mask)
    }
}
