import Foundation
import Yams

/// A mihomo profile reduced to what the helper accepts (`ks core import <file.json>`).
/// Everything else in a subscription (ports, controller, tun, dns, listeners…) is dropped here
/// and decided by the helper, so a subscription cannot open local ports or a control API.
typealias Profile = [String: Any]

enum ProfileError: LocalizedError, Equatable {
    case html
    case notAProfile
    case noProxies
    case badYAML(String)

    var errorDescription: String? {
        switch self {
        case .html: String(localized: "Сервер вернул веб-страницу вместо списка серверов. Проверь ссылку подписки.")
        case .notAProfile: String(localized: "Ответ не похож на подписку mihomo/Clash.")
        case .noProxies: String(localized: "В подписке нет ни одного сервера.")
        case .badYAML(let detail): String(localized: "Не получилось разобрать подписку: \(detail)")
        }
    }
}

enum ProfileConverter {
    /// What goes to the helper: the routing, plus the sniffer and DNS policy it validates (ADR 0013).
    static let keptKeys = ["proxies", "proxy-groups", "rules", "rule-providers", "sniffer", "dns"]

    /// Body of a subscription response: mihomo/Clash YAML, or a base64 (or plain) list of links.
    static func profile(fromSubscription body: String) throws -> Profile {
        try read(subscription: body).profile
    }

    /// What `readInBackground` hands back. A Profile is not Sendable; this one is made by the
    /// background task and owned by the caller alone once it returns.
    struct Read: @unchecked Sendable {
        let profile: Profile
        let leftOut: [String]
        /// The profile as `json` gives it (the app's cache), nil if it would not encode.
        let json: Data?
    }

    /// `read` (and `json` for the cache) on a background thread: a flat profile of ~19 MB took
    /// ~25 s to parse in a Debug build and froze the window on the main actor (#50).
    static func readInBackground(subscription body: String) async throws -> Read {
        try await Task.detached(priority: .userInitiated) {
            let (profile, leftOut) = try read(subscription: body)
            return Read(profile: profile, leftOut: leftOut, json: try? json(profile))
        }.value
    }

    /// The profile and the top-level keys of the subscription left out of it (sorted), for «Трафик».
    static func read(subscription body: String) throws -> (profile: Profile, leftOut: [String]) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") { throw ProfileError.html }
        if let links = linkList(text) {
            let proxies = links.compactMap { try? ProxyLink.parse($0) }
            guard let profile = ProfileMerger.merge(subscription: nil, manual: proxies) else { throw ProfileError.noProxies }
            return (profile, [])
        }
        let loaded: Any?
        do {
            let node = try Yams.compose(yaml: text, resolver)
            // KS-21: composing shares an alias's node; turning it into values copies it each time
            var budget = maxNodes
            if let node, !fits(node, &budget) { throw ProfileError.badYAML("too many nodes after aliases") }
            loaded = node?.any
        } catch let error as ProfileError {
            throw error
        } catch {
            throw ProfileError.badYAML(String(describing: error).prefix(200).description)
        }
        guard let map = jsonSafe(loaded) as? [String: Any] else { throw ProfileError.notAProfile }
        var profile: Profile = [:]
        for key in keptKeys { if let value = map[key] { profile[key] = value } }
        guard let proxies = profile["proxies"] as? [Any], !proxies.isEmpty else { throw ProfileError.noProxies }
        return (profile, map.keys.filter { !keptKeys.contains($0) }.sorted())
    }

    static func json(_ profile: Profile) throws -> Data {
        try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
    }

    /// Far above a real 20 MB profile, far below what nested aliases ("billion laughs") expand to.
    static let maxNodes = 4_000_000

    /// Counts the nodes as they will be expanded, stopping as soon as `budget` runs out.
    private static func fits(_ node: Node, _ budget: inout Int) -> Bool {
        budget -= 1
        guard budget >= 0 else { return false }
        switch node {
        case .scalar, .alias: return true
        case .mapping(let mapping): return mapping.allSatisfy { fits($0.key, &budget) && fits($0.value, &budget) }
        case .sequence(let sequence): return sequence.allSatisfy { fits($0, &budget) }
        }
    }

    /// mihomo reads YAML 1.2 (go-yaml v3): only true/false are booleans, no sexagesimal or
    /// timestamps. Yams' default is YAML 1.1, which would turn `password: on` into a Bool and
    /// `short-id: 12:34` into a number.
    private static let resolver: Resolver = {
        var resolver = Resolver.default
        for tag in [Tag.Name.bool, .int, .float, .timestamp] { resolver = resolver.removing(tag) }
        // swiftlint:disable:next force_try
        return try! resolver
            .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
            .appending(.int, "^(?:[-+]?[0-9]+|0x[0-9a-fA-F]+|0o[0-7]+)$")
            .appending(.float, "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$")
    }()

    /// Converts Yams output into values JSONSerialization accepts.
    private static func jsonSafe(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let map as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (key, item) in map { out[String(describing: key.base)] = jsonSafe(item) }
            return out
        case let list as [Any]: return list.map { jsonSafe($0) }
        case let bool as Bool: return bool
        case let int as Int: return int
        case let double as Double: return double.isFinite ? double : String(double)
        case let data as Data: return data.base64EncodedString()
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let string as String: return string
        case is NSNull: return NSNull()
        case let other?: return String(describing: other)
        }
    }

    /// Lines of share links, either as they are or base64 encoded (the classic subscription format).
    private static func linkList(_ text: String) -> [String]? {
        func links(in candidate: String) -> [String]? {
            let lines = candidate.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty, lines.allSatisfy({ $0.range(of: "^[a-z0-9]+://", options: .regularExpression) != nil }) else { return nil }
            return lines
        }
        if let plain = links(in: text) { return plain }
        guard let decoded = Base64.decode(text) else { return nil }
        return links(in: decoded)
    }
}

enum Base64 {
    /// Standard or URL-safe alphabet, padding optional, whitespace ignored.
    static func decode(_ text: String) -> String? {
        var clean = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !clean.isEmpty, clean.range(of: "^[A-Za-z0-9+/]+=*$", options: .regularExpression) != nil else { return nil }
        while clean.count % 4 != 0 { clean += "=" }
        guard let data = Data(base64Encoded: clean) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
