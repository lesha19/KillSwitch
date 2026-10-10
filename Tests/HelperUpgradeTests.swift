import XCTest

/// ADR 0012: after an app update the daemon puts the bundled helper in place without a password,
/// but never an older one over a newer one, and only once the daemon itself is the new one.
final class HelperUpgradeTests: XCTestCase {
    private func helper(_ version: String?, _ body: String = "echo") -> Data {
        Data(((version.map { "#!/bin/bash -p\nKS_VERSION=\"\($0)\"\n" } ?? "#!/bin/bash -p\n") + body + "\n").utf8)
    }

    func testDecisions() {
        XCTAssertEqual(HelperUpgrade.decide(installed: nil, bundled: helper("0.14")), .notInstalled)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.14"), bundled: helper("0.14")), .current)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.13"), bundled: nil), .current)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.13"), bundled: helper("0.14")), .upgrade)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.9.1"), bundled: helper("0.14")), .upgrade)
        // helpers before 0.9.1 have no version: any versioned one is newer
        XCTAssertEqual(HelperUpgrade.decide(installed: helper(nil), bundled: helper("0.14")), .upgrade)
        // a rebuilt helper of the same version (a fix between builds) goes in
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.14", "a"), bundled: helper("0.14", "b")), .upgrade)
        // an old app (downgraded by hand, or a planted older signed copy) never replaces a newer helper
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.14"), bundled: helper("0.13")), .downgrade)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.14"), bundled: helper("0.13.9")), .downgrade)
        XCTAssertEqual(HelperUpgrade.decide(installed: helper("0.14"), bundled: helper(nil)), .downgrade)
    }

    /// The same order as install.sh's version_lt (Helper/tests/upgrade.sh).
    func testVersionOrder() {
        XCTAssertTrue(HelperUpgrade.isOlder("0.13", than: "0.14"))
        XCTAssertTrue(HelperUpgrade.isOlder("0.9.1", than: "0.13"))
        XCTAssertTrue(HelperUpgrade.isOlder("0.13", than: "0.13.1"))
        XCTAssertFalse(HelperUpgrade.isOlder("0.14", than: "0.14"))
        XCTAssertFalse(HelperUpgrade.isOlder("0.14", than: "0.13"))
        XCTAssertFalse(HelperUpgrade.isOlder("1.0", than: "0.99"))
        XCTAssertFalse(HelperUpgrade.isOlder("0.14.0", than: "0.14"))
    }

    /// A daemon from before the update still runs until it has been idle for two minutes; it has no
    /// `upgrade`, so the app waits for the new one (its CFBundleVersion is the app's build).
    func testDaemonMustBeTheAppsBuild() {
        XCTAssertTrue(HelperUpgrade.daemonIsCurrent(daemonBuild: "16", appBuild: "16"))
        XCTAssertTrue(HelperUpgrade.daemonIsCurrent(daemonBuild: "17", appBuild: "16"))
        XCTAssertFalse(HelperUpgrade.daemonIsCurrent(daemonBuild: "15", appBuild: "16"))
        XCTAssertFalse(HelperUpgrade.daemonIsCurrent(daemonBuild: "", appBuild: "16"))
        XCTAssertFalse(HelperUpgrade.daemonIsCurrent(daemonBuild: "x", appBuild: "16"))
    }

    /// What install.sh --upgrade prints decides the notice.
    func testCoreRestartIsReadFromTheOutput() {
        XCTAssertEqual(HelperUpgrade.outcome("watchdog: new helper\ncore: kept\nkill switch: on"), .seamless)
        XCTAssertEqual(HelperUpgrade.outcome("core: restarted\nkill switch: on"), .coreRestarted)
        XCTAssertEqual(HelperUpgrade.outcome("helper: current"), .seamless)
    }

    func testNotice() {
        XCTAssertEqual(UserNotice.updateInstalled(coreRestarted: false).title, "Обновление установлено")
        XCTAssertEqual(UserNotice.updateInstalled(coreRestarted: false).body, "VPN не прерывался.")
        XCTAssertTrue(UserNotice.updateInstalled(coreRestarted: true).body.contains("защита не отключалась"))
        XCTAssertNil(UserNotice.updateInstalled(coreRestarted: false).setting)
        XCTAssertNil(UserNotice.updateInstalled(coreRestarted: false).action)
    }

    /// The daemon command: install.sh --upgrade from the verified bundle, no authorization (it only
    /// ever installs code signed like the daemon itself), not a sudoers command.
    func testUpgradeCommand() {
        XCTAssertEqual(HelperCommand.upgrade.program, .upgrade)
        XCTAssertEqual(HelperCommand.upgrade.arguments, ["--upgrade"])
        XCTAssertFalse(HelperCommand.upgrade.needsAuthorization)
        XCTAssertTrue(HelperCommand.upgrade.isValid)
        // the app never builds it as argv: neither the sudo nor the AppleScript path can run it
        XCTAssertNil(HelperCommand(command: AdminScript.bundled("/A.app/Contents/Resources/Helper/install.sh", ["--upgrade"]),
                                   helper: "/Library/KillSwitch/ks"))
        XCTAssertNil(HelperCommand(ks: ["--upgrade"]))
    }

    /// The bundled install.sh knows --upgrade (its behaviour: Helper/tests/upgrade.sh).
    func testBundledInstallKnowsUpgrade() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let install = try String(contentsOf: repo.appendingPathComponent("Helper/install.sh"), encoding: .utf8)
        XCTAssertTrue(install.contains("\"${1:-}\" = --upgrade"))
    }
}
