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

    /// KS-13: every value the app later reads (used, Int(expire), Double ratios) must not trap.
    private func assertSane(_ usage: SubscriptionUsage?, _ header: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let usage else { return }
        let limit = Int64(1) << 53
        XCTAssert((0...limit).contains(usage.upload) && (0...limit).contains(usage.download), header, file: file, line: line)
        XCTAssert(usage.used >= 0, header, file: file, line: line)
        if let total = usage.total { XCTAssert((1...limit).contains(total), header, file: file, line: line) }
        if let expire = usage.expire {
            let seconds = expire.timeIntervalSince1970
            XCTAssert(seconds.isFinite && seconds > 0 && seconds <= 253_402_300_799, header, file: file, line: line)
            _ = Int(seconds)
        }
        _ = Double(usage.used) / Double(usage.total ?? 1)
    }

    func testUserinfoReproducedCrashes() {
        let forms = [
            "upload=1e30", "upload=nan", "download=NaN", "upload=inf", "upload=-inf", "total=infinity",
            "download=1e308", "upload=9223372036854775807; download=1", "upload=9223372036854775807; download=9223372036854775807",
            "upload=-5; download=-9223372036854775808", "expire=9223372036854775807", "expire=1e300", "expire=-1e300",
            "expire=nan", "total=-1", "upload=18446744073709551616", "upload=0x10", "upload=; download=", "=;=;",
            "upload==1", "UPLOAD=1", "upload=١٢٣", "expire=253402300800", "upload=1.5e3; download=2.5",
        ]
        for header in forms { assertSane(SubscriptionUsage(header: header), header) }
        let big = SubscriptionUsage(header: "upload=9223372036854775807; download=1")
        XCTAssertEqual(big?.upload, Int64(1) << 53)
        XCTAssertNil(SubscriptionUsage(header: "upload=nan"))
    }

    func testUserinfoFuzz() {
        var seed: UInt64 = 0x5EED
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let alphabet = Array("0123456789.e+-naifxNI=; ")
        let keys = ["upload=", "download=", "total=", "expire="]
        for _ in 0..<5000 {
            var header = ""
            for _ in 0..<(next() % 4 + 1) {
                header += keys[next() % keys.count]
                header += String((0..<(next() % 24)).map { _ in alphabet[next() % alphabet.count] }) + ";"
            }
            assertSane(SubscriptionUsage(header: header), header)
        }
    }

    /// The bad value was saved with the status and crashed every launch: a saved one is clamped too.
    func testSavedUsageIsClamped() throws {
        let json = #"{"upload":9223372036854775807,"download":1,"total":-4,"expire":1e30}"#
        let usage = try JSONDecoder().decode(SubscriptionUsage.self, from: Data(json.utf8))
        assertSane(usage, json)
        XCTAssertNil(usage.total)
        let back = try JSONDecoder().decode(SubscriptionUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(back, usage)
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
