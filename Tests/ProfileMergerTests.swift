import Foundation
import XCTest

final class ProfileMergerTests: XCTestCase {
    private let manual: [[String: Any]] = [
        ["name": "Мой", "type": "trojan", "server": "1.1.1.1", "port": 443, "password": "x"],
    ]

    func testManualOnly() throws {
        let profile = try XCTUnwrap(ProfileMerger.merge(subscription: nil, manual: manual))
        XCTAssertEqual((profile["proxies"] as? [[String: Any]])?.count, 1)
        let groups = try XCTUnwrap(profile["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["name"] as? String, ProfileMerger.defaultGroup)
        XCTAssertEqual(groups[0]["proxies"] as? [String], ["Мой"])
        XCTAssertEqual(profile["rules"] as? [String], ["MATCH,\(ProfileMerger.defaultGroup)"])
    }

    func testNothing() {
        XCTAssertNil(ProfileMerger.merge(subscription: nil, manual: []))
    }

    func testSubscriptionUntouchedWithoutManual() throws {
        let sub: [String: Any] = ["proxies": [["name": "A"]], "proxy-groups": [["name": "G", "type": "select", "proxies": ["A"]]], "rules": ["MATCH,G"]]
        let merged = try XCTUnwrap(ProfileMerger.merge(subscription: sub, manual: []))
        XCTAssertEqual((merged["proxy-groups"] as? [[String: Any]])?.count, 1)
    }

    func testManualJoinsFirstSelectGroupAndRenamesClashes() throws {
        let sub: [String: Any] = [
            "proxies": [["name": "Мой"], ["name": "B"]],
            "proxy-groups": [
                ["name": "Auto", "type": "url-test", "proxies": ["Мой", "B"]],
                ["name": "G", "type": "select", "proxies": ["Auto", "Мой", "B"]],
            ],
            "rules": ["MATCH,G"],
        ]
        let merged = try XCTUnwrap(ProfileMerger.merge(subscription: sub, manual: manual))
        let names = (merged["proxies"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["Мой", "B", "Мой (2)"])
        let groups = try XCTUnwrap(merged["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups[1]["proxies"] as? [String], ["Auto", "Мой", "B", ProfileMerger.manualGroup])
        XCTAssertEqual(groups.last?["name"] as? String, ProfileMerger.manualGroup)
        XCTAssertEqual(groups.last?["proxies"] as? [String], ["Мой (2)"])
        XCTAssertEqual(groups[0]["proxies"] as? [String], ["Мой", "B"])
    }
}
