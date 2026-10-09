@file:Suppress("DEPRECATION")

package `in`.keyda.bot

import android.app.Activity
import android.app.Fragment
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log

/**
 * Opens the system file chooser for the chat's attach button (CONTRACT rule 9) from the Activity
 * the chat is in, and hands the files back to the [KeydaBotView] that asked. Headless: it adds no
 * view, and removes itself once it has answered.
 *
 * Why a fragment of the platform's own (`android.app.Fragment`, deprecated but present on every
 * version, and no AndroidX — rule 5): the read permission for a picked file is granted to the
 * Activity that RECEIVES the result and lasts as long as that Activity does. A [KeydaBotView] cannot
 * receive a result itself, and a go-between Activity of our own lost the permission the moment it
 * finished — the chat then failed to read the file it had just been handed. A fragment's result
 * arrives through the host Activity, so the permission lives as long as the screen the chat is on.
 */
class KeydaBotPickerFragment : Fragment() {

    private var answered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Restored after the process died with the chooser up: the WebView that asked is gone with
        // it, and the answer has nowhere to go. Leave quietly when it arrives (or now).
        if (savedInstanceState != null) {
            if (!pending.containsKey(requestId())) removeSelf()
            return
        }
        val chooser: Intent? = arguments?.getParcelable(ARG_CHOOSER)
        if (chooser == null) {
            answer(null)
            return
        }
        try {
            startActivityForResult(chooser, REQUEST_CODE)
        } catch (noApp: ActivityNotFoundException) {
            Log.w(KeydaBot.TAG, "No app on this device can pick a file", noApp)
            answer(null)
        } catch (refused: RuntimeException) {
            // Built from a web page's accept list; startActivity has more ways to throw than one.
            Log.w(KeydaBot.TAG, "Refused to open the file picker", refused)
            answer(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE) return
        // A cancel has to be answered too: left unanswered, the WebView never opens a chooser
        // again and the attach button is dead for the rest of the conversation.
        answer(if (resultCode == Activity.RESULT_OK) chosenFiles(data) else null)
    }

    override fun onDestroy() {
        // Torn down without an answer (the host screen closed with the chooser up): a cancel.
        if (!answered && activity?.isChangingConfigurations != true) deliver(requestId(), null)
        super.onDestroy()
    }

    private fun requestId(): Int = arguments?.getInt(ARG_REQUEST) ?: 0

    private fun answer(uris: Array<Uri>?) {
        answered = true
        deliver(requestId(), uris)
        removeSelf()
    }

    private fun removeSelf() {
        try {
            fragmentManager?.beginTransaction()?.remove(this)?.commitAllowingStateLoss()
        } catch (late: IllegalStateException) {
            // The host is going away anyway; nothing left to remove from.
        }
    }

    /**
     * Every URI the picker returned, or null when it returned none. A multiple selection puts its
     * URIs in the ClipData, not in getData() - FileChooserParams.parseResult() would keep the first
     * and drop the rest silently.
     */
    private fun chosenFiles(data: Intent?): Array<Uri>? {
        if (data == null) return null
        val clip = data.clipData
        if (clip != null) {
            val uris = ArrayList<Uri>(clip.itemCount)
            for (index in 0 until clip.itemCount) clip.getItemAt(index)?.uri?.let(uris::add)
            if (uris.isNotEmpty()) return uris.toTypedArray()
        }
        return data.data?.let { arrayOf(it) }
    }

    internal companion object {
        private const val ARG_CHOOSER = "in.keyda.bot.CHOOSER"
        private const val ARG_REQUEST = "in.keyda.bot.REQUEST"
        private const val FRAGMENT_TAG = "in.keyda.bot.picker"
        private const val REQUEST_CODE = 0x4B42

        /** Main thread only, like everything that touches it. */
        private val pending = HashMap<Int, (Array<Uri>?) -> Unit>()
        private var nextId = 1

        /**
         * Opens [chooser] from [activity] and calls [onResult] with the files, or null for a
         * cancel. Returns false when it could not be started; [onResult] is then never called.
         */
        fun launch(activity: Activity, chooser: Intent, onResult: (Array<Uri>?) -> Unit): Boolean {
            if (activity.isFinishing || activity.isDestroyed) return false
            val id = nextId++
            pending[id] = onResult
            val fragment = KeydaBotPickerFragment().apply {
                arguments = Bundle().apply {
                    putParcelable(ARG_CHOOSER, chooser)
                    putInt(ARG_REQUEST, id)
                }
            }
            return try {
                activity.fragmentManager.beginTransaction()
                    .add(fragment, FRAGMENT_TAG)
                    .commitAllowingStateLoss()
                true
            } catch (refused: RuntimeException) {
                Log.w(KeydaBot.TAG, "Could not open the file picker", refused)
                pending.remove(id)
                false
            }
        }

        private fun deliver(id: Int, uris: Array<Uri>?) {
            pending.remove(id)?.invoke(uris)
        }
    }
}
