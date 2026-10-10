import XCTest

/// Any process can post the widget's Darwin notifications: only turning protection on, which
/// needs no password and only tightens, runs directly.
final class WidgetCommandTests: XCTestCase {
    func testOnlyTurningOnRunsWithoutTheApp() {
        XCTAssertFalse(Shared.Command.on.needsConfirmation)
        XCTAssertTrue(Shared.Command.off.needsConfirmation)
        XCTAssertTrue(Shared.Command.pause5.needsConfirmation)
    }

    func testNotificationNamesAreStable() {
        XCTAssertEqual(Shared.Command.off.notificationName, "local.lesha.killswitch.off")
        XCTAssertEqual(Shared.Command(notificationName: "local.lesha.killswitch.pause5"), .pause5)
        XCTAssertNil(Shared.Command(notificationName: "local.lesha.killswitch.rm"))
    }
}
