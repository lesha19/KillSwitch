import Foundation
import XCTest

/// `killswitch` (ADR 0025): what it accepts, what it sends to the daemon, and what it prints.
final class CLITests: XCTestCase {
    private func parse(_ words: String...) -> CLI.Command? { try? CLI.parse(words).get() }

    // MARK: arguments

    func testCommands() {
        XCTAssertEqual(parse("status"), .status(json: false))
        XCTAssertEqual(parse("status", "--json"), .status(json: true))
        XCTAssertEqual(parse("connect"), .connect)
        XCTAssertEqual(parse("disconnect"), .disconnect)
        XCTAssertEqual(parse("protection", "on"), .protection(on: true))
        XCTAssertEqual(parse("protection", "off"), .protection(on: false))
        XCTAssertEqual(parse("pause", "15"), .pause(minutes: 15))
        XCTAssertEqual(parse("server", "list"), .serverList(json: false))
        XCTAssertEqual(parse("server", "list", "--json"), .serverList(json: true))
        XCTAssertEqual(parse("server", "select", "LT-Vilnius"), .serverSelect("LT-Vilnius"))
        XCTAssertEqual(parse("version"), .version)
        XCTAssertEqual(parse("--version"), .version)
        for help in ["help", "-h", "--help"] { XCTAssertEqual(parse(help), .help) }
    }

    /// `killswitch server select 🇱🇹 Литва` without quotes: the words are one name.
    func testServerNameMayBeSeveralWords() {
        XCTAssertEqual(parse("server", "select", "🇱🇹", "Литва"), .serverSelect("🇱🇹 Литва"))
    }

    func testRefusedArguments() {
        let refused: [[String]] = [
            [], ["bogus"], ["status", "--yaml"], ["status", "--json", "--json"], ["connect", "now"], ["disconnect", "-f"],
            ["protection"], ["protection", "maybe"], ["protection", "on", "off"],
            ["pause"], ["pause", "0"], ["pause", "10000"], ["pause", "-5"], ["pause", "+5"], ["pause", "５"], ["pause", "5", "6"],
            ["pause", "abc"], ["server"], ["server", "list", "--yaml"], ["server", "select"], ["server", "select", ""],
            ["server", "remove", "x"], ["version", "1"],
        ]
        for words in refused {
            guard case .failure(let error) = CLI.parse(words) else { return XCTFail("accepted \(words)") }
            XCTAssertFalse(error.message.isEmpty, "\(words)")
        }
    }

    /// Control characters never reach the daemon's names (it refuses them anyway).
    func testServerNameWithControlCharactersIsRefused() {
        XCTAssertNil(parse("server", "select", "a\nb"))
    }

    // MARK: what goes to the daemon, and behind which right

    func testDaemonCommandsAreTheAppsOwn() {
        XCTAssertEqual(CLI.Command.connect.daemonCommand, .coreOn)
        XCTAssertEqual(CLI.Command.disconnect.daemonCommand, .coreOff)
        XCTAssertEqual(CLI.Command.protection(on: true).daemonCommand, .protectionOn)
        XCTAssertEqual(CLI.Command.protection(on: false).daemonCommand, .protectionOff)
        XCTAssertEqual(CLI.Command.pause(minutes: 15).daemonCommand, .pause(minutes: 15))
        for command: CLI.Command in [.status(json: false), .serverList(json: true), .serverSelect("x"), .help, .version] {
            XCTAssertNil(command.daemonCommand, "\(command)")
        }
    }

    /// Never weaker than the app: what widens the rules carries the same right through
    /// HelperCommand.needsAuthorization, which both the app and the CLI ask before sending.
    func testWideningCommandsNeedTheRight() throws {
        XCTAssertTrue(try XCTUnwrap(CLI.Command.protection(on: false).daemonCommand).needsAuthorization)
        XCTAssertTrue(try XCTUnwrap(CLI.Command.pause(minutes: 1).daemonCommand).needsAuthorization)
        for command: CLI.Command in [.connect, .disconnect, .protection(on: true)] {
            XCTAssertFalse(try XCTUnwrap(command.daemonCommand).needsAuthorization, "\(command)")
        }
        // the reads and the server choice
        for command: HelperCommand in [.state, .coreState, .coreProxies, .coreSelect(group: "g", proxy: "p")] {
            XCTAssertFalse(command.needsAuthorization)
        }
    }

    func testEveryCommandItSendsIsValid() {
        for command: CLI.Command in [.connect, .disconnect, .protection(on: true), .protection(on: false), .pause(minutes: 1),
                                     .pause(minutes: 9999)] {
            XCTAssertEqual(command.daemonCommand?.isValid, true, "\(command)")
        }
    }

    // MARK: status

    private let utc = TimeZone(identifier: "UTC")!

    func testStatusJSON() {
        let on = CLI.Status(protection: .on, vpn: true, server: "LT-Vilnius")
        XCTAssertEqual(CLI.json(on), #"{"paused_until":null,"protection":"on","server":"LT-Vilnius","vpn":"on"}"#)
        let off = CLI.Status(protection: .off, vpn: false, server: nil)
        XCTAssertEqual(CLI.json(off), #"{"paused_until":null,"protection":"off","server":null,"vpn":"off"}"#)
        let paused = CLI.Status(protection: .paused(until: Date(timeIntervalSince1970: 1_760_000_000)), vpn: false, server: nil)
        XCTAssertEqual(CLI.json(paused),
                       #"{"paused_until":"2025-10-09T08:53:20Z","protection":"paused","server":null,"vpn":"off"}"#)
    }

    /// Names as they are: emoji and slashes are not escaped.
    func testStatusJSONKeepsNames() {
        let status = CLI.Status(protection: .on, vpn: true, server: "🇱🇹 Литва/1")
        XCTAssertEqual(CLI.json(status), #"{"paused_until":null,"protection":"on","server":"🇱🇹 Литва/1","vpn":"on"}"#)
    }

    func testStatusText() {
        XCTAssertEqual(CLI.text(CLI.Status(protection: .on, vpn: true, server: "LT-Vilnius"), timeZone: utc),
                       "Protection: on\nVPN: on, server LT-Vilnius")
        XCTAssertEqual(CLI.text(CLI.Status(protection: .on, vpn: true, server: nil), timeZone: utc),
                       "Protection: on\nVPN: on")
        XCTAssertEqual(CLI.text(CLI.Status(protection: .off, vpn: false, server: nil), timeZone: utc),
                       "Protection: off\nVPN: off")
        let paused = CLI.Status(protection: .paused(until: Date(timeIntervalSince1970: 1_760_000_000)), vpn: false, server: nil)
        XCTAssertEqual(CLI.text(paused, timeZone: utc), "Protection: paused until 08:53\nVPN: off")
    }

    /// `ks state` and `ks core state` as the daemon returns them.
    func testStatusFromTheDaemonsAnswers() {
        XCTAssertEqual(CLI.Status(state: "on\n", coreState: "on\n", proxies: nil),
                       CLI.Status(protection: .on, vpn: true, server: nil))
        XCTAssertEqual(CLI.Status(state: "paused:1760000000", coreState: "off", proxies: nil),
                       CLI.Status(protection: .paused(until: Date(timeIntervalSince1970: 1_760_000_000)), vpn: false, server: nil))
        XCTAssertEqual(CLI.Status(state: "off", coreState: "on later words", proxies: try? proxies()).server, "⚡ Авто")
        // no server while the core is off, even with a stale list
        XCTAssertNil(CLI.Status(state: "on", coreState: "off", proxies: try? proxies()).server)
    }

    // MARK: servers

    private let json = """
    {"proxies": {
      "🚀 Выбор сервера": {"type": "Selector", "now": "⚡ Авто",
                           "all": ["⚡ Авто", "🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "DIRECT", "Свои серверы"]},
      "⚡ Авто": {"type": "URLTest", "now": "🇱🇹 Литва", "all": ["🇱🇹 Литва", "🇩🇪 Германия"]},
      "Свои серверы": {"type": "Selector", "now": "🇵🇱 Варшава", "all": ["🇵🇱 Варшава", "Дом"]},
      "🇱🇹 Литва": {"type": "Vless"}, "🇩🇪 Германия": {"type": "Vless"}, "LT-Vilnius": {"type": "Trojan"},
      "🇵🇱 Варшава": {"type": "Vless"}, "Дом": {"type": "WireGuard"}, "DIRECT": {"type": "Direct"}
    }}
    """

    private func proxies() throws -> CoreProxies {
        try CoreProxies(data: Data(json.utf8), order: ["🚀 Выбор сервера", "⚡ Авто", "Свои серверы"])
    }

    private let main = "🚀 Выбор сервера"

    func testSelectByExactName() throws {
        XCTAssertEqual(try CLI.selection("LT-Vilnius", in: proxies()).get(), [.init(group: main, proxy: "LT-Vilnius")])
    }

    func testSelectFastest() throws {
        XCTAssertEqual(try CLI.selection("fastest", in: proxies()).get(), [.init(group: main, proxy: "⚡ Авто")])
        XCTAssertEqual(try CLI.selection("Самый быстрый", in: proxies()).get(), [.init(group: main, proxy: "⚡ Авто")])
    }

    func testSelectOwnServerGoesThroughItsGroup() throws {
        XCTAssertEqual(try CLI.selection("дом", in: proxies()).get(),
                       [.init(group: "Свои серверы", proxy: "Дом"), .init(group: main, proxy: "Свои серверы")])
    }

    func testSelectBySearchWhenOneMatches() throws {
        XCTAssertEqual(try CLI.selection("герм", in: proxies()).get(), [.init(group: main, proxy: "🇩🇪 Германия")])
    }

    func testSelectRefusesAmbiguousAndUnknown() throws {
        guard case .failure(.ambiguous(let names)) = CLI.selection("лит", in: try proxies()) else { return XCTFail() }
        XCTAssertEqual(names, ["🇱🇹 Литва", "LT-Vilnius"])
        XCTAssertEqual(CLI.selection("Narnia", in: try proxies()), .failure(.notFound))
        XCTAssertEqual(CLI.selection("DIRECT", in: try proxies()), .failure(.notFound))
    }

    func testServerListText() {
        let entries = [ServerPicker.Entry(name: "⚡ Авто", title: "Самый быстрый", isFastest: true, path: []),
                       ServerPicker.Entry(name: "LT-Vilnius", title: "LT-Vilnius", path: []),
                       ServerPicker.Entry(name: "Дом", title: "Дом (свой)", own: true, path: [])]
        XCTAssertEqual(CLI.text(entries, current: "LT-Vilnius"),
                       "  ⚡ Авто — Самый быстрый\n* LT-Vilnius\n  Дом — Дом (свой)")
        XCTAssertEqual(CLI.text([], current: nil), "")
    }

    func testServerListJSON() {
        let entries = [ServerPicker.Entry(name: "⚡ Авто", title: "Самый быстрый", isFastest: true, path: []),
                       ServerPicker.Entry(name: "Дом", title: "Дом (свой)", own: true, path: [])]
        XCTAssertEqual(CLI.json(entries, current: "Дом"),
                       #"[{"current":false,"fastest":true,"name":"⚡ Авто","own":false,"title":"Самый быстрый"},"#
                           + #"{"current":true,"fastest":false,"name":"Дом","own":true,"title":"Дом (свой)"}]"#)
        XCTAssertEqual(CLI.json([], current: nil), "[]")
    }

    // MARK: exit codes (sysexits)

    func testExitCodes() {
        XCTAssertEqual(CLI.Exit.ok.rawValue, 0)
        XCTAssertEqual(CLI.Exit.failed.rawValue, 1)
        XCTAssertEqual(CLI.Exit.usage.rawValue, 64)
        XCTAssertEqual(CLI.Exit.unavailable.rawValue, 69)
        XCTAssertEqual(CLI.Exit.notAuthorized.rawValue, 77)
        XCTAssertEqual(CLI.exit(for: HelperReply(status: 0, stdout: "", stderr: "")), .ok)
        XCTAssertEqual(CLI.exit(for: HelperReply(status: 3, stdout: "", stderr: "")), .failed)
        XCTAssertEqual(CLI.exit(for: HelperReply(status: HelperReply.refused, stdout: "", stderr: "")), .failed)
        XCTAssertEqual(CLI.exit(for: HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: "")), .notAuthorized)
    }
}

/// Where the tool ships and under which identifier (the daemon's requirement names it).
final class CLIBundleTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    func testProjectShipsItInHelpersUnderItsIdentifier() throws {
        let project = try String(contentsOf: repo.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(HelperIdentity.cliIdentifier)\n"))
        XCTAssertTrue(project.contains("PRODUCT_NAME: killswitch\n"))
        XCTAssertTrue(project.contains("subpath: Contents/Helpers\n"))
        let release = try String(contentsOf: repo.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        XCTAssertTrue(release.contains("CLI_ID=\(HelperIdentity.cliIdentifier)\n"))
        XCTAssertTrue(release.contains("Contents/Helpers/killswitch"))
    }
}
