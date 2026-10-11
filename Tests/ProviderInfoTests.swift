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
        XCTAssertEqual(link(" http://example.com/help "), URL(string: "http://example.com/help"))
        XCTAssertEqual(link("tg://resolve?domain=stork_support"), URL(string: "tg://resolve?domain=stork_support"))
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
