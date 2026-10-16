import XCTest
@testable import KillSwitch

/// The helper still reads "x-ks-routing" (the routing profiles of ADR 0034, removed from the app by
/// #73): a subscription's own is taken out of every profile and config before the helper sees it.
final class RoutingHintTests: XCTestCase {
    private let theirs: [String: Any] = ["name": "Мой выбор", "direct": ["sites": ["domain:example.com"]]]

    func testXrayConfigsLoseIt() throws {
        let panel = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": [], "x-ks-routing": theirs],
                                                                ["remarks": "B", "outbounds": []]])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingHint.strippingXray(panel)) as? [[String: Any]])
        XCTAssertEqual(out.map { $0["remarks"] as? String }, ["A", "B"])
        XCTAssertTrue(out.allSatisfy { $0["x-ks-routing"] == nil })
        let plain = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": []]])
        XCTAssertEqual(RoutingHint.strippingXray(plain), plain, "none there: the panel's bytes as they are")
        XCTAssertEqual(RoutingHint.strippingXray(Data("{}".utf8)), Data("{}".utf8), "not an array: left alone")
    }

    func testXrayProviderSwitchMarkIsStripped() throws {
        let panel = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": [], "x-ks-switch": true]])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingHint.strippingXray(panel)) as? [[String: Any]])
        XCTAssertEqual(out.map { $0["remarks"] as? String }, ["A"])
        XCTAssertNil(out[0]["x-ks-switch"])
    }

    func testMihomoProfileLosesIt() {
        let profile: Profile = ["proxies": [], "rules": ["MATCH,DIRECT"], "x-ks-routing": theirs]
        let out = RoutingHint.stripping(profile)
        XCTAssertNil(out["x-ks-routing"])
        XCTAssertEqual(out["rules"] as? [String], ["MATCH,DIRECT"])
    }
}
