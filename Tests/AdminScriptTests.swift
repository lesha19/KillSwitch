import XCTest

final class AdminScriptTests: XCTestCase {
    func testOneCommandQuotesEveryArgument() {
        XCTAssertEqual(AdminScript.source([["/Library/KillSwitch/ks", "set", "lan", "0"]]),
                       "do shell script quoted form of \"/Library/KillSwitch/ks\" & \" \" & quoted form of \"set\" & \" \" & quoted form of \"lan\" & \" \" & quoted form of \"0\" with prompt \(AdminScript.literal(AdminScript.prompt)) with administrator privileges")
    }

    func testQuotesAndBackslashesCannotLeaveTheStringLiteral() {
        // a server name from a subscription ends up in `ks set multihop <name>`
        let name = "x\" & do shell script \"touch /tmp/pwned\" & \"\\"
        let source = AdminScript.source([["/Library/KillSwitch/ks", "set", "multihop", name]])
        XCTAssertTrue(source.contains("quoted form of \"x\\\" & do shell script \\\"touch /tmp/pwned\\\" & \\\"\\\\\""))
        XCTAssertTrue(source.hasSuffix("\\\\\" with prompt \(AdminScript.literal(AdminScript.prompt)) with administrator privileges"))
    }

    func testSeveralCommandsRunAsOneAndStopAtTheFirstFailure() {
        let source = AdminScript.source([["/k", "allow", "10.0.0.1"], ["/k", "unallow", "10.0.0.2"]])
        XCTAssertEqual(source,
                       "do shell script quoted form of \"/k\" & \" \" & quoted form of \"allow\" & \" \" & quoted form of \"10.0.0.1\" & \" && \" & quoted form of \"/k\" & \" \" & quoted form of \"unallow\" & \" \" & quoted form of \"10.0.0.2\" with prompt \(AdminScript.literal(AdminScript.prompt)) with administrator privileges")
    }

    /// osascript names itself in the password dialog: the prompt says who asks.
    func testPromptNamesTheApp() {
        XCTAssertTrue(AdminScript.prompt.hasPrefix("KillSwitch"))
    }

    func testOutcomeOfARun() {
        XCTAssertEqual(AdminScript.outcome(status: 0, stdout: "line1\rline2\n", stderr: ""), .ok("line1\nline2"))
        XCTAssertEqual(AdminScript.outcome(status: 1, stdout: "", stderr: "6:22: execution error: User canceled. (-128)\n"),
                       .cancelled)
        XCTAssertEqual(AdminScript.outcome(status: 1, stdout: "", stderr: "0:61: execution error: pf: bad rule (1)\n"),
                       .failed("pf: bad rule"))
        XCTAssertEqual(AdminScript.outcome(status: 1, stdout: "", stderr: "0:9: execution error: line one\rline two (3)\n"),
                       .failed("line one\nline two"))
        XCTAssertEqual(AdminScript.outcome(status: 1, stdout: "", stderr: ""), .failed("Не получилось"))
        XCTAssertEqual(AdminScript.outcome(status: -1, stdout: "", stderr: "launch failed"), .failed("launch failed"))
    }

    /// NSAppleScript may only be used on the main thread, where the prompt would freeze the app:
    /// the script runs in its own osascript process, its text through stdin (not visible in ps).
    @MainActor
    func testRunsInOsascriptWithoutBlocking() async {
        let ok = await AdminScript.execute("do shell script \"printf 'a\\\\nb'\"")
        XCTAssertEqual(ok, .ok("a\nb"))
        let failed = await AdminScript.execute("do shell script \"echo boom >&2; exit 3\"")
        XCTAssertEqual(failed, .failed("boom"))
        let unicode = await AdminScript.execute("do shell script quoted form of \"/bin/echo\" & \" \" & quoted form of \"🇱🇹 Литва\"")
        XCTAssertEqual(unicode, .ok("🇱🇹 Литва"))
    }
}
