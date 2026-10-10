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
}
