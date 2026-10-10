import Foundation
import XCTest

final class CoreDelayTests: XCTestCase {
    func testGroupAnswer() throws {
        let result = try CoreDelay.parse(Data(#"{"🇩🇪 DE": 120, "🇳🇱 NL": 0, "Auto": 95}"#.utf8),
                                         members: ["🇩🇪 DE", "🇳🇱 NL", "🇫🇮 FI", "Auto"])
        XCTAssertEqual(result["🇩🇪 DE"], 120)
        XCTAssertEqual(result["Auto"], 95)
        XCTAssertEqual(result["🇳🇱 NL"], CoreDelay.timeout)     // 0 = failed
        XCTAssertEqual(result["🇫🇮 FI"], CoreDelay.timeout)     // missing = failed
        XCTAssertEqual(result.count, 4)
    }

    func testSingleProxyAnswer() throws {
        XCTAssertEqual(try CoreDelay.parse(Data(#"{"delay": 88}"#.utf8), members: ["DE"]), ["DE": 88])
    }

    func testErrorAnswer() {
        XCTAssertThrowsError(try CoreDelay.parse(Data(#"{"message": "get delay: all proxies timeout"}"#.utf8), members: ["DE"]))
        XCTAssertThrowsError(try CoreDelay.parse(Data("junk".utf8), members: ["DE"]))
    }

    func testSortByLatency() {
        let delays = ["A": 300, "B": 50, "C": CoreDelay.timeout, "E": 50]
        // measured fastest first (stable for ties), timeouts after, untested last
        XCTAssertEqual(CoreDelay.sorted(["D", "C", "A", "B", "E"], delays: delays), ["B", "E", "A", "C", "D"])
    }

    func testBest() {
        XCTAssertEqual(CoreDelay.best(of: ["A", "B", "C"], delays: ["A": 300, "B": 50, "C": CoreDelay.timeout]), "B")
        XCTAssertNil(CoreDelay.best(of: ["A", "C"], delays: ["C": CoreDelay.timeout]))
    }
}
