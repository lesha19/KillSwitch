import CryptoKit
import Foundation

/// A named routing profile the person added (ADR 0034, #30): block, through-the-VPN and direct
/// lists of sites and addresses, in the Happ/INCY routing format. Its rules go after KillSwitch's
/// own and before the subscription's; the helper checks every entry again and puts the direct ones
/// in the DIRECT signature, so a profile that sends anything past the VPN needs the admin.
struct RoutingProfile: Codable, Equatable, Identifiable, Sendable {
    struct Lists: Codable, Equatable, Sendable {
        var sites: [String] = []
        var ips: [String] = []
        var isEmpty: Bool { sites.isEmpty && ips.isEmpty }
    }

    var id = UUID()
    var name: String
    var block = Lists()
    var proxy = Lists()
    var direct = Lists()
    /// block, proxy and direct in the profile's order (RouteOrder).
    var order = ["block", "proxy", "direct"]
    /// What the source holds that KillSwitch does not take (its own DNS, geodata links, «everything
    /// else direct»…), named for the person, never applied.
    var ignored: [String] = []
    /// Where it updates from (https only); nil: added by hand.
    var url: String?
    var fetched: Date?
    /// The last update's failure, shown next to the profile.
    var error: String?

    static let maxEntries = 10_000
    static let actions = ["block", "proxy", "direct"]
    /// Updated once a day when it has a link.
    static let updateInterval: TimeInterval = 24 * 3600

    enum Problem: Error, Equatable {
        case notProfile, empty, tooMany, badEntry

        var message: String {
            switch self {
            case .notProfile: String(localized: "Это не профиль маршрутизации.")
            case .empty: String(localized: "В профиле нет ни одного правила.")
            case .tooMany: String(localized: "В профиле больше 10 000 записей.")
            case .badEntry: String(localized: "В профиле есть запись с недопустимыми символами.")
            }
        }
    }

    var sendsDirect: Bool { !direct.isEmpty }
    var count: Int { [block, proxy, direct].reduce(0) { $0 + $1.sites.count + $1.ips.count } }

    /// JSON, base64 of it, or a happ:// / incy:// routing link with it.
    static func parse(_ text: String) throws -> RoutingProfile {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = body.range(of: #"^(happ|incy)://routing/(on)?add/"#, options: [.regularExpression, .caseInsensitive]) {
            body = String(body[range.upperBound...])
        }
        let data: Data
        if body.hasPrefix("{") {
            data = Data(body.utf8)
        } else if let decoded = base64(body) {
            data = decoded
        } else {
            throw Problem.notProfile
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Problem.notProfile }
        return try parse(object)
    }

    /// Whole characters up to `scalars` code points: the helper counts code points, and a flag
    /// or an emoji with a skin tone is one character of several.
    private static func capped(_ text: String, scalars: Int) -> String {
        var out = ""
        for ch in text {
            guard out.unicodeScalars.count + ch.unicodeScalars.count <= scalars else { break }
            out.append(ch)
        }
        return out
    }

    private static func base64(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    private static func parse(_ o: [String: Any]) throws -> RoutingProfile {
        func list(_ key: String) throws -> [String] {
            guard let raw = o[key] else { return [] }
            guard let items = raw as? [Any] else { throw Problem.notProfile }
            return try items.map { item in
                guard let s = item as? String else { throw Problem.notProfile }
                let entry = s.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty, entry.utf8.count <= 256, !entry.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                    throw Problem.badEntry
                }
                return entry
            }
        }
        let rawName = (o["Name"] as? String ?? "").unicodeScalars.filter { $0.properties.generalCategory != .control }
        var name = String(String.UnicodeScalarView(rawName)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = String(localized: "Профиль") }
        var p = RoutingProfile(name: capped(name, scalars: 64))
        p.block = Lists(sites: try list("BlockSites"), ips: try list("BlockIp"))
        p.proxy = Lists(sites: try list("ProxySites"), ips: try list("ProxyIp"))
        p.direct = Lists(sites: try list("DirectSites"), ips: try list("DirectIp"))
        guard p.count > 0 else { throw Problem.empty }
        guard p.count <= maxEntries else { throw Problem.tooMany }
        if let order = o["RouteOrder"] as? String {
            let parts = order.lowercased().split(separator: "-").map(String.init)
            if parts.sorted() == actions.sorted() { p.order = parts }
        }
        var ignored: [String] = []
        if (o["GlobalProxy"] as? String)?.lowercased() == "false" || o["GlobalProxy"] as? Bool == false { ignored.append("GlobalProxy") }
        if o.keys.contains(where: { $0.hasPrefix("RemoteDNS") || $0.hasPrefix("DomesticDNS") }) { ignored.append("DNS") }
        if let hosts = o["DnsHosts"] as? [String: Any], !hosts.isEmpty { ignored.append("DnsHosts") }
        for key in ["Geoipurl", "Geositeurl"] where !((o[key] as? String) ?? "").isEmpty { ignored.append(key) }
        if !((o["DomainStrategy"] as? String) ?? "").isEmpty { ignored.append("DomainStrategy") }
        if (o["FakeDNS"] as? String)?.lowercased() == "true" || o["FakeDNS"] as? Bool == true { ignored.append("FakeDNS") }
        p.ignored = ignored
        return p
    }

    /// An https link to update from; nothing else is fetched.
    static func sourceURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// What the helper takes as "x-ks-routing" (Helper/ks routing_hint).
    var hint: [String: Any] {
        var h: [String: Any] = ["name": name, "order": order]
        for (action, lists) in [("block", block), ("proxy", proxy), ("direct", direct)] where !lists.isEmpty {
            var part: [String: [String]] = [:]
            if !lists.sites.isEmpty { part["sites"] = lists.sites }
            if !lists.ips.isEmpty { part["ips"] = lists.ips }
            h[action] = part
        }
        return h
    }

    /// The same profile with a newer body from its link.
    func updated(with new: RoutingProfile, at date: Date) -> RoutingProfile {
        var p = new
        p.id = id
        p.url = url
        p.fetched = date
        p.error = nil
        return p
    }

    func due(now: Date) -> Bool {
        guard url != nil else { return false }
        guard let fetched else { return true }
        return now.timeIntervalSince(fetched) >= Self.updateInterval
    }
}

/// Where a change of what goes past the VPN that waits for the admin comes from (review S5).
enum RoutingChangeSource: Equatable, Sendable {
    /// The subscription's DIRECT rules or DNS (or nothing of the profile).
    case subscription
    /// The profile in use sends sites direct and is not the one applied: its rules wait.
    case profile(name: String)
    /// The applied profile sent sites direct and is off now (or replaced by one that does not):
    /// its rules stay until the password.
    case profileOff
}

/// The profiles in UserDefaults and the one in use (nil: «Как в подписке»).
enum RoutingProfiles {
    static let listKey = "routingProfiles"
    static let activeKey = "routingProfileActive"
    /// The profile the core has (its hint's SHA-256, "" for none) and whether it sends sites direct.
    static let appliedKey = "routingProfileApplied"
    static let appliedDirectKey = "routingProfileAppliedDirect"

    static func fingerprint(_ routing: RoutingProfile?) -> String {
        guard let routing, let data = try? JSONSerialization.data(withJSONObject: routing.hint, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The core took a config with this profile (nil: none).
    static func recordApplied(_ routing: RoutingProfile?, _ defaults: UserDefaults = .standard) {
        defaults.set(fingerprint(routing), forKey: appliedKey)
        defaults.set(routing?.sendsDirect ?? false, forKey: appliedDirectKey)
    }

    static func changeSource(active: RoutingProfile?, _ defaults: UserDefaults = .standard) -> RoutingChangeSource {
        guard fingerprint(active) != defaults.string(forKey: appliedKey) ?? "" else { return .subscription }
        if let active, active.sendsDirect { return .profile(name: active.name) }
        return defaults.bool(forKey: appliedDirectKey) ? .profileOff : .subscription
    }

    static func load(_ defaults: UserDefaults = .standard) -> [RoutingProfile] {
        defaults.data(forKey: listKey).flatMap { try? JSONDecoder().decode([RoutingProfile].self, from: $0) } ?? []
    }

    static func save(_ list: [RoutingProfile], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(list), forKey: listKey)
    }

    static func active(_ defaults: UserDefaults = .standard) -> RoutingProfile? {
        guard let id = defaults.string(forKey: activeKey) else { return nil }
        return load(defaults).first { $0.id.uuidString == id }
    }

    static let hintKey = "x-ks-routing"

    /// The list with the profile of this id changed; unchanged when it is no longer there (a
    /// fetch's result after the wait: the list may have changed meanwhile).
    static func changing(_ id: UUID, in list: [RoutingProfile], _ change: (inout RoutingProfile) -> Void) -> [RoutingProfile] {
        list.map { p in
            guard p.id == id else { return p }
            var p = p
            change(&p)
            return p
        }
    }

    /// mihomo: the profile for the helper with "x-ks-routing" (nil: none). One the subscription
    /// brought itself is always taken out: only the person picks a profile.
    static func adding(_ routing: RoutingProfile?, to profile: Profile) -> Profile {
        var profile = profile
        profile[hintKey] = routing?.hint
        return profile
    }

    /// Xray: the hint in the panel's first config (the helper applies it to every host). One the
    /// subscription brought in any config is always taken out; with none there and none chosen the
    /// panel's bytes stay as they are.
    static func addingXray(_ routing: RoutingProfile?, to data: Data) -> Data {
        guard var array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], !array.isEmpty else { return data }
        let theirs = array.contains { ($0 as? [String: Any])?[hintKey] != nil }
        guard routing != nil || theirs else { return data }
        array = array.map { config in
            guard var c = config as? [String: Any] else { return config }
            c[hintKey] = nil
            return c
        }
        if let routing {
            guard var first = array[0] as? [String: Any] else { return data }
            first[hintKey] = routing.hint
            array[0] = first
        }
        return (try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes])) ?? data
    }
}
