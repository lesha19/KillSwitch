import XCTest

/// «Сеть выключена»: the boot window guard's mark (ADR 0037). On 15.10.2026 the watchdog ran and the
/// network stayed off, and the banner said nothing because it waited for the watchdog to stop.
final class NetworkMarkTests: XCTestCase {
    func testNoMarkNoBanner() {
        XCTAssertFalse(NetworkMark.leftOff(age: nil, daemonRuns: false))
        XCTAssertFalse(NetworkMark.leftOff(age: nil, daemonRuns: true))
    }

    func testWatchdogGoneShowsAtOnce() {
        XCTAssertTrue(NetworkMark.leftOff(age: 0, daemonRuns: false))
    }

    func testWatchdogRunningGetsTwentySeconds() {
        XCTAssertFalse(NetworkMark.leftOff(age: 5, daemonRuns: true), "the watchdog is turning it back on")
        XCTAssertFalse(NetworkMark.leftOff(age: 20, daemonRuns: true))
        XCTAssertTrue(NetworkMark.leftOff(age: 21, daemonRuns: true), "it did not manage: the incident")
    }

    func testClockSteppedBack() {
        XCTAssertFalse(NetworkMark.leftOff(age: -300, daemonRuns: true))
    }

    /// The age counts from when this boot's mark was first seen (ks: $NET_SEEN), not from the
    /// mark's own time, which is the shutdown's: an overnight mark is not 20 s old at login, and a
    /// watchdog restarting does not make it young again.
    func testAgeFromTheFirstSeenTimeOfThisBoot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seen: String?, id: String? = "UUID-A", mtime: Double = 0, boot: Double = 900_000) -> TimeInterval? {
            NetworkMark.age(markExists: true, seen: seen, bootId: id, markModified: Date(timeIntervalSince1970: mtime),
                            bootDate: Date(timeIntervalSince1970: boot), now: now)
        }
        XCTAssertNil(NetworkMark.age(markExists: false, seen: "UUID-A 999990\n", bootId: "UUID-A", markModified: nil,
                                     bootDate: nil, now: now))
        XCTAssertEqual(age("UUID-A 999970\n"), 30)
        XCTAssertEqual(age("UUID-A 0999970"), 30, "a leading zero is not octal")
    }

    /// The daemon stuck before net_guard never writes the first-seen file: the age then counts from
    /// the later of the mark's own time (the shutdown's) and the boot, so the banner still shows.
    func testWithoutAFirstSeenTimeTheAgeCountsFromBootOrTheMark() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seen: String?, id: String? = "UUID-A", mtime: Double, boot: Double) -> TimeInterval? {
            NetworkMark.age(markExists: true, seen: seen, bootId: id, markModified: Date(timeIntervalSince1970: mtime),
                            bootDate: Date(timeIntervalSince1970: boot), now: now)
        }
        XCTAssertEqual(age(nil, mtime: 100, boot: 999_900), 100, "overnight mark: age since boot")
        XCTAssertEqual(age("garbage", mtime: 100, boot: 999_900), 100)
        XCTAssertEqual(age("499 900000", mtime: 100, boot: 999_900), 100, "old numeric id: another boot")
        XCTAssertEqual(age("UUID-B 999990", mtime: 100, boot: 999_900), 100, "another boot's time")
        XCTAssertEqual(age(nil, mtime: 999_950, boot: 999_900), 50, "a mark written in this boot: since the mark")
        XCTAssertEqual(age(nil, mtime: 100, boot: 1_000_100), 0, "clamped, never negative")
        XCTAssertEqual(age("UUID-A 999970", id: nil, mtime: 100, boot: 999_900), 100, "no boot id: the fallback")
        XCTAssertEqual(NetworkMark.age(markExists: true, seen: nil, bootId: nil, markModified: nil, bootDate: nil, now: now), 0,
                       "nothing known: 0, as before")
    }

    /// With the watchdog's state file live the app refreshes every 30 s: the banner must not wait
    /// for that once the 20 s are up.
    func testLooksAgainWhenTheTwentySecondsAreUp() throws {
        XCTAssertEqual(try XCTUnwrap(NetworkMark.recheck(age: 5, daemonRuns: true)), 16, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(NetworkMark.recheck(age: 0, daemonRuns: true)), 21, accuracy: 0.01)
        XCTAssertNil(NetworkMark.recheck(age: 25, daemonRuns: true), "already shown")
        XCTAssertNil(NetworkMark.recheck(age: 5, daemonRuns: false), "already shown")
        XCTAssertNil(NetworkMark.recheck(age: nil, daemonRuns: true), "no mark")
    }

    func testBootDateIsKernBoottime() throws {
        let boot = try XCTUnwrap(NetworkMark.bootDate())
        XCTAssertLessThanOrEqual(boot, Date())
        XCTAssertGreaterThan(boot.timeIntervalSince1970, 1_500_000_000)
    }

    func testBootIdIsTheSessionUUID() throws {
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(NetworkMark.bootId())))
    }
}
