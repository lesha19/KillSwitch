import XCTest

/// ADR 0010: the daemon runs only these commands, with values Helper/ks would take, and asks for
/// the authorization right exactly where the password prompt was asked before.
final class HelperCommandTests: XCTestCase {
    private let ks = "/Library/KillSwitch/ks"

    // MARK: mapping to Helper/ks

    func testEveryCommandMapsToTheKsArgumentsItReplaces() {
        let cases: [(HelperCommand, [String])] = [
            (.state, ["state"]), (.probe, ["probe"]), (.protectionOn, ["on"]), (.netRestore, ["netrestore"]),
            (.coreState, ["core", "state"]), (.coreOn, ["core", "on"]), (.coreOff, ["core", "off"]),
            (.coreProxies, ["core", "proxies"]), (.coreTraffic, ["core", "traffic"]), (.coreConnections, ["core", "connections"]),
            (.coreSelect(group: "🇩🇪 Germany", proxy: "de-1"), ["core", "select", "🇩🇪 Germany", "de-1"]),
            (.coreDelay("Auto"), ["core", "delay", "Auto"]),
            (.coreRefresh(profile: "/private/tmp/p.json"), ["core", "refresh", "/private/tmp/p.json"]),
            (.protectionOff, ["off"]), (.pause(minutes: 5), ["pause", "5"]),
            (.setSwitch("lan", true), ["set", "lan", "1"]), (.setSwitch("wifiguard", false), ["set", "wifiguard", "0"]),
            (.setSwitch("adblock", true), ["set", "adblock", "1"]),
            (.setSplitApps(["/Applications/Telegram.app", "zoom.us"]),
             ["set", "splitapps", "/Applications/Telegram.app,zoom.us"]),
            (.setSplitApps([]), ["set", "splitapps", ""]),
            (.setMultihop("🇩🇪 de-1"), ["set", "multihop", "🇩🇪 de-1"]), (.setMultihop(nil), ["set", "multihop", "off"]),
            (.allow("10.0.0.0/8"), ["allow", "10.0.0.0/8"]), (.unallow("10.0.0.0/8"), ["unallow", "10.0.0.0/8"]),
            (.serverAdd("2001:db8::1"), ["server-add", "2001:db8::1"]),
            (.serverRemove("192.0.2.1"), ["server-remove", "192.0.2.1"]),
            (.coreImport(profile: "/private/tmp/p.json"), ["core", "import", "/private/tmp/p.json"]),
            (.repair, ["repair"]),
        ]
        for (command, arguments) in cases {
            XCTAssertEqual(command.program, .ks, "\(command)")
            XCTAssertEqual(command.arguments, arguments, "\(command)")
            XCTAssertTrue(command.isValid, "\(command)")
            // the app still builds argv (Batch, Onboarding): it parses back to the same command
            XCTAssertEqual(HelperCommand(command: [ks] + arguments, helper: ks), command, "\(command)")
        }
    }

    func testInstallAndUninstallRunTheBundledScripts() {
        let install = HelperCommand.install(user: "alex", servers: ["192.0.2.1", "2001:db8::1"])
        XCTAssertEqual(install.program, .install)
        XCTAssertEqual(install.arguments, ["alex", "192.0.2.1", "2001:db8::1"])
        XCTAssertEqual(HelperCommand.uninstall.program, .uninstall)
        XCTAssertEqual(HelperCommand.uninstall.arguments, [])
        XCTAssertEqual(HelperCommand(command: AdminScript.bundled("/Applications/KillSwitch.app/Contents/Resources/Helper/install.sh",
                                                                  ["alex", "192.0.2.1"]), helper: ks),
                       .install(user: "alex", servers: ["192.0.2.1"]))
        XCTAssertEqual(HelperCommand(command: AdminScript.bundled("/A.app/Contents/Resources/Helper/uninstall.sh", []), helper: ks),
                       .uninstall)
        // 0.12.1: only the `bash -p` form the app builds
        XCTAssertNil(HelperCommand(command: ["/bin/bash", "/A.app/Contents/Resources/Helper/uninstall.sh"], helper: ks))
    }

    /// 0.12.1 for the daemon too: root runs the scripts with `bash -p` (no BASH_ENV, ENV, SHELLOPTS or
    /// exported functions) and every program with the system tools' PATH and nothing else.
    func testDaemonRunsWithTheSanitizedEnvironment() {
        XCTAssertEqual(HelperCommand.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(HelperCommand.environment, AdminScript.environment)
        XCTAssertEqual(HelperCommand.scriptArguments("/x/Helper/install.sh", ["alex"]), ["-p", "/x/Helper/install.sh", "alex"])
        XCTAssertEqual(["/bin/bash"] + HelperCommand.scriptArguments("/p", ["a"]), AdminScript.bundled("/p", ["a"]))
    }

    /// The wizard's one-password chain becomes three daemon commands, one authorization.
    func testOnboardingChainParses() {
        let commands = Onboarding.commands(installScript: "/A.app/Contents/Resources/Helper/install.sh", user: "alex",
                                           servers: ["192.0.2.1"], helper: ks, profile: "/tmp/p.json")
        XCTAssertEqual(commands.map { HelperCommand(command: $0, helper: ks) },
                       [.install(user: "alex", servers: ["192.0.2.1"]), .coreImport(profile: "/tmp/p.json"), .coreOn])
    }

    func testBatchCommandsParse() {
        let commands = Batch.list(helper: ks, add: "allow", remove: "unallow", old: ["192.0.2.1"], new: ["198.51.100.0/24"])
            + Batch.settings(helper: ks, old: ["lan": true], new: ["lan": false])
        XCTAssertEqual(commands.map { HelperCommand(command: $0, helper: ks) },
                       [.unallow("192.0.2.1"), .allow("198.51.100.0/24"), .setSwitch("lan", false)])
    }

    func testAnythingElseDoesNotParse() {
        let refused: [[String]] = [
            [], [ks], ["/bin/sh", "-c", "id"], ["/bin/bash", "/tmp/evil.sh"], ["/bin/bash", "/tmp/install.sh.sh"],
            ["/usr/local/bin/ks", "off"], [ks, "status"], [ks, "watch"], [ks, "apply"], [ks, "_rotate"], [ks, "_dns", "apply"],
            [ks, "version"], [ks, "off", "now"], [ks, "pause"], [ks, "pause", "-1"], [ks, "pause", "10000"],
            [ks, "set", "lan", "yes"], [ks, "set", "evil", "1"], [ks, "set", "lan"], [ks, "allow", "example.com"],
            [ks, "allow", "1.2.3.4; rm -rf /"], [ks, "server-add", "-f"], [ks, "core"], [ks, "core", "import"],
            [ks, "core", "import", "relative.json"], [ks, "core", "select", "only-group"], [ks, "core", "traffic", "x"], [ks, "core", "delay", ""],
            [ks, "core", "select", "g", "a\nb"], [ks, "set", "multihop", ""], [ks, "set", "splitapps", "a,,b"],
            [ks, "set", "splitapps", "/tmp/../evil.app"],
        ]
        for command in refused {
            XCTAssertNil(HelperCommand(command: command, helper: ks), "\(command)")
        }
    }

    // MARK: what needs the authorization right

    /// Exactly what Helper/install.sh's sudoers line allows goes without the right; everything
    /// else asked for the admin password before and asks for the right now.
    func testPasswordlessCommandsAreTheSudoersOnes() throws {
        let installScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helper/install.sh")
        let text = try String(contentsOf: installScript, encoding: .utf8)
        // sudoers_text: "$ks state, $ks probe, … $ks core refresh *"
        let sudoers = Set(text.matches(of: /\$ks ([a-z -]+?)( \*)?[,"]/).map { String($0.1) })
        XCTAssertFalse(sudoers.isEmpty)
        let all: [HelperCommand] = [
            .state, .probe, .protectionOn, .netRestore, .coreState, .coreOn, .coreOff, .coreProxies, .coreTraffic, .coreConnections,
            .coreSelect(group: "g", proxy: "p"), .coreDelay("g"), .coreRefresh(profile: "/tmp/p.json"),
            .protectionOff, .pause(minutes: 5), .setSwitch("lan", true), .setSwitch("adblock", true), .setSplitApps([]),
            .setMultihop(nil),
            .allow("192.0.2.1"), .unallow("192.0.2.1"), .serverAdd("192.0.2.1"), .serverRemove("192.0.2.1"),
            .coreImport(profile: "/tmp/p.json"), .install(user: "alex", servers: []), .uninstall, .repair,
        ]
        for command in all {
            let words = command.program == .ks ? command.arguments.prefix(command.arguments.first == "core" ? 2 : 1)
                .joined(separator: " ") : "-"
            XCTAssertEqual(command.needsAuthorization, !sudoers.contains(words), "\(command)")
        }
        let passwordless = Set(all.filter { !$0.needsAuthorization }
            .map { $0.arguments.prefix($0.arguments.first == "core" ? 2 : 1).joined(separator: " ") })
        XCTAssertEqual(passwordless, sudoers)
        // ADR 0012: the one daemon command without the right that is not a sudoers one. It runs only
        // the verified bundle's install.sh --upgrade, never older than what is installed; sudo and
        // the AppleScript prompt cannot run it at all (HelperUpgradeTests).
        XCTAssertFalse(HelperCommand.upgrade.needsAuthorization)
        XCTAssertNotEqual(HelperCommand.upgrade.program, .ks)
    }

    // MARK: validation (Helper/ks is the authority; the daemon checks before it runs anything)

    func testAddressesAsKsTakesThem() {
        for good in ["192.0.2.1", "10.0.0.0/8", "2001:db8::1", "2001:db8::/32", "::1"] {
            XCTAssertTrue(HelperCommand.allow(good).isValid, good)
            XCTAssertTrue(HelperCommand.serverAdd(good).isValid, good)
        }
        for bad in ["", "example.com", "1.2.3", "1.2.3.4.5", "1.2.3.4/", "-1.2.3.4", "1.2.3.4 ", " 1.2.3.4", "1.2.3.4\n",
                    "1.2.3.4/8/8", String(repeating: "1", count: 80)] {
            XCTAssertFalse(HelperCommand.allow(bad).isValid, bad)
            XCTAssertFalse(HelperCommand.serverAdd(bad).isValid, bad)
            XCTAssertFalse(HelperCommand.install(user: "alex", servers: [bad]).isValid, bad)
        }
    }

    /// An entry an older version let in can still be removed; nothing that is not an address shape.
    func testRemovalTakesAnyListedShape() {
        XCTAssertTrue(HelperCommand.unallow("1.2.3").isValid)
        XCTAssertTrue(HelperCommand.serverRemove("abcd").isValid)
        XCTAssertFalse(HelperCommand.unallow("").isValid)
        XCTAssertFalse(HelperCommand.serverRemove("host.example").isValid)
        XCTAssertFalse(HelperCommand.serverRemove("1.2.3.4\nevil").isValid)
    }

    func testPauseMinutes() {
        XCTAssertTrue(HelperCommand.pause(minutes: 0).isValid)
        XCTAssertTrue(HelperCommand.pause(minutes: 9999).isValid)
        XCTAssertFalse(HelperCommand.pause(minutes: -1).isValid)
        XCTAssertFalse(HelperCommand.pause(minutes: 10000).isValid)
    }

    func testSwitchKeys() {
        for key in ["lan", "tailscale", "dns", "direct", "wifiguard", "adblock"] {
            XCTAssertTrue(HelperCommand.setSwitch(key, true).isValid, key)
        }
        // «Российские сайты напрямую» is gone (ADR 0013): ks refuses it, so the daemon does too
        for key in ["", "coredirect", "splitapps", "multihop", "LAN", "lan ", "x"] {
            XCTAssertFalse(HelperCommand.setSwitch(key, true).isValid, key)
        }
    }

    func testNamesOfServersAndGroups() {
        XCTAssertTrue(HelperCommand.coreSelect(group: "🇩🇪 Германия", proxy: String(repeating: "a", count: 256)).isValid)
        XCTAssertFalse(HelperCommand.coreSelect(group: "g", proxy: String(repeating: "a", count: 257)).isValid)
        XCTAssertFalse(HelperCommand.coreSelect(group: "", proxy: "p").isValid)
        XCTAssertFalse(HelperCommand.coreDelay("a\u{7}b").isValid)
        XCTAssertFalse(HelperCommand.setMultihop("").isValid)
        XCTAssertFalse(HelperCommand.setMultihop("off").isValid)   // would mean «выключен»
        XCTAssertFalse(HelperCommand.setMultihop("a\tb").isValid)
    }

    /// Mirrors Helper/ks splitapps_parse and SplitApps.isValid.
    func testSplitApps() {
        let good = ["/Applications/Telegram.app", "/Users/a/Applications/My App.app", "zoom.us", "Discord"]
        XCTAssertTrue(HelperCommand.setSplitApps(good).isValid)
        for name in good { XCTAssertTrue(SplitApps.isValid(name), name) }
        for bad in ["", "a,b", "/Applications/Telegram", "/Applications/../evil.app", "/Applications//x.app", "dir/name",
                    String(repeating: "n", count: 65), "/" + String(repeating: "a", count: 255) + ".app", "a\nb", " lead"] {
            XCTAssertFalse(HelperCommand.setSplitApps([bad]).isValid, bad)
        }
        XCTAssertTrue(HelperCommand.setSplitApps((1...50).map { "app\($0)" }).isValid)
        XCTAssertFalse(HelperCommand.setSplitApps((1...51).map { "app\($0)" }).isValid)
        XCTAssertFalse(HelperCommand.setSplitApps(["a", "a"]).isValid)
    }

    func testProfilePathsAreAbsolute() {
        XCTAssertTrue(HelperCommand.coreImport(profile: "/private/var/tmp/x.json").isValid)
        XCTAssertFalse(HelperCommand.coreImport(profile: "x.json").isValid)
        XCTAssertFalse(HelperCommand.coreRefresh(profile: "").isValid)
        XCTAssertFalse(HelperCommand.coreRefresh(profile: "/tmp/a\nb").isValid)
    }

    func testInstallUser() {
        XCTAssertTrue(HelperCommand.install(user: "alexey.zhuravel", servers: []).isValid)
        XCTAssertTrue(HelperCommand.install(user: "_svc", servers: []).isValid)
        // as install.sh's valid_user takes it into sudoers (Helper/tests/args.sh)
        for bad in ["", "-alex", "a b", "a/b", "root\n", String(repeating: "a", count: 256), "ALL", "0day", "%admin", "#0",
                    String(repeating: "a", count: 33)] {
            XCTAssertFalse(HelperCommand.install(user: bad, servers: []).isValid, bad)
        }
        XCTAssertFalse(HelperCommand.install(user: "alex", servers: Array(repeating: "192.0.2.1", count: 513)).isValid)
    }

    /// 0.14.2: the daemon could not make its verified copy of the app and answered failedToRun to
    /// «Восстановить службу…». Nothing ran: the bundled script goes to the password prompt instead
    /// of a dead end. Other answers (a failed script, a refused value, no right) stay as they are.
    func testBundledScriptsFallBackToThePasswordWhenTheDaemonCouldNotRunThem() {
        let couldNotRun = HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Служба KillSwitch не нашла свою программу")
        XCTAssertTrue(HelperCommand.install(user: "alex", servers: []).fallsBackToPassword(couldNotRun))
        XCTAssertTrue(HelperCommand.uninstall.fallsBackToPassword(couldNotRun))
        XCTAssertTrue(HelperCommand.upgrade.fallsBackToPassword(couldNotRun))
        XCTAssertFalse(HelperCommand.state.fallsBackToPassword(couldNotRun))       // ks itself is missing: repair, not a retry
        XCTAssertFalse(HelperCommand.protectionOff.fallsBackToPassword(couldNotRun))
        for status in [0, 1, 2, HelperReply.refused, HelperReply.notAuthorized] {
            XCTAssertFalse(HelperCommand.uninstall.fallsBackToPassword(HelperReply(status: status, stdout: "", stderr: "")), "\(status)")
        }
    }
}
