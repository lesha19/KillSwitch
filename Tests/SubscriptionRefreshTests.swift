import XCTest

/// #67: each subscription on its own interval, retry and error; deleting the one in use.
final class SubscriptionRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let hour: TimeInterval = 3600

    private func subscription(_ id: String, interval: TimeInterval, updatedAgo: TimeInterval?) -> Subscription {
        var s = Subscription(id: id, host: id)
        s.status.serverInterval = interval
        s.status.lastUpdate = updatedAgo.map { now.addingTimeInterval(-$0) }
        return s
    }

    /// Two subscriptions with their providers' intervals: only the one whose time has come is due.
    func testEachSubscriptionKeepsItsOwnInterval() {
        let list = [subscription("a", interval: 6 * hour, updatedAgo: 7 * hour),
                    subscription("b", interval: 24 * hour, updatedAgo: 7 * hour)]
        XCTAssertEqual(SubscriptionRefresh.due(list, retryAt: [:], appHours: 0, now: now), ["a"])
        XCTAssertEqual(SubscriptionRefresh.due(list, retryAt: [:], appHours: 1, now: now), ["a", "b"], "the person's interval wins")
        XCTAssertEqual(SubscriptionRefresh.due(list, retryAt: [:], appHours: 12, now: now), [])
    }

    /// One failed and waits for its own retry; the other is not held back and is not made due early.
    func testOneFailingDoesNotMoveTheOther() {
        let list = [subscription("a", interval: 6 * hour, updatedAgo: 7 * hour),
                    subscription("b", interval: 6 * hour, updatedAgo: 7 * hour),
                    subscription("c", interval: 6 * hour, updatedAgo: 1 * hour)]
        let retry = ["a": now.addingTimeInterval(hour)]
        XCTAssertEqual(SubscriptionRefresh.due(list, retryAt: retry, appHours: 0, now: now), ["b"])
        XCTAssertEqual(SubscriptionRefresh.due(list, retryAt: retry, appHours: 0, now: now.addingTimeInterval(hour)), ["a", "b"])
    }

    func testNeverFetchedIsDue() {
        XCTAssertEqual(SubscriptionRefresh.due([subscription("a", interval: 24 * hour, updatedAgo: nil)], retryAt: [:], appHours: 0, now: now), ["a"])
    }

    /// Deleting the subscription the helper runs: asks for another server; the others and «Свои серверы» do not.
    func testActiveRemoved() {
        let list = [subscription("b", interval: hour, updatedAgo: nil)]
        XCTAssertTrue(SubscriptionRefresh.activeWasRemoved(active: "a", list: list, coreConfigured: true))
        XCTAssertFalse(SubscriptionRefresh.activeWasRemoved(active: "b", list: list, coreConfigured: true))
        XCTAssertFalse(SubscriptionRefresh.activeWasRemoved(active: ServerID.own, list: list, coreConfigured: true))
        XCTAssertFalse(SubscriptionRefresh.activeWasRemoved(active: "a", list: list, coreConfigured: false), "nothing was handed over")
    }
}
