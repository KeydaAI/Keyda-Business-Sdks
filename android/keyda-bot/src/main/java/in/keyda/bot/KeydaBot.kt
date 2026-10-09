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
 * askButton.setOnClickListener { KeydaBot.show(this, "Is this in stock?") }
 * ```
 *
 * To put the chat inside one of your own screens instead, see [KeydaBotView].
 */
object KeydaBot {

    /** Where the chat is served from. Override in [init] for self-hosting or staging. */
    const val DEFAULT_BASE_URL = "https://keyda.in/business"

    // Deliberately not `const`: a const is compiled into a public static field that Java callers
    // can see, and the public surface of this SDK is four calls and nothing else.
    internal val TAG = "KeydaBot"

    internal val EXTRA_CHAT_URL = "in.keyda.bot.EXTRA_CHAT_URL"

    internal val EXTRA_QUESTION = "in.keyda.bot.EXTRA_QUESTION"

    /**
     * Told when the full-screen chat appears and when the customer closes it, and when the business
     * replies while no chat is open — on the main thread. Every method has an empty default, so
     * implement only the ones you need (from Java too).
     */
    interface Listener {
        /** The chat screen is on screen. */
        fun onShow() {}

        /** The chat screen was closed — by the customer, by back, or by [dismiss]. */
        fun onDismiss() {}

        /**
         * A person from the business answered a customer who asked for one, while no chat was on
         * screen — so they have not seen it. Called once per new reply. Show a badge or a dot on
         * your chat button; [hasUnreadReply] stays true until the customer opens the chat, which
         * shows the reply. The SDK asks when your app comes to the foreground (once a minute at
         * most), and when you call [checkForReplies].
         */
        fun onReply() {}
    }

    /** Optional; see [Listener]. Held strongly, so clear it when the screen that set it goes away. */
    @JvmStatic
    @Volatile
    var listener: Listener? = null

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

    /** True from the chat screen appearing until the customer closes it. */
    @JvmStatic
    val isShowing: Boolean
        get() = showing

    /**
     * True when the business has replied to this customer while no chat was on screen, until the
     * customer opens the chat. Only a reply the chat itself has not shown yet counts, and a chat
     * that is loaded but hidden (a tab in the background, a [KeydaBotView] with
     * [KeydaBotView.active] false) does not count as shown. See [Listener.onReply].
     *
     * From Java: `KeydaBot.hasUnreadReply()`.
     */
    @JvmStatic
    @get:JvmName("hasUnreadReply")
    val hasUnreadReply: Boolean
        get() = KeydaBotReplies.hasUnreadReply

    /**
     * Asks now whether the business has replied, rather than at the next foreground. At most one
     * request every 10 seconds; nothing at all unless the customer asked for a person in the last
     * 14 days. The answer arrives as [Listener.onReply].
     */
    @JvmStatic
    fun checkForReplies() {
        KeydaBotReplies.look(forced = true)
    }

    /**
     * Your signed-in customer, so the chat does not ask them what your app already knows. Offered
     * — never sent — in the forms that ask for them: "talk to a person", an order, a booking, and a
     * welcome question for a name, a phone number or an email. The customer sees the values and
     * submits them; until then nothing leaves the phone (they travel in the URL's #fragment, which
     * no server sees). They are your app's word, not a verified identity, and are treated as typed
     * by the customer. Each is optional; one that does not look like what it claims is dropped
     * whole, never cut (a name of up to 80 characters; a phone of 8 to 15 digits, written with
     * digits, spaces and `+ - ( ) .`; an email address up to 254). Applies to the chats open now
     * and every one after.
     */
    @JvmStatic
    @JvmOverloads
    fun setVisitor(name: String? = null, phone: String? = null, email: String? = null) {
        val next = KeydaBotVisitor.of(name, phone, email)
        synchronized(visitorLock) {
            // The same details again (a host that sets them in every onResume) are no news to a
            // chat, and offering them again would refill a field the customer just emptied.
            if (next?.json() == visitor?.json()) return
            visitor = next
            // After the visitor: a reader that sees this number sees the details it stands for.
            visitorVersion++
        }
        runOnMain { liveViews.keys.toList().forEach { it.applyVisitor() } }
    }

    /** Forgets [setVisitor]'s details — call it when the customer signs out. */
    @JvmStatic
    fun clearVisitor() {
        setVisitor(null, null, null)
    }

    private val visitorLock = Any()

    @Volatile
    internal var visitor: KeydaBotVisitor? = null
        private set

    /**
     * Moves on every change of [visitor]. A chat that was off its window when the details changed
     * (a tab's view detached by its fragment) compares this when it comes back, and catches up.
     */
    @Volatile
    internal var visitorVersion = 0
        private set

    /** Chats attached to a window right now, full screen and embedded, for [setVisitor]. Main thread only. */
    private val liveViews = java.util.WeakHashMap<KeydaBotView, Boolean>()

    internal fun viewAlive(view: KeydaBotView) {
        liveViews[view] = true
    }

    internal fun viewGone(view: KeydaBotView) {
        liveViews.remove(view)
    }

    /**
     * Main thread. Whether [activity] has a chat the customer is about to see: attached, shown,
     * [KeydaBotView.active]. Asked as the app returns to the foreground, before the platform has
     * told the view its window is visible again.
     */
    internal fun chatShownIn(activity: Activity): Boolean {
        // peek: a screen with no content yet has no chat, and must not be given a decor view here.
        val window = activity.window?.peekDecorView() ?: return false
        return liveViews.keys.any { it.active && it.isShown && it.rootView === window }
    }

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
        KeydaBotReplies.start(context, clientId, root)

        warnAboutHostAppProblems(context.applicationContext)
    }

    /**
     * Presents the chat over [activity].
     *
     * @param question optional: put in the chat's message box for the customer to send — they
     *        still tap send. It travels in the URL's #fragment, so it never reaches a server log.
     *        With the chat already on screen, it replaces what is in the box.
     * @throws IllegalStateException if [init] has not run. A silent no-op here would look like a
     *         dead button and cost an afternoon to find.
     */
    @JvmStatic
    @JvmOverloads
    fun show(activity: Activity, question: String? = null) {
        val url = chatUrl ?: throw IllegalStateException(
            "KeydaBot.show() was called before KeydaBot.init(). Call init() once, with the client " +
                "id from Install in the Keyda Business dashboard."
        )

        // A double tap on a support button, or a tap during the open animation, would otherwise
        // stack two chat Activities: dismiss() closes one and the customer stares at the other.
        // A question for a chat already open goes into its message box instead. A chat that is
        // closing is not open: `showing` is false from the moment it starts to finish.
        if (showing) {
            if (!question.isNullOrBlank()) {
                val chat = currentChat?.get()
                if (chat != null) runOnMain { chat.prefill(question) }
            }
            return
        }

        // The URL travels in the Intent as well as living in this object. After process death
        // Android restores the Activity before any of the app's code runs, so the object may be
        // empty at that moment while the Intent survives.
        val intent = Intent(activity, KeydaBotActivity::class.java)
            .putExtra(EXTRA_CHAT_URL, url)
        if (!question.isNullOrBlank()) intent.putExtra(EXTRA_QUESTION, question)

        activity.startActivity(intent)
    }

    /** Closes the chat if it is open. Safe to call when it is not, and from any thread. */
    @JvmStatic
    fun dismiss() {
        val chat = currentChat?.get() ?: return
        if (chat.isFinishing || chat.isDestroyed) return

        runOnMain { if (!chat.isFinishing && !chat.isDestroyed) chat.finish() }
    }

    private fun runOnMain(work: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) work() else Handler(Looper.getMainLooper()).post(work)
    }

    internal fun chatUrlOrNull(): String? = chatUrl

    /**
     * @param restored the screen is being rebuilt (a configuration change, or after process death)
     *        rather than opened: the customer saw no new chat appear, so there is no second onShow.
     */
    internal fun onChatCreated(chat: KeydaBotActivity, restored: Boolean) {
        currentChat = WeakReference(chat)
        showing = true
        if (!restored) notify { it.onShow() }
    }

    /**
     * The chat started to finish (onPause with isFinishing). From here it is closed: a show() now
     * opens a new chat instead of being swallowed by one that is on its way out, which can take
     * seconds to reach onDestroy.
     */
    internal fun onChatLeaving(chat: KeydaBotActivity) {
        if (currentChat?.get() !== chat) return
        currentChat = null
        showing = false
        notify { it.onDismiss() }
    }

    internal fun onChatDestroyed(chat: KeydaBotActivity) {
        // Identity check: an old instance's onDestroy() can run after a new instance's onCreate()
        // when Android recreates the screen, and a finishing chat already left in onChatLeaving.
        if (currentChat?.get() !== chat) return
        currentChat = null
        showing = false
        // Only a chat the customer actually left. Android destroying a backgrounded screen to
        // reclaim memory, or rebuilding it, is not a dismissal; it comes back.
        if (chat.isFinishing) notify { it.onDismiss() }
    }

    /** The host app's listener is its code: a throw from it is its own, not swallowed here. */
    private fun notify(event: (Listener) -> Unit) {
        listener?.let(event)
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
