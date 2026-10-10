import XCTest

final class ExpiringCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testKeepsAValueForItsLifetime() {
        var cache = ExpiringCache<String, Int>(lifetime: 10, capacity: 4)
        XCTAssertNil(cache.value(for: "a", now: t0))
        cache.set(1, for: "a", now: t0)
        XCTAssertEqual(cache.value(for: "a", now: t0.addingTimeInterval(9.9)), .some(1))
        XCTAssertNil(cache.value(for: "a", now: t0.addingTimeInterval(10)), "expired: asked again")
    }

    /// "Not trusted" is a result too: a program that failed the check is not checked on every flow.
    func testCachesNil() {
        var cache = ExpiringCache<String, Int?>(lifetime: 10, capacity: 4)
        cache.set(nil, for: "x", now: t0)
        XCTAssertEqual(cache.value(for: "x", now: t0), .some(.none))
    }

    func testCapacityBoundsMemory() {
        var cache = ExpiringCache<Int, Int>(lifetime: 10, capacity: 3)
        for key in 0..<10 { cache.set(key, for: key, now: t0) }
        XCTAssertLessThanOrEqual(cache.count, 3)
        XCTAssertEqual(cache.value(for: 9, now: t0), .some(9), "the newest stays")
    }
}
