import Foundation
import XCTest

/// #22 provider announcement and support contacts, #26 hide-url — from the subscription's headers
/// (names as Remnawave and Happ/INCY send them; values plain or `base64:`).
final class ProviderInfoTests: XCTestCase {
    private func base64(_ text: String) -> String { "base64:" + Data(text.utf8).base64EncodedString() }

    func testNothingWithoutHeaders() {
        let info = ProviderInfo(headers: ["profile-title": "StorkVPN"])
        XCTAssertNil(info.announcement)
        XCTAssertNil(info.announcementURL)
        XCTAssertNil(info.supportURL)
        XCTAssertNil(info.supportEmail)
        XCTAssertFalse(info.hidesURL)
    }

    func testAnnouncementPlainAndBase64() {
        XCTAssertEqual(ProviderInfo(headers: ["announce": "Maintenance at 03:00"]).announcement, "Maintenance at 03:00")
        // Remnawave's `rwEncodeBase64:` template gives `base64:<UTF-8>`
        XCTAssertEqual(ProviderInfo(headers: ["announce": base64("Плановые работы 15 марта")]).announcement,
                       "Плановые работы 15 марта")
        XCTAssertNil(ProviderInfo(headers: ["announce": "   "]).announcement)
    }

    func testAnnouncementDropsControlAndBidiCharacters() {
        let info = ProviderInfo(headers: ["announce": base64("Hi\u{0007}\u{202E}there\u{0000}\r\nline two\tend")])
        XCTAssertEqual(info.announcement, "Hithere\nline two end")
    }

    /// Emoji sequences are joined by U+200D (a format character too): kept, while the bidi and
    /// other invisible format characters go.
    func testAnnouncementKeepsEmojiSequences() {
        let family = "👨\u{200D}👩\u{200D}👧", rainbow = "🏳\u{FE0F}\u{200D}🌈"
        let info = ProviderInfo(headers: ["announce": base64("\(family) \u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}\u{200B}ok \(rainbow)")])
        XCTAssertEqual(info.announcement, "\(family) ok \(rainbow)")
        XCTAssertEqual(SubscriptionHeaders.title("Stork \(rainbow)"), "Stork \(rainbow)")
    }

    /// A kept joiner must not make an invisible banner or «Сообщение от «»», nor glue thousands of
    /// scalars into one Character that slips past the caps.
    func testJoinerAloneIsNothing() {
        XCTAssertNil(ProviderInfo.text("\u{200D}"))
        XCTAssertNil(ProviderInfo.text(" \u{200D}\u{200D} \u{FE0F} "))
        XCTAssertNil(SubscriptionHeaders.title("\u{200D}"))
        XCTAssertNil(ProviderInfo(headers: ["announce": base64("\u{200D}\n\u{200D}\u{200D}")]).announcement)
        XCTAssertEqual(ProviderInfo.text("\u{200D}Hi\u{200D}"), "Hi")
        XCTAssertEqual(ProviderInfo.text("👨\u{200D}\u{200D}\u{200D}👩"), "👨\u{200D}👩", "no runs of joiners")
        XCTAssertEqual(ProviderInfo.text("a \u{200D} b"), "a  b", "only between two visible scalars")
    }

    func testJoinedEmojiCannotBypassTheCaps() throws {
        let glued = Array(repeating: "😀", count: 4000).joined(separator: "\u{200D}")
        XCTAssertEqual(glued.count, 1)
        let announcement = ProviderInfo.text("ok " + glued)
        XCTAssertLessThanOrEqual(announcement?.unicodeScalars.count ?? 0, ProviderInfo.maxAnnouncementLength)
        XCTAssertLessThanOrEqual(SubscriptionHeaders.title(glued)?.unicodeScalars.count ?? 0, SubscriptionHeaders.maxTitleLength)
        let long = try XCTUnwrap(ProviderInfo.text(String(repeating: "👨\u{200D}👩\u{200D}👧 ", count: 200)))
        XCTAssertLessThanOrEqual(long.unicodeScalars.count, ProviderInfo.maxAnnouncementLength)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix("👨\u{200D}👩\u{200D}👧 "), "whole emoji are kept")
    }

    func testAnnouncementIsCapped() throws {
        let long = String(repeating: "а", count: 1000)
        let text = try XCTUnwrap(ProviderInfo(headers: ["announce": base64(long)]).announcement)
        XCTAssertLessThanOrEqual(text.count, ProviderInfo.maxAnnouncementLength)
        XCTAssertTrue(text.hasSuffix("…"))
        let lines = (1...9).map { "строка \($0)" }.joined(separator: "\n")
        let short = try XCTUnwrap(ProviderInfo(headers: ["announce": base64(lines + "\n\n\n")]).announcement)
        XCTAssertEqual(short.split(separator: "\n").count, ProviderInfo.maxAnnouncementLines)
        XCTAssertFalse(short.contains("\n\n"))
    }

    func testAnnouncementKeepsMarkupAsText() {
        // shown with Text(String): no HTML, no Markdown links
        let info = ProviderInfo(headers: ["announce": "<b>Скидка</b> [тут](https://evil.example)"])
        XCTAssertEqual(info.announcement, "<b>Скидка</b> [тут](https://evil.example)")
    }

    func testLinksOnlyWebTelegramMail() {
        func link(_ value: String) -> URL? { ProviderInfo(headers: ["support-url": value]).supportURL }
        XCTAssertEqual(link("https://t.me/stork_support"), URL(string: "https://t.me/stork_support"))
        XCTAssertEqual(link(" https://example.com/help "), URL(string: "https://example.com/help"))
        XCTAssertEqual(link("tg://resolve?domain=stork_support"), URL(string: "tg://resolve?domain=stork_support"))
        // KS-20: plain http can be rewritten on the way; tg: only opens a chat, never a log-in,
        // a proxy or a socks setting (Telegram asks once and then trusts it)
        XCTAssertNil(link("http://example.com/help"))
        XCTAssertNil(link("tg://login?token=abc"))
        XCTAssertNil(link("tg://proxy?server=203.0.113.1&port=443&secret=00"))
        XCTAssertNil(link("tg://socks?server=203.0.113.1&port=1080"))
        XCTAssertNil(link("tg://resolve?domain=stork_support&start=x&phone=1"))
        XCTAssertNil(link("tg:resolve?domain=stork_support"))
        XCTAssertEqual(link("mailto:help@example.com"), URL(string: "mailto:help@example.com"))
        XCTAssertNil(link("javascript:alert(1)"))
        XCTAssertNil(link("file:///etc/passwd"))
        XCTAssertNil(link("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))
        XCTAssertNil(link("killswitch://disconnect"))
        XCTAssertNil(link("https://"))
        XCTAssertNil(link("not a link"))
        XCTAssertEqual(ProviderInfo(headers: ["announce-url": "https://example.com/news"]).announcementURL,
                       URL(string: "https://example.com/news"))
        XCTAssertNil(ProviderInfo(headers: ["announce-url": "ftp://example.com/news"]).announcementURL)
    }

    func testSupportEmail() {
        let info = ProviderInfo(headers: ["support-email": " help@example.com "])
        XCTAssertEqual(info.supportEmail, "help@example.com")
        XCTAssertEqual(info.supportMail, URL(string: "mailto:help@example.com"))
        XCTAssertNil(ProviderInfo(headers: ["support-email": "help@example.com?bcc=x@y.z"]).supportEmail)
        XCTAssertNil(ProviderInfo(headers: ["support-email": "not an address"]).supportEmail)
        XCTAssertNil(ProviderInfo(headers: [:]).supportMail)
    }

    func testHideURL() {
        for value in ["1", "true", "TRUE", " yes ", " True "] {
            XCTAssertTrue(ProviderInfo(headers: ["hide-url": value]).hidesURL, value)
        }
        for value in ["0", "false", "", "maybe", "no"] {
            XCTAssertFalse(ProviderInfo(headers: ["hide-url": value]).hidesURL, value)
        }
        XCTAssertFalse(ProviderInfo(headers: [:]).hidesURL)
    }

    func testAnnouncementShownOncePerText() {
        let info = ProviderInfo(headers: ["announce": "Работы ночью"])
        XCTAssertEqual(info.announcementToShow(dismissed: nil), "Работы ночью")
        XCTAssertNil(info.announcementToShow(dismissed: "Работы ночью"))
        let next = ProviderInfo(headers: ["announce": "Работы закончены"])
        XCTAssertEqual(next.announcementToShow(dismissed: "Работы ночью"), "Работы закончены")
        XCTAssertNil(ProviderInfo(headers: [:]).announcementToShow(dismissed: nil))
    }

    func testSavedAndRestored() throws {
        let info = ProviderInfo(headers: ["announce": "Работы", "support-url": "https://t.me/x", "hide-url": "1"])
        XCTAssertEqual(try JSONDecoder().decode(ProviderInfo.self, from: JSONEncoder().encode(info)), info)
    }
}
