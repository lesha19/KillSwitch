import XCTest

/// #11: the subscription is asked from its own link first, then through the VPN (the core's
/// loopback listener, Helper/ks FETCH_PORT). The backup link is gone (ADR 0036).
final class SubscriptionSourceTests: XCTestCase {
    func testOrder() {
        XCTAssertEqual(SubscriptionSource.order(vpnRunning: false), [.primary])
        XCTAssertEqual(SubscriptionSource.order(vpnRunning: true), [.primary, .primaryViaVPN])
    }

    func testWhatEachUses() {
        XCTAssertFalse(SubscriptionSource.primary.viaVPN)
        XCTAssertTrue(SubscriptionSource.primaryViaVPN.viaVPN)
    }

    func testPlainWords() {
        XCTAssertEqual(SubscriptionSource.primary.label, "основная ссылка")
        XCTAssertEqual(SubscriptionSource.primaryViaVPN.label, "основная ссылка через VPN")
    }

    func testProxyIsTheCoresListener() throws {
        let proxy = SubscriptionSource.proxy
        XCTAssertEqual(proxy["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, SubscriptionSource.proxyPort)
        XCTAssertEqual(proxy["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(proxy["HTTPProxy"] as? String, "127.0.0.1")
        let ks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helper/ks")
        let text = try String(contentsOf: ks, encoding: .utf8)
        XCTAssertTrue(text.contains("\nFETCH_PORT=\(SubscriptionSource.proxyPort) "), "the port Helper/ks gives the core")
    }

    /// Saved with the status; a status from before #11 has none.
    func testStatusKeepsTheSource() throws {
        let old = try JSONDecoder().decode(SubscriptionSource?.self, from: Data("null".utf8))
        XCTAssertNil(old)
        let data = try JSONEncoder().encode(SubscriptionSource.primaryViaVPN)
        XCTAssertEqual(try JSONDecoder().decode(SubscriptionSource.self, from: data), .primaryViaVPN)
    }
}
