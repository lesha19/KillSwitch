import Foundation
import XCTest

/// «Сети Wi‑Fi» (#39): per network only «Подключаться автоматически» and «Предпочитаемый сервер»;
/// nothing turns protection off on a network.
final class WiFiRulesTests: XCTestCase {
    private let ready = AutoConnect.Core(ready: true, connected: false, otherVPN: false)
    private let cafe = AutoConnect.Network(online: true, wifi: true, ssid: "Cafe Free", interfaces: ["en0"])
    private let off = AutoConnect.Settings(enabled: false, skipTrusted: false, trusted: [])

    private func entry(_ name: String, _ subscription: String = ServerID.own) -> ServerPicker.Entry {
        ServerPicker.Entry(name: name, title: name, path: [.init(group: "Proxy", proxy: name)], subscription: subscription)
    }

    // MARK: matching

    func testRuleMatchesExactName() {
        let rules = [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: true), WiFiRules.Rule(ssid: "Дом")]
        XCTAssertEqual(WiFiRules.rule(for: "Cafe Free", in: rules)?.ssid, "Cafe Free")
        XCTAssertNil(WiFiRules.rule(for: "cafe free", in: rules), "Wi-Fi names are case-sensitive")
        XCTAssertNil(WiFiRules.rule(for: nil, in: rules), "no name (cable, no Location): no rule")
    }

    // MARK: «Подключаться автоматически»

    func testRuleConnectsEvenWhenAutoConnectIsOff() {
        var settings = off
        settings.rules = [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: true)]
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: ready), .connect)
    }

    func testRuleWithoutAutoConnectFollowsTheGeneralSwitch() {
        var settings = off
        settings.rules = [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: false)]
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: ready), .skip(.disabled))
    }

    /// Asked for on this very network: the more protective answer wins over «доверенная».
    func testRuleWinsOverTrustedList() {
        let settings = AutoConnect.Settings(enabled: true, skipTrusted: true, trusted: ["Cafe Free"],
                                            rules: [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: true)])
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: ready), .connect)
    }

    func testRuleStillRespectsTheCoreState() {
        var settings = off
        settings.rules = [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: true)]
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: .init(ready: false, connected: false, otherVPN: false)), .skip(.notReady))
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: .init(ready: true, connected: true, otherVPN: false)), .skip(.connected))
        XCTAssertEqual(AutoConnect.decide(settings, network: cafe, core: .init(ready: true, connected: false, otherVPN: true)), .skip(.otherVPN))
    }

    func testRuleNeedsTheWiFiName() {
        var settings = off
        settings.rules = [WiFiRules.Rule(ssid: "Cafe Free", autoConnect: true)]
        let hidden = AutoConnect.Network(online: true, wifi: true, ssid: nil, interfaces: ["en0"])
        XCTAssertEqual(AutoConnect.decide(settings, network: hidden, core: ready), .skip(.disabled))
    }

    // MARK: «Предпочитаемый сервер»

    func testPreferredServerIsPickedOnJoining() {
        let rule = WiFiRules.Rule(ssid: "Cafe Free", server: "NL-Amsterdam")
        let entries = [entry("DE-Berlin"), entry("NL-Amsterdam")]
        XCTAssertEqual(WiFiRules.server(for: rule, entries: entries, current: "DE-Berlin", active: ServerID.own), .select(entry("NL-Amsterdam")))
    }

    func testPreferredServerAlreadyInUse() {
        let rule = WiFiRules.Rule(ssid: "Cafe Free", server: "NL-Amsterdam")
        XCTAssertEqual(WiFiRules.server(for: rule, entries: [entry("NL-Amsterdam")], current: "NL-Amsterdam", active: ServerID.own), .keep)
    }

    func testNoPreferredServer() {
        XCTAssertEqual(WiFiRules.server(for: WiFiRules.Rule(ssid: "Cafe Free"), entries: [entry("DE-Berlin")], current: nil, active: ServerID.own), .keep)
        XCTAssertEqual(WiFiRules.server(for: nil, entries: [entry("DE-Berlin")], current: nil, active: ServerID.own), .keep)
    }

    /// Gone from the subscription: nothing changes, and Settings says the server is missing.
    func testPreferredServerMissing() {
        let rule = WiFiRules.Rule(ssid: "Cafe Free", server: "NL-Amsterdam")
        XCTAssertEqual(WiFiRules.server(for: rule, entries: [entry("DE-Berlin")], current: "DE-Berlin", active: ServerID.own), .missing("NL-Amsterdam"))
    }

    /// ADR 0036 (#74): «Литва» of two subscriptions are two servers. A rule names the one of its
    /// subscription; while another subscription is in use nothing changes (a rule never switches
    /// subscriptions). A rule kept before ADR 0036 has no subscription: the one in use.
    func testPreferredServerOfItsSubscription() {
        let stork = entry("🇱🇹 Литва", "s1"), other = entry("🇱🇹 Литва", "s2")
        let rule = WiFiRules.Rule(ssid: "Cafe Free", server: "🇱🇹 Литва", subscription: "s2")
        XCTAssertEqual(WiFiRules.server(for: rule, entries: [other], current: "DE", active: "s2"), .select(other))
        XCTAssertEqual(WiFiRules.server(for: rule, entries: [stork], current: "DE", active: "s1"), .keep)
        XCTAssertEqual(WiFiRules.server(for: rule, entries: [stork], current: "🇱🇹 Литва", active: "s1"), .keep)
        let old = WiFiRules.Rule(ssid: "Cafe Free", server: "🇱🇹 Литва")
        XCTAssertEqual(WiFiRules.server(for: old, entries: [stork], current: "DE", active: "s1"), .select(stork))
        XCTAssertEqual(WiFiRules.decode(WiFiRules.encode([rule])), [rule])
    }

    // MARK: editing and storage

    func testAddingKeepsOneRulePerNetwork() {
        var rules = WiFiRules.adding(" Дом ", to: [])
        XCTAssertEqual(rules, [WiFiRules.Rule(ssid: "Дом")])
        rules = WiFiRules.adding("Дом", to: rules)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(WiFiRules.adding("", to: rules), rules)
    }

    /// A new rule connects there: that is why people add a network.
    func testNewRuleAutoConnects() {
        XCTAssertTrue(WiFiRules.Rule(ssid: "Cafe Free").autoConnect)
        XCTAssertNil(WiFiRules.Rule(ssid: "Cafe Free").server)
    }

    func testStorageRoundTrip() {
        let rules = [WiFiRules.Rule(ssid: "Дом", autoConnect: false, server: "DE-Berlin"), WiFiRules.Rule(ssid: "Cafe Free")]
        XCTAssertEqual(WiFiRules.decode(WiFiRules.encode(rules)), rules)
    }

    /// Damaged or missing: no rules, so the general switches decide (they never weaken protection).
    func testDamagedStorageMeansNoRules() {
        XCTAssertEqual(WiFiRules.decode(nil), [])
        XCTAssertEqual(WiFiRules.decode(Data("{not json".utf8)), [])
    }
}
