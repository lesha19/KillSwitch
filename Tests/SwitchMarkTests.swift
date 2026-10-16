import XCTest
@testable import KillSwitch

/// A provider's own "x-ks-switch" never reaches the helper: only the app marks a switching import (#74).
final class SwitchMarkTests: XCTestCase {
    func testXrayProviderSwitchMarkIsStripped() throws {
        let panel = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": [], "x-ks-switch": true],
                                                                ["remarks": "B", "outbounds": []]])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: SwitchMark.strippingXray(panel)) as? [[String: Any]])
        XCTAssertEqual(out.map { $0["remarks"] as? String }, ["A", "B"])
        XCTAssertTrue(out.allSatisfy { $0["x-ks-switch"] == nil })
        let plain = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": []]])
        XCTAssertEqual(SwitchMark.strippingXray(plain), plain, "none there: the panel's bytes as they are")
        XCTAssertEqual(SwitchMark.strippingXray(Data("{}".utf8)), Data("{}".utf8), "not an array: left alone")
    }
}
