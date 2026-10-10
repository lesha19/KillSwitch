import XCTest

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let day: TimeInterval = 86_400

    func testFirstUpdateIsDue() {
        XCTAssertTrue(UpdateSchedule().isDue(interval: day, now: now))
    }

    func testAppliedWaitsTheFullInterval() {
        var schedule = UpdateSchedule()
        schedule.record(.applied, now: now)
        XCTAssertEqual(schedule.lastUpdate, now)
        XCTAssertNil(schedule.retryAt)
        XCTAssertFalse(schedule.isDue(interval: day, now: now.addingTimeInterval(day - 1)))
        XCTAssertTrue(schedule.isDue(interval: day, now: now.addingTimeInterval(day)))
    }

    /// Fetched, but the helper refused it (needs a password, new servers, a failure): the last good
    /// update stays what it was, and the next try comes in an hour, not after the full interval.
    func testNotAppliedRetriesInAnHour() {
        var schedule = UpdateSchedule()
        schedule.record(.applied, now: now)
        let later = now.addingTimeInterval(day)
        schedule.record(.notApplied, now: later)
        XCTAssertEqual(schedule.lastUpdate, now, "lastUpdate only moves when the profile reached the core")
        XCTAssertEqual(schedule.retryAt, later.addingTimeInterval(3600))
        XCTAssertFalse(schedule.isDue(interval: day, now: later.addingTimeInterval(3599)))
        XCTAssertTrue(schedule.isDue(interval: day, now: later.addingTimeInterval(3600)))
    }

    func testFetchFailures() {
        var schedule = UpdateSchedule()
        schedule.record(.fetchFailed(offline: true), now: now)
        XCTAssertEqual(schedule.retryAt, now.addingTimeInterval(540), "offline: the next 10-minute tick")
        schedule.record(.fetchFailed(offline: false), now: now)
        XCTAssertEqual(schedule.retryAt, now.addingTimeInterval(3600))
        XCTAssertNil(schedule.lastUpdate)
    }

    func testSuccessClearsTheRetry() {
        var schedule = UpdateSchedule()
        schedule.record(.notApplied, now: now)
        schedule.record(.applied, now: now.addingTimeInterval(3600))
        XCTAssertNil(schedule.retryAt)
        XCTAssertEqual(schedule.lastUpdate, now.addingTimeInterval(3600))
    }
}
