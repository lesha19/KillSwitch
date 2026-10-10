import XCTest

final class RefreshOutcomeTests: XCTestCase {
    func testRefreshApplied() {
        XCTAssertEqual(RefreshOutcome(status: 0, output: ""), .applied)
    }

    func testRefreshWithNewServersNeedsConfirmation() {
        let output = "В профиле новые адреса серверов (203.0.113.7): нужен пароль администратора"
        XCTAssertEqual(RefreshOutcome(status: 3, output: output), .newServers)
    }

    func testRefreshNotAllowedBySudoersNeedsPassword() {
        XCTAssertEqual(RefreshOutcome(status: 1, output: "sudo: a password is required\n"), .needsPassword)
    }

    func testRefreshFailure() {
        XCTAssertEqual(RefreshOutcome(status: 1, output: "pf не принял адреса серверов\n"), .failed("pf не принял адреса серверов"))
        XCTAssertEqual(RefreshOutcome(status: 1, output: ""), .failed("Не получилось"))
    }
}
