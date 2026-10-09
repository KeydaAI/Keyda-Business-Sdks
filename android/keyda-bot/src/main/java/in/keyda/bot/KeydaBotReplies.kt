package `in`.keyda.bot

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import android.util.Log
import android.view.Choreographer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/**
 * A reply from the business that arrives while the chat is closed.
 *
 * A customer who asked for a person leaves their details and closes the chat; the owner answers
 * in the dashboard an hour later. The answer lands in the conversation, and the chat page shows it
 * the next time it opens — but nothing told the customer to open it. This is that something.
 *
 * The page is the source of truth. It keeps the chats it is waiting on (up to three, for 14 days,
 * each with the time of the last row it showed) and sends that list over the bridge as
 * `keyda:waits` whenever it changes. This object keeps a copy on disk, and when the app comes to
 * the foreground with no chat on screen it asks the same public route the page asks
 * (`/widget/{clientId}/messages`) whether a person has written since. Nothing here moves the
 * page's place: the page does that when it draws the reply, and sends the list back.
 *
 * The page draws a reply in a chat nobody can see, too. A Help tab in the background, a ViewPager2
 * neighbour, a GONE view: each keeps its page loaded and polling, and that page moves its place
 * and says so. So each wait keeps the page's place ([Wait.page]) apart from the customer's
 * ([Wait.at]), and only a chat on screen moves the customer's. The check asks after the customer's.
 *
 * The list and the file are touched only on [worker]. [lock] covers the rest: the on-screen count,
 * each [KeydaBotView.onScreen], the unread flag, and the order in which page messages and screen
 * changes are queued on [worker] — so on the worker no screen change overtakes a message that was
 * read before it, nor the other way round.
 */
internal object KeydaBotReplies {

    private const val MAX_WAITS = 3
    private const val WAIT_TTL_MS = 14L * 24 * 60 * 60 * 1000
    /** One look per minute at most. Three requests a foreground is nothing; three a second is. */
    private const val MIN_INTERVAL_MS = 60_000L
    /** What [KeydaBot.checkForReplies] still waits between looks, for a host that calls it a lot. */
    private const val MIN_FORCED_INTERVAL_MS = 10_000L
    private const val TIMEOUT_MS = 10_000
    /** A page of 100 rows is far below this; anything bigger is not the route we know. */
    private const val MAX_BODY_BYTES = 1 shl 20
    /** Apex to www and http to https take two; a third is spare, a fourth is a loop. */
    private const val MAX_REDIRECTS = 3
    private const val FILE_PREFIX = "keyda_bot_waits_"

    private val REDIRECTS = setOf(301, 302, 303, 307, 308)
    private val CONVERSATION_SHAPE = Regex("^[0-9a-f-]{36}\$", RegexOption.IGNORE_CASE)
    /** The server's ISO time, as the page stores it. Compared as strings, as the page does. */
    private val TIME_SHAPE = Regex("^[0-9T:.+\\-Z]{0,40}\$")

    /**
     * One chat waiting for a person.
     *
     * @property at the place the customer has seen: the page's place as a chat ON SCREEN last
     *           reported it. The check asks for rows after it.
     * @property page the page's place as any chat last reported it, hidden ones included. A chat
     *           coming on screen shows the customer everything up to it.
     * @property told the newest reply the app has been told about, so a foreground does not tell it
     *           twice. Never below [at].
     */
    private class Wait(
        val conversation: String,
        var at: String,
        var page: String,
        val since: Long,
        var told: String
    )

    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "KeydaBot-replies").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    // ── worker-thread state ──
    private var store: AtomicFile? = null
    private var messagesUrl: String? = null
    private var root: String? = null
    /** The chat the store belongs to (`{root}/chat/{clientId}`); null until the first [start]. */
    private var pageUrl: String? = null
    private var waits = mutableListOf<Wait>()
    /** The chat [waits] came from. Before [start], that is a chat restored after process death. */
    private var waitsFrom: String? = null
    private var lastLook = 0L

    // ── under [lock] ──
    internal val lock = Any()
    /** Chats on screen: the full-screen one and every [KeydaBotView] counted as on screen. */
    @Volatile
    private var chatsOnScreen = 0
    @Volatile
    private var unread = false
    /** The chat of the last [start]: a start() for the same one changes nothing. */
    private var configured: String? = null
    @Volatile
    private var generation = 0

    @Volatile
    private var loading: Future<*>? = null

    /** True once the current client's list has been read; from then on nobody waits for it. */
    @Volatile
    private var loaded = false

    // ── main-thread state ──
    private var callbacksRegistered = false

    /**
     * The list is read from disk on [worker] at [start]. Asked before that read is done — an
     * Activity's first onResume after a cold start — this waits for it (briefly), rather than
     * answer false for a reply the customer has not seen. Only then: once the current client's
     * list is in, a reader never waits, whatever [worker] is busy with (a look can take a minute
     * on a bad network). The read is never on the caller's thread, so StrictMode has nothing to
     * report.
     */
    val hasUnreadReply: Boolean
        get() {
            if (!loaded) {
                loading?.let { pending ->
                    try {
                        pending.get(250, TimeUnit.MILLISECONDS)
                    } catch (late: Exception) {
                        // Slow storage: answer with what is known.
                    }
                }
            }
            return unread
        }

    /** From [KeydaBot.init]. Safe to call again; a different client id or server starts afresh. */
    fun start(context: Context, clientId: String, baseRoot: String) {
        val app = context.applicationContext
        val origin = Uri.parse(baseRoot).let { "${it.scheme}://${it.encodedAuthority}" }
        val url = "$origin/api/business/v1/widget/$clientId/messages"
        val page = "$baseRoot/chat/$clientId"
        synchronized(lock) {
            if (page != configured) {
                configured = page
                loaded = false
                val mine = ++generation
                loading = worker.submit {
                    // A later start() for yet another client: its own task reads that list.
                    if (mine != generation) return@submit
                    try {
                        switchTo(app, clientId, baseRoot, url, page)
                    } finally {
                        if (mine == generation) loaded = true
                    }
                }
            }
        }
        runOnMain {
            if (callbacksRegistered) return@runOnMain
            callbacksRegistered = true
            (app as? Application)?.registerActivityLifecycleCallbacks(Foreground)
        }
    }

    /**
     * A `keyda:waits` message from the page in [from]. The bridge's thread.
     *
     * Whether [from] is on screen is read here, with [lock] held, and not when [worker] gets to
     * it: a chat that came on screen in between has its own task queued behind this one.
     */
    fun onWaits(list: JSONArray?, from: KeydaBotView) {
        val parsed = mutableListOf<Wait>()
        val now = System.currentTimeMillis()
        if (list != null) {
            for (i in 0 until minOf(list.length(), MAX_WAITS)) {
                val w = list.optJSONObject(i) ?: continue
                val c = w.optString("c")
                val at = w.optString("at")
                val since = w.optLong("t", 0L)
                if (!CONVERSATION_SHAPE.matches(c) || !TIME_SHAPE.matches(at)) continue
                if (since <= 0L || now - since >= WAIT_TTL_MS) continue
                parsed.add(Wait(c, at, at, since, at))
            }
        }
        val source = from.pageUrl
        synchronized(lock) {
            val seen = from.onScreen
            worker.execute { replaceWaits(parsed, seen, source) }
        }
    }

    /**
     * A chat came on screen: whatever is waiting is about to be shown there, and whatever a hidden
     * chat drew is in it too. Main thread.
     */
    fun chatAppeared() {
        synchronized(lock) {
            chatsOnScreen++
            unread = false
            worker.execute {
                for (w in waits) if (w.page > w.at) w.at = w.page
                settle()
            }
        }
    }

    /**
     * Main thread. Unread again only if the chat did not get to show the reply (it failed to
     * load, say): the page moves its place when it draws one, and sends the list back first.
     */
    fun chatWentAway() {
        synchronized(lock) {
            if (chatsOnScreen > 0) chatsOnScreen--
            worker.execute { settle() }
        }
    }

    /** [KeydaBot.checkForReplies], and the foreground. Any thread. */
    fun look(forced: Boolean) {
        if (chatsOnScreen > 0) return
        worker.execute { lookNow(if (forced) MIN_FORCED_INTERVAL_MS else MIN_INTERVAL_MS) }
    }

    /**
     * Worker. The page's list replaces ours, with two marks of ours kept: what the app was already
     * told about survives (a reply the page has now shown is behind its new place, and so no
     * longer unread), and a place a hidden chat reported does not count as seen.
     *
     * A hidden chat's new place says only that some row arrived. The page moves past every row it
     * draws — an order's status, the bot's own — not just a person's, so it is not a reply by
     * itself and does not move [Wait.told]. It is a reason to look, though, at once: the look asks
     * after the customer's place and counts a person's rows only, so a real reply is told (and
     * [KeydaBot.Listener.onReply] called) and anything else changes nothing.
     */
    private fun replaceWaits(incoming: MutableList<Wait>, seen: Boolean, source: String) {
        // A chat left over from another client id or server: not the list we keep.
        val expected = pageUrl
        if (expected != null && source != expected) return
        val prior = waits.associateBy { it.conversation }
        var hiddenPageMoved = false
        for (w in incoming) {
            val p = prior[w.conversation] ?: continue
            if (seen) {
                w.told = maxOf(p.told, w.at)
            } else {
                if (p.at < w.at) w.at = p.at
                w.told = maxOf(p.told, w.at)
                if (w.page > p.page) hiddenPageMoved = true
            }
        }
        waits = incoming
        waitsFrom = source
        settle()
        // Not held to the minute: the page's own poll (every 12 seconds) bounds how often a hidden
        // chat can move, and the customer should hear of the reply it drew now, not next foreground.
        if (hiddenPageMoved && chatsOnScreen == 0) lookNow(minInterval = 0L)
    }

    /**
     * Worker. The store for [page]'s client. A list a chat sent before this — a chat restored after
     * process death, in an app that calls init() from a screen rather than Application.onCreate —
     * is newer than the file: its entries win, and the file fills in the rest.
     */
    private fun switchTo(app: Context, clientId: String, baseRoot: String, url: String, page: String) {
        try {
            // Here and not in start(): noBackupFilesDir creates its folder, which is disk on
            // init()'s thread, and init() belongs in Application.onCreate. noBackupFilesDir: chat
            // ids belong to this install. Restored onto a new phone they would be watched there
            // too, for a conversation that phone never had.
            val dir = app.noBackupFilesDir
            val file = File(dir, "$FILE_PREFIX$clientId.json")
            val early = if (waitsFrom == page) waits else mutableListOf()
            store = AtomicFile(file)
            root = baseRoot
            messagesUrl = url
            pageUrl = page
            val merged = early
            for (d in load()) {
                val m = merged.firstOrNull { it.conversation == d.conversation }
                if (m != null) {
                    if (d.told > m.told) m.told = d.told
                } else if (merged.size < MAX_WAITS) {
                    merged.add(d)
                }
            }
            waits = merged
            waitsFrom = page
            settle()
            forgetOtherClients(dir, file.name)
        } catch (e: Exception) {
            Log.w(KeydaBot.TAG, "Could not open the reply list: ${e.javaClass.simpleName}")
        }
    }

    /** Unread: a person wrote past the place the customer last saw, and no chat is open to show it. */
    private fun settle() {
        // Computed and published in one step: a chat that appears meanwhile is not overwritten by
        // a count from before it.
        synchronized(lock) {
            unread = chatsOnScreen == 0 && waits.any { it.told > it.at }
        }
        save()
    }

    /** Worker. [minInterval]: how long since the last look this one needs, 0 for none. */
    private fun lookNow(minInterval: Long) {
        val url = messagesUrl ?: return
        val now = System.currentTimeMillis()
        if (waits.removeAll { now - it.since >= WAIT_TTL_MS }) settle()
        if (waits.isEmpty() || chatsOnScreen > 0) return
        if (now - lastLook < minInterval) return
        lastLook = now

        // Offline is not "no reply": a failed look changes nothing, so a badge the customer has
        // not acted on stays until the page shows them the reply.
        var fresh = false
        for (w in waits) {
            val rows = fetch(url, w) ?: continue
            var latest = ""
            for (i in 0 until rows.length()) {
                val row = rows.optJSONObject(i) ?: continue
                if (row.optString("from") != "human") continue
                val at = row.optString("at")
                if (at > w.at && at > latest) latest = at
            }
            if (latest > w.told) {
                w.told = latest
                fresh = true
            }
        }
        settle()
        if (fresh) {
            main.post {
                // The customer opened the chat while we were asking: they are reading it already.
                if (chatsOnScreen == 0 && unread) KeydaBot.listener?.onReply()
            }
        }
    }

    /**
     * The rows after [w]'s place, or null for anything else — which changes nothing.
     *
     * Redirects are followed here, at most [MAX_REDIRECTS], and only where the chat's own server
     * can move: the same host, its www or apex twin, or http to https. HttpURLConnection left to
     * itself follows one anywhere, and this request names a conversation.
     */
    private fun fetch(base: String, w: Wait): JSONArray? {
        val query = "?conversationId=" + Uri.encode(w.conversation) +
            if (w.at.isEmpty()) "" else "&after=" + Uri.encode(w.at)
        var url = try {
            URL(base + query)
        } catch (bad: Exception) {
            return null
        }
        val start = url
        for (hop in 0..MAX_REDIRECTS) {
            var connection: HttpURLConnection? = null
            try {
                connection = (url.openConnection() as HttpURLConnection).apply {
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    useCaches = false
                    instanceFollowRedirects = false
                    setRequestProperty("Accept", "application/json")
                }
                val code = connection.responseCode
                if (code in REDIRECTS) {
                    val next = connection.getHeaderField("Location")?.let { URL(url, it) }
                    if (next == null || !mayFollow(url, next, start)) {
                        Log.d(KeydaBot.TAG, "Reply check: not following a redirect off the chat's server")
                        return null
                    }
                    url = next
                    continue
                }
                if (code != HttpURLConnection.HTTP_OK) return null
                val bytes = connection.inputStream.use { input ->
                    val out = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        if (out.size() > MAX_BODY_BYTES) return null
                    }
                    out.toByteArray()
                }
                return JSONObject(String(bytes, Charsets.UTF_8)).optJSONArray("messages") ?: JSONArray()
            } catch (e: Exception) {
                // No network, a captive portal, a server hiccup: the next foreground asks again.
                Log.d(KeydaBot.TAG, "Reply check failed: ${e.javaClass.simpleName}")
                return null
            } finally {
                connection?.disconnect()
            }
        }
        Log.d(KeydaBot.TAG, "Reply check: too many redirects")
        return null
    }

    /** The same host as [start], or its www / apex twin; never from https down to http. */
    private fun mayFollow(from: URL, to: URL, start: URL): Boolean {
        val scheme = to.protocol.lowercase()
        val upOrLevel = scheme == "https" || (scheme == "http" && from.protocol.equals("http", ignoreCase = true))
        if (!upOrLevel) return false
        val host = to.host.lowercase()
        val home = start.host.lowercase()
        return host == home || host == "www.$home" || home == "www.$host"
    }

    /** The list in the file, for this server. Worker. */
    private fun load(): MutableList<Wait> {
        val list = mutableListOf<Wait>()
        val file = store ?: return list
        try {
            val json = JSONObject(String(file.readFully(), Charsets.UTF_8))
            if (json.optString("root") != root) return list
            val stored = json.optJSONArray("waits") ?: return list
            for (i in 0 until minOf(stored.length(), MAX_WAITS)) {
                val w = stored.optJSONObject(i) ?: continue
                val c = w.optString("c")
                val at = w.optString("at")
                val told = w.optString("told")
                if (!CONVERSATION_SHAPE.matches(c) || !TIME_SHAPE.matches(at) || !TIME_SHAPE.matches(told)) continue
                // A file from before the page's place was kept apart: the page was where we were.
                val page = w.optString("page", at).takeIf { TIME_SHAPE.matches(it) } ?: at
                list.add(Wait(c, at, page, w.optLong("t", 0L), if (told > at) told else at))
            }
        } catch (e: java.io.FileNotFoundException) {
            // Nothing was ever waited on.
        } catch (e: Exception) {
            Log.w(KeydaBot.TAG, "Discarding an unreadable reply list: ${e.javaClass.simpleName}")
        }
        return list
    }

    private fun save() {
        val file = store ?: return
        val list = JSONArray()
        for (w in waits) {
            list.put(
                JSONObject().put("c", w.conversation).put("at", w.at).put("page", w.page)
                    .put("t", w.since).put("told", w.told)
            )
        }
        val json = JSONObject().put("root", root).put("waits", list)
        var out: java.io.FileOutputStream? = null
        try {
            if (waits.isEmpty()) {
                file.delete()
                return
            }
            out = file.startWrite()
            out.write(json.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(out)
        } catch (e: Exception) {
            if (out != null) file.failWrite(out)
            Log.w(KeydaBot.TAG, "Could not save the reply list: ${e.javaClass.simpleName}")
        }
    }

    /**
     * The lists of client ids this app used before. Nothing asks about them again, so nothing
     * should keep them. [keep]'s own backup and new files (AtomicFile's) share its name as a
     * prefix and stay.
     */
    private fun forgetOtherClients(dir: File, keep: String) {
        try {
            dir.listFiles()?.forEach { f ->
                if (f.name.startsWith(FILE_PREFIX) && !f.name.startsWith(keep)) f.delete()
            }
        } catch (e: Exception) {
            Log.d(KeydaBot.TAG, "Could not tidy old reply lists: ${e.javaClass.simpleName}")
        }
    }

    private fun runOnMain(work: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) work() else main.post(work)
    }

    /** The app coming to the foreground: the first of its Activities to start. Main thread. */
    private object Foreground : Application.ActivityLifecycleCallbacks {
        private var startedActivities = 0

        /** The app came to the foreground and has not resumed a screen since. */
        private var returning = false

        override fun onActivityStarted(activity: Activity) {
            startedActivities++
            if (startedActivities == 1) returning = true
        }

        /**
         * Asked from here and a frame later, not from onActivityStarted: a chat on the screen that
         * comes back learns its window is visible only at the first traversal after onResume.
         * Asked before that, the check would go out for a reply the customer is looking at, and
         * spend its onReply on it.
         */
        override fun onActivityResumed(activity: Activity) {
            if (!returning) return
            returning = false
            // The full-screen chat shows whatever came (back from its own file picker, too).
            if (activity is KeydaBotActivity) return
            Choreographer.getInstance().postFrameCallback {
                // Frame callbacks run before the frame's traversal: one post more runs after it.
                main.post {
                    // An embedded chat the platform has not reported visible yet still counts.
                    if (!KeydaBot.chatShownIn(activity)) look(forced = false)
                }
            }
        }

        override fun onActivityStopped(activity: Activity) {
            if (startedActivities > 0) startedActivities--
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }
}
