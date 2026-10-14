import Foundation
import XCTest

final class ServerChoiceTests: XCTestCase {
    /// The first click adds the server to «Недавние» and the rows below move: the second click of a
    /// double-click lands on the neighbour and must not switch again.
    func testTheSecondClickOfADoubleClickIsIgnored() {
        var choice = ServerChoice(interval: 0.5)
        XCTAssertTrue(choice.accept(at: 1000))
        XCTAssertFalse(choice.accept(at: 1000.3))
        XCTAssertFalse(choice.accept(at: 1000.5))
    }

    func testAClickAfterTheIntervalChooses() {
        var choice = ServerChoice(interval: 0.5)
        XCTAssertTrue(choice.accept(at: 1000))
        XCTAssertTrue(choice.accept(at: 1000.6))
        // an ignored click does not extend the window: a triple-click chooses once, a later click again
        XCTAssertFalse(choice.accept(at: 1000.9))
        XCTAssertTrue(choice.accept(at: 1001.2))
    }

    /// A time before the last choice (a clock that went back) never swallows the clicks after it.
    func testAnEarlierTimeChooses() {
        var choice = ServerChoice(interval: 0.5)
        XCTAssertTrue(choice.accept(at: 1000))
        XCTAssertTrue(choice.accept(at: 10))
        XCTAssertFalse(choice.accept(at: 10.2))
    }
}
