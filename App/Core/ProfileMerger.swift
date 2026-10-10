import Foundation

/// Joins the subscription profile with servers added by hand from share links.
enum ProfileMerger {
    static let defaultGroup = "Сервер"
    static let manualGroup = "Свои серверы"

    static func merge(subscription: Profile?, manual: [[String: Any]]) -> Profile? {
        guard var profile = subscription else {
            guard !manual.isEmpty else { return nil }
            let proxies = uniqued(manual, taken: [])
            let names = proxies.compactMap { $0["name"] as? String }
            return [
                "proxies": proxies,
                "proxy-groups": [["name": defaultGroup, "type": "select", "proxies": names]],
                "rules": ["MATCH,\(defaultGroup)"],
            ]
        }
        guard !manual.isEmpty else { return profile }
        var proxies = profile["proxies"] as? [[String: Any]] ?? []
        var groups = profile["proxy-groups"] as? [[String: Any]] ?? []
        let taken = Set(proxies.compactMap { $0["name"] as? String } + groups.compactMap { $0["name"] as? String })
        let added = uniqued(manual, taken: taken)
        proxies += added
        // the first selector is where the user picks a server; the manual group becomes one of its options
        if let index = groups.firstIndex(where: { ($0["type"] as? String) == "select" }) {
            groups[index]["proxies"] = (groups[index]["proxies"] as? [String] ?? []) + [manualGroup]
        }
        groups.append(["name": manualGroup, "type": "select", "proxies": added.compactMap { $0["name"] as? String }])
        profile["proxies"] = proxies
        profile["proxy-groups"] = groups
        return profile
    }

    /// Names must be unique in a mihomo profile: clashes get " (2)", " (3)"…
    private static func uniqued(_ proxies: [[String: Any]], taken: Set<String>) -> [[String: Any]] {
        var used = taken
        return proxies.map { proxy in
            var proxy = proxy
            let base = proxy["name"] as? String ?? "Сервер"
            var name = base
            var n = 2
            while used.contains(name) { name = "\(base) (\(n))"; n += 1 }
            used.insert(name)
            proxy["name"] = name
            return proxy
        }
    }
}
