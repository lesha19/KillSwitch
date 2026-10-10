import Foundation

/// The core's live connections as `ks core connections` gives them (Helper/ks core_connections):
/// per connection the program, host or address, the rule it matched, where it goes and its bytes;
/// per rule provider its size and last update.
struct CoreConnections: Decodable, Equatable, Sendable {
    struct Connection: Decodable, Equatable, Sendable, Identifiable {
        /// The core's id of the connection (random, stable while it lives).
        var id: String
        var host: String
        var ip: String
        var port: String
        var network: String
        var process: String
        var processPath: String
        /// mihomo's rule type name (`DomainSuffix`, `GeoIP`, `Match`) and its payload.
        var rule: String
        var rulePayload: String
        /// The proxies it goes through, the one that carries it first (the server, DIRECT or REJECT).
        var chains: [String]
        var upload: Int64
        var download: Int64
        var start: String

        var route: TrafficRoute { TrafficRoute(target: chains.first ?? "DIRECT") }
        /// The group the rule chose, when it is not the server itself.
        var group: String? { chains.count > 1 ? chains.last : nil }

        /// What the person recognises: the domain, else the address.
        var destination: String { host.isEmpty ? ip : host }

        var programName: String {
            if !process.isEmpty { return process }
            return processPath.split(separator: "/").last.map(String.init) ?? ""
        }

        /// The app bundle the program belongs to (for its icon): `/Applications/Safari.app`.
        var bundlePath: String? {
            guard let range = processPath.range(of: ".app/", options: .backwards) else { return nil }
            return String(processPath[..<range.lowerBound]) + ".app"
        }

        /// «Домен и поддомены: ru», «Всё остальное».
        var ruleText: String {
            let title = RoutingRule.title(type: Self.ruleType(rule))
            return rulePayload.isEmpty ? title : "\(title): \(rulePayload)"
        }

        var startDate: Date? { Self.date(start) }

        func duration(now: Date) -> TimeInterval { startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

        /// mihomo's names (`DomainSuffix`, `IPCIDR`, `GeoIP`, `RuleSet`, `ProcessName`…) as rule types.
        static func ruleType(_ name: String) -> String {
            switch name.lowercased() {
            case "domain": "DOMAIN"
            case "domainsuffix": "DOMAIN-SUFFIX"
            case "domainkeyword": "DOMAIN-KEYWORD"
            case "domainregex": "DOMAIN-REGEX"
            case "domainwildcard": "DOMAIN-WILDCARD"
            case "geosite": "GEOSITE"
            case "geoip": "GEOIP"
            case "srcgeoip": "SRC-GEOIP"
            case "ipasn": "IP-ASN"
            case "ipcidr", "ipcidr6": "IP-CIDR"
            case "srcipcidr": "SRC-IP-CIDR"
            case "ipsuffix": "IP-SUFFIX"
            case "srcport": "SRC-PORT"
            case "dstport": "DST-PORT"
            case "processname": "PROCESS-NAME"
            case "processpath": "PROCESS-PATH"
            case "processnameregex": "PROCESS-NAME-REGEX"
            case "processpathregex": "PROCESS-PATH-REGEX"
            case "network": "NETWORK"
            case "ruleset": "RULE-SET"
            case "and": "AND"
            case "or": "OR"
            case "not": "NOT"
            case "match": "MATCH"
            default: name
            }
        }

        private static func date(_ text: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            // mihomo writes nanoseconds and a zone offset: cut to milliseconds
            if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let fraction = text[text.index(after: dot)..<zone].prefix(3)
                if let date = fractional.date(from: String(text[..<dot]) + "." + fraction + String(text[zone...])) { return date }
            }
            return ISO8601DateFormatter().date(from: text)
        }
    }

    struct ProviderInfo: Decodable, Equatable, Sendable {
        var count: Int
        var updatedAt: String
    }

    var connections: [Connection]
    var uploadTotal: Int64
    var downloadTotal: Int64
    var providers: [String: ProviderInfo]

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    init(connections: [Connection] = [], uploadTotal: Int64 = 0, downloadTotal: Int64 = 0, providers: [String: ProviderInfo] = [:]) {
        self.connections = connections
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.providers = providers
    }

    /// Bytes of the open connections by where they go: the summary bar.
    var bytesByKind: [TrafficRoute.Kind: Int64] {
        connections.reduce(into: [:]) { $0[$1.route.kind, default: 0] += $1.upload + $1.download }
    }

    /// The «Соединения» list: by filter and search (program, host, address, rule, server), newest first.
    func filtered(kind: TrafficRoute.Kind?, search: String) -> [Connection] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.filter { c in
            (kind == nil || c.route.kind == kind)
                && (needle.isEmpty || [c.host, c.ip, c.programName, c.ruleText, c.rulePayload, c.route.title, c.group ?? ""]
                    .contains { $0.lowercased().contains(needle) })
        }
        .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }
}

extension TrafficRoute.Kind {
    var title: String {
        switch self {
        case .direct: String(localized: "Напрямую")
        case .vpn: "VPN"
        case .block: String(localized: "Блок")
        }
    }
}
