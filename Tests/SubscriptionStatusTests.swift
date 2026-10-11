import Foundation
import XCTest

/// The saved subscription status: an interval saved before it was clamped (a provider's
/// `profile-update-interval: 1e300`) once made Settings › Подписка trap every time it opened.
final class SubscriptionStatusTests: XCTestCase {
    func testSavedStatusWithAHugeIntervalIsClamped() throws {
        for (saved, expected) in [("3.6e303", 30.0 * 24 * 3600), ("-1", 12.0 * 3600), ("0", 12.0 * 3600), ("21600", 21600.0)] {
            let json = Data(#"{"serverInterval": \#(saved)}"#.utf8)
            let status = try JSONDecoder().decode(SubscriptionStatus.self, from: json)
            XCTAssertEqual(status.serverInterval, expected, saved)
            XCTAssertEqual(status.serverIntervalHours, Int(expected / 3600), saved)
        }
        let old = try JSONDecoder().decode(SubscriptionStatus.self, from: Data("{}".utf8))
        XCTAssertEqual(old.serverInterval, 12 * 3600)
    }

    func testStatusRoundTrips() throws {
        let status = SubscriptionStatus(title: "Stork", serverInterval: 6 * 3600, lastUpdate: Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(try JSONDecoder().decode(SubscriptionStatus.self, from: JSONEncoder().encode(status)), status)
    }

    func testHoursOfAnUnclampedIntervalDoNotTrap() {
        var status = SubscriptionStatus()
        status.serverInterval = .infinity
        XCTAssertEqual(status.serverIntervalHours, 12)
        status.serverInterval = 3.6e303
        XCTAssertEqual(status.serverIntervalHours, 720)
    }
}
