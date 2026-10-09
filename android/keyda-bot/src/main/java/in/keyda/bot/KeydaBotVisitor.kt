package `in`.keyda.bot

import android.net.Uri
import org.json.JSONObject

/**
 * [KeydaBot.setVisitor]'s details, held to the limits the server itself applies when the customer
 * submits them (a name of 80 characters, a phone of 8 to 15 digits, an email), so a value the chat
 * would refuse at the last step never leaves the app. A value that fails is dropped whole, never
 * cut: half a name or most of a phone number is worse than an empty field.
 */
internal class KeydaBotVisitor private constructor(
    val name: String,
    val phone: String,
    val email: String
) {

    /** `&name=…&phone=…&email=…` for the URL's #fragment, the empty ones left out. */
    fun fragment(): String = buildString {
        if (name.isNotEmpty()) append("&name=").append(Uri.encode(name))
        if (phone.isNotEmpty()) append("&phone=").append(Uri.encode(phone))
        if (email.isNotEmpty()) append("&email=").append(Uri.encode(email))
    }

    /** `{"name":…,"phone":…,"email":…}` for `KeydaBot.setVisitor` on a page that is already up. */
    fun json(): String = JSONObject().put("name", name).put("phone", phone).put("email", email).toString()

    companion object {
        private const val NAME_MAX = 80
        private const val EMAIL_MAX = 254

        /**
         * JavaScript's `\s`, spelled out: the page and the server judge these values with it, and
         * Java's `\s` is ASCII-only on one runtime and Unicode-aware on another. Joiners, soft
         * hyphens and direction marks are not in it, and a name keeps them.
         */
        private const val WS = "\\x09-\\x0d\\x20\\x{a0}\\x{1680}\\x{2000}-\\x{200a}" +
            "\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}\\x{feff}"
        private val CONTROL = Regex("[\\x00-\\x1f\\x7f]+")
        private val SPACES = Regex("[$WS]+")
        private val EDGES = Regex("^[$WS]+|[$WS]+\$")
        private val PHONE = Regex("^\\+?[0-9() .-]{8,32}\$")
        private val EMAIL = Regex("^[^@$WS]+@[^@$WS]+\\.[^@.$WS]{2,}\$")

        /** Null when nothing usable is left — the same as never having called setVisitor. */
        fun of(name: String?, phone: String?, email: String?): KeydaBotVisitor? {
            val n = name.orEmpty().replace(CONTROL, " ").replace(SPACES, " ").trim(' ')
                .takeIf { it.isNotEmpty() && it.codePointCount(0, it.length) <= NAME_MAX }.orEmpty()
            val p = phone.orEmpty().replace(EDGES, "").takeIf(::isPhone).orEmpty()
            val e = email.orEmpty().replace(EDGES, "").takeIf(::isEmail).orEmpty()
            if (n.isEmpty() && p.isEmpty() && e.isEmpty()) return null
            return KeydaBotVisitor(n, p, e)
        }

        /**
         * As the server's normalisePhone sees it: 8 to 15 digits, and after a "+" a country code,
         * which never starts with 0 — "+(0)…" included, since the server reads past the brackets.
         */
        private fun isPhone(value: String): Boolean {
            if (!PHONE.matches(value)) return false
            val digits = value.filter { it in '0'..'9' }
            if (value.startsWith("+") && digits.startsWith("0")) return false
            return digits.length in 8..15
        }

        private fun isEmail(value: String): Boolean =
            value.length <= EMAIL_MAX && EMAIL.matches(value) && !value.contains("..")
    }
}
