import XCTest

final class TrafficSpeedTests: XCTestCase {
    func testParsesTheHelpersLine() {
        XCTAssertEqual(TrafficSpeed.Totals("up=7890 down=123456"), TrafficSpeed.Totals(up: 7890, down: 123_456))
        XCTAssertEqual(TrafficSpeed.Totals("up=0 down=0\n"), TrafficSpeed.Totals(up: 0, down: 0))
        XCTAssertNil(TrafficSpeed.Totals(""))
        XCTAssertNil(TrafficSpeed.Totals("up=x down=1"))
        XCTAssertNil(TrafficSpeed.Totals("Ядро не запущено"))
    }

    func testSpeedComesFromTwoReadings() {
        var meter = TrafficSpeed()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(meter.add(.init(up: 1000, down: 5000), at: start), "one reading is no speed yet")
        let speed = meter.add(.init(up: 3000, down: 2_005_000), at: start + 2)
        XCTAssertEqual(speed, TrafficSpeed.Speed(up: 1000, down: 1_000_000))
    }

    /// The core restarted: its totals start from zero again.
    func testACounterResetIsNoNegativeSpeed() {
        var meter = TrafficSpeed()
        let start = Date(timeIntervalSince1970: 1000)
        _ = meter.add(.init(up: 9000, down: 9000), at: start)
        XCTAssertNil(meter.add(.init(up: 10, down: 20), at: start + 1))
        XCTAssertEqual(meter.add(.init(up: 110, down: 1044), at: start + 2), TrafficSpeed.Speed(up: 100, down: 1024))
    }

    func testTheSameMomentIsNoSpeed() {
        var meter = TrafficSpeed()
        let start = Date(timeIntervalSince1970: 1000)
        _ = meter.add(.init(up: 0, down: 0), at: start)
        XCTAssertNil(meter.add(.init(up: 10, down: 10), at: start))
    }

    func testFormat() {
        XCTAssertEqual(TrafficSpeed.format(0), "0 КБ/с")
        XCTAssertEqual(TrafficSpeed.format(300), "0 КБ/с")
        XCTAssertEqual(TrafficSpeed.format(64 * 1024), "64 КБ/с")
        XCTAssertEqual(TrafficSpeed.format(1.25 * 1024 * 1024), "1,2 МБ/с")
        XCTAssertEqual(TrafficSpeed.format(12.6 * 1024 * 1024), "13 МБ/с")
        XCTAssertEqual(TrafficSpeed.label(.init(up: 64 * 1024, down: 1.25 * 1024 * 1024)), "↓ 1,2 МБ/с ↑ 64 КБ/с")
    }
}
