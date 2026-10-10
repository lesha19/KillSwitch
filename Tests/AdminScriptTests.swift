import XCTest

final class AdminScriptTests: XCTestCase {
    func testOneCommandQuotesEveryArgument() {
        XCTAssertEqual(AdminScript.source([["/Library/KillSwitch/ks", "set", "lan", "0"]]),
                       "do shell script quoted form of \"/Library/KillSwitch/ks\" & \" \" & quoted form of \"set\" & \" \" & quoted form of \"lan\" & \" \" & quoted form of \"0\" with administrator privileges")
    }

    func testQuotesAndBackslashesCannotLeaveTheStringLiteral() {
        // a server name from a subscription ends up in `ks set multihop <name>`
        let name = "x\" & do shell script \"touch /tmp/pwned\" & \"\\"
        let source = AdminScript.source([["/Library/KillSwitch/ks", "set", "multihop", name]])
        XCTAssertTrue(source.contains("quoted form of \"x\\\" & do shell script \\\"touch /tmp/pwned\\\" & \\\"\\\\\""))
        XCTAssertTrue(source.hasSuffix("\\\\\" with administrator privileges"))
    }

    func testSeveralCommandsRunAsOneAndStopAtTheFirstFailure() {
        let source = AdminScript.source([["/k", "allow", "10.0.0.1"], ["/k", "unallow", "10.0.0.2"]])
        XCTAssertEqual(source,
                       "do shell script quoted form of \"/k\" & \" \" & quoted form of \"allow\" & \" \" & quoted form of \"10.0.0.1\" & \" && \" & quoted form of \"/k\" & \" \" & quoted form of \"unallow\" & \" \" & quoted form of \"10.0.0.2\" with administrator privileges")
    }

    func testOutcomeOfARun() {
        XCTAssertEqual(AdminScript.outcome(output: "line1\rline2", errorNumber: nil, errorMessage: nil), .ok("line1\nline2"))
        XCTAssertEqual(AdminScript.outcome(output: nil, errorNumber: -128, errorMessage: "User canceled."), .cancelled)
        XCTAssertEqual(AdminScript.outcome(output: nil, errorNumber: 1, errorMessage: "pf: bad rule"), .failed("pf: bad rule"))
        XCTAssertEqual(AdminScript.outcome(output: nil, errorNumber: 1, errorMessage: nil), .failed("Не получилось"))
        XCTAssertEqual(AdminScript.outcome(output: nil, errorNumber: nil, errorMessage: nil), .failed("Не получилось"))
    }

    /// The password prompt and install.sh can take minutes: the main thread must stay free.
    @MainActor
    func testRunsOffTheMainThread() async {
        let ranOnMain = await AdminScript.run(source: "x") { _ in Thread.isMainThread }
        XCTAssertFalse(ranOnMain)
    }
}
