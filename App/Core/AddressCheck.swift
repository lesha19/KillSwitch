import Foundation

/// «Проверить адрес»: which rule of the config a site or an address would meet first and where it
/// goes. mihomo has no API for this, so the rules are walked here, in their order, for an ordinary
/// visit: TCP to port 443 from some program. Whatever cannot be told here (which program, a rule set
/// downloaded by the core, the address a name will resolve to) is not guessed: such a rule is
/// listed as a caveat and the walk goes on, so the answer says honestly what it rests on.
enum AddressCheck {
    /// What was typed: a host name or an address (a URL, a port or a path are cut off).
    struct Target: Equatable {
        var host: String?
        var ip: String?

        init?(_ text: String) {
            var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let scheme = t.range(of: "://") { t = String(t[scheme.upperBound...]) }
            if let slash = t.firstIndex(where: { "/?#".contains($0) }) { t = String(t[..<slash]) }
            if let at = t.lastIndex(of: "@") { t = String(t[t.index(after: at)...]) }
            if t.hasPrefix("["), let end = t.firstIndex(of: "]") {
                t = String(t[t.index(after: t.startIndex)..<end])
            } else if t.filter({ $0 == ":" }).count == 1, let colon = t.firstIndex(of: ":") {
                t = String(t[..<colon])
            }
            while t.hasSuffix(".") { t.removeLast() }
            guard !t.isEmpty, t.count <= 253 else { return nil }
            if IPv4(t) != nil || (t.contains(":") && t.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })) {
                host = nil; ip = t
            } else if t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }), t.contains(".") || t == "localhost" {
                host = t; ip = nil
            } else {
                return nil
            }
        }
    }

    enum Verdict: Equatable {
        case yes, no
        case unknown(String)
    }

    struct Caveat: Equatable {
        var position: Int
        var rule: String
        var reason: String
    }

    struct Result: Equatable {
        /// Position in the config's rules of the first rule that surely matches (nil: none, the core
        /// then sends it DIRECT, mihomo's default).
        var position: Int?
        var rule: String?
        var route: TrafficRoute
        /// Rules before it that might match too, with why it is unknown.
        var caveats: [Caveat]
        var isExact: Bool { caveats.isEmpty }
    }

    struct Context {
        var providers: [RoutingReport.Provider]
        var geosite: (_ category: String, _ host: String) -> Bool?
        var geoip: (_ ip: String, _ country: String) -> Bool?
    }

    static func check(_ target: Target, rules: [String], context: Context) -> Result {
        var caveats: [Caveat] = []
        for (position, text) in rules.enumerated() {
            guard let rule = RoutingRule(text) else { continue }
            switch evaluate(rule, target, context) {
            case .yes: return Result(position: position, rule: text, route: rule.route, caveats: caveats)
            case .no: continue
            case .unknown(let reason): caveats.append(Caveat(position: position, rule: text, reason: reason))
            }
        }
        return Result(position: nil, rule: nil, route: .direct, caveats: caveats)
    }

    static func evaluate(_ rule: RoutingRule, _ target: Target, _ context: Context, depth: Int = 0) -> Verdict {
        guard depth < 8 else { return .unknown(String(localized: "слишком глубоко вложенное правило")) }
        let payload = rule.payload
        switch rule.type {
        case "MATCH":
            return .yes
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD":
            guard let host = target.host else { return .no }
            return domain(rule.type, payload.lowercased(), host) ? .yes : .no
        case "GEOSITE":
            guard let host = target.host else { return .no }
            guard let found = context.geosite(payload, host) else {
                return .unknown(String(localized: "категорию сайтов здесь не проверить"))
            }
            return found ? .yes : .no
        case "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "GEOIP", "IP-ASN":
            guard let ip = target.ip else {
                return rule.noResolve ? .no : .unknown(String(localized: "ядро узнает адрес сайта и сверит его с этим правилом"))
            }
            switch rule.type {
            case "GEOIP":
                if payload.uppercased() == "LAN" { return IPv4(ip)?.isPrivate == true ? .yes : .no }
                guard let found = context.geoip(ip, payload) else { return .unknown(String(localized: "страну адреса здесь не проверить")) }
                return found ? .yes : .no
            case "IP-ASN":
                return .unknown(String(localized: "сеть (ASN) здесь не проверить"))
            default:
                guard let inside = cidr(payload, contains: ip) else { return .unknown(String(localized: "адрес IPv6 здесь не проверить")) }
                return inside ? .yes : .no
            }
        case "DST-PORT":
            return ports(payload, contain: 443) ? .yes : .no
        case "NETWORK":
            return payload.lowercased() == "tcp" ? .yes : .no
        case "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX", "PROCESS-NAME-WILDCARD",
             "PROCESS-PATH-WILDCARD", "UID":
            return .unknown(String(localized: "зависит от программы"))
        case "RULE-SET":
            return ruleSet(payload, target, context, depth: depth)
        case "AND", "OR", "NOT":
            let parts = rule.conditions.map { evaluate($0, target, context, depth: depth + 1) }
            guard !parts.isEmpty else { return .unknown(String(localized: "не удалось разобрать условия")) }
            let unknown = parts.first { if case .unknown = $0 { true } else { false } }
            switch rule.type {
            case "AND":
                if parts.contains(.no) { return .no }
                return unknown ?? .yes
            case "OR":
                if parts.contains(.yes) { return .yes }
                return unknown ?? .no
            default:
                if let unknown { return unknown }
                return parts.first == .yes ? .no : .yes
            }
        default:
            return .unknown(String(localized: "правило зависит от подробностей соединения"))
        }
    }

    // MARK: Xray (ADR 0027)

    /// With Xray: the report's rule objects in order, for the same ordinary visit (TCP to 443 from
    /// some program, into our TUN, sniffed as TLS). All conditions of a rule must hold; a list
    /// holds when one entry does. What no rule takes goes to Xray's first outbound (`fallback`).
    static func check(_ target: Target, report: RoutingReport, context: Context) -> Result {
        var caveats: [Caveat] = []
        for (position, rule) in report.rules.enumerated() {
            guard let object = rule.xray else { continue }
            switch evaluate(xray: object, target, context) {
            case .no: continue
            case .unknown(let reason): caveats.append(Caveat(position: position, rule: rule.rule, reason: reason))
            case .yes:
                let tag = object["outboundTag"]?.strings.first ?? object["balancerTag"]?.strings.first ?? ""
                if case .string = object["balancerTag"] ?? .null,
                   report.groups.first(where: { $0.name == tag })?.proxies.contains(where: { report.xrayRoute($0) == .direct }) == true {
                    caveats.append(Caveat(position: position, rule: rule.rule,
                                          reason: String(localized: "этот балансировщик может выбрать и «напрямую»")))
                }
                return Result(position: position, rule: rule.rule, route: report.xrayRoute(tag), caveats: caveats)
            }
        }
        return Result(position: nil, rule: nil, route: report.xrayRoute(report.fallback ?? ""), caveats: caveats)
    }

    static func evaluate(xray rule: [String: JSONValue], _ target: Target, _ context: Context) -> Verdict {
        var unknown: Verdict?
        for key in rule.keys.sorted() {
            let value = rule[key]!
            let verdict: Verdict
            switch key {
            case "outboundTag", "balancerTag", "ruleTag", "type", "domainMatcher":
                continue
            case "domain", "domains":
                verdict = any(value.strings) { xrayDomain($0, target, context) }
            case "ip":
                verdict = any(value.strings) { xrayIP($0, target, context) }
            case "port":
                verdict = ports(value.text.replacingOccurrences(of: " ", with: ""), contain: 443) ? .yes : .no
            case "network":
                verdict = value.text.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "tcp" } ? .yes : .no
            case "inboundTag":
                verdict = value.strings.contains("ks-tun") ? .yes : .no
            case "protocol":
                verdict = value.strings.contains("tls") ? .yes : .no
            case "user":
                verdict = .no   // our TUN has no users
            case "process":
                verdict = .unknown(String(localized: "зависит от программы"))
            default:
                verdict = .unknown(String(localized: "правило зависит от подробностей соединения"))
            }
            if verdict == .no { return .no }
            if case .unknown = verdict { unknown = unknown ?? verdict }
        }
        return unknown ?? .yes
    }

    private static func any(_ entries: [String], _ match: (String) -> Verdict) -> Verdict {
        var unknown: Verdict?
        for entry in entries {
            switch match(entry) {
            case .yes: return .yes
            case .no: continue
            case .unknown(let reason): unknown = unknown ?? .unknown(reason)
            }
        }
        return unknown ?? .no
    }

    /// `domain:` (and below), `full:`, `keyword:` or a bare word (a part of the name), `regexp:`,
    /// `geosite:`; a list from a file (`ext:`) is not visible here.
    static func xrayDomain(_ entry: String, _ target: Target, _ context: Context) -> Verdict {
        guard let host = target.host else { return .no }
        let (kind, value) = prefixed(entry)
        switch kind {
        case "domain": return domain("DOMAIN-SUFFIX", value.lowercased(), host) ? .yes : .no
        case "full": return host == value.lowercased() ? .yes : .no
        case "keyword", "": return host.contains(value.lowercased()) ? .yes : .no
        case "regexp": return host.range(of: value, options: .regularExpression) != nil ? .yes : .no
        case "dotless": return !host.contains(".") && host.contains(value.lowercased()) ? .yes : .no
        case "geosite":
            guard !value.hasPrefix("!"), let found = context.geosite(value, host) else {
                return .unknown(String(localized: "категорию сайтов здесь не проверить"))
            }
            return found ? .yes : .no
        default: return .unknown(String(localized: "список сайтов из файла здесь не проверить"))
        }
    }

    /// An address or network, `geoip:<country>`, `geoip:!<country>`, `geoip:private`; a name is
    /// sent to the address it resolves to, which is not known here.
    static func xrayIP(_ entry: String, _ target: Target, _ context: Context) -> Verdict {
        guard let ip = target.ip else { return .unknown(String(localized: "ядро узнает адрес сайта и сверит его с этим правилом")) }
        let (kind, value) = prefixed(entry)
        switch kind {
        case "":
            guard let inside = cidr(value, contains: ip) else { return .unknown(String(localized: "адрес IPv6 здесь не проверить")) }
            return inside ? .yes : .no
        case "geoip":
            let negated = value.hasPrefix("!")
            let country = negated ? String(value.dropFirst()) : value
            let found: Bool?
            if country.lowercased() == "private" { found = IPv4(ip).map(\.isPrivate) } else { found = context.geoip(ip, country) }
            guard let found else { return .unknown(String(localized: "страну адреса здесь не проверить")) }
            return found != negated ? .yes : .no
        default: return .unknown(String(localized: "список адресов из файла здесь не проверить"))
        }
    }

    /// `kind:value`; a bare value has kind "" (an IPv6 address is bare too).
    private static func prefixed(_ entry: String) -> (String, String) {
        guard let colon = entry.firstIndex(of: ":") else { return ("", entry) }
        let kind = entry[..<colon].lowercased()
        guard ["domain", "full", "keyword", "regexp", "geosite", "geoip", "ext", "dotless"].contains(kind) else { return ("", entry) }
        return (kind, String(entry[entry.index(after: colon)...]))
    }

    // MARK: matching

    static func domain(_ type: String, _ value: String, _ host: String) -> Bool {
        switch type {
        case "DOMAIN": host == value
        case "DOMAIN-SUFFIX": host == value || host.hasSuffix("." + value)
        case "DOMAIN-KEYWORD": host.contains(value)
        case "DOMAIN-REGEX": host.range(of: value, options: .regularExpression) != nil
        default: wildcard(value, host)
        }
    }

    /// `*` any run of characters, `?` one character.
    static func wildcard(_ pattern: String, _ host: String) -> Bool {
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
        return host.range(of: regex, options: .regularExpression) != nil
    }

    /// A domain-set entry of a rule provider: `+.x` (x and below), `.x` (below), `*.x` (one level), `x`.
    static func domainSet(_ entry: String, _ host: String) -> Bool {
        let e = entry.lowercased()
        if e.hasPrefix("+.") { let s = String(e.dropFirst(2)); return host == s || host.hasSuffix("." + s) }
        if e.hasPrefix(".") { return host.hasSuffix(e) }
        if e.contains("*") { return wildcard(e, host) }
        return host == e
    }

    static func cidr(_ network: String, contains ip: String) -> Bool? {
        let parts = network.split(separator: "/")
        guard let address = IPv4(ip) else { return nil }
        guard let base = IPv4(String(parts.first ?? "")) else { return network.contains(":") ? nil : false }
        let bits = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
        guard (0...32).contains(bits) else { return false }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return address.value & mask == base.value & mask
    }

    /// `443`, `80/443`, `8000-9000`, `80,443` (mihomo takes "/" between ports).
    static func ports(_ list: String, contain port: Int) -> Bool {
        list.split(whereSeparator: { $0 == "/" || $0 == "," }).contains { part in
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2 { return (bounds[0]...max(bounds[0], bounds[1])).contains(port) }
            return bounds.first == port
        }
    }

    private static func ruleSet(_ name: String, _ target: Target, _ context: Context, depth: Int) -> Verdict {
        guard let provider = context.providers.first(where: { $0.name == name }) else { return .no }
        guard let payload = provider.payload, provider.type == "inline" else {
            return .unknown(String(localized: "набор «\(name)» ядро скачивает само, его содержимое здесь не видно"))
        }
        if (provider.count ?? payload.count) > payload.count {
            return .unknown(String(localized: "набор «\(name)» здесь виден не целиком"))
        }
        switch provider.behavior ?? "classical" {
        case "domain":
            guard let host = target.host else { return .no }
            return payload.contains { domainSet($0, host) } ? .yes : .no
        case "ipcidr":
            guard let ip = target.ip else { return .unknown(String(localized: "ядро узнает адрес сайта и сверит его с набором")) }
            return payload.contains { cidr($0, contains: ip) == true } ? .yes : .no
        default:
            var unknown: Verdict?
            for line in payload {
                guard let rule = RoutingRule.condition(line) else { continue }
                switch evaluate(rule, target, context, depth: depth + 1) {
                case .yes: return .yes
                case .no: continue
                case .unknown(let reason): unknown = unknown ?? .unknown(reason)
                }
            }
            return unknown ?? .no
        }
    }
}

/// An IPv4 address as a number.
struct IPv4: Equatable {
    var value: UInt32

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard part.count <= 3, part.allSatisfy(\.isASCII), let n = UInt32(part), n <= 255 else { return nil }
            value = value << 8 | n
        }
        self.value = value
    }

    var isPrivate: Bool {
        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10"].contains {
            AddressCheck.cidr($0, contains: String(value >> 24) + "." + String(value >> 16 & 255) + "." + String(value >> 8 & 255) + "." + String(value & 255)) == true
        }
    }
}
