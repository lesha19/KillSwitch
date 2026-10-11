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
                                                      "direct": false, "adblock": false, "diag": false],
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
