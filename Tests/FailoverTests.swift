import Foundation
import XCTest

final class FailoverTests: XCTestCase {
    // MARK: what the app asks the helper for

    private let profile: Profile = [
        "proxies": [["name": "🇱🇹 Литва 1"], ["name": "🇱🇹 Литва 2"], ["name": "🇩🇪 Германия"], ["name": "LT-Vilnius"],
                    ["name": "🇳🇱 NL"], ["name": "Без страны"], ["name": "Мой"]],
        "proxy-groups": [
            ["name": "🚀 Выбор", "type": "select",
             "proxies": ["⚡ Авто", "🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия", "LT-Vilnius", "🇳🇱 NL", "Без страны", "DIRECT",
                         "Свои серверы"]],
            ["name": "⚡ Авто", "type": "url-test", "proxies": ["🇱🇹 Литва 1", "🇩🇪 Германия"]],
            ["name": "Свои серверы", "type": "select", "proxies": ["Мой"]],
        ],
    ]

    func testSetsAreTheMainSelectorsServersByCountry() {
        // groups, built-ins, single-server countries and names without a country stay out
        XCTAssertEqual(Failover.sets(profile), [["🇱🇹 Литва 1", "🇱🇹 Литва 2", "LT-Vilnius"]])
    }

    func testTheHintGoesIntoTheProfileOnlyWhenThereIsASet() {
        let hinted = Failover.adding(to: profile)
        XCTAssertEqual(hinted[Failover.hintKey] as? [[String]], [["🇱🇹 Литва 1", "🇱🇹 Литва 2", "LT-Vilnius"]])
        XCTAssertEqual(NSDictionary(dictionary: hinted.filter { $0.key != Failover.hintKey }), NSDictionary(dictionary: profile))
        let single: Profile = ["proxies": [["name": "A"]], "proxy-groups": [["name": "P", "type": "select", "proxies": ["A"]]]]
        XCTAssertNil(Failover.adding(to: single)[Failover.hintKey])
        XCTAssertEqual(Failover.sets([:]), [])
    }

    // MARK: the running core

    private func proxies(mainNow: String = "KS-FO-1", foNow: String = "🇱🇹 Литва 2", alive1: Bool = false,
                         alive2: Bool = true, aliveDE: Bool = true) throws -> CoreProxies {
        let json = """
        {"proxies": {
          "GLOBAL": {"type": "Selector", "now": "🚀 Выбор", "all": ["🚀 Выбор", "DIRECT"]},
          "🚀 Выбор": {"type": "Selector", "now": "\(mainNow)",
                      "all": ["⚡ Авто", "🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия", "DIRECT", "KS-FO-1"]},
          "⚡ Авто": {"type": "URLTest", "now": "🇱🇹 Литва 2", "all": ["🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия"]},
          "KS-FO-1": {"type": "Fallback", "now": "\(foNow)", "all": ["🇱🇹 Литва 1", "🇱🇹 Литва 2"], "hidden": true},
          "🇱🇹 Литва 1": {"type": "Vless", "alive": \(alive1)},
          "🇱🇹 Литва 2": {"type": "Vless", "alive": \(alive2)},
          "🇩🇪 Германия": {"type": "Vless", "alive": \(aliveDE)},
          "DIRECT": {"type": "Direct", "alive": true}
        }}
        """
        return try CoreProxies(data: Data(json.utf8), order: ["🚀 Выбор", "⚡ Авто"])
    }

    func testFailoverGroupsAreKeptApartAndNotListed() throws {
        let proxies = try proxies()
        XCTAssertEqual(proxies.failover.map(\.name), ["KS-FO-1"])
        XCTAssertEqual(proxies.mainGroup?.all, ["⚡ Авто", "🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия", "DIRECT"])
        XCTAssertFalse(ServerPicker.entries(proxies).map(\.name).contains("KS-FO-1"))
        XCTAssertFalse(proxies.servers.contains("KS-FO-1"))
        XCTAssertEqual(proxies.alive("🇱🇹 Литва 1"), false)
        XCTAssertEqual(proxies.alive("🇱🇹 Литва 2"), true)
        XCTAssertNil(proxies.alive("nope"))
    }

    func testTheCurrentServerIsTheOneTheFailoverGroupUses() throws {
        let proxies = try proxies()
        XCTAssertEqual(ServerPicker.selected(proxies), "🇱🇹 Литва 2")
        XCTAssertEqual(proxies.leaf(of: "🚀 Выбор"), "🇱🇹 Литва 2")
    }

    func testPickingAServerGoesThroughItsCountrysGroup() throws {
        let proxies = try proxies()
        let entries = ServerPicker.entries(proxies)
        let lithuania = try XCTUnwrap(entries.first { $0.name == "🇱🇹 Литва 1" })
        XCTAssertEqual(Failover.path(for: lithuania, in: proxies),
                       [.init(group: "KS-FO-1", proxy: "🇱🇹 Литва 1"), .init(group: "🚀 Выбор", proxy: "KS-FO-1")])
        let germany = try XCTUnwrap(entries.first { $0.name == "🇩🇪 Германия" })
        XCTAssertEqual(Failover.path(for: germany, in: proxies), germany.path)
        let fastest = try XCTUnwrap(entries.first(where: \.isFastest))
        XCTAssertEqual(Failover.path(for: fastest, in: proxies), fastest.path)
    }

    /// A server picked before 0.10 (or in the grouped list) is moved behind its group once.
    func testAdoption() throws {
        XCTAssertEqual(Failover.adoption(try proxies(mainNow: "🇱🇹 Литва 1")),
                       [.init(group: "KS-FO-1", proxy: "🇱🇹 Литва 1"), .init(group: "🚀 Выбор", proxy: "KS-FO-1")])
        XCTAssertNil(Failover.adoption(try proxies(mainNow: "KS-FO-1")))
        XCTAssertNil(Failover.adoption(try proxies(mainNow: "🇩🇪 Германия")))
        XCTAssertNil(Failover.adoption(try proxies(mainNow: "⚡ Авто")))
    }

    func testSwitchedWhenTheChosenServerStoppedAnswering() throws {
        XCTAssertEqual(Failover.state(chosen: "🇱🇹 Литва 1", proxies: try proxies()),
                       .switched(from: "🇱🇹 Литва 1", to: "🇱🇹 Литва 2"))
        XCTAssertEqual(Failover.state(chosen: "🇱🇹 Литва 1", proxies: try proxies(foNow: "🇱🇹 Литва 1", alive1: true)), .fine)
        XCTAssertEqual(Failover.state(chosen: "🇱🇹 Литва 2", proxies: try proxies()), .fine)
        XCTAssertEqual(Failover.state(chosen: nil, proxies: try proxies()), .fine)
    }

    /// Only within the country: when all of it is down the person is asked, not moved abroad.
    func testCountryDownWhenNoServerOfItAnswers() throws {
        XCTAssertEqual(Failover.state(chosen: "🇱🇹 Литва 1", proxies: try proxies(foNow: "🇱🇹 Литва 1", alive2: false)),
                       .countryDown(country: "Литва"))
        XCTAssertEqual(Failover.state(chosen: "🇩🇪 Германия", proxies: try proxies(mainNow: "🇩🇪 Германия", aliveDE: false)),
                       .countryDown(country: "Германия"))
        // «Самый быстрый» moves by itself across countries
        XCTAssertEqual(Failover.state(chosen: "⚡ Авто", proxies: try proxies(mainNow: "⚡ Авто", alive2: false, aliveDE: false)),
                       .fine)
    }

    // MARK: Xray: the helper switches between the subscription's hosts (ADR 0023)

    private func xray(now: String = "🇱🇹Литва 2", alive1: Bool = false, alive2: Bool = true) throws -> CoreProxies {
        let json = """
        {"proxies": {
          "Сервер": {"type": "Selector", "now": "\(now)", "all": ["🇱🇹Литва", "🇱🇹Литва 2", "🇩🇪Германия"]},
          "🇱🇹Литва": {"type": "Xray", "alive": \(alive1), "history": [{"delay": \(alive1 ? 90 : 0)}]},
          "🇱🇹Литва 2": {"type": "Xray", "alive": \(alive2), "history": [{"delay": \(alive2 ? 120 : 0)}]},
          "🇩🇪Германия": {"type": "Xray", "alive": true, "history": [{"delay": 30}]}
        }}
        """
        return try CoreProxies(data: Data(json.utf8))
    }

    func testXrayHostsCarryTheObservatorysLatency() throws {
        let proxies = try xray()
        XCTAssertEqual(proxies.delay("🇱🇹Литва 2"), 120)
        XCTAssertNil(proxies.delay("🇱🇹Литва"))
        XCTAssertEqual(proxies.alive("🇱🇹Литва"), false)
    }

    func testXraySwitchByTheHelperIsNoticed() throws {
        XCTAssertEqual(Failover.state(chosen: "🇱🇹Литва", proxies: try xray()), .switched(from: "🇱🇹Литва", to: "🇱🇹Литва 2"))
        XCTAssertEqual(Failover.state(chosen: "🇱🇹Литва 2", proxies: try xray()), .fine)
    }

    /// The helper moves within the country by itself: the person is asked only when every host of it is silent.
    func testXrayCountryDownOnlyWhenEveryHostOfItIsSilent() throws {
        XCTAssertEqual(Failover.state(chosen: "🇱🇹Литва", proxies: try xray(now: "🇱🇹Литва")), .fine)
        XCTAssertEqual(Failover.state(chosen: "🇱🇹Литва", proxies: try xray(now: "🇱🇹Литва", alive2: false)),
                       .countryDown(country: "Литва"))
    }

    func testSwitchIsShownForAnHour() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let change = Failover.Switch(from: "🇱🇹 Литва 1", to: "🇱🇹 Литва 2", at: at)
        XCTAssertTrue(change.isRecent(now: at.addingTimeInterval(3599)))
        XCTAssertFalse(change.isRecent(now: at.addingTimeInterval(3601)))
    }

    // MARK: what the person sees

    func testStatusLineTellsAboutTheSwitch() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = Status.Detail(server: "🇱🇹 Литва 2", ping: 40,
                                   switched: Failover.Switch(from: "🇱🇹 Литва 1", to: "🇱🇹 Литва 2", at: at))
        XCTAssertEqual(Status.protected.homeLine(detail),
                       "Интернет только через VPN. В \(Status.time(at)) «🇱🇹 Литва 1» перестал отвечать — переключились на «🇱🇹 Литва 2».")
        XCTAssertEqual(Status.protected.homeLine(Status.Detail(server: "🇱🇹 Литва 2")), "Интернет только через VPN")
    }

    func testNotices() {
        let switched = UserNotice.serverSwitched(from: "🇱🇹 Литва 1", to: "🇱🇹 Литва 2")
        XCTAssertEqual(switched.title, "VPN переключился на другой сервер")
        XCTAssertEqual(switched.body, "«🇱🇹 Литва 1» не отвечал. Теперь — «🇱🇹 Литва 2».")
        XCTAssertEqual(switched.setting, .connection)
        XCTAssertEqual(switched.key, UserNotice.serverSwitched(from: "x", to: "y").key, "one event for the 10-minute rule")
        let down = UserNotice.serversDown(country: "Литва")
        XCTAssertEqual(down.title, "Серверы «Литва» не отвечают")
        XCTAssertEqual(down.body, "Выбери другую страну или «Самый быстрый».")
        XCTAssertEqual(down.action, .openApp)
        XCTAssertEqual(down.setting, .connection)
    }

    func testHomeNoticeRightAfterAnotherVPN() {
        var input = HomeNotice.Input(otherVPN: true, usage: nil, newServers: true, filterIncomplete: false, filterDismissed: false,
                                     now: Date(), serversDown: "Литва")
        XCTAssertEqual(HomeNotice.pick(input), .otherVPN)
        input.otherVPN = false
        XCTAssertEqual(HomeNotice.pick(input), .serversDown(country: "Литва"))
        XCTAssertEqual(HomeNotice.serversDown(country: "Литва").title, "Серверы «Литва» не отвечают.")
        XCTAssertEqual(HomeNotice.serversDown(country: "Литва").message,
                       "Другие страны KillSwitch сам не включает: выбери страну или «Самый быстрый».")
    }
}
