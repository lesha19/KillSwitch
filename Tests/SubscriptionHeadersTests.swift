import Foundation
import XCTest

final class SubscriptionHeadersTests: XCTestCase {
    func testUserinfo() throws {
        let info = try XCTUnwrap(SubscriptionUsage(header: "upload=1024; download=2048;total=10737418240; expire=1767225600"))
        XCTAssertEqual(info.upload, 1024)
        XCTAssertEqual(info.download, 2048)
        XCTAssertEqual(info.used, 3072)
        XCTAssertEqual(info.total, 10_737_418_240)
        XCTAssertEqual(info.expire, Date(timeIntervalSince1970: 1_767_225_600))
    }

    func testUserinfoUnlimited() throws {
        let info = try XCTUnwrap(SubscriptionUsage(header: "upload=0; download=5; total=0; expire=0"))
        XCTAssertNil(info.total)
        XCTAssertNil(info.expire)
    }

    func testUserinfoGarbage() {
        XCTAssertNil(SubscriptionUsage(header: "hello"))
        XCTAssertNil(SubscriptionUsage(header: nil))
    }

    func testUpdateInterval() {
        XCTAssertEqual(SubscriptionHeaders.updateInterval("6"), 6 * 3600)
        XCTAssertEqual(SubscriptionHeaders.updateInterval(" 24 "), 24 * 3600)
        XCTAssertEqual(SubscriptionHeaders.updateInterval(nil), 12 * 3600)
        XCTAssertEqual(SubscriptionHeaders.updateInterval("0"), 12 * 3600)
        XCTAssertEqual(SubscriptionHeaders.updateInterval("x"), 12 * 3600)
    }

    func testTitle() {
        XCTAssertEqual(SubscriptionHeaders.title("StorkVPN"), "StorkVPN")
        let encoded = "base64:" + Data("Сторк VPN".utf8).base64EncodedString()
        XCTAssertEqual(SubscriptionHeaders.title(encoded), "Сторк VPN")
        XCTAssertNil(SubscriptionHeaders.title("  "))
        XCTAssertNil(SubscriptionHeaders.title(nil))
    }

    func testMaskedURL() {
        XCTAssertEqual(SubscriptionHeaders.masked("https://sub.example.com/AbCdEf123456"), "https://sub.example.com/•••••3456")
        XCTAssertEqual(SubscriptionHeaders.masked("https://sub.example.com/ab"), "https://sub.example.com/•••••")
    }

    func testRequestHeaders() {
        let headers = SubscriptionHeaders.request(appVersion: "0.7", hwid: "0123456789abcdef0123456789abcdef", osVersion: "15.6", model: "MacBookPro18,2")
        XCTAssertEqual(headers["x-hwid"], "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(headers["x-device-os"], "macOS")
        XCTAssertEqual(headers["x-ver-os"], "15.6")
        // recognisable in the panel's device list
        XCTAssertEqual(headers["x-device-model"], "MacBookPro18,2 KillSwitch")
        // Remnawave's Mihomo rule is anchored: the UA must START with mihomo to get YAML;
        // StorkVPN's Caddy passes anything containing it
        XCTAssertEqual(headers["User-Agent"], "mihomo/1.19.32 (KillSwitch/0.7; macOS 15.6)")
        // text/html would match Remnawave's browser rule and return a web page
        XCTAssertFalse(headers["Accept"]?.contains("html") ?? false)
    }

    func testHWIDFormat() {
        // Remnawave ignores an x-hwid outside ^[A-Za-z0-9=-]{10,64}$
        XCTAssertTrue(SubscriptionHeaders.isValidHWID("0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(SubscriptionHeaders.isValidHWID("short"))
        XCTAssertFalse(SubscriptionHeaders.isValidHWID("has_underscore_123"))
        XCTAssertFalse(SubscriptionHeaders.isValidHWID("aa:bb:cc:dd:ee:ff"))
    }

    func testHWIDProblems() {
        XCTAssertNil(SubscriptionHeaders.hwidProblem(headers: ["x-hwid-active": "true"]))
        XCTAssertNil(SubscriptionHeaders.hwidProblem(headers: [:]))
    }
}
