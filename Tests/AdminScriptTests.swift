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

    /// The root shell must not inherit the app's environment: any process of the user can set it
    /// for apps it starts (launchctl setenv), and BASH_ENV would run before install.sh as root.
    @MainActor
    func testRootShellGetsNoneOfTheAppsEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran").path
        let hook = dir.appendingPathComponent("hook.sh")
        try "touch '\(marker)'\n".write(to: hook, atomically: true, encoding: .utf8)
        setenv("BASH_ENV", hook.path, 1)
        setenv("KS_TEST_LEAK", "leaked", 1)
        defer { unsetenv("BASH_ENV"); unsetenv("KS_TEST_LEAK") }
        let script = "do shell script quoted form of \"/bin/bash\" & \" -c \" & quoted form of \"echo ${KS_TEST_LEAK:-none} $PATH\""
        let result = await AdminScript.execute(script)
        XCTAssertEqual(result, .ok("none \(AdminScript.environment["PATH"] ?? "")"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "BASH_ENV ran")
        XCTAssertEqual(AdminScript.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// Bundled scripts run as root through "bash -p": no BASH_ENV, ENV or exported functions.
    func testBundledScriptsRunPrivileged() {
        XCTAssertEqual(AdminScript.bundled("/App/Helper/uninstall.sh", []), ["/bin/bash", "-p", "/App/Helper/uninstall.sh"])
        XCTAssertEqual(AdminScript.bundled("/App/Helper/install.sh", ["alex"]), ["/bin/bash", "-p", "/App/Helper/install.sh", "alex"])
    }

    // MARK: the verified copy behind the password prompt (#37)

    /// Behind the password prompt a bundled script runs from a copy in a root-only folder that
    /// root checks first, like the daemon's verified copy (ADR 0012): nothing can be swapped in the
    /// bundle between the check and the run. Everything else is left as it is.
    func testBundledScriptsAreStaged() {
        let app = "/Applications/KillSwitch.app"
        XCTAssertEqual(AdminScript.staged(["/bin/bash", "-p", app + "/Contents/Resources/Helper/install.sh", "alex", "10.0.0.1"]),
                       ["/bin/bash", "-p", "-c", AdminScript.stagingScript, "killswitch-staged", app, HelperIdentity.appRequirement,
                        "install.sh", "alex", "10.0.0.1"])
        XCTAssertEqual(AdminScript.staged(["/bin/bash", "-p", app + "/Contents/Resources/Helper/uninstall.sh"]),
                       ["/bin/bash", "-p", "-c", AdminScript.stagingScript, "killswitch-staged", app, HelperIdentity.appRequirement,
                        "uninstall.sh"])
        XCTAssertEqual(AdminScript.staged(["/Library/KillSwitch/ks", "core", "import", "/tmp/p.json"]),
                       ["/Library/KillSwitch/ks", "core", "import", "/tmp/p.json"])
        // a script in any other shape would run in place, unverified: refused instead
        for command in [["/bin/bash", "-p", "/elsewhere/install.sh", "alex"],
                        ["/bin/bash", "-p", app + "/Contents/Resources/Helper/fetch-xray.sh"],
                        ["/bin/bash", app + "/Contents/Resources/Helper/install.sh", "alex"],
                        ["/bin/bash", "-p", "Rel.app/Contents/Resources/Helper/install.sh"],
                        ["/bin/bash"]] {
            XCTAssertEqual(AdminScript.staged(command), AdminScript.refusal, "\(command)")
        }
        let refused = Process()
        refused.executableURL = URL(fileURLWithPath: AdminScript.refusal[0])
        refused.arguments = Array(AdminScript.refusal.dropFirst())
        refused.standardError = FileHandle.nullDevice
        XCTAssertNoThrow(try refused.run())
        refused.waitUntilExit()
        XCTAssertEqual(refused.terminationStatus, 64)
        // what osascript gets: every command staged, every argument quoted
        let source = AdminScript.source([AdminScript.bundled(app + "/Contents/Resources/Helper/install.sh", ["alex"]),
                                         ["/Library/KillSwitch/ks", "core", "on"]].map { AdminScript.staged($0) })
        XCTAssertTrue(source.contains("quoted form of \"-c\""))
        XCTAssertTrue(source.contains("quoted form of \"/Library/KillSwitch/ks\""))
    }

    func testStagedScriptRunsTheVerifiedCopyOnly() throws {
        let fixture = try SignedBundle()
        defer { fixture.remove() }
        let command = AdminScript.staged(AdminScript.bundled(fixture.script("install.sh"), ["alex", "10.0.0.1"]),
                                         requirement: fixture.requirement)
        var run = try fixture.run(command)
        XCTAssertEqual(run.status, 0, run.stderr)
        let ranFrom = run.stdout.components(separatedBy: " ").first ?? ""
        XCTAssertTrue(ranFrom.hasSuffix("/KillSwitch.app/Contents/Resources/Helper/install.sh"), run.stdout)
        XCTAssertFalse(ranFrom.hasPrefix(fixture.app.path), "ran from the bundle itself: \(run.stdout)")
        XCTAssertTrue(run.stdout.hasSuffix(" alex 10.0.0.1"), run.stdout)
        let staging = URL(fileURLWithPath: ranFrom).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the copy is left behind: \(staging.path)")

        // another signer's app, and an unknown script, never run
        run = try fixture.run(AdminScript.staged(AdminScript.bundled(fixture.script("install.sh"), []),
                                                 requirement: #"identifier "com.example.other""#))
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(run.stderr.contains("повреждена"), run.stderr)
        var odd = command
        odd[7] = "../../../../bin/echo"
        run = try fixture.run(odd)
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")

        // a script changed after signing: the copy fails the check, nothing runs
        try "#!/bin/bash\necho ran swapped\n".write(to: URL(fileURLWithPath: fixture.script("install.sh")), atomically: false, encoding: .utf8)
        run = try fixture.run(command)
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertTrue(run.stderr.contains("повреждена"), run.stderr)
    }

    /// The bundle given as a link is copied as the folder it points at, so what is checked is
    /// the copy, never the link's current target.
    func testStagedScriptCopiesThroughALink() throws {
        let fixture = try SignedBundle()
        defer { fixture.remove() }
        let link = fixture.dir.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)
        let command = AdminScript.staged(["/bin/bash", "-p", link.path + "/Contents/Resources/Helper/uninstall.sh"],
                                         requirement: fixture.requirement)
        let run = try fixture.run(command)
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(run.stdout.hasPrefix(link.path))
        XCTAssertTrue(run.stdout.contains("/KillSwitch.app/Contents/Resources/Helper/uninstall.sh"), run.stdout)
    }
}

/// A tiny ad-hoc signed app with Helper/install.sh and uninstall.sh that print where they ran.
private struct SignedBundle {
    let dir: URL
    let app: URL
    let requirement = #"identifier "com.example.kstest""#

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)")
        app = dir.appendingPathComponent("Test.app")
        let fm = FileManager.default
        let helper = app.appendingPathComponent("Contents/Resources/Helper")
        try fm.createDirectory(at: helper, withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Test").path)
        let info: [String: Any] = ["CFBundleExecutable": "Test", "CFBundleIdentifier": "com.example.kstest"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        for name in ["install.sh", "uninstall.sh"] {
            try "#!/bin/bash\necho \"$0 $*\"; echo ran >&2\n".write(to: helper.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", "--identifier", "com.example.kstest", app.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func script(_ name: String) -> String { app.appendingPathComponent("Contents/Resources/Helper/\(name)").path }

    func run(_ command: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = AdminScript.environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: stderr, as: UTF8.self))
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}
