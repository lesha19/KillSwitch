import Foundation

/// «Недавние» of the server list: the last servers chosen, newest first. Kept in UserDefaults
/// like the favourites, by server identity (ServerIdentity: type, address, port and a hash of the
/// secret, never the secret itself), or by name where there is no identity (Xray).
enum ServerRecents {
    static let key = "recentServers"
    static let limit = 5

    static func adding(_ entry: String, to stored: [String]) -> [String] {
        Array(([entry] + stored.filter { $0 != entry }).prefix(limit))
    }

    /// A chosen server by its identity when it has one; its name stored before goes.
    static func adding(name: String, keys: [String: String], to stored: [String]) -> [String] {
        adding(keys[name] ?? name, to: stored.filter { $0 != name })
    }

    /// The current names, in the stored order: a key gives the server's name now, a name stays.
    static func names(_ stored: [String], keys: [String: String]) -> [String] {
        var byKey: [String: String] = [:]
        for (name, key) in keys where byKey[key] == nil || name < byKey[key]! { byKey[key] = name }
        return stored.compactMap { $0.hasPrefix(ServerIdentity.prefix) ? byKey[$0] : $0 }
    }

    static func list(_ text: String) -> [String] { text.split(separator: "\n").map(String.init) }
    static func text(_ list: [String]) -> String { list.joined(separator: "\n") }
}
