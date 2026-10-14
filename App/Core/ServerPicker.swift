import Foundation

/// «Выбор сервера» (spec §5.2): one flat list of countries from the main selector group instead of
/// the profile's groups. An auto (URLTest) group in it becomes «Самый быстрый»; nested selector
/// groups (own servers) are opened up; mihomo's built-ins are not servers.
enum ServerPicker {
    /// One `ks core select <group> <proxy>`.
    struct Selection: Codable, Equatable {
        var group: String
        var proxy: String
    }

    struct Entry: Codable, Equatable, Identifiable {
        /// What the core calls it (a server, or the auto group for «Самый быстрый»).
        var name: String
        var title: String
        var isFastest = false
        /// Added by hand («Свои серверы»).
        var own = false
        /// The selections that make this entry current, innermost group first.
        var path: [Selection]
        /// Whose server it is (Subscription.id, or ServerID.own).
        var subscription = ServerID.own
        var server: ServerID { ServerID(subscription: subscription, name: name) }
        var id: String { server.stored }
    }

    static let builtIn: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
    static let fastestTitle = String(localized: "Самый быстрый")

    /// `subscription`: whose servers they are (ADR 0036).
    static func entries(_ proxies: CoreProxies, subscription: String = ServerID.own) -> [Entry] {
        guard let main = proxies.mainGroup else { return [] }
        let groups = Dictionary(proxies.groups.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Entry] = []
        var hasFastest = false

        func add(_ member: String, through path: [Selection], own: Bool, seen: Set<String>) {
            guard !builtIn.contains(member), !result.contains(where: { $0.name == member }) else { return }
            if let group = groups[member] {
                if group.selectable {
                    guard !seen.contains(member) else { return }
                    for inner in group.all {
                        add(inner, through: [Selection(group: member, proxy: inner)] + path,
                            own: own || member == ProfileMerger.manualGroup, seen: seen.union([member]))
                    }
                    return
                }
                if group.type == "URLTest" && !hasFastest {
                    hasFastest = true
                    result.insert(Entry(name: member, title: fastestTitle, isFastest: true, path: path), at: 0)
                    return
                }
            }
            let title = ServerName.display(member) + (own ? String(localized: " (свой)") : "")
            result.append(Entry(name: member, title: title, own: own, path: path))
        }

        for member in main.all {
            add(member, through: [Selection(group: main.name, proxy: member)], own: false, seen: [main.name])
        }
        return result.map { var entry = $0; entry.subscription = subscription; return entry }
    }

    /// The entry the traffic goes through now: the main group's choice, opened through selectors.
    static func selected(_ proxies: CoreProxies) -> String? {
        guard let main = proxies.mainGroup, var current = main.now else { return nil }
        var seen: Set<String> = [main.name]
        while let group = proxies.groups.first(where: { $0.name == current && $0.selectable }),
              let next = group.now, !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    /// Case-insensitive, by the name and by the country in Russian («лит» finds LT-Vilnius).
    static func search(_ entries: [Entry], _ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = [entry.title, entry.name, ServerName(entry.name).country ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// «Фильтр» of the list: by country, protocol and the subscription's group; nil = any.
    struct Filter: Equatable {
        var country: String?
        var protocolName: String?
        var group: String?

        var isOn: Bool { country != nil || protocolName != nil || group != nil }
    }

    /// What the filter offers: each kind only when the list has two or more of it.
    struct FilterOptions: Equatable {
        var countries: [String]
        var protocols: [String]
        var groups: [String]

        var isEmpty: Bool { countries.isEmpty && protocols.isEmpty && groups.isEmpty }
    }

    static func filterOptions(_ entries: [Entry], proxies: CoreProxies) -> FilterOptions {
        let servers = entries.filter { !$0.isFastest }
        func distinct(_ values: [String?]) -> [String] {
            var result: [String] = []
            for value in values.compactMap({ $0 }) where !result.contains(value) { result.append(value) }
            return result.count > 1 ? result : []
        }
        let russian = Locale(identifier: "ru_RU")
        return FilterOptions(
            countries: distinct(servers.map { ServerName($0.name).country })
                .sorted { $0.compare($1, locale: russian) == .orderedAscending },
            protocols: distinct(servers.map { proxies.protocolName(of: $0.name) }).sorted(),
            groups: distinct(servers.map(\.path.first?.group)))
    }

    /// The servers the filter lets through; with it on, «Самый быстрый» is not one of them.
    static func filtered(_ entries: [Entry], _ filter: Filter, proxies: CoreProxies) -> [Entry] {
        guard filter.isOn else { return entries }
        return entries.filter { entry in
            !entry.isFastest
                && (filter.country == nil || ServerName(entry.name).country == filter.country)
                && (filter.protocolName == nil || proxies.protocolName(of: entry.name) == filter.protocolName)
                && (filter.group == nil || entry.path.first?.group == filter.group)
        }
    }

    struct Sections: Equatable {
        var fastest: Entry?
        /// The last chosen servers (ServerRecents), also listed in their own section.
        var recents: [Entry] = []
        var favourites: [Entry]
        var all: [Entry]
    }

    /// «Порядок» of the list: as the subscription lists them, fastest first, or by name.
    enum Sort: String, CaseIterable {
        case subscription, ping, name

        var title: String {
            switch self {
            case .subscription: String(localized: "Как в подписке")
            case .ping: String(localized: "По пингу")
            case .name: String(localized: "По имени")
            }
        }
    }

    static func sections(_ entries: [Entry], favourites: Set<String>, recents: [String] = [], query: String, sort: Sort,
                         delays: [String: Int]) -> Sections {
        let found = search(entries, query)
        var servers = found.filter { !$0.isFastest }
        switch sort {
        case .subscription: break
        case .ping:
            let order = CoreDelay.sorted(servers.map(\.name), delays: delays)
            servers.sort { order.firstIndex(of: $0.name)! < order.firstIndex(of: $1.name)! }
        case .name:
            // without the flag, Russian order whatever the Mac's language, «Литва 2» before «Литва 10»
            let russian = Locale(identifier: "ru_RU")
            servers = servers.enumerated().sorted { a, b in
                let order = ServerName.spoken(a.element.name).compare(ServerName.spoken(b.element.name),
                                                                       options: [.caseInsensitive, .numeric], locale: russian)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }.map(\.element)
        }
        let byName = Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Sections(fastest: found.first(where: \.isFastest),
                        recents: query.trimmingCharacters(in: .whitespaces).isEmpty ? recents.compactMap { byName[$0] } : [],
                        favourites: servers.filter { favourites.contains($0.name) },
                        all: servers.filter { !favourites.contains($0.name) })
    }

    /// «🇱🇹 Литва · Stork»: the menu bar and the home screen name the server's subscription (#66).
    static func label(_ server: String, subscription: String?) -> String {
        subscription.map { "\(server) · \($0)" } ?? server
    }

    /// One block of the list (ADR 0036): a subscription's servers, or «Свои серверы».
    struct Block: Codable, Equatable, Identifiable {
        /// Subscription.id, or ServerID.own.
        var id: String
        var title: String
        var entries: [Entry]
    }

    struct List: Equatable {
        struct Block: Equatable, Identifiable {
            var id: String
            var title: String
            var fastest: Entry?
            var servers: [Entry]
        }

        var recents: [Entry]
        var favourites: [Entry]
        var blocks: [Block]
    }

    /// The whole list: «Недавние» and «Избранное» across the blocks, then each block searched and
    /// sorted as `sections` does it; a favourite is listed under «Избранное» only; a block where
    /// nothing was found is left out. `delays` by server, of the blocks whose ping is known.
    static func list(_ blocks: [Block], favourites: Set<ServerID>, recents: [ServerID], query: String, sort: Sort,
                     delays: [ServerID: Int]) -> List {
        var result = List(recents: [], favourites: [], blocks: [])
        var recent: [ServerID: Entry] = [:]
        for block in blocks {
            let names = { (servers: [ServerID]) in servers.filter { $0.subscription == block.id }.map(\.name) }
            let ping = Dictionary(delays.filter { $0.key.subscription == block.id }.map { ($0.key.name, $0.value) }, uniquingKeysWith: { a, _ in a })
            let sections = sections(block.entries, favourites: Set(names(Array(favourites))), recents: names(recents),
                                    query: query, sort: sort, delays: ping)
            for entry in sections.recents { recent[entry.server] = entry }
            result.favourites += sections.favourites
            guard sections.fastest != nil || !sections.all.isEmpty else { continue }
            result.blocks.append(.init(id: block.id, title: block.title, fastest: sections.fastest, servers: sections.all))
        }
        result.recents = recents.compactMap { recent[$0] }
        return result
    }

    /// A latency as words and a mark, never as colour alone (spec §9.3).
    enum Ping: Equatable {
        case fast(Int), medium(Int), slow(Int), noAnswer, unknown

        static let slowFrom = 400
        static let mediumFrom = 150

        init(delay: Int?, timedOut: Bool) {
            if let delay {
                self = delay >= Self.slowFrom ? .slow(delay) : delay >= Self.mediumFrom ? .medium(delay) : .fast(delay)
            } else {
                self = timedOut ? .noAnswer : .unknown
            }
        }

        var text: String {
            switch self {
            case .fast(let ms), .medium(let ms), .slow(let ms): String(localized: "\(ms) мс")
            case .noAnswer: String(localized: "нет ответа")
            case .unknown: ""
            }
        }

        var spoken: String {
            switch self {
            case .fast(let ms), .medium(let ms): String(localized: "\(ms) миллисекунд")
            case .slow(let ms): String(localized: "\(ms) миллисекунд, медленно")
            case .noAnswer: String(localized: "не отвечает")
            case .unknown: ""
            }
        }

        static let maxBars = 3

        /// Signal bars lit: three for fast, two for medium, one for slow, none without an answer;
        /// nil (nothing drawn) while there is no test result.
        var bars: Int? {
            switch self {
            case .fast: 3
            case .medium: 2
            case .slow: 1
            case .noAnswer: 0
            case .unknown: nil
            }
        }
    }
}

extension ServerName {
    /// «🇱🇹 Литва»; a name that brings its own emoji keeps it, without a 🌐 in front.
    static func display(_ name: String) -> String {
        let parts = ServerName(name)
        guard let flag = parts.flag else { return name }
        return "\(flag) \(parts.title.isEmpty ? parts.country ?? name : parts.title)"
    }
}
