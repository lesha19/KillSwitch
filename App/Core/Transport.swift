import Foundation

/// Per-server transport overrides from Settings › «Дополнительно» (ADR 0007): the uTLS client
/// fingerprint and sing-mux multiplexing, where mihomo supports them. Without an override the
/// subscription's value stays. The helper checks the same rules again (Helper/ks, x-ks-overrides).
enum Transport {
    static let hintKey = "x-ks-overrides"
    static let storeKey = "transportOverrides"
    /// mihomo's `client-fingerprint` values (meta-docs, proxies/general).
    static let fingerprints = ["chrome", "firefox", "safari", "iOS", "android", "edge", "360", "qq", "random"]
    /// `smux.protocol`; mihomo's default is h2mux.
    static let muxProtocols = ["smux", "yamux", "h2mux"]
    static let off = "off"

    /// nil fields: as in the subscription.
    struct Override: Codable, Equatable {
        var fingerprint: String?
        /// A protocol, or `Transport.off`.
        var mux: String?

        var isEmpty: Bool { fingerprint == nil && mux == nil }
    }

    struct Server: Equatable, Identifiable {
        let name: String
        let canFingerprint: Bool
        let canMux: Bool
        /// The subscription's values.
        let fingerprint: String?
        let mux: String?
        var id: String { name }
    }

    private static func canFingerprint(_ type: String) -> Bool { ["vmess", "vless", "trojan", "anytls"].contains(type) }

    /// sing-mux runs over TCP transports only and not with an XTLS flow.
    private static func canMux(_ type: String, _ proxy: [String: Any]) -> Bool {
        ["ss", "vmess", "trojan", "vless"].contains(type) && ((proxy["flow"] as? String) ?? "").isEmpty
    }

    /// The profile's servers that have something to change, in profile order.
    static func servers(_ profile: Profile) -> [Server] {
        (profile["proxies"] as? [[String: Any]] ?? []).compactMap { proxy in
            guard let name = proxy["name"] as? String else { return nil }
            let type = (proxy["type"] as? String ?? "").lowercased()
            let fp = canFingerprint(type), mux = canMux(type, proxy)
            guard fp || mux else { return nil }
            var current: String?
            if let smux = proxy["smux"] as? [String: Any] {
                current = smux["enabled"] as? Bool == true ? (smux["protocol"] as? String ?? "h2mux") : off
            }
            return Server(name: name, canFingerprint: fp, canMux: mux, fingerprint: proxy["client-fingerprint"] as? String,
                          mux: current)
        }
    }

    /// The profile for the helper, with the overrides that still apply: a server gone from the
    /// subscription or a value the helper would refuse is left out, so the import never fails on it.
    static func adding(_ overrides: [String: Override], to profile: Profile) -> Profile {
        var hint: [String: [String: Any]] = [:]
        for server in servers(profile) {
            guard let o = overrides[server.name] else { continue }
            var entry: [String: Any] = [:]
            if server.canFingerprint, let fp = o.fingerprint, fingerprints.contains(fp) { entry["client-fingerprint"] = fp }
            if server.canMux, let mux = o.mux {
                if mux == off { entry["smux"] = ["enabled": false] }
                else if muxProtocols.contains(mux) { entry["smux"] = ["enabled": true, "protocol": mux] as [String: Any] }
            }
            if !entry.isEmpty { hint[server.name] = entry }
        }
        guard !hint.isEmpty else { return profile }
        var profile = profile
        profile[hintKey] = hint
        return profile
    }

    static func encode(_ overrides: [String: Override]) -> Data? { try? JSONEncoder().encode(overrides) }

    static func decode(_ data: Data?) -> [String: Override] {
        data.flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }

    static func fingerprintTitle(_ value: String?, subscription: String?) -> String {
        value ?? "Как в подписке (\(subscription ?? "нет"))"
    }

    static func muxTitle(_ value: String?, subscription: String?) -> String {
        func name(_ v: String) -> String { v == off ? "выкл." : v }
        if let value { return value == off ? "Выкл." : value }
        return "Как в подписке (\(name(subscription ?? off)))"
    }
}
