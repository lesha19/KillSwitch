import CryptoKit
import Foundation

/// A server's identity that survives a rename in the subscription: type, address, port and a
/// hash of its secret (uuid, password or key), never the secret itself. Per-server settings
/// (transport overrides, favourites) are kept under it; before 0.13 they were kept by name and
/// are moved over once the server is in the profile (`migrate`).
enum ServerIdentity {
    static let prefix = "id:"

    /// `id:<type>|<server>|<port>|<16 hex of sha256(secret)>`; nil for what is not a server.
    static func key(_ proxy: [String: Any]) -> String? {
        let peer = (proxy["peers"] as? [[String: Any]])?.first
        guard let type = (proxy["type"] as? String)?.lowercased(), !type.isEmpty,
              let server = (proxy["server"] as? String) ?? (peer?["server"] as? String), !server.isEmpty else { return nil }
        let port = text(proxy["port"]) ?? text(peer?["port"]) ?? ""
        let secret = ["uuid", "password", "private-key", "auth-str", "psk", "key"].lazy.compactMap { proxy[$0] as? String }.first ?? ""
        let hash = SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)\(type)|\(server.lowercased())|\(port)|\(hash)"
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let int as Int: String(int)
        case let string as String: string
        default: nil
        }
    }

    /// Server name → key, for the profile's proxies.
    static func keys(_ profile: Profile) -> [String: String] {
        var result: [String: String] = [:]
        for proxy in profile["proxies"] as? [[String: Any]] ?? [] {
            if let name = proxy["name"] as? String, let key = key(proxy), result[name] == nil { result[name] = key }
        }
        return result
    }

    /// Name-keyed entries of servers in the profile move to their key; a value already under the
    /// key wins; anything else stays.
    static func migrate<Value>(_ stored: [String: Value], keys: [String: String]) -> [String: Value] {
        var result: [String: Value] = [:]
        for (name, value) in stored where !name.hasPrefix(prefix) {
            result[keys[name] ?? name] = value
        }
        for (key, value) in stored where key.hasPrefix(prefix) { result[key] = value }
        return result
    }

    /// The same for a list, in its order, without duplicates.
    static func migrate(_ stored: [String], keys: [String: String]) -> [String] {
        var result: [String] = []
        for entry in stored {
            let moved = entry.hasPrefix(prefix) ? entry : keys[entry] ?? entry
            if !result.contains(moved) { result.append(moved) }
        }
        return result
    }

    /// The current names of stored entries: a key gives the server's name now, a name stays.
    static func names(_ stored: [String], keys: [String: String]) -> Set<String> {
        var byKey: [String: [String]] = [:]
        for (name, key) in keys { byKey[key, default: []].append(name) }
        return Set(stored.flatMap { $0.hasPrefix(prefix) ? byKey[$0] ?? [] : [$0] })
    }
}
