import Foundation
import XCTest

final class NetworkCauseTests: XCTestCase {
    func testTheHelpersAnswerIsRead() {
        XCTAssertEqual(NetworkCause.Probe("link=1 ru=1 foreign=0\n"), NetworkCause.Probe(link: true, ru: true, foreign: false))
        XCTAssertEqual(NetworkCause.Probe("link=0 ru=0 foreign=0"), NetworkCause.Probe(link: false, ru: false, foreign: false))
        XCTAssertNil(NetworkCause.Probe(""))
        XCTAssertNil(NetworkCause.Probe("usage: ks ..."))
        XCTAssertNil(NetworkCause.Probe("link=1 ru=1"))
    }

    func testCauses() {
        func cause(_ link: Bool, _ ru: Bool, _ foreign: Bool, servers: Bool?) -> NetworkCause? {
            NetworkCause.classify(NetworkCause.Probe(link: link, ru: ru, foreign: foreign), serversAnswer: servers)
        }
        XCTAssertEqual(cause(false, false, false, servers: false), .noNetwork)
        XCTAssertEqual(cause(true, false, false, servers: false), .noInternet)
        XCTAssertEqual(cause(true, true, false, servers: false), .whitelist)
        XCTAssertEqual(cause(true, true, false, servers: nil), .whitelist)
        XCTAssertEqual(cause(true, true, true, servers: false), .serversBlocked)
        XCTAssertEqual(cause(true, false, true, servers: false), .serversBlocked)
        // the internet works and so do the servers (or we do not know): nothing to explain
        XCTAssertNil(cause(true, true, true, servers: true))
        XCTAssertNil(cause(true, true, true, servers: nil))
        // whatever the servers say, a dead network is the cause
        XCTAssertEqual(cause(true, false, false, servers: true), .noInternet)
    }

    func testServersAnswerFromTheCoresHealthChecks() throws {
        func proxies(_ a: Bool, _ b: Bool) throws -> CoreProxies {
            try CoreProxies(data: Data("""
            {"proxies": {
              "P": {"type": "Selector", "now": "A", "all": ["A", "B", "DIRECT"]},
              "A": {"type": "Vless", "alive": \(a)}, "B": {"type": "Trojan", "alive": \(b)},
              "DIRECT": {"type": "Direct", "alive": true}
            }}
            """.utf8))
        }
        XCTAssertEqual(NetworkCause.serversAnswer(try proxies(false, false)), false)
        XCTAssertEqual(NetworkCause.serversAnswer(try proxies(false, true)), true)
        XCTAssertNil(NetworkCause.serversAnswer(try CoreProxies(data: Data(#"{"proxies": {}}"#.utf8))))
    }

    func testPlainRussianWithWhatToDo() {
        for cause in [NetworkCause.noNetwork, .noInternet, .whitelist, .serversBlocked] {
            XCTAssertFalse(cause.title.isEmpty)
            XCTAssertFalse(cause.message.isEmpty)
            XCTAssertFalse(cause.message.contains("TSPU"))
        }
        XCTAssertEqual(NetworkCause.whitelist.title, "Оператор пускает только на российские сайты")
        XCTAssertTrue(NetworkCause.whitelist.message.contains("Wi‑Fi"))
        XCTAssertTrue(NetworkCause.serversBlocked.message.contains("«Самый быстрый»"))
    }

    func testTheCauseComesRightAfterAnotherVPN() {
        var input = HomeNotice.Input(otherVPN: false, usage: nil, newServers: true, filterIncomplete: false,
                                     filterDismissed: false, now: Date(), serversDown: "🇱🇹 Литва 1", networkCause: .whitelist)
        XCTAssertEqual(HomeNotice.pick(input), .network(.whitelist))
        XCTAssertEqual(HomeNotice.network(.whitelist).title, "Оператор пускает только на российские сайты.")
        input.otherVPN = true
        XCTAssertEqual(HomeNotice.pick(input), .otherVPN)
        input.otherVPN = false
        input.networkCause = nil
        XCTAssertEqual(HomeNotice.pick(input), .serversDown(server: "🇱🇹 Литва 1"))
    }

    // MARK: the chosen server's country is silent (no server is ever switched by itself, ADR 0036)

    private func proxies(now: String = "🇱🇹 Литва 1", alive1: Bool = false, alive2: Bool = true, aliveDE: Bool = true) throws -> CoreProxies {
        let json = """
        {"proxies": {
          "GLOBAL": {"type": "Selector", "now": "🚀 Выбор", "all": ["🚀 Выбор", "DIRECT"]},
          "🚀 Выбор": {"type": "Selector", "now": "\(now)", "all": ["⚡ Авто", "🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия", "DIRECT"]},
          "⚡ Авто": {"type": "URLTest", "now": "🇱🇹 Литва 2", "all": ["🇱🇹 Литва 1", "🇱🇹 Литва 2", "🇩🇪 Германия"]},
          "🇱🇹 Литва 1": {"type": "Vless", "alive": \(alive1)},
          "🇱🇹 Литва 2": {"type": "Vless", "alive": \(alive2)},
          "🇩🇪 Германия": {"type": "Vless", "alive": \(aliveDE)},
          "DIRECT": {"type": "Direct", "alive": true}
        }}
        """
        return try CoreProxies(data: Data(json.utf8), order: ["🚀 Выбор", "⚡ Авто"])
    }

    private func xray(now: String = "🇱🇹Литва", alive1: Bool = false, alive2: Bool = true) throws -> CoreProxies {
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

    /// Nothing moves off a dead server by itself any more: the person is told and picks.
    func testServerDownWhenTheChosenServerIsSilent() throws {
        XCTAssertEqual(NetworkCause.serverDown(chosen: "🇱🇹 Литва 1", proxies: try proxies()), "🇱🇹 Литва 1")
        XCTAssertNil(NetworkCause.serverDown(chosen: "🇱🇹 Литва 1", proxies: try proxies(alive1: true)))
        XCTAssertEqual(NetworkCause.serverDown(chosen: "🇩🇪 Германия", proxies: try proxies(now: "🇩🇪 Германия", aliveDE: false)), "🇩🇪 Германия")
        XCTAssertNil(NetworkCause.serverDown(chosen: "🇱🇹 Литва 1", proxies: try proxies(now: "🇩🇪 Германия")),
                     "the person picked something else since")
        XCTAssertNil(NetworkCause.serverDown(chosen: nil, proxies: try proxies()))
        // «Самый быстрый» moves by itself across countries
        XCTAssertNil(NetworkCause.serverDown(chosen: "⚡ Авто", proxies: try proxies(now: "⚡ Авто", alive2: false, aliveDE: false)))
        XCTAssertEqual(NetworkCause.serverDown(chosen: "🇱🇹Литва", proxies: try xray()), "🇱🇹 Литва")
        XCTAssertNil(NetworkCause.serverDown(chosen: "🇱🇹Литва", proxies: try xray(alive1: true)))
        XCTAssertNil(NetworkCause.serverDown(chosen: "🇱🇹Литва", proxies: try xray(now: "🇱🇹Литва 2")), "picked by the person since")
    }

    /// The owner's wording (PR #70): one server, never a country.
    func testServerDownNotices() {
        let down = UserNotice.serversDown(server: "🇱🇹 Литва 1")
        XCTAssertEqual(down.title, "Сервер «🇱🇹 Литва 1» не отвечает")
        XCTAssertEqual(down.body, "Выбери другой сервер.")
        XCTAssertEqual(down.action, .openApp)
        XCTAssertEqual(down.setting, .connection)
        XCTAssertEqual(HomeNotice.serversDown(server: "🇱🇹 Литва 1").title, "Сервер «🇱🇹 Литва 1» не отвечает.")
        XCTAssertEqual(HomeNotice.serversDown(server: "🇱🇹 Литва 1").message, "Выбери другой сервер.")
    }

    func testXrayHostsCarryTheObservatorysLatency() throws {
        let proxies = try xray(now: "🇱🇹Литва 2")
        XCTAssertEqual(proxies.delay("🇱🇹Литва 2"), 120)
        XCTAssertNil(proxies.delay("🇱🇹Литва"))
        XCTAssertEqual(proxies.alive("🇱🇹Литва"), false)
        XCTAssertNil(proxies.alive("nope"))
    }

    func testProbedAtMostOncePerMinuteAndOnlyWhenNothingAnswers() {
        let now = Date()
        XCTAssertTrue(NetworkCause.shouldProbe(serversAnswer: false, serversDown: false, last: nil, now: now))
        XCTAssertTrue(NetworkCause.shouldProbe(serversAnswer: true, serversDown: true, last: nil, now: now))
        XCTAssertFalse(NetworkCause.shouldProbe(serversAnswer: true, serversDown: false, last: nil, now: now))
        XCTAssertFalse(NetworkCause.shouldProbe(serversAnswer: nil, serversDown: false, last: nil, now: now))
        XCTAssertFalse(NetworkCause.shouldProbe(serversAnswer: false, serversDown: false, last: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(NetworkCause.shouldProbe(serversAnswer: false, serversDown: false, last: now.addingTimeInterval(-61), now: now))
    }

    /// Our servers go silent because another VPN (Happ) took the routes, not because the network
    /// or the provider blocks them: no probe, no cause (ADR 0009).
    func testNoCauseWhileAnotherVPNIsUp() {
        let now = Date()
        XCTAssertFalse(NetworkCause.shouldProbe(serversAnswer: false, serversDown: true, last: nil, now: now, otherVPN: true))
        XCTAssertTrue(NetworkCause.shouldProbe(serversAnswer: false, serversDown: true, last: nil, now: now, otherVPN: false))
    }
}
