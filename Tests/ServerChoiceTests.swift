import Foundation
import XCTest

final class ServerChoiceTests: XCTestCase {
    /// The first click adds the server to «Недавние» and the rows below move: the second click of a
    /// double-click lands on the neighbour and must not switch again.
    func testTheSecondClickOfADoubleClickIsIgnored() {
        var choice = ServerChoice(interval: 0.5)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(choice.accept(at: start))
        XCTAssertFalse(choice.accept(at: start.addingTimeInterval(0.3)))
        XCTAssertFalse(choice.accept(at: start.addingTimeInterval(0.5)))
    }

    func testAClickAfterTheIntervalChooses() {
        var choice = ServerChoice(interval: 0.5)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(choice.accept(at: start))
        XCTAssertTrue(choice.accept(at: start.addingTimeInterval(0.6)))
        // an ignored click does not extend the window: a triple-click chooses once, a later click again
        XCTAssertFalse(choice.accept(at: start.addingTimeInterval(0.9)))
        XCTAssertTrue(choice.accept(at: start.addingTimeInterval(1.2)))
    }
}
