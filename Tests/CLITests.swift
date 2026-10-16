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
        XCTAssertEqual(CLI.json(on), #"{"paused_until":null,"protection":"on","server":"LT-Vilnius","subscription":null,"vpn":"on"}"#)
        let off = CLI.Status(protection: .off, vpn: false, server: nil)
        XCTAssertEqual(CLI.json(off), #"{"paused_until":null,"protection":"off","server":null,"subscription":null,"vpn":"off"}"#)
        let paused = CLI.Status(protection: .paused(until: Date(timeIntervalSince1970: 1_760_000_000)), vpn: false, server: nil)
        XCTAssertEqual(CLI.json(paused),
                       #"{"paused_until":"2025-10-09T08:53:20Z","protection":"paused","server":null,"subscription":null,"vpn":"off"}"#)
    }

    /// Names as they are: emoji and slashes are not escaped.
    func testStatusJSONKeepsNames() {
        let status = CLI.Status(protection: .on, vpn: true, server: "🇱🇹 Литва/1")
        XCTAssertEqual(CLI.json(status), #"{"paused_until":null,"protection":"on","server":"🇱🇹 Литва/1","subscription":null,"vpn":"on"}"#)
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

    /// mihomo's JSON has no group order: the CLI reads the profile's order the app saved, so the
    /// main selector is «🚀 Выбор сервера», not the alphabetically first «Свои серверы».
    func testProxiesUseTheAppsGroupOrder() throws {
        let suite = "CLITests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(["🚀 Выбор сервера", "⚡ Авто", "Свои серверы"], forKey: CoreProxies.groupOrderKey)
        let list = try XCTUnwrap(CLI.proxies(json, appDefaults: defaults))
        XCTAssertEqual(list.groups.first?.name, main)
        XCTAssertEqual(CLI.Status(state: "on", coreState: "on", proxies: list).server, "⚡ Авто")
        XCTAssertEqual(try CLI.selection("дом", in: [block(list)], running: "s1").get().path,
                       [.init(group: "Свои серверы", proxy: "Дом"), .init(group: main, proxy: "Свои серверы")])
        XCTAssertTrue(ServerPicker.entries(list).contains { $0.name == "🇩🇪 Германия" })
        XCTAssertNil(CLI.proxies("not json", appDefaults: defaults))
    }

    /// Without a saved order (another account, before the first import) the selector no other
    /// group offers comes first: it is the one the rules use.
    func testWithoutAnOrderTheTopSelectorComesFirst() throws {
        let suite = "CLITests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(CLI.proxies(json, appDefaults: defaults)?.groups.first?.name, main)
        XCTAssertEqual(try CoreProxies(data: Data(json.utf8)).groups.first?.name, main)
    }

    func testSelectByExactName() throws {
        XCTAssertEqual(try CLI.selection("LT-Vilnius", in: [block()], running: "s1").get().path, [.init(group: main, proxy: "LT-Vilnius")])
    }

    func testSelectFastest() throws {
        XCTAssertEqual(try CLI.selection("fastest", in: [block()], running: "s1").get().path, [.init(group: main, proxy: "⚡ Авто")])
        XCTAssertEqual(try CLI.selection("Самый быстрый", in: [block()], running: "s1").get().path, [.init(group: main, proxy: "⚡ Авто")])
    }

    func testSelectOwnServerGoesThroughItsGroup() throws {
        XCTAssertEqual(try CLI.selection("дом", in: [block()], running: "s1").get().path,
                       [.init(group: "Свои серверы", proxy: "Дом"), .init(group: main, proxy: "Свои серверы")])
    }

    func testSelectBySearchWhenOneMatches() throws {
        XCTAssertEqual(try CLI.selection("герм", in: [block()], running: "s1").get().path, [.init(group: main, proxy: "🇩🇪 Германия")])
    }

    func testSelectRefusesAmbiguousAndUnknown() throws {
        guard case .failure(.ambiguous(let names)) = CLI.selection("лит", in: [try block()], running: "s1") else { return XCTFail() }
        XCTAssertEqual(names, ["Stork/🇱🇹 Литва", "Stork/LT-Vilnius"])
        XCTAssertEqual(CLI.selection("Narnia", in: [try block()], running: "s1"), .failure(.notFound))
        XCTAssertEqual(CLI.selection("DIRECT", in: [try block()], running: "s1"), .failure(.notFound))
    }

    func testServerListText() {
        let entries = [ServerPicker.Entry(name: "⚡ Авто", title: "Самый быстрый", isFastest: true, path: [], subscription: "s1"),
                       ServerPicker.Entry(name: "LT-Vilnius", title: "LT-Vilnius", path: [], subscription: "s1")]
        let own = [ServerPicker.Entry(name: "Дом", title: "Дом (свой)", own: true, path: [])]
        let blocks = [ServerPicker.Block(id: "s1", title: "Stork", entries: entries),
                      ServerPicker.Block(id: ServerID.own, title: "Свои серверы", entries: own)]
        XCTAssertEqual(CLI.text(blocks, current: ServerID(subscription: "s1", name: "LT-Vilnius")),
                       "  Stork/⚡ Авто — Самый быстрый\n* Stork/LT-Vilnius\n  Свои серверы/Дом — Дом (свой)")
        XCTAssertEqual(CLI.text([], current: nil), "")
    }

    /// #66: each row names its subscription.
    func testServerListJSON() {
        let blocks = [ServerPicker.Block(id: ServerID.own, title: "Свои серверы", entries: [
            ServerPicker.Entry(name: "⚡ Авто", title: "Самый быстрый", isFastest: true, path: []),
            ServerPicker.Entry(name: "Дом", title: "Дом (свой)", own: true, path: [])])]
        XCTAssertEqual(CLI.json(blocks, current: ServerID(subscription: ServerID.own, name: "Дом")),
                       #"[{"current":false,"fastest":true,"name":"⚡ Авто","own":false,"subscription":"Свои серверы","title":"Самый быстрый"},"#
                           + #"{"current":true,"fastest":false,"name":"Дом","own":true,"subscription":"Свои серверы","title":"Дом (свой)"}]"#)
        XCTAssertEqual(CLI.json([], current: nil), "[]")
    }

    private func block(_ list: CoreProxies? = nil, id: String = "s1", title: String = "Stork") throws -> ServerPicker.Block {
        ServerPicker.Block(id: id, title: title, entries: ServerPicker.entries(try list ?? proxies(), subscription: id))
    }

    /// #66: two subscriptions with the same server. A name in one of them is chosen; in both, the
    /// CLI says so and takes «subscription/server» (the subscription by title, in any case).
    func testSameNameInTwoSubscriptions() throws {
        let ivpn = ServerPicker.Block(id: "s2", title: "iVPN", entries: [
            ServerPicker.Entry(name: "🇱🇹 Литва", title: "Литва", path: [.init(group: "iVPN", proxy: "🇱🇹 Литва")], subscription: "s2"),
            ServerPicker.Entry(name: "🇳🇱 NL", title: "NL", path: [.init(group: "iVPN", proxy: "🇳🇱 NL")], subscription: "s2")])
        let blocks = [try block(), ivpn]
        XCTAssertEqual(CLI.selection("🇱🇹 Литва", in: blocks, running: "s1"), .failure(.ambiguous(["Stork/🇱🇹 Литва", "iVPN/🇱🇹 Литва"])))
        XCTAssertEqual(try CLI.selection("ivpn/🇱🇹 Литва", in: blocks, running: "s1").get().server, ServerID(subscription: "s2", name: "🇱🇹 Литва"))
        XCTAssertEqual(try CLI.selection("STORK/🇱🇹 литва", in: blocks, running: "s1").get().server, ServerID(subscription: "s1", name: "🇱🇹 Литва"))
        XCTAssertEqual(try CLI.selection("LT-Vilnius", in: blocks, running: "s1").get().server, ServerID(subscription: "s1", name: "LT-Vilnius"))
        XCTAssertEqual(try CLI.selection("🇳🇱 NL", in: blocks, running: "s1").get().server, ServerID(subscription: "s2", name: "🇳🇱 NL"))
        XCTAssertEqual(CLI.selection("Stork/Narnia", in: blocks, running: "s1"), .failure(.notFound))
        XCTAssertEqual(CLI.label(ivpn.entries[1], in: blocks), "iVPN/🇳🇱 NL")
    }

    /// PR 79 review: «fastest» is the running subscription's, whatever the others have.
    func testFastestIsTheRunningSubscriptions() throws {
        let blocks = [try block(), try block(id: "s2", title: "iVPN")]
        XCTAssertEqual(try CLI.selection("fastest", in: blocks, running: "s2").get().server, ServerID(subscription: "s2", name: "⚡ Авто"))
    }

    /// PR 79 review: the longest title before «/» names the subscription; two of the same title
    /// cannot be told apart, and the CLI says so.
    func testSubscriptionTitlesThatAreAPrefixOrTheSame() throws {
        func one(_ id: String, _ title: String) -> ServerPicker.Block {
            ServerPicker.Block(id: id, title: title, entries: [ServerPicker.Entry(name: "x", title: "x", path: [], subscription: id)])
        }
        let blocks = [one("a", "A"), one("ab", "A/B")]
        XCTAssertEqual(CLI.selection("A/B/x", in: blocks, running: "a").map(\.subscription), .success("ab"))
        XCTAssertEqual(CLI.selection("a/x", in: blocks, running: "a").map(\.subscription), .success("a"))
        XCTAssertEqual(CLI.selection("Same/x", in: [one("1", "Same"), one("2", "same")], running: "1"), .failure(.sameTitle("Same")))
    }

    /// PR 79 review: the CLI runs only the running subscription's servers, by the path the core
    /// gives now; never a path of the app's list (`cliServers` is only a file anyone could write).
    func testStepsComeFromTheCore() throws {
        let forged = ServerPicker.Entry(name: "LT-Vilnius", title: "LT-Vilnius", path: [.init(group: "x", proxy: "y")], subscription: "s1")
        XCTAssertEqual(CLI.steps(forged, running: "s1", proxies: try proxies()), [.init(group: main, proxy: "LT-Vilnius")])
        XCTAssertNil(CLI.steps(forged, running: "s2", proxies: try proxies()))
        XCTAssertNil(CLI.steps(ServerPicker.Entry(name: "Narnia", title: "", path: [], subscription: "s1"), running: "s1", proxies: try proxies()))
        let data = try JSONEncoder().encode([ServerPicker.Block(id: "s2", title: "iVPN", entries: [forged])])
        XCTAssertEqual(CLI.blocks(data, running: "s1", proxies: try proxies()).first { $0.id == "s2" }?.entries.map(\.subscription), ["s2"])
    }

    /// PR 79 review: a running subscription the app's list does not have is named by nothing, not its id.
    func testAnUnknownRunningSubscriptionHasNoName() throws {
        let blocks = CLI.blocks(nil, running: "9F2C-uuid", proxies: try proxies())
        XCTAssertEqual(CLI.label(blocks[0].entries[1], in: blocks), blocks[0].entries[1].name)
        XCTAssertFalse(CLI.json(blocks, current: nil).contains("9F2C"))
        XCTAssertFalse(CLI.json(blocks, current: nil).contains(#""subscription""#))
        XCTAssertNil(CLI.title(of: "9F2C-uuid", in: blocks))
    }

    /// The app's list (VPNClient, `serversKey`) with the running subscription's servers from the
    /// core; without the app's list, the running servers alone.
    func testBlocksTakeTheRunningServersFromTheCore() throws {
        let stale = ServerPicker.Block(id: "s1", title: "Stork", entries: [])
        let ivpn = ServerPicker.Block(id: "s2", title: "iVPN", entries: [])
        let data = try JSONEncoder().encode([stale, ivpn])
        let blocks = CLI.blocks(data, running: "s1", proxies: try proxies())
        XCTAssertEqual(blocks.map(\.title), ["Stork", "iVPN"])
        XCTAssertEqual(blocks[0].entries, try block().entries)
        XCTAssertEqual(CLI.blocks(nil, running: "s1", proxies: try proxies()).map(\.id), ["s1"])
        XCTAssertEqual(CLI.activeKey, Subscriptions.activeKey)
    }

    /// #66: the status names the subscription of the server.
    func testStatusJSONNamesTheSubscription() {
        let on = CLI.Status(protection: .on, vpn: true, server: "LT-Vilnius", subscription: "Stork")
        XCTAssertEqual(CLI.json(on), #"{"paused_until":null,"protection":"on","server":"LT-Vilnius","subscription":"Stork","vpn":"on"}"#)
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
