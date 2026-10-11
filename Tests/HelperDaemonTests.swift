import Security
import ServiceManagement
import XCTest

/// ADR 0010: who may talk to the daemon, the right it asks for, and how its answers read.
final class HelperDaemonTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    // MARK: code-signing requirements

    func testRequirementsCompileAndPinTeamAndIdentifier() throws {
        for (text, identifier) in [(HelperIdentity.appRequirement, "com.lesha19.KillSwitch"),
                                   (HelperIdentity.daemonRequirement, "com.lesha19.KillSwitch.helper")] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertTrue(text.hasPrefix("anchor apple generic and "), text)
            XCTAssertTrue(text.contains("identifier \"\(identifier)\" and"), text)
            XCTAssertTrue(text.hasSuffix("certificate leaf[subject.OU] = \"YR58655PJ7\""), text)
        }
    }

    /// ADR 0025: the daemon takes our app or our `killswitch` tool, same anchor and team, nothing else.
    func testClientRequirementIsTheAppOrTheCLI() throws {
        let text = HelperIdentity.clientRequirement
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
        XCTAssertEqual(text, "anchor apple generic and (identifier \"com.lesha19.KillSwitch\" or identifier "
                           + "\"com.lesha19.KillSwitch.cli\") and certificate leaf[subject.OU] = \"YR58655PJ7\"")
        XCTAssertEqual(HelperIdentity.cliIdentifier, "com.lesha19.KillSwitch.cli")
    }

    /// Before root runs install.sh the bundle must be the app itself: a bundle signed as the CLI is not.
    func testBundleCheckKeepsTheAppOnlyRequirement() throws {
        let runner = try String(contentsOf: repo.appendingPathComponent("HelperDaemon/Runner.swift"), encoding: .utf8)
        XCTAssertTrue(runner.contains("requirement: HelperIdentity.appRequirement"))
        XCTAssertFalse(runner.contains("clientRequirement"))
        XCTAssertFalse(HelperIdentity.appRequirement.contains(HelperIdentity.cliIdentifier))
    }

    /// A program that is not ours, signed by anyone (here: the test runner, Apple-signed), is refused.
    func testOtherProgramsDoNotSatisfyTheClientRequirement() throws {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/true") as CFURL, [], &code), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(HelperIdentity.clientRequirement as CFString, [], &requirement),
                       errSecSuccess)
        XCTAssertNotEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], requirement), errSecSuccess)
    }

    // MARK: the launchd plist inside the app

    func testDaemonPlistMatchesTheProtocol() throws {
        let url = repo.appendingPathComponent("HelperDaemon/LaunchDaemons/\(HelperIdentity.plistName)")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperIdentity.machService)
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/\(HelperIdentity.executable)")
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], [HelperIdentity.machService: true])
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["com.lesha19.KillSwitch"])
        XCTAssertNil(plist["Program"])            // the path comes from the bundle, never absolute
        XCTAssertNil(plist["ProgramArguments"])
        XCTAssertNil(plist["KeepAlive"])          // started on demand by its Mach service
    }

    // MARK: the authorization right

    func testRightAsksForAnAdminEveryFiveMinutesAndIsNotShared() {
        let definition = HelperRight.definition
        XCTAssertEqual(HelperRight.name, "com.lesha19.KillSwitch.widen")
        XCTAssertEqual(definition["class"] as? String, "user")
        XCTAssertEqual(definition["group"] as? String, "admin")
        XCTAssertEqual(definition["timeout"] as? Int, 300)
        XCTAssertEqual(definition["shared"] as? Bool, false)
        XCTAssertEqual(definition["allow-root"] as? Bool, false)
        XCTAssertEqual(definition["authenticate-user"] as? Bool, true)
        XCTAssertEqual(definition["session-owner"] as? Bool, false)
        XCTAssertTrue(HelperRight.matches(definition))
    }

    /// `config.add.` lets anyone create a right that does not exist yet: whatever is there is
    /// checked key by key, and anything weaker is rewritten by the daemon or refused.
    func testWeakerDefinitionsDoNotMatch() {
        XCTAssertFalse(HelperRight.matches(nil))
        XCTAssertFalse(HelperRight.matches(["class": "allow"]))
        let changes: [(String, Any)] = [
            ("class", "allow"), ("group", "staff"), ("timeout", 86400), ("shared", true), ("allow-root", true),
            ("authenticate-user", false), ("session-owner", true),
        ]
        for (key, value) in changes {
            var weaker = HelperRight.definition
            weaker[key] = value
            XCTAssertFalse(HelperRight.matches(weaker), key)
            weaker[key] = nil
            XCTAssertFalse(HelperRight.matches(weaker), "missing \(key)")
        }
        var stored = HelperRight.definition   // authd adds its own bookkeeping
        stored["created"] = 655253090.98
        stored["modified"] = 655253090.98
        stored["comment"] = "something else"
        stored["timeout"] = NSNumber(value: 300)
        XCTAssertTrue(HelperRight.matches(stored))
    }

    // MARK: SMAppService states

    func testServiceStates() {
        XCTAssertEqual(HelperService.availability(.enabled, daemonBundled: true), .ready)
        XCTAssertEqual(HelperService.availability(.notRegistered, daemonBundled: true), .needsRegistration)
        XCTAssertEqual(HelperService.availability(.requiresApproval, daemonBundled: true), .needsApproval)
        XCTAssertEqual(HelperService.availability(.notFound, daemonBundled: false), .unavailable)
    }

    /// 0.14.1 on the owner's Mac: a daemon that was never registered can read `.notFound`, not
    /// `.notRegistered`, so it was taken for a build without the daemon and never registered. With
    /// the plist in the bundle, `.notFound` means "register it".
    func testNotFoundWithTheDaemonInTheBundleNeedsRegistration() {
        let availability = HelperService.availability(.notFound, daemonBundled: true)
        XCTAssertEqual(availability, .needsRegistration)
        XCTAssertEqual(HelperService.launchStep(helperInstalled: true, availability: availability), .register)
    }

    // MARK: answers

    func testRepliesReadLikeTheSudoPath() {
        XCTAssertEqual(HelperReply(status: 0, stdout: "on\n", stderr: "").text(separateStderr: false), "on")
        XCTAssertEqual(HelperReply(status: 1, stdout: "a", stderr: "b").text(separateStderr: false), "a\nb")
        XCTAssertEqual(HelperReply(status: 1, stdout: "{}", stderr: "boom\n").text(separateStderr: true), "boom")
        XCTAssertEqual(HelperReply(status: 0, stdout: "{}", stderr: "warn").text(separateStderr: true), "{}")
        XCTAssertEqual(HelperReply(status: 0, stdout: "", stderr: "").text(separateStderr: false), "")
        XCTAssertTrue(HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: "").needsAuthorization)
        XCTAssertFalse(HelperReply(status: 1, stdout: "", stderr: "").needsAuthorization)
    }

    /// A failed install.sh through the daemon reads as through the password prompt: its stderr,
    /// where it says why, not its progress on stdout (0.15.1: «Не получилось установить —
    /// core: kept»). Without stderr, both. A ks command keeps both, as `sudo -n` gave them.
    func testFailedScriptsShowTheirStderr() {
        let stopped = HelperReply(status: 1, stdout: "core: kept\nwatchdog: new helper\n", stderr: "install.sh:214: exit 1\n")
        XCTAssertEqual(stopped.failureText(.install), "install.sh:214: exit 1")
        XCTAssertEqual(stopped.failureText(.upgrade), "install.sh:214: exit 1")
        XCTAssertEqual(stopped.failureText(.uninstall), "install.sh:214: exit 1")
        XCTAssertEqual(stopped.failureText(.ks), "core: kept\nwatchdog: new helper\ninstall.sh:214: exit 1")
        XCTAssertEqual(HelperReply(status: 1, stdout: "core: kept", stderr: "").failureText(.install), "core: kept")
        XCTAssertEqual(HelperReply(status: 1, stdout: "", stderr: "").failureText(.install), "")
        XCTAssertEqual(UserError.from(raw: stopped.failureText(.upgrade), context: .install)?.message, "install.sh:214: exit 1")
    }
}
