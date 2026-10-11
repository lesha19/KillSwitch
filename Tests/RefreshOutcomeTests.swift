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

    /// KS-12: ks refuses a refresh with exit 3 for new servers and for a change of what goes past
    /// the VPN (DIRECT rules, DNS); the second must reach the admin as what it is.
    func testRoutingChangeIsNotNewServers() {
        let output = "Профиль меняет, что идёт мимо VPN (DIRECT): нужно подтверждение паролем администратора\n"
        XCTAssertEqual(RefreshOutcome(status: 3, output: output), .routingChanged(.subscription))
        XCTAssertEqual(RefreshOutcome(status: 3, output: ""), .newServers)
    }

    /// The words the app tells the two apart by are ks's own (refresh_check).
    func testKsWordsTheTwoRefusalsApart() throws {
        let ks = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helper/ks"), encoding: .utf8)
        let start = try XCTUnwrap(ks.range(of: "\nrefresh_check() {"))
        let end = try XCTUnwrap(ks.range(of: "\n}\n", range: start.upperBound..<ks.endIndex))
        let check = ks[start.lowerBound..<end.lowerBound]
        let refusals = check.split(separator: "\n").filter { $0.contains("echo \"") && $0.contains(">&2") }
        XCTAssertEqual(refusals.count, 2)
        XCTAssertFalse(refusals[0].contains(RefreshOutcome.routingMarker), String(refusals[0]))
        XCTAssertTrue(refusals[1].contains(RefreshOutcome.routingMarker), String(refusals[1]))
    }

    func testRoutingChangeNotices() {
        XCTAssertEqual(UserNotice.routingChanged.action, .approve)
        XCTAssertEqual(UserNotice.routingChanged.setting, .subscription)
        XCTAssertTrue(UserNotice.routingChanged.title.contains("напрямую"))
        XCTAssertNotEqual(UserNotice.routingChanged.key, UserNotice.newServers.key)
        var input = HomeNotice.Input(otherVPN: false, usage: nil, newServers: true, filterIncomplete: false, filterDismissed: false, now: Date())
        XCTAssertEqual(HomeNotice.pick(input), .newServers)
        input.routingChanged = true
        XCTAssertEqual(HomeNotice.pick(input), .routingChanged)
        XCTAssertTrue(HomeNotice.routingChanged.title.contains("напрямую"))
        XCTAssertFalse(HomeNotice.routingChanged.title.contains("серверы"))
    }
}
