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
        var id: String { name }
    }

    static let builtIn: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"]
    static let fastestTitle = String(localized: "Самый быстрый")

    static func entries(_ proxies: CoreProxies) -> [Entry] {
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
        return result
    }

    /// The entry the traffic goes through now: the main group's choice, opened through selectors
    /// and failover groups.
    static func selected(_ proxies: CoreProxies) -> String? {
        guard let main = proxies.mainGroup, var current = main.now else { return nil }
        var seen: Set<String> = [main.name]
        // through selectors and our failover groups (the server the group uses now)
        while let group = proxies.groups.first(where: { $0.name == current && $0.selectable })
                ?? proxies.failover.first(where: { $0.name == current }),
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

        /// 0…1 for the signal bars: three for fast, two for medium, one for slow.
        var bars: Double? {
            switch self {
            case .fast: 1
            case .medium: 0.67
            case .slow: 0.34
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
