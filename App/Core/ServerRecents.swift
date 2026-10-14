import Foundation

/// «Недавние» of the server list: the last servers chosen, newest first. Kept in UserDefaults
/// like the favourites, as (subscription, server) lines (ServerID.stored) whose server is its
/// identity (ServerIdentity: type, address, port and a hash of the secret, never the secret
/// itself), or its name where there is no identity (Xray). The favourites use the same lines.
enum ServerRecents {
    static let key = Subscriptions.recentsKey
    static let limit = 5

    static func adding(_ entry: String, to stored: [String]) -> [String] {
        Array(([entry] + stored.filter { $0 != entry }).prefix(limit))
    }

    /// A chosen server by its identity when it has one (`keys`: its subscription's name → key);
    /// its line by name stored before goes.
    static func adding(_ server: ServerID, keys: [String: String], to stored: [String]) -> [String] {
        adding(line(server, keys: keys), to: stored.filter { $0 != server.stored })
    }

    /// «Избранное»: adds the server, or takes it out (by identity or by name).
    static func toggled(_ server: ServerID, keys: [String: String], in stored: [String]) -> [String] {
        let line = line(server, keys: keys)
        if stored.contains(line) || stored.contains(server.stored) { return stored.filter { $0 != line && $0 != server.stored } }
        return stored + [line]
    }

    /// The servers now, in the stored order (`keys`: per subscription, name → key): a key gives the
    /// server's name now, a name stays; a key no longer in its subscription and an unreadable line
    /// are left out.
    static func servers(_ stored: [String], keys: [String: [String: String]]) -> [ServerID] {
        var names: [String: [String: String]] = [:]
        for (subscription, byName) in keys {
            for (name, key) in byName where names[subscription]?[key] == nil || name < names[subscription]![key]! {
                names[subscription, default: [:]][key] = name
            }
        }
        return stored.compactMap(ServerID.init(stored:)).compactMap { server in
            guard server.name.hasPrefix(ServerIdentity.prefix) else { return server }
            return names[server.subscription]?[server.name].map { ServerID(subscription: server.subscription, name: $0) }
        }
    }

    private static func line(_ server: ServerID, keys: [String: String]) -> String {
        ServerID(subscription: server.subscription, name: keys[server.name] ?? server.name).stored
    }

    static func list(_ text: String) -> [String] { text.split(separator: "\n").map(String.init) }
    static func text(_ list: [String]) -> String { list.joined(separator: "\n") }
}
