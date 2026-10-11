import Foundation
import XCTest

/// «Перенос настроек» (#15, ADR 0024): a JSON file without secrets; reading it checks everything
/// before anything changes; root settings change only through the `ks` commands the UI uses.
final class SettingsBackupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let helper = "/Library/KillSwitch/ks"
    private let germanyKey = "id:vless|de.example.net|443|0123456789abcdef"

    override func setUp() {
        suite = "SettingsBackupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func fresh() -> (UserDefaults, String) {
        let name = "SettingsBackupTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return (UserDefaults(suiteName: name)!, name)
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func file(app: [String: Any] = [:], root: [String: Any]? = nil, version: Int = 1) -> Data {
        var object: [String: Any] = ["format": "killswitch-settings", "version": version, "app": app]
        if let root { object["root"] = root }
        return json(object)
    }

    private let root = SettingsBackup.Root(core: .xray,
                                           switches: ["lan": true, "tailscale": true, "dns": false, "wifiguard": true,
                                                      "direct": false, "adblock": false, "diag": false, "failover": true],
                                           exceptions: ["10.8.0.0/24"], manualServers: [], splitApps: ["Telegram"])

    // MARK: export

    func testExportCarriesNoSecrets() throws {
        defaults.set("\(germanyKey)\nGone", forKey: "favouriteServers")
        defaults.set(germanyKey, forKey: "recentServers")
        defaults.set("https://sub.example.com/secret-token", forKey: "subscriptionStatus")
        defaults.set(10, forKey: "pauseShort")
        let app = SettingsBackup.snapshot(defaults, serverKeys: ["🇩🇪 Germany": germanyKey])
        let data = SettingsBackup.export(.init(app: app, root: root), appVersion: "0.18.1", date: Date(timeIntervalSince1970: 0))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("🇩🇪 Germany"), "favourites by name, not by identity")
        XCTAssertFalse(text.contains("id:"), "a server identity carries a hash of its secret")
        XCTAssertFalse(text.contains("0123456789abcdef"))
        XCTAssertFalse(text.contains("secret-token"), "only the listed settings are written")
        XCTAssertFalse(text.contains("subscriptionStatus"))
        XCTAssertTrue(text.contains("\"pauseShort\" : 10"))
        XCTAssertTrue(text.contains("\"format\" : \"killswitch-settings\""))
    }

    func testExportReadsBackTheSame() throws {
        defaults.set(false, forKey: "autoConnect")
        defaults.set(["Дом"], forKey: "trustedNetworks")
        defaults.set(WiFiRules.encode([.init(ssid: "Cafe", autoConnect: true, server: "NL")]), forKey: WiFiRules.key)
        defaults.set("ping", forKey: "serverSort")
        let app = SettingsBackup.snapshot(defaults, serverKeys: [:])
        let read = try SettingsBackup.read(SettingsBackup.export(.init(app: app, root: root), appVersion: "0.18.1", date: Date()))
        XCTAssertEqual(read, .init(app: app, root: root))
        XCTAssertEqual(read.app["wifiRules"], .rules([.init(ssid: "Cafe", autoConnect: true, server: "NL")]))
    }

    // MARK: import

    func testApplyWritesWhatTheAppReads() throws {
        let read = try SettingsBackup.read(file(app: ["pauseLong": 60, "favouriteServers": ["NL"], "wifiRules": [["ssid": "Cafe", "autoConnect": false]],
                                                      "trustedNetworks": ["Дом"], "updateBetaChannel": true]))
        defaults.set(7, forKey: "pauseShort")
        SettingsBackup.apply(read.app, to: defaults)

        XCTAssertEqual(defaults.integer(forKey: "pauseLong"), 60)
        XCTAssertEqual(defaults.string(forKey: "favouriteServers"), "NL")
        XCTAssertEqual(WiFiRules.decode(defaults.data(forKey: WiFiRules.key)), [.init(ssid: "Cafe", autoConnect: false)])
        XCTAssertEqual(defaults.stringArray(forKey: "trustedNetworks"), ["Дом"])
        XCTAssertTrue(UpdateChannel.isBeta(defaults))
        XCTAssertEqual(defaults.integer(forKey: "pauseShort"), 7, "what the file does not name stays")
    }

    func testRefusesWhatIsNotItsFile() {
        XCTAssertThrowsError(try SettingsBackup.read(Data("not json".utf8))) { XCTAssertEqual($0 as? SettingsBackup.Problem, .notSettings) }
        XCTAssertThrowsError(try SettingsBackup.read(json(["proxies": []]))) { XCTAssertEqual($0 as? SettingsBackup.Problem, .notSettings) }
        XCTAssertThrowsError(try SettingsBackup.read(file(version: 2))) { XCTAssertEqual($0 as? SettingsBackup.Problem, .newer) }
        XCTAssertThrowsError(try SettingsBackup.read(Data(count: SettingsBackup.maxBytes + 1))) {
            XCTAssertEqual($0 as? SettingsBackup.Problem, .notSettings)
        }
    }

    func testRefusesTheWholeFileOverOneBadValue() {
        let bad: [[String: Any]] = [
            ["pauseShort": 0], ["pauseShort": true], ["autoConnect": 1], ["serverSort": "random"],
            ["subscriptionIntervalHours": 5], ["favouriteServers": "NL"], ["wifiRules": [["autoConnect": true]]],
            ["favouriteServers": [String(repeating: "x", count: 300)]],
        ]
        for app in bad {
            XCTAssertThrowsError(try SettingsBackup.read(file(app: app)), "\(app)") {
                guard case .damaged = $0 as? SettingsBackup.Problem else { return XCTFail("\(app): \($0)") }
            }
        }
        let badRoot: [[String: Any]] = [
            ["core": "wireguard"], ["switches": ["pf": true]], ["switches": ["lan": 1]], ["exceptions": ["example.com"]],
            ["manualServers": ["1.2.3.4; rm -rf /"]], ["splitApps": ["a,b"]],
        ]
        for root in badRoot {
            XCTAssertThrowsError(try SettingsBackup.read(file(root: root)), "\(root)") {
                guard case .damaged = $0 as? SettingsBackup.Problem else { return XCTFail("\(root): \($0)") }
            }
        }
    }

    func testIgnoresWhatItDoesNotKnow() throws {
        let read = try SettingsBackup.read(json(["format": "killswitch-settings", "version": 1, "future": 1,
                                                 "app": ["subscriptionURL": "https://x", "pauseShort": 3]]))
        XCTAssertEqual(read, .init(app: ["pauseShort": .int(3)], root: nil))
    }

    func testDropsServerIdentitiesFromAFile() throws {
        let read = try SettingsBackup.read(file(app: ["recentServers": [germanyKey, "NL"]]))
        XCTAssertEqual(read.app["recentServers"], .list(["NL"]))
    }

    // MARK: what changes

    func testChangesNameOnlyWhatDiffers() {
        let current = SettingsBackup.Settings(app: ["pauseShort": .int(5), "autoConnect": .bool(true)], root: root)
        var newRoot = root
        newRoot.switches?["adblock"] = true
        newRoot.core = nil
        let new = SettingsBackup.Settings(app: ["pauseShort": .int(5), "autoConnect": .bool(false)], root: newRoot)
        let changes = SettingsBackup.changes(from: current, to: new)
        XCTAssertEqual(changes.map(\.key), ["autoConnect", "adblock"])
        XCTAssertEqual(changes.map(\.root), [false, true])
    }

    /// A file could hide 0.0.0.0/1 and 128.0.0.0/1 as the 4th and 5th entries behind «и ещё 2»,
    /// and the admin's password would open the whole internet past the kill switch: every entry
    /// a root list gains or loses is named, and a very broad network is called out.
    func testRootListChangesNameEveryEntry() throws {
        let file = file(root: ["exceptions": ["10.8.0.0/24", "1.1.1.1", "2.2.2.2", "3.3.3.3", "0.0.0.0/1", "128.0.0.0/1"],
                               "manualServers": ["5.6.7.8", "6.6.6.6", "7.7.7.7", "8.8.8.8", "::/0"],
                               "splitApps": ["Safari", "Mail", "Notes", "Music", "/Applications/Evil.app"]])
        let read = try SettingsBackup.read(file)
        let changes = SettingsBackup.changes(from: .init(app: [:], root: root), to: read)
        let exceptions = try XCTUnwrap(changes.first { $0.key == "exceptions" })
        XCTAssertEqual(exceptions.added, ["1.1.1.1", "2.2.2.2", "3.3.3.3", "0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(exceptions.removed, [])
        XCTAssertEqual(exceptions.warnings, [
            "0.0.0.0/1 — это огромная часть интернета: всё, что туда идёт, пойдёт мимо VPN.",
            "128.0.0.0/1 — это огромная часть интернета: всё, что туда идёт, пойдёт мимо VPN.",
        ])
        let servers = try XCTUnwrap(changes.first { $0.key == "manualServers" })
        XCTAssertEqual(servers.added, ["5.6.7.8", "6.6.6.6", "7.7.7.7", "8.8.8.8", "::/0"])
        XCTAssertEqual(servers.warnings, ["::/0 — это весь интернет: всё пойдёт мимо VPN."])
        let apps = try XCTUnwrap(changes.first { $0.key == "splitApps" })
        XCTAssertEqual(apps.added, ["Safari", "Mail", "Notes", "Music", "/Applications/Evil.app"])
        XCTAssertEqual(apps.removed, ["Telegram"])
        XCTAssertEqual(apps.warnings, [])
    }

    func testBroadNetworksAreCalledOut() {
        for entry in ["0.0.0.0/0", "0.0.0.0/1", "64.0.0.0/2", "10.0.0.0/7", "::/0", "8000::/1", "2000::/3", "2001::/15"] {
            XCTAssertNotNil(SettingsBackup.broadNetworkWarning(entry), entry)
        }
        for entry in ["10.0.0.0/8", "192.168.0.0/16", "1.1.1.1", "2001:db8::/16", "2001:db8::/32", "fe80::1", "::1"] {
            XCTAssertNil(SettingsBackup.broadNetworkWarning(entry), entry)
        }
        // IPv4 written as IPv6 (::ffff:0:0/96) is the IPv4 internet
        for entry in ["::ffff:0:0/96", "::ffff:0.0.0.0/97", "::ffff:64.0.0.0/98", "::/80", "::/64"] {
            XCTAssertNotNil(SettingsBackup.broadNetworkWarning(entry), entry)
        }
        for entry in ["::ffff:10.0.0.0/104", "::ffff:1.2.3.4", "::ffff:1.0.0.0/104", "fc00::/7", "fe80::/10", "224.0.0.0/3"] {
            XCTAssertNil(SettingsBackup.broadNetworkWarning(entry), entry)
        }
    }

    /// 256 entries of /8 are the whole internet one /8 at a time: the sum is called out once.
    func testManyNetworksTogetherAreCalledOut() {
        let together = "Вместе эти адреса — огромная часть интернета: всё, что туда идёт, пойдёт мимо VPN."
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings((0...255).map { "\($0).0.0.0/8" }), [together])
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings(["1.0.0.0/8", "2.0.0.0/8"]), [together])
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings((0...255).map { "2\(String(format: "%03x", $0))::/16" }), [together])
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings(["::ffff:1.0.0.0/104", "::ffff:2.0.0.0/104"]), [together])
        // a home network's private ranges are not the internet
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7"]), [])
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings(["1.0.0.0/8", "10.0.0.0/8", "192.168.1.0/24"]), [], "exactly a /8 of the internet")
        // one broad entry already says it; no second, summed warning
        XCTAssertEqual(SettingsBackup.broadNetworkWarnings(["0.0.0.0/1", "128.0.0.0/8"]).count, 1)
    }

    /// «Cafe → Cafe» said nothing: a Wi‑Fi rule's change shows what it does, and only the rules
    /// that change.
    func testWiFiRuleChangesShowTheirValues() throws {
        let current = SettingsBackup.Settings(app: [WiFiRules.key: .rules([.init(ssid: "Cafe", autoConnect: true, server: "🇳🇱Нидерланды"),
                                                                            .init(ssid: "Home", autoConnect: true)])], root: nil)
        let new = SettingsBackup.Settings(app: [WiFiRules.key: .rules([.init(ssid: "Cafe", autoConnect: false),
                                                                        .init(ssid: "Home", autoConnect: true),
                                                                        .init(ssid: "Office", autoConnect: true, server: "🇩🇪Германия")])], root: nil)
        let change = try XCTUnwrap(SettingsBackup.changes(from: current, to: new).first)
        XCTAssertEqual(change.old, "Cafe: подключаться, сервер 🇳🇱 Нидерланды")
        XCTAssertEqual(change.new, "Cafe: не подключаться; Office: подключаться, сервер 🇩🇪 Германия")
        let removed = SettingsBackup.changes(from: new, to: .init(app: [WiFiRules.key: .rules([])], root: nil)).first
        XCTAssertEqual(removed?.new, "нет")
    }

    /// ADR 0031: the blocked categories and the own DoH server travel with the file, through the
    /// commands Settings runs; "" in the file clears the server, a bad address refuses the file.
    func testBlockingAndOwnDoHTravel() throws {
        var current = root
        current.doh = ""
        let read = try SettingsBackup.read(file(root: ["switches": ["blockadult": true, "blocksocial": false, "blockbetting": true],
                                                       "doh": "https://dns.example.com/dns-query"]))
        XCTAssertEqual(read.root?.switches, ["blockadult": true, "blocksocial": false, "blockbetting": true])
        XCTAssertEqual(read.root?.doh, "https://dns.example.com/dns-query")
        let changes = SettingsBackup.changes(from: .init(app: [:], root: current), to: read)
        XCTAssertEqual(changes.map(\.key), ["blockadult", "blockbetting", "doh"])
        XCTAssertEqual(changes.last?.title, "Свой сервер DNS-over-HTTPS")
        XCTAssertEqual(changes.last?.old, "нет")
        XCTAssertEqual(changes.last?.new, "https://dns.example.com/dns-query")
        XCTAssertTrue(changes.allSatisfy(\.root))
        let commands = SettingsBackup.rootCommands(helper: helper, current: current, new: read.root!)
        XCTAssertEqual(commands, [[helper, "set", "blockadult", "1"], [helper, "set", "blockbetting", "1"],
                                  [helper, "set", "doh", "https://dns.example.com/dns-query"]])
        XCTAssertTrue(commands.allSatisfy { HelperCommand(command: $0, helper: helper)?.isValid == true })
        // the file says nothing of it: left alone; "" clears it
        XCTAssertNil(try SettingsBackup.read(file(root: ["switches": ["lan": true]])).root?.doh)
        var withServer = root
        withServer.doh = "https://dns.example.com/dns-query"
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: withServer, new: try SettingsBackup.read(file(root: ["doh": ""])).root!),
                       [[helper, "set", "doh", ""]])
        for bad: Any in ["http://dns.example.com/x", "https://192.168.1.1/x", 1] {
            XCTAssertThrowsError(try SettingsBackup.read(file(root: ["doh": bad])), "\(bad)") {
                guard case .damaged = $0 as? SettingsBackup.Problem else { return XCTFail("\(bad): \($0)") }
            }
        }
        // export and back
        var full = root
        full.doh = "https://dns.example.com/dns-query"
        full.switches?["blockadult"] = true
        let again = try SettingsBackup.read(SettingsBackup.export(.init(app: [:], root: full), appVersion: "0.20.0", date: Date()))
        XCTAssertEqual(again.root, full)
        // reset: nothing blocked but ads as before (off), no own server
        XCTAssertEqual(SettingsBackup.reset.root?.doh, "")
        XCTAssertEqual(SettingsBackup.reset.root?.switches?["blockadult"], false)
    }

    /// ADR 0033: own addresses of sites travel as a root list, through `ks set hosts`; a bad entry refuses the file.
    func testOwnHostsTravel() throws {
        let read = try SettingsBackup.read(file(root: ["hosts": ["nas.lan=192.168.1.10", "dns.example.com=203.0.113.53"]]))
        XCTAssertEqual(read.root?.hosts, ["nas.lan=192.168.1.10", "dns.example.com=203.0.113.53"])
        let change = try XCTUnwrap(SettingsBackup.changes(from: .init(app: [:], root: root), to: read).first)
        XCTAssertEqual(change.key, "hosts")
        XCTAssertEqual(change.title, "Свои адреса сайтов")
        XCTAssertEqual(change.added, ["nas.lan=192.168.1.10", "dns.example.com=203.0.113.53"])
        XCTAssertTrue(change.root)
        let commands = SettingsBackup.rootCommands(helper: helper, current: root, new: read.root!)
        XCTAssertEqual(commands, [[helper, "set", "hosts", "nas.lan=192.168.1.10,dns.example.com=203.0.113.53"]])
        XCTAssertTrue(commands.allSatisfy { HelperCommand(command: $0, helper: helper)?.isValid == true })
        for bad: Any in [["nas=1.2.3.4"], ["github.com=1.2.3.4"], "nas.lan=192.168.1.10", [1]] {
            XCTAssertThrowsError(try SettingsBackup.read(file(root: ["hosts": bad])), "\(bad)") {
                guard case .damaged = $0 as? SettingsBackup.Problem else { return XCTFail("\(bad): \($0)") }
            }
        }
        var full = root
        full.hosts = ["nas.lan=192.168.1.10"]
        XCTAssertEqual(try SettingsBackup.read(SettingsBackup.export(.init(app: [:], root: full), appVersion: "0.20.0", date: Date())).root, full)
        XCTAssertEqual(SettingsBackup.reset.root?.hosts, [])
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: full, new: SettingsBackup.reset.root!).last, [helper, "set", "hosts", ""])
    }

    /// The same entries in another order change nothing, in the sheet and in the commands.
    func testReorderedRootListIsNoChange() {
        var new = root
        new.exceptions = ["10.8.0.0/24"]
        new.splitApps = ["Telegram"]
        var current = root
        current.exceptions = ["10.8.0.0/24", "1.1.1.1"]
        current.splitApps = ["Safari", "Telegram"]
        new.exceptions = ["1.1.1.1", "10.8.0.0/24"]
        new.splitApps = ["Telegram", "Safari"]
        XCTAssertEqual(SettingsBackup.changes(from: .init(app: [:], root: current), to: .init(app: [:], root: new)), [])
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: current, new: new), [])
    }

    func testResetNamesWhatItRemoves() throws {
        let changes = SettingsBackup.changes(from: .init(app: [:], root: root), to: SettingsBackup.reset)
        let exceptions = try XCTUnwrap(changes.first { $0.key == "exceptions" })
        XCTAssertEqual(exceptions.removed, ["10.8.0.0/24"])
        XCTAssertEqual(exceptions.added, [])
        XCTAssertEqual(exceptions.warnings, [])
    }

    func testRootCommandsAreTheOnesTheUIRuns() {
        var new = root
        new.switches = ["lan": false, "adblock": true]
        new.exceptions = ["1.1.1.1"]
        new.manualServers = ["5.6.7.8"]
        new.splitApps = ["Telegram", "Safari"]
        new.core = .mihomo
        let commands = SettingsBackup.rootCommands(helper: helper, current: root, new: new)
        XCTAssertEqual(commands, [
            [helper, "set", "adblock", "1"], [helper, "set", "lan", "0"],
            [helper, "unallow", "10.8.0.0/24"], [helper, "allow", "1.1.1.1"],
            [helper, "server-add", "5.6.7.8"],
            [helper, "set", "splitapps", "Telegram,Safari"],
        ], "the core goes through VPNClient.switchCore, which imports the subscription again")
        XCTAssertTrue(commands.allSatisfy { HelperCommand(command: $0, helper: helper)?.isValid == true })
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: root, new: .init()), [])
    }

    // MARK: reset

    func testAutomaticServerSwitchTravels() throws {
        var current = root
        current.switches?["failover"] = true
        var new = root
        new.switches?["failover"] = false
        let read = try SettingsBackup.read(file(root: ["switches": ["failover": false]]))
        XCTAssertEqual(read.root?.switches, ["failover": false])
        let changes = SettingsBackup.changes(from: .init(app: [:], root: current), to: .init(app: [:], root: new))
        XCTAssertEqual(changes.map(\.key), ["failover"])
        XCTAssertEqual(changes.first?.title, "Переключать сервер, если он перестал отвечать")
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: current, new: new), [[helper, "set", "failover", "0"]])
        XCTAssertEqual(SettingsBackup.reset.root?.switches?["failover"], true, "on by default, as in ks (ADR 0023)")
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: new, new: try XCTUnwrap(SettingsBackup.reset.root)).first,
                       [helper, "set", "failover", "1"])
    }

    func testResetIsTheDefaults() throws {
        defaults.set(9, forKey: "pauseShort")
        defaults.set(false, forKey: "notifyVPNDropped")
        defaults.set("NL", forKey: "favouriteServers")
        SettingsBackup.apply(SettingsBackup.reset.app, to: defaults)
        XCTAssertEqual(SettingsBackup.snapshot(defaults, serverKeys: [:]), SettingsBackup.reset.app)
        XCTAssertEqual(defaults.object(forKey: "notifyVPNDropped") as? Bool, true)

        let reset = try XCTUnwrap(SettingsBackup.reset.root)
        XCTAssertNil(reset.core, "the way of connecting stays")
        XCTAssertEqual(SettingsBackup.rootCommands(helper: helper, current: root, new: reset), [
            [helper, "unallow", "10.8.0.0/24"], [helper, "set", "splitapps", ""],
        ])
    }
}
