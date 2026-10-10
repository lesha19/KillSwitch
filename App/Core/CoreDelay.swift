import Foundation

/// Latency tests of the running core (`ks core delay <group|proxy>`, mihomo's
/// `GET /group/<name>/delay` or `GET /proxies/<name>/delay`).
enum CoreDelay {
    /// Stored for a server that did not answer in time.
    static let timeout = -1

    enum Failure: LocalizedError, Equatable {
        case core(String)
        case notJSON

        var errorDescription: String? {
            switch self {
            case .core(let message): "Проверка не удалась: \(message)"
            case .notJSON: "Ядро ответило непонятно."
            }
        }
    }

    /// `members`: what was tested (the group's members, or the one proxy). A group answer lists
    /// only the servers that replied; the rest, and zeros, are timeouts.
    static func parse(_ data: Data, members: [String]) throws -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        if let message = root["message"] as? String { throw Failure.core(message) }
        if members.count == 1, root.count == 1, let delay = root["delay"] as? Int {
            return [members[0]: delay > 0 ? delay : timeout]
        }
        var result: [String: Int] = [:]
        for name in members {
            let delay = root[name] as? Int ?? 0
            result[name] = delay > 0 ? delay : timeout
        }
        return result
    }

    /// Fastest first; ties keep their order; timeouts after, untested last.
    static func sorted(_ names: [String], delays: [String: Int]) -> [String] {
        func rank(_ name: String) -> Int {
            guard let delay = delays[name] else { return Int.max }
            return delay == timeout ? Int.max - 1 : delay
        }
        return names.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The member with the lowest measured delay.
    static func best(of names: [String], delays: [String: Int]) -> String? {
        names.filter { (delays[$0] ?? timeout) > 0 }.min { delays[$0]! < delays[$1]! }
    }
}
