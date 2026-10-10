import Foundation

/// Auto-failover (ADR 0005). The app names the main selector's servers by country
/// (`x-ks-failover` in the profile); the helper turns every set into a hidden mihomo `fallback`
/// group `KS-FO-<n>` that the main selector can pick. A server is picked through its country's
/// group, so when it stops answering the core itself moves to the next server of that country,
/// through the tunnel, with the kill switch untouched. Another country is never picked by itself:
/// the person is asked. «Самый быстрый» (url-test) already moves across countries.
enum Failover {
    static let prefix = "KS-FO-"
    static let hintKey = "x-ks-failover"

    static func isGroup(_ name: String) -> Bool { name.hasPrefix(prefix) }

    // MARK: profile

    /// Servers (not groups, not built-ins) of the main selector, by country flag, in its order;
    /// only countries with two or more.
    static func sets(_ profile: Profile) -> [[String]] {
        let groups = profile["proxy-groups"] as? [[String: Any]] ?? []
        guard let main = groups.first(where: { ($0["type"] as? String)?.lowercased() == "select" }) else { return [] }
        let proxies = Set((profile["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        var order: [String] = []
        var byFlag: [String: [String]] = [:]
        for case let name as String in main["proxies"] as? [Any] ?? [] where proxies.contains(name) {
            guard let flag = ServerName(name).flag else { continue }
            if byFlag[flag] == nil { order.append(flag) }
            if byFlag[flag]?.contains(name) != true { byFlag[flag, default: []].append(name) }
        }
        return order.compactMap { byFlag[$0] }.filter { $0.count >= 2 }
    }

    /// The profile with the sets for the helper (`ks core import`), unchanged without any.
    static func adding(to profile: Profile) -> Profile {
        let sets = sets(profile)
        guard !sets.isEmpty else { return profile }
        var profile = profile
        profile[hintKey] = sets
        return profile
    }

    // MARK: running core

    /// The failover group that holds `server` and that the main selector offers.
    static func group(of server: String, in proxies: CoreProxies) -> CoreProxies.Group? {
        guard let main = proxies.mainGroup else { return nil }
        return proxies.failover.first { $0.all.contains(server) && main.offers.contains($0.name) }
    }

    /// The selections that pick `entry` so that it fails over within its country: the server in
    /// its group, then the group in the main selector. Other entries keep their own path.
    static func path(for entry: ServerPicker.Entry, in proxies: CoreProxies) -> [ServerPicker.Selection] {
        guard !entry.isFastest, let main = proxies.mainGroup, entry.path == [.init(group: main.name, proxy: entry.name)],
              let group = group(of: entry.name, in: proxies) else { return entry.path }
        return [.init(group: group.name, proxy: entry.name), .init(group: main.name, proxy: group.name)]
    }

    /// The main selector points straight at a server that has a failover group (picked before
    /// 0.10, or in the grouped list): the selections that put it behind its group.
    static func adoption(_ proxies: CoreProxies) -> [ServerPicker.Selection]? {
        guard let main = proxies.mainGroup, let now = main.now, !isGroup(now),
              let group = group(of: now, in: proxies) else { return nil }
        return [.init(group: group.name, proxy: now), .init(group: main.name, proxy: group.name)]
    }

    enum State: Equatable {
        case fine
        /// The chosen server stopped answering; the core moved to another one of its country.
        case switched(from: String, to: String)
        /// No server of the chosen one's country answers.
        case countryDown(country: String)
    }

    /// `chosen`: the server the person picked last (or the last good one after a switch).
    static func state(chosen: String?, proxies: CoreProxies) -> State {
        guard let chosen, proxies.groups.first(where: { $0.name == chosen }) == nil,
              let current = ServerPicker.selected(proxies) else { return .fine }
        let members = group(of: chosen, in: proxies)?.all ?? [chosen]
        guard members.contains(current) else { return .fine }   // the person picked something else since
        if members.allSatisfy({ proxies.alive($0) == false }) {
            return .countryDown(country: ServerName(chosen).country ?? ServerName.display(chosen))
        }
        if current != chosen, proxies.alive(chosen) == false { return .switched(from: chosen, to: current) }
        return .fine
    }

    /// A switch the status line mentions for an hour.
    struct Switch: Equatable, Codable {
        var from: String
        var to: String
        var at: Date

        static let shownFor: TimeInterval = 3600

        func isRecent(now: Date) -> Bool { now.timeIntervalSince(at) < Self.shownFor }
    }
}
