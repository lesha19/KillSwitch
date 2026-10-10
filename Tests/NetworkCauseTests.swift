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
                                     filterDismissed: false, now: Date(), serversDown: "Литва", networkCause: .whitelist)
        XCTAssertEqual(HomeNotice.pick(input), .network(.whitelist))
        XCTAssertEqual(HomeNotice.network(.whitelist).title, "Оператор пускает только на российские сайты.")
        input.otherVPN = true
        XCTAssertEqual(HomeNotice.pick(input), .otherVPN)
        input.otherVPN = false
        input.networkCause = nil
        XCTAssertEqual(HomeNotice.pick(input), .serversDown(country: "Литва"))
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
}
