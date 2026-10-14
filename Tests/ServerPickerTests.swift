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

    /// #66: the menu bar and the home screen name the server's subscription.
    func testLabelNamesTheSubscription() {
        XCTAssertEqual(ServerPicker.label("🇱🇹 Литва", subscription: "Stork"), "🇱🇹 Литва · Stork")
        XCTAssertEqual(ServerPicker.label("🇱🇹 Литва", subscription: nil), "🇱🇹 Литва")
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
        let sections = ServerPicker.sections(entries, favourites: ["🇩🇪 Германия"], query: "", sort: .subscription, delays: [:])
        XCTAssertEqual(sections.fastest?.name, "⚡ Авто")
        XCTAssertEqual(sections.favourites.map(\.name), ["🇩🇪 Германия"])
        // a favourite is listed once, under «Избранные»
        XCTAssertEqual(sections.all.map(\.name), ["🇱🇹 Литва", "LT-Vilnius", "🇵🇱 Варшава", "Дом"])
    }

    func testSortByPingPutsSilentOnesLast() throws {
        let entries = ServerPicker.entries(try proxies())
        let delays = ["🇱🇹 Литва": 37, "🇩🇪 Германия": 48, "LT-Vilnius": 412, "Дом": CoreDelay.timeout]
        let sections = ServerPicker.sections(entries, favourites: [], query: "", sort: .ping, delays: delays)
        XCTAssertEqual(sections.all.map(\.name), ["🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "Дом", "🇵🇱 Варшава"])
    }

    func testSearchHidesTheFastestRowUnlessItMatches() throws {
        let entries = ServerPicker.entries(try proxies())
        XCTAssertNil(ServerPicker.sections(entries, favourites: [], query: "лит", sort: .subscription, delays: [:]).fastest)
    }

    /// By the name without its flag, Russian order (Cyrillic first), numbers as numbers.
    func testSortByName() throws {
        let entries = ServerPicker.entries(try proxies()) + [
            .init(name: "🇱🇹 Литва 10", title: "🇱🇹 Литва 10", path: []),
            .init(name: "🇱🇹 Литва 2", title: "🇱🇹 Литва 2", path: []),
        ]
        let sections = ServerPicker.sections(entries, favourites: ["Дом"], query: "", sort: .name, delays: [:])
        XCTAssertEqual(sections.fastest?.name, "⚡ Авто")   // stays on top
        XCTAssertEqual(sections.favourites.map(\.name), ["Дом"])
        XCTAssertEqual(sections.all.map(\.name),
                       ["🇵🇱 Варшава", "🇩🇪 Германия", "🇱🇹 Литва", "🇱🇹 Литва 2", "🇱🇹 Литва 10", "LT-Vilnius"])
    }

    /// «Недавние»: in the order used, servers of the list only, not «Самый быстрый», not while searching.
    func testRecents() throws {
        let entries = ServerPicker.entries(try proxies())
        let recents = ["Дом", "⚡ Авто", "gone", "🇩🇪 Германия"]
        let sections = ServerPicker.sections(entries, favourites: ["🇩🇪 Германия"], recents: recents, query: "",
                                             sort: .name, delays: [:])
        XCTAssertEqual(sections.recents.map(\.name), ["Дом", "🇩🇪 Германия"])
        // still in their own sections too
        XCTAssertEqual(sections.favourites.map(\.name), ["🇩🇪 Германия"])
        XCTAssertTrue(sections.all.map(\.name).contains("Дом"))
        XCTAssertEqual(ServerPicker.sections(entries, favourites: [], recents: recents, query: "дом", sort: .name, delays: [:]).recents, [])
        XCTAssertEqual(ServerPicker.sections(entries, favourites: [], query: "", sort: .name, delays: [:]).recents, [])
    }

    /// ADR 0036: one block per subscription, then «Свои серверы»; «Литва» of two subscriptions are
    /// two rows; «Недавние» and «Избранное» across the blocks, each row knowing its subscription.
    func testBlocksPerSubscription() throws {
        let stork = ServerPicker.entries(try proxies(), subscription: "s1")
        let ivpn = ServerPicker.entries(CoreProxies(xrayServers: ["🇱🇹 Литва", "🇳🇱 Нидерланды"]), subscription: "s2")
        let own = ServerPicker.entries(CoreProxies(xrayServers: ["Дом (свой)"]), subscription: ServerID.own)
        let blocks = [ServerPicker.Block(id: "s1", title: "Stork", entries: stork),
                      ServerPicker.Block(id: "s2", title: "iVPN", entries: ivpn),
                      ServerPicker.Block(id: ServerID.own, title: "Свои серверы", entries: own)]
        let lithuania = ServerID(subscription: "s2", name: "🇱🇹 Литва")
        let list = ServerPicker.list(blocks, favourites: [lithuania], recents: [ServerID(subscription: ServerID.own, name: "Дом (свой)"),
                                                                                ServerID(subscription: "s1", name: "🇱🇹 Литва")],
                                     query: "", sort: .subscription, delays: [:])
        XCTAssertEqual(list.recents.map(\.server), [ServerID(subscription: ServerID.own, name: "Дом (свой)"), ServerID(subscription: "s1", name: "🇱🇹 Литва")])
        XCTAssertEqual(list.favourites.map(\.server), [lithuania])
        XCTAssertEqual(list.blocks.map(\.title), ["Stork", "iVPN", "Свои серверы"])
        XCTAssertEqual(list.blocks[0].fastest?.name, "⚡ Авто")
        XCTAssertTrue(list.blocks[0].servers.contains { $0.name == "🇱🇹 Литва" })   // Stork's, not the favourite
        XCTAssertEqual(list.blocks[1].servers.map(\.name), ["🇳🇱 Нидерланды"])
        XCTAssertNotEqual(list.blocks[0].servers.first { $0.name == "🇱🇹 Литва" }?.id, lithuania.stored)
        // search inside every block; a block with nothing found is left out
        let found = ServerPicker.list(blocks, favourites: [], recents: [], query: "нидер", sort: .name, delays: [:])
        XCTAssertEqual(found.blocks.map(\.id), ["s2"])
        // ping order inside each block
        let byPing = ServerPicker.list(blocks, favourites: [], recents: [], query: "", sort: .ping,
                                       delays: [ServerID(subscription: "s2", name: "🇳🇱 Нидерланды"): 20,
                                                ServerID(subscription: "s1", name: "🇳🇱 Нидерланды"): 999])
        XCTAssertEqual(byPing.blocks[1].servers.map(\.name), ["🇳🇱 Нидерланды", "🇱🇹 Литва"])
    }

    func testSortBySubscriptionKeepsItsOrder() throws {
        let entries = ServerPicker.entries(try proxies())
        let delays = ["🇩🇪 Германия": 30, "🇱🇹 Литва": 90]
        XCTAssertEqual(ServerPicker.sections(entries, favourites: [], query: "", sort: .subscription, delays: delays).all.map(\.name),
                       ["🇱🇹 Литва", "🇩🇪 Германия", "LT-Vilnius", "🇵🇱 Варшава", "Дом"])
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

    /// Signal bars: three fast, two medium, one slow (≥ 400), none without an answer; nothing at
    /// all without a test (also with Xray, which has no latency test yet).
    func testPingBars() {
        XCTAssertEqual(ServerPicker.Ping(delay: 149, timedOut: false).bars, 3)
        XCTAssertEqual(ServerPicker.Ping(delay: 150, timedOut: false).bars, 2)
        XCTAssertEqual(ServerPicker.Ping(delay: 399, timedOut: false).bars, 2)
        XCTAssertEqual(ServerPicker.Ping(delay: 400, timedOut: false).bars, 1)
        XCTAssertEqual(ServerPicker.Ping(delay: nil, timedOut: true).bars, 0)
        XCTAssertNil(ServerPicker.Ping(delay: nil, timedOut: false).bars)
        XCTAssertEqual(ServerPicker.Ping.maxBars, 3)
        // VoiceOver reads the number, not the bars
        XCTAssertEqual(ServerPicker.Ping.fast(37).spoken, "37 миллисекунд")
        XCTAssertEqual(ServerPicker.Ping.unknown.spoken, "")
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

    // MARK: filter

    func testFilterOffersOnlyWhatDiffers() throws {
        let proxies = try proxies()
        let options = ServerPicker.filterOptions(ServerPicker.entries(proxies), proxies: proxies)
        XCTAssertEqual(options.countries, ["Германия", "Литва", "Польша"])   // «Дом» has none
        XCTAssertEqual(options.protocols, ["Trojan", "VLESS", "WireGuard"])
        XCTAssertEqual(options.groups, ["🚀 Выбор сервера", "Свои серверы"])
        XCTAssertFalse(options.isEmpty)

        let one = CoreProxies(profile: [
            "proxies": [["name": "🇱🇹 Литва 1", "type": "vless"], ["name": "🇱🇹 Литва 2", "type": "vless"]],
            "proxy-groups": [["name": "PROXY", "type": "select", "proxies": ["🇱🇹 Литва 1", "🇱🇹 Литва 2"]]],
        ])
        XCTAssertTrue(ServerPicker.filterOptions(ServerPicker.entries(one), proxies: one).isEmpty)
    }

    func testFilterByCountryProtocolAndGroup() throws {
        let proxies = try proxies()
        let entries = ServerPicker.entries(proxies)
        func names(_ filter: ServerPicker.Filter) -> [String] {
            ServerPicker.filtered(entries, filter, proxies: proxies).map(\.name)
        }
        XCTAssertEqual(names(.init()), entries.map(\.name))   // off: everything, «Самый быстрый» too
        XCTAssertEqual(names(.init(country: "Литва")), ["🇱🇹 Литва", "LT-Vilnius"])
        XCTAssertEqual(names(.init(protocolName: "VLESS")), ["🇱🇹 Литва", "🇩🇪 Германия", "🇵🇱 Варшава"])
        XCTAssertEqual(names(.init(group: "Свои серверы")), ["🇵🇱 Варшава", "Дом"])
        XCTAssertEqual(names(.init(country: "Литва", protocolName: "Trojan")), ["LT-Vilnius"])
        XCTAssertFalse(ServerPicker.Filter().isOn)
        XCTAssertTrue(ServerPicker.Filter(group: "Свои серверы").isOn)
    }

    func testProtocolsOfAProfileBeforeConnecting() {
        let proxies = CoreProxies(profile: [
            "proxies": [["name": "A", "type": "vless"], ["name": "B", "type": "ss"], ["name": "C", "type": "hysteria2"]],
            "proxy-groups": [["name": "PROXY", "type": "select", "proxies": ["A", "B", "C"]]],
        ])
        XCTAssertEqual(["A", "B", "C", "D"].map { proxies.protocolName(of: $0) }, ["VLESS", "Shadowsocks", "Hysteria2", nil])
    }
}
