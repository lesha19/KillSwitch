import Foundation

/// mihomo's `/proxies` answer, as returned by `ks core proxies`.
struct CoreProxies: Equatable {
    struct Group: Equatable, Identifiable {
        let name: String
        let type: String
        let now: String?
        let all: [String]
        var id: String { name }
        /// Only Selector groups take a manual choice; url-test/fallback pick by themselves.
        var selectable: Bool { type == "Selector" }
    }

    private(set) var groups: [Group] = []
    private var nowByName: [String: String] = [:]
    private var delays: [String: Int] = [:]

    static let helperDNSGroup = "KS-DNS"
    static let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]

    /// `order`: group names in profile order (mihomo's JSON object has none); unknown ones follow,
    /// selectors first.
    init(data: Data, order: [String] = []) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = root["proxies"] as? [String: [String: Any]] else {
            throw ProfileError.notAProfile
        }
        var groups: [Group] = []
        for (name, info) in proxies {
            let type = info["type"] as? String ?? ""
            if let history = info["history"] as? [[String: Any]], let last = history.last?["delay"] as? Int, last > 0 {
                delays[name] = last
            }
            guard Self.groupTypes.contains(type) else { continue }
            let now = info["now"] as? String
            if let now { nowByName[name] = now }
            if name == "GLOBAL" { continue }   // mihomo's built-in group, used only in global mode
            // the helper's DNS group (Helper/ks KS_DNS) and groups the profile hides are not server choices
            if name == Self.helperDNSGroup || info["hidden"] as? Bool == true { continue }
            groups.append(Group(name: name, type: type, now: now, all: info["all"] as? [String] ?? []))
        }
        groups.sort { a, b in
            let ia = order.firstIndex(of: a.name) ?? Int.max, ib = order.firstIndex(of: b.name) ?? Int.max
            if ia != ib { return ia < ib }
            if a.selectable != b.selectable { return a.selectable }
            return a.name < b.name
        }
        self.groups = groups
    }

    func delay(_ name: String) -> Int? { delays[name] }

    /// Follows `now` through nested groups to the actual server.
    func leaf(of name: String) -> String? {
        var current = name
        var seen: Set<String> = []
        while let next = nowByName[current], !seen.contains(next) {
            seen.insert(current)
            current = next
        }
        return current == name ? nil : current
    }

    /// Servers (not groups, not mihomo's built-ins) in group order, for «Двойной VPN».
    var servers: [String] {
        let groupNames = Set(groups.map(\.name)).union(["GLOBAL"])
        let builtIn: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]
        var result: [String] = []
        for name in groups.flatMap(\.all) where !groupNames.contains(name) && !builtIn.contains(name) && !result.contains(name) {
            result.append(name)
        }
        return result
    }

    /// The group the traffic goes through: the first selector (profile order).
    var mainGroup: Group? { groups.first(where: \.selectable) ?? groups.first }
}
