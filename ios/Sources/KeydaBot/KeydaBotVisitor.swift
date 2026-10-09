import Foundation

/// `KeydaBot.setVisitor`'s details, cleaned the way the chat page cleans them, so a
/// value the page would drop never leaves the app either. A value that does not look
/// like what it claims is dropped whole, never cut to fit: half a name or a phone
/// number short of a digit is worse than asking the customer.
struct KeydaBotVisitor: Equatable, Sendable {
    let name: String
    let phone: String
    let email: String

    /// `nil` when nothing usable is left — the same as never having called setVisitor.
    init?(name: String?, phone: String?, email: String?) {
        let p = Self.trimmed(phone ?? "")
        let e = Self.trimmed(email ?? "")
        self.name = Self.cleanedName(name ?? "")
        self.phone = Self.isPhone(p) ? p : ""
        self.email = Self.isEmail(e) ? e : ""
        if self.name.isEmpty && self.phone.isEmpty && self.email.isEmpty { return nil }
    }

    /// Runs of control characters (U+0000–U+001F, U+007F) and of spaces become one
    /// space, and the ends are trimmed; kept at 1–80 code points. Nothing else is
    /// touched: a zero-width non-joiner, a soft hyphen or a direction mark is part of
    /// how a name is written (the Persian علی‌رضا), not noise to strip.
    private static func cleanedName(_ raw: String) -> String {
        let name = raw.unicodeScalars
            .split(omittingEmptySubsequences: true) { $0.value <= 0x1F || $0.value == 0x7F || isSpace($0) }
            .map { String($0) }
            .joined(separator: " ")
        return (1...80).contains(name.unicodeScalars.count) ? name : ""
    }

    /// `^\+?[0-9() .-]{8,32}$` with 8–15 digits (E.164 has at most 15), and not `+0`:
    /// no country code starts with a zero.
    private static func isPhone(_ phone: String) -> Bool {
        let scalars = Array(phone.unicodeScalars)
        let body = scalars.first == "+" ? scalars.dropFirst() : scalars[...]
        guard (8...32).contains(body.count),
              body.allSatisfy({ "0123456789() .-".unicodeScalars.contains($0) }) else { return false }
        let digits = body.filter { ("0"..."9").contains($0) }.count
        return (8...15).contains(digits) && !phone.hasPrefix("+0")
    }

    /// `^[^\s@]+@[^\s@]+\.[^\s@.]{2,}$`, at most 254 long, with no `..`. Checked over
    /// UTF-16 units by hand, as the page's JavaScript sees the text: one `@` with
    /// something before it, and a last dot with something before it and at least two
    /// units after it.
    private static func isEmail(_ email: String) -> Bool {
        let units = Array(email.utf16)
        guard units.count <= 254, !email.contains(".."),
              !email.unicodeScalars.contains(where: isSpace),
              let at = units.firstIndex(of: 0x40), at > 0,
              !units[(at + 1)...].contains(0x40),
              let dot = units.lastIndex(of: 0x2E), dot > at + 1 else { return false }
        return units.count - dot - 1 >= 2
    }

    /// JavaScript's `\s`, which is what the page's `trim()` and `/\s+/` treat as space.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// `name=…&phone=…&email=…` for the URL's #fragment, the empty ones left out.
    func fragmentItems(encode: (String) -> String) -> [String] {
        var items: [String] = []
        if !name.isEmpty { items.append("name=" + encode(name)) }
        if !phone.isEmpty { items.append("phone=" + encode(phone)) }
        if !email.isEmpty { items.append("email=" + encode(email)) }
        return items
    }

    /// `{"name":…,"phone":…,"email":…}` for `KeydaBot.setVisitor` on a page that is up.
    var json: String {
        let object = ["name": name, "phone": phone, "email": email]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
