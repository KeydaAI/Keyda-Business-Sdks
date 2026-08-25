package `in`.keyda.bot

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.WebView
import java.lang.ref.WeakReference

/**
 * The whole SDK.
 *
 * `KeydaBot` opens `{baseUrl}/chat/{clientId}` in a full-screen WebView. It is a wrapper around a
 * hosted page, not a native chat client, so that a change an owner makes in their dashboard is
 * live in this app the moment they save it, with no release on your side.
 *
 * Kotlin callers: `in` is a Kotlin keyword, so it has to be escaped in the import -- the README
 * shows the exact line. Java callers import the package normally.
 *
 * ```
 * KeydaBot.init(this, "kb_live_9f4c2a10")     // once, in Application.onCreate()
 * chatButton.setOnClickListener { KeydaBot.show(this) }
 * ```
 */
object KeydaBot {

    /** Where the chat is served from. Override in [init] for self-hosting or staging. */
    const val DEFAULT_BASE_URL = "https://keyda.in/business"

    // Deliberately not `const`: a const is compiled into a public static field that Java callers
    // can see, and the public surface of this SDK is four calls and nothing else.
    internal val TAG = "KeydaBot"

    internal val EXTRA_CHAT_URL = "in.keyda.bot.EXTRA_CHAT_URL"

    /**
     * `kb_live_` followed by 8-48 hex characters. An id of any other shape is rejected in [init]
     * rather than being pasted into a URL: a typo that reaches production would otherwise show a
     * customer a 404 page inside what looks like the app's own support screen.
     */
    private val CLIENT_ID_SHAPE = Regex("^kb_live_[0-9a-f]{8,48}\$")

    @Volatile
    private var chatUrl: String? = null

    @Volatile
    private var showing = false

    /**
     * Weak on purpose. This is a process-lifetime singleton holding a reference to an Activity; a
     * strong one would keep the whole destroyed screen - its WebView and every bitmap in it - alive
     * for as long as the host app runs.
     *
     * Volatile like the two fields above it: [dismiss] is documented as safe from any thread, and
     * without it a background caller can keep reading a stale null and silently close nothing.
     */
    @Volatile
    private var currentChat: WeakReference<KeydaBotActivity>? = null

    /** True between the chat screen appearing and it being destroyed. */
    @JvmStatic
    val isShowing: Boolean
        get() = showing

    /**
     * Stores the configuration and validates it. Call once; `Application.onCreate()` is the right
     * place, because a chat Activity restored after process death needs the configuration to be
     * there before any of your own screens run.
     *
     * @param clientId from **Install** in the Keyda Business dashboard.
     * @param baseUrl override only for self-hosting or staging.
     * @throws IllegalArgumentException if the client id or base URL is malformed. This is a
     *         mistake in your integration, it is the same on every device and every launch, and it
     *         is far cheaper to hit on your desk than to ship.
     */
    @JvmStatic
    @JvmOverloads
    fun init(context: Context, clientId: String, baseUrl: String = DEFAULT_BASE_URL) {
        require(CLIENT_ID_SHAPE.matches(clientId)) {
            "KeydaBot: \"$clientId\" is not a Keyda client id. Expected kb_live_ followed by " +
                "8 to 48 hex characters, copied exactly from Install in the Keyda Business dashboard."
        }

        // Trailing slashes are the common paste error; "https://host//chat/kb_live_x" 404s.
        val root = baseUrl.trim().trimEnd('/')
        val parsed = Uri.parse(root)
        val scheme = parsed.scheme?.lowercase()

        require(scheme == "https" || scheme == "http") {
            "KeydaBot: baseUrl must start with https:// (http:// is accepted for local " +
                "development only). Got \"$baseUrl\"."
        }
        require(!parsed.host.isNullOrBlank()) {
            "KeydaBot: baseUrl has no host. Got \"$baseUrl\"."
        }

        chatUrl = "$root/chat/$clientId"

        warnAboutHostAppProblems(context.applicationContext)
    }

    /**
     * Presents the chat over [activity].
     *
     * @throws IllegalStateException if [init] has not run. A silent no-op here would look like a
     *         dead button and cost an afternoon to find.
     */
    @JvmStatic
    fun show(activity: Activity) {
        val url = chatUrl ?: throw IllegalStateException(
            "KeydaBot.show() was called before KeydaBot.init(). Call init() once, with the client " +
                "id from Install in the Keyda Business dashboard."
        )

        // A double tap on a support button, or a tap during the open animation, would otherwise
        // stack two chat Activities: dismiss() closes one and the customer stares at the other.
        if (showing) return

        // The URL travels in the Intent as well as living in this object. After process death
        // Android restores the Activity before any of the app's code runs, so the object may be
        // empty at that moment while the Intent survives.
        val intent = Intent(activity, KeydaBotActivity::class.java)
            .putExtra(EXTRA_CHAT_URL, url)

        activity.startActivity(intent)
    }

    /** Closes the chat if it is open. Safe to call when it is not, and from any thread. */
    @JvmStatic
    fun dismiss() {
        val chat = currentChat?.get() ?: return
        if (chat.isFinishing || chat.isDestroyed) return

        if (Looper.myLooper() == Looper.getMainLooper()) {
            chat.finish()
        } else {
            Handler(Looper.getMainLooper()).post {
                if (!chat.isFinishing && !chat.isDestroyed) chat.finish()
            }
        }
    }

    internal fun chatUrlOrNull(): String? = chatUrl

    internal fun onChatCreated(chat: KeydaBotActivity) {
        currentChat = WeakReference(chat)
        showing = true
    }

    internal fun onChatDestroyed(chat: KeydaBotActivity) {
        // Identity check: an old instance's onDestroy() can run after a new instance's onCreate()
        // when Android recreates the screen. Clearing unconditionally would report isShowing =
        // false while the chat is on screen, and dismiss() would then do nothing.
        if (currentChat?.get() !== chat) return
        currentChat = null
        showing = false
    }

    /**
     * Environment problems are logged, never thrown: they depend on the device, not on the
     * integration, and CONTRACT rule 6 says the host app's users are not ours to crash. Both of
     * these otherwise surface only as a customer looking at the retry screen forever.
     */
    @SuppressLint("WebViewApiAvailability") // WebViewCompat means androidx.webkit; see CONTRACT rule 5.
    private fun warnAboutHostAppProblems(app: Context) {
        val packageManager = app.packageManager

        val granted = packageManager.checkPermission(
            Manifest.permission.INTERNET,
            app.packageName
        ) == PackageManager.PERMISSION_GRANTED

        if (!granted) {
            Log.e(
                TAG,
                "android.permission.INTERNET is not held by ${app.packageName}. This SDK's manifest " +
                    "declares it, so something in the app is removing it (a tools:node=\"remove\" " +
                    "or a manifest-stripping build step). Every chat load will fail until it is back."
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && WebView.getCurrentWebViewPackage() == null) {
            Log.e(
                TAG,
                "No Android System WebView provider is installed or enabled on this device, so the " +
                    "chat cannot render. This happens on stripped-down and older budget devices; " +
                    "the customer will see the retry screen."
            )
        }
    }
}
