import XCTest
@testable import KeydaBot

/// `setVisitor`'s cleaning, which must drop exactly what the chat page would drop.
final class KeydaBotVisitorTests: XCTestCase {

    /// Text from code points, so that invisible characters are visible in the test.
    private func text(_ values: UInt32...) -> String {
        String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
    }

    func testKeepsWellFormedDetails() {
        let v = KeydaBotVisitor(name: "  Asha   Rao ", phone: "+91 98765 43210", email: "asha@example.com")
        XCTAssertEqual(v?.name, "Asha Rao")
        XCTAssertEqual(v?.phone, "+91 98765 43210")
        XCTAssertEqual(v?.email, "asha@example.com")
    }

    func testDropsWhatDoesNotLookLikeWhatItClaims() {
        let v = KeydaBotVisitor(name: String(repeating: "a", count: 81), phone: "call me", email: "x@y")
        XCTAssertNil(v, "nothing usable is the same as no visitor")
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: nil, email: nil))
        XCTAssertNil(KeydaBotVisitor(name: " \n\t ", phone: "  ", email: ""))
        XCTAssertEqual(KeydaBotVisitor(name: nil, phone: "12", email: "a@b.co")?.phone, "")
        XCTAssertEqual(KeydaBotVisitor(name: "Line\nbreak\tand\u{7}bell", phone: nil, email: nil)?.name, "Line break and bell")
    }

    func testNameIsKeptWholeOrDropped() {
        let eighty = String(repeating: "a", count: 80)
        XCTAssertEqual(KeydaBotVisitor(name: eighty, phone: nil, email: nil)?.name, eighty)
        // Counted in code points: 80 emoji are 80, not 160 UTF-16 units.
        let faces = String(repeating: text(0x1F600), count: 80)
        XCTAssertEqual(KeydaBotVisitor(name: faces, phone: nil, email: nil)?.name, faces)
        XCTAssertNil(KeydaBotVisitor(name: faces + text(0x1F600), phone: nil, email: nil))
    }

    func testNameKeepsJoinersSoftHyphensAndDirectionMarks() {
        // علی‌رضا: the zero-width non-joiner is how the name is spelled.
        let persian = text(0x0639, 0x0644, 0x06CC, 0x200C, 0x0631, 0x0636, 0x0627)
        XCTAssertEqual(KeydaBotVisitor(name: persian, phone: nil, email: nil)?.name, persian)
        let marks = "Ann" + text(0x00AD) + "Marie " + text(0x200F) + "X" + text(0x200D) + "Y"
        XCTAssertEqual(KeydaBotVisitor(name: marks, phone: nil, email: nil)?.name, marks)
        // DEL and a no-break space are a control and a space, as on the page.
        XCTAssertEqual(KeydaBotVisitor(name: "A" + text(0x7F) + "B" + text(0xA0, 0x3000) + "C", phone: nil, email: nil)?.name, "A B C")
    }

    func testPhoneNeedsEightToFifteenDigits() {
        XCTAssertEqual(KeydaBotVisitor(name: nil, phone: "1234 5678", email: nil)?.phone, "1234 5678")
        XCTAssertEqual(KeydaBotVisitor(name: nil, phone: "+1 (415) 555-0100", email: nil)?.phone, "+1 (415) 555-0100")
        XCTAssertEqual(KeydaBotVisitor(name: nil, phone: "123456789012345", email: nil)?.phone, "123456789012345")
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: "1234567", email: nil), "7 digits")
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: "1234567890123456", email: nil), "16 digits")
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: "+0 1234 5678", email: nil), "no country code starts with 0")
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: "12345678 ext 9", email: nil))
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: "1-2-3-4-5-6-7-8" + String(repeating: " ", count: 20) + "9", email: nil), "over 32")
    }

    func testEmail() {
        XCTAssertEqual(KeydaBotVisitor(name: nil, phone: nil, email: " a.b@mail.example.in ")?.email, "a.b@mail.example.in")
        for bad in ["a@b.c", "a..b@example.com", "a@example..com", "@example.com", "a@.com", "a@b@c.com", "a b@c.com", "a@c.com."] {
            XCTAssertNil(KeydaBotVisitor(name: nil, phone: nil, email: bad), bad)
        }
        let local = String(repeating: "a", count: 254 - "@example.com".count)
        XCTAssertNotNil(KeydaBotVisitor(name: nil, phone: nil, email: local + "@example.com"))
        XCTAssertNil(KeydaBotVisitor(name: nil, phone: nil, email: local + "a@example.com"), "255 long")
    }

    func testFragmentAndJson() {
        let v = KeydaBotVisitor(name: "Asha & Co", phone: nil, email: "a+b@example.com")!
        let items = v.fragmentItems { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        XCTAssertEqual(items, ["name=Asha%20%26%20Co", "email=a%2Bb%40example%2Ecom"])
        XCTAssertEqual(v.json, #"{"email":"a+b@example.com","name":"Asha & Co","phone":""}"#)
    }
}
