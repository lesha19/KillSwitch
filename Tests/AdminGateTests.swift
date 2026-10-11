import XCTest

/// Nothing may ask for an administrator's password without a direct user action: every prompt
/// (osascript's, or macOS's dialog for the daemon's right) passes AdminGate, which refuses requests
/// that are not user-initiated. Launch, refresh and timer code may not even ask.
final class AdminGateTests: XCTestCase {
    func testOnlyUserActionsMayPrompt() {
        XCTAssertTrue(AdminGate.allows(.init(reason: "ks off", userInitiated: true)))
        XCTAssertFalse(AdminGate.allows(.init(reason: "ks on (resume after reconnect)", userInitiated: false)))
    }

    func testPermitAnswersLikeAllows() {
        XCTAssertTrue(AdminGate.permit(.init(reason: "test", userInitiated: true)))
        XCTAssertFalse(AdminGate.permit(.init(reason: "test", userInitiated: false)))
    }

    /// The log names the commands, not their values.
    func testReasonLeavesValuesOut() {
        XCTAssertEqual(AdminGate.reason([["/Library/KillSwitch/ks", "allow", "10.0.0.1"], ["/Library/KillSwitch/ks", "set", "lan", "0"]]),
                       "ks allow; ks set")
        XCTAssertEqual(AdminGate.reason([["/Library/KillSwitch/ks", "core", "import", "/tmp/p.json"]]), "ks core import")
        XCTAssertEqual(AdminGate.reason([AdminScript.bundled("/A.app/Contents/Resources/Helper/install.sh", ["alex"])]), "install.sh")
    }

    // MARK: static checks of the app's sources

    private let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")

    private func source(_ file: String) throws -> String {
        try String(contentsOf: app.appending(path: file), encoding: .utf8)
    }

    /// The body of `func name(` (or `init(`), braces matched; nil when not found.
    private func body(of name: String, in text: String) -> String? {
        let heads = name == "init" ? ["\n    init(", "\n    override init("] : ["func \(name)("]
        guard let start = heads.lazy.compactMap({ text.range(of: $0) }).first, let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Calls that end in a password prompt (or are user actions that may).
    private let promptingCalls = [
        "interactive: true", "userInitiated: true", "runAsAdmin(", "adminRun(", "runBundled(", "AdminScript.",
        "authorization.obtain", "turnOn(", "turnOff(", "pause(minutes", "coreOn()", "restartCore(", "install()", "setUp(",
        "coreImport(", "select(group", "runDelay(", "testDelay(", "testAllDelays(", "selectBest(", "setSwitches(",
        "setExceptions(", "setSplitApps(", "setMultihop(", "setManualServers(", "uninstall(", "restoreNetwork(",
        "prepareHelper(", "confirmNewServers(", "setCore(", "switchCore(", "applySettings(",
    ]

    private func assertNoPrompt(_ code: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for call in promptingCalls {
            XCTAssertFalse(code.contains(call), "\(label) can reach an admin prompt through \(call)", file: file, line: line)
        }
        // `set("lan", …)` of the control, not `defaults.set(`
        XCTAssertNil(code.firstMatch(of: /(^|[^.\w])set\("/), "\(label) changes a setting (admin prompt)", file: file, line: line)
    }

    /// What runs at launch, on refresh (timer, file watcher) and from the daemon state: never a prompt.
    func testLaunchAndRefreshPathsCannotPrompt() throws {
        let text = try source("KillSwitchControl.swift")
        let automatic = [
            "init", "refresh", "registerHelperAtLaunch", "updateHelperAvailability", "notifyIfMacOSUpdated", "listenForWidget",
            "scheduleTimer", "watchHelperDirectory", "helperDirectoryChanged", "compareHelper", "upgradeHelper", "trackConnecting",
            "resumeIfReconnected", "publish", "syncFilter", "readSettings", "checkDaemon", "daemonRuns", "loadProxies",
            "checkFailover", "checkNetwork", "readOtherVPN", "readOtherTunnels", "syncSpeed", "readSpeed",
            "applyPendingChoice", "coreOnAutomatically", "coreRefresh", "readHelper",
        ]
        for name in automatic {
            let code = try XCTUnwrap(body(of: name, in: text), "KillSwitchControl.\(name) not found")
            assertNoPrompt(code, "KillSwitchControl.\(name)")
        }
    }

    /// The other things that start with the app: auto-connect, the subscription timer, the filter.
    func testOtherLaunchCodeCannotPrompt() throws {
        assertNoPrompt(try source("AutoConnector.swift"), "AutoConnector")
        assertNoPrompt(try XCTUnwrap(body(of: "init", in: try source("Updater.swift"))), "Updater.init")
        let filter = try source("FilterControl.swift")
        assertNoPrompt(try XCTUnwrap(body(of: "init", in: filter)), "FilterControl.init")
        assertNoPrompt(try XCTUnwrap(body(of: "checkForUpdate", in: filter)), "FilterControl.checkForUpdate")
        assertNoPrompt(try XCTUnwrap(body(of: "sync", in: filter)), "FilterControl.sync")
        let client = try source("VPNClient.swift")
        for name in ["init", "updateIfDue"] {
            assertNoPrompt(try XCTUnwrap(body(of: name, in: client)), "VPNClient.\(name)")
        }
        let app = try source("KillSwitchApp.swift")
        assertNoPrompt(try XCTUnwrap(body(of: "init", in: app)), "KillSwitchApp.init")
    }

    /// The two ways to a prompt each go through the gate, and nothing else calls them.
    func testEveryPromptPassesTheGate() throws {
        var osascript: [String] = []
        var rights: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path(percentEncoded: false)) where file.hasSuffix(".swift") {
            let text = try source(file)
            if text.contains("AdminScript.run(") || text.contains("AdminScript.execute(") { osascript.append(file) }
            if text.contains("authorization.obtain(") { rights.append(file) }
        }
        XCTAssertEqual(osascript, ["KillSwitchControl.swift"])
        XCTAssertEqual(rights, ["HelperClient.swift"])

        let control = try source("KillSwitchControl.swift")
        XCTAssertEqual(control.components(separatedBy: "AdminScript.run(").count, 2, "one osascript call site")
        let adminRun = try XCTUnwrap(body(of: "adminRun", in: control))
        XCTAssertTrue(adminRun.contains("AdminScript.run("))
        XCTAssertLessThan(try XCTUnwrap(adminRun.range(of: "AdminGate.permit(")).lowerBound,
                          try XCTUnwrap(adminRun.range(of: "AdminScript.run(")).lowerBound, "the gate comes first")

        let client = try source("HelperClient.swift")
        let send = try XCTUnwrap(body(of: "send", in: client))
        XCTAssertLessThan(try XCTUnwrap(send.range(of: "AdminGate.permit(")).lowerBound,
                          try XCTUnwrap(send.range(of: "authorization.obtain(")).lowerBound, "the gate comes first")
    }
}
