import Foundation
import XCTest

final class ServerPickerTests: XCTestCase {
    /// A Remnawave-like profile: a main selector with an auto group, countries, DIRECT and own servers.
    private let json = """
    {"proxies": {
      "GLOBAL": {"type": "Selector", "now": "🚀 Выбор сервера", "all": ["🚀 Выбор сервера", "DIRECT"]},
      "🚀 Выбор сервера": {"type": "Selector", "now": "⚡ Авто",
                           "all": ["⚡ Авто", "🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "DIRECT", "REJECT", "Свои серверы"]},
      "⚡ Авто": {"type": "URLTest", "now": "🇱🇹 Литва", "all": ["🇱🇹 Литва", "🇩🇪 Германия"], "history": [{"delay": 37}]},
      "Свои серверы": {"type": "Selector", "now": "🇵🇱 Варшава", "all": ["🇵🇱 Варшава", "Дом"]},
      "🇱🇹 Литва": {"type": "Vless", "history": [{"delay": 37}]},
      "🇩🇪 Германия": {"type": "Vless", "history": [{"delay": 48}]},
      "LT-Vilnius": {"type": "Trojan", "history": [{"delay": 412}]},
      "🇵🇱 Варшава": {"type": "Vless"},
      "Дом": {"type": "WireGuard"},
      "DIRECT": {"type": "Direct"}, "REJECT": {"type": "Reject"}
    }}
    """

    private func proxies() throws -> CoreProxies {
        try CoreProxies(data: Data(json.utf8), order: ["🚀 Выбор сервера", "⚡ Авто", "Свои серверы"])
    }

    func testFlatListFromTheMainGroup() throws {
        let entries = ServerPicker.entries(try proxies())
        XCTAssertEqual(entries.map(\.name), ["⚡ Авто", "🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "🇵🇱 Варшава", "Дом"])
    }

    func testAutoGroupIsTheFastestRow() throws {
        let fastest = try XCTUnwrap(ServerPicker.entries(try proxies()).first)
        XCTAssertTrue(fastest.isFastest)
        XCTAssertEqual(fastest.title, "Самый быстрый")
        XCTAssertEqual(fastest.path, [.init(group: "🚀 Выбор сервера", proxy: "⚡ Авто")])
    }

    func testBuiltInsAreNotServers() throws {
        let names = ServerPicker.entries(try proxies()).map(\.name)
        XCTAssertFalse(names.contains("DIRECT"))
        XCTAssertFalse(names.contains("REJECT"))
        XCTAssertFalse(names.contains("GLOBAL"))
    }

    func testOwnServersAreMarkedAndSelectedThroughTheirGroup() throws {
        let entries = ServerPicker.entries(try proxies())
        let warsaw = try XCTUnwrap(entries.first { $0.name == "🇵🇱 Варшава" })
        XCTAssertTrue(warsaw.own)
        XCTAssertEqual(warsaw.title, "🇵🇱 Варшава (свой)")
        // the inner group first, so the traffic switches once
        XCTAssertEqual(warsaw.path, [.init(group: "Свои серверы", proxy: "🇵🇱 Варшава"),
                                     .init(group: "🚀 Выбор сервера", proxy: "Свои серверы")])
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.name == "🇱🇹 Литва" }).own)
    }

    func testSelectedFollowsNestedGroups() throws {
        XCTAssertEqual(ServerPicker.selected(try proxies()), "⚡ Авто")
        let nested = json.replacingOccurrences(of: "\"now\": \"⚡ Авто\"", with: "\"now\": \"Свои серверы\"")
        XCTAssertEqual(ServerPicker.selected(try CoreProxies(data: Data(nested.utf8))), "🇵🇱 Варшава")
    }

    func testSearchByNameAndCountry() throws {
        let entries = ServerPicker.entries(try proxies())
        XCTAssertEqual(ServerPicker.search(entries, "лит").map(\.name), ["🇱🇹 Литва", "LT-Vilnius"])
        XCTAssertEqual(ServerPicker.search(entries, "ГЕРМ").map(\.name), ["🇩🇪 Германия"])
        XCTAssertEqual(ServerPicker.search(entries, "  ").count, entries.count)
        XCTAssertEqual(ServerPicker.search(entries, "быстр").map(\.name), ["⚡ Авто"])
    }

    func testSections() throws {
        let entries = ServerPicker.entries(try proxies())
        let sections = ServerPicker.sections(entries, favourites: ["🇩🇪 Германия"], query: "", sortByPing: false, delays: [:])
        XCTAssertEqual(sections.fastest?.name, "⚡ Авто")
        XCTAssertEqual(sections.favourites.map(\.name), ["🇩🇪 Германия"])
        // a favourite is listed once, under «Избранные»
        XCTAssertEqual(sections.all.map(\.name), ["🇱🇹 Литва", "LT-Vilnius", "🇵🇱 Варшава", "Дом"])
    }

    func testSortByPingPutsSilentOnesLast() throws {
        let entries = ServerPicker.entries(try proxies())
        let delays = ["🇱🇹 Литва": 37, "🇩🇪 Германия": 48, "LT-Vilnius": 412, "Дом": CoreDelay.timeout]
        let sections = ServerPicker.sections(entries, favourites: [], query: "", sortByPing: true, delays: delays)
        XCTAssertEqual(sections.all.map(\.name), ["🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "Дом", "🇵🇱 Варшава"])
    }

    func testSearchHidesTheFastestRowUnlessItMatches() throws {
        let entries = ServerPicker.entries(try proxies())
        XCTAssertNil(ServerPicker.sections(entries, favourites: [], query: "лит", sortByPing: false, delays: [:]).fastest)
    }

    func testPingWords() {
        XCTAssertEqual(ServerPicker.Ping(delay: 37, timedOut: false), .fast(37))
        XCTAssertEqual(ServerPicker.Ping(delay: 182, timedOut: false), .medium(182))
        XCTAssertEqual(ServerPicker.Ping(delay: 412, timedOut: false), .slow(412))
        XCTAssertEqual(ServerPicker.Ping(delay: nil, timedOut: true), .noAnswer)
        XCTAssertEqual(ServerPicker.Ping(delay: nil, timedOut: false), .unknown)
        XCTAssertEqual(ServerPicker.Ping.slow(412).spoken, "412 миллисекунд, медленно")
        XCTAssertEqual(ServerPicker.Ping.noAnswer.text, "нет ответа")
    }

    func testProxiesFromAProfileBeforeConnecting() throws {
        let profile: Profile = [
            "proxies": [["name": "A", "type": "vless"], ["name": "B", "type": "trojan"]],
            "proxy-groups": [
                ["name": "PROXY", "type": "select", "proxies": ["Auto", "A", "B", "DIRECT"]],
                ["name": "Auto", "type": "url-test", "proxies": ["A", "B"]],
            ],
        ]
        let proxies = CoreProxies(profile: profile)
        XCTAssertEqual(proxies.groups.map(\.name), ["PROXY", "Auto"])
        XCTAssertEqual(proxies.groups.map(\.type), ["Selector", "URLTest"])
        XCTAssertEqual(ServerPicker.entries(proxies).map(\.name), ["Auto", "A", "B"])
        XCTAssertNil(ServerPicker.selected(proxies))
    }
}
