import Foundation

/// mihomo's `/proxies` answer, as returned by `ks core proxies`.
struct CoreProxies: Equatable {
    struct Group: Equatable, Identifiable {
        let name: String
        let type: String
        let now: String?
        /// Members to show and test: without our failover groups (Failover).
        let all: [String]
        /// Every member the core offers, failover groups included.
        var offers: [String] = []
        var id: String { name }
        /// Only Selector groups take a manual choice; url-test/fallback pick by themselves.
        var selectable: Bool { type == "Selector" }
    }

    private(set) var groups: [Group] = []
    /// The helper's hidden fallback groups `KS-FO-<n>` (Failover), apart from the list.
    private(set) var failover: [Group] = []
    private var nowByName: [String: String] = [:]
    private var delays: [String: Int] = [:]
    /// The core's last health check of each proxy; true until the first one.
    private var aliveByName: [String: Bool] = [:]
    /// Each server's type as given (mihomo's «Vless», the profile's «vless»), for the filter.
    private var types: [String: String] = [:]
    /// ServerDescription of the profile's servers.
    private var descriptions: [String: String] = [:]

    static let helperDNSGroup = "KS-DNS"
    /// The one selector Helper/ks offers with Xray (XRAY_GROUP): the subscription's hosts.
    static let xrayGroup = "Сервер"
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
            if let alive = info["alive"] as? Bool { aliveByName[name] = alive }
            guard Self.groupTypes.contains(type) else {
                types[name] = type
                continue
            }
            let now = info["now"] as? String
            if let now { nowByName[name] = now }
            if name == "GLOBAL" { continue }   // mihomo's built-in group, used only in global mode
            let members = info["all"] as? [String] ?? []
            if Failover.isGroup(name) {
                failover.append(Group(name: name, type: type, now: now, all: members, offers: members))
                continue
            }
            // the helper's DNS group (Helper/ks KS_DNS) and groups the profile hides are not server choices
            if name == Self.helperDNSGroup || info["hidden"] as? Bool == true { continue }
            groups.append(Group(name: name, type: type, now: now, all: members.filter { !Failover.isGroup($0) }, offers: members))
        }
        failover.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        groups.sort { a, b in
            let ia = order.firstIndex(of: a.name) ?? Int.max, ib = order.firstIndex(of: b.name) ?? Int.max
            if ia != ib { return ia < ib }
            if a.selectable != b.selectable { return a.selectable }
            return a.name < b.name
        }
        self.groups = groups
    }

    /// The groups of a profile before the core runs it (choosing a server before connecting):
    /// profile order, no current choice, no latency.
    init(profile: Profile) {
        let types = ["select": "Selector", "url-test": "URLTest", "fallback": "Fallback", "load-balance": "LoadBalance",
                     "relay": "Relay"]
        for proxy in profile["proxies"] as? [[String: Any]] ?? [] {
            guard let name = proxy["name"] as? String else { continue }
            if let type = proxy["type"] as? String { self.types[name] = type }
            if let description = proxy[ServerDescription.key] as? String { descriptions[name] = description }
        }
        for group in profile["proxy-groups"] as? [[String: Any]] ?? [] {
            guard let name = group["name"] as? String, let type = types[(group["type"] as? String ?? "").lowercased()],
                  name != Self.helperDNSGroup, group["hidden"] as? Bool != true else { continue }
            let members = group["proxies"] as? [String] ?? []
            groups.append(Group(name: name, type: type, now: nil, all: members, offers: members))
        }
    }

    /// With Xray before the core runs: the hosts of the panel's config (XrayProfile).
    init(xrayServers: [String]) {
        groups = [Group(name: Self.xrayGroup, type: "Selector", now: nil, all: xrayServers, offers: xrayServers)]
    }

    func delay(_ name: String) -> Int? { delays[name] }

    /// The subscription's few words about the server (ServerDescription); only from a profile.
    func serverDescription(of name: String) -> String? { descriptions[name] }

    /// «VLESS», «Shadowsocks»…: the server's protocol as people know it; nil for unknown names.
    func protocolName(of name: String) -> String? {
        guard let type = types[name], !type.isEmpty else { return nil }
        return Self.protocolNames[type.lowercased()] ?? type
    }

    private static let protocolNames = [
        "vless": "VLESS", "vmess": "VMess", "trojan": "Trojan", "ss": "Shadowsocks", "shadowsocks": "Shadowsocks",
        "ssr": "ShadowsocksR", "shadowsocksr": "ShadowsocksR", "hysteria": "Hysteria", "hysteria2": "Hysteria2",
        "tuic": "TUIC", "wireguard": "WireGuard", "socks5": "SOCKS5", "http": "HTTP", "anytls": "AnyTLS",
        "snell": "Snell", "ssh": "SSH", "mieru": "Mieru", "openvpn": "OpenVPN",
    ]

    /// False once the core's health check found the proxy dead; nil for unknown names.
    func alive(_ name: String) -> Bool? { aliveByName[name] }

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
