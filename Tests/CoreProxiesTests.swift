import Foundation
import XCTest

final class CoreProxiesTests: XCTestCase {
    private let json = """
    {"proxies": {
      "GLOBAL": {"type": "Selector", "now": "PROXY", "all": ["PROXY", "DIRECT"], "history": []},
      "PROXY": {"type": "Selector", "now": "🇩🇪 Германия", "all": ["Auto", "🇩🇪 Германия", "🇳🇱 NL"], "history": []},
      "Auto": {"type": "URLTest", "now": "🇳🇱 NL", "all": ["🇩🇪 Германия", "🇳🇱 NL"], "history": [{"time": "x", "delay": 80}]},
      "🇩🇪 Германия": {"type": "Vless", "history": [{"time": "a", "delay": 120}, {"time": "b", "delay": 95}]},
      "🇳🇱 NL": {"type": "Trojan", "history": [{"time": "a", "delay": 0}]},
      "DIRECT": {"type": "Direct", "history": []}
    }}
    """

    func testGroupsAndDelays() throws {
        let state = try CoreProxies(data: Data(json.utf8))
        XCTAssertEqual(state.groups.map(\.name), ["PROXY", "Auto"])   // GLOBAL hidden, profile order unknown → selectors first
        let proxy = try XCTUnwrap(state.groups.first)
        XCTAssertTrue(proxy.selectable)
        XCTAssertEqual(proxy.now, "🇩🇪 Германия")
        XCTAssertFalse(state.groups[1].selectable)
        XCTAssertEqual(state.delay("🇩🇪 Германия"), 95)
        XCTAssertNil(state.delay("🇳🇱 NL"))          // 0 = timed out
        XCTAssertEqual(state.delay("Auto"), 80)
    }

    func testResolvesCurrentLeaf() throws {
        let state = try CoreProxies(data: Data(json.utf8))
        XCTAssertEqual(state.leaf(of: "PROXY"), "🇩🇪 Германия")
        XCTAssertEqual(state.leaf(of: "GLOBAL"), "🇩🇪 Германия")
        XCTAssertEqual(state.mainGroup?.name, "PROXY")
    }

    func testOrderHint() throws {
        let state = try CoreProxies(data: Data(json.utf8), order: ["Auto", "PROXY"])
        XCTAssertEqual(state.groups.map(\.name), ["Auto", "PROXY"])
    }

    func testBadJSON() {
        XCTAssertThrowsError(try CoreProxies(data: Data("nope".utf8)))
    }
}

final class ServerNameTests: XCTestCase {
    func testFlagFromEmoji() {
        let name = ServerName("🇩🇪 Германия, Франкфурт")
        XCTAssertEqual(name.flag, "🇩🇪")
        XCTAssertEqual(name.title, "Германия, Франкфурт")
    }

    func testFlagFromCountryWord() {
        XCTAssertEqual(ServerName("Нидерланды 2").flag, "🇳🇱")
        XCTAssertEqual(ServerName("NL-Amsterdam").flag, "🇳🇱")
        XCTAssertEqual(ServerName("Germany").flag, "🇩🇪")
    }

    func testNoFlag() {
        let name = ServerName("Auto")
        XCTAssertNil(name.flag)
        XCTAssertEqual(name.title, "Auto")
    }
}
