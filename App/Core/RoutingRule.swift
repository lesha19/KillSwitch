import Foundation

/// One mihomo rule read the way mihomo (and Helper/ks split_rule) reads it:
/// `TYPE,PAYLOAD,TARGET[,options]`, `MATCH,TARGET`, or `AND|OR|NOT,((…),(…)),TARGET`.
struct RoutingRule: Equatable, Sendable {
    var type: String
    var payload: String
    var target: String
    var options: [String]

    init?(_ text: String) {
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let type = text[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
        let rest = String(text[text.index(after: comma)...])
        guard !type.isEmpty else { return nil }
        if type == "MATCH" {
            let parts = Self.split(rest)
            guard let target = parts.first, !target.isEmpty else { return nil }
            self.init(type: type, payload: "", target: target, options: Array(parts.dropFirst()))
            return
        }
        if Self.logic.contains(type) {
            let trimmed = rest.drop { $0 == " " }
            guard trimmed.first == "(", let end = Self.closing(of: trimmed) else { return nil }
            let after = trimmed[trimmed.index(after: end)...].drop { $0 == " " }
            guard after.first == "," else { return nil }
            let parts = Self.split(String(after.dropFirst()))
            guard let target = parts.first, !target.isEmpty else { return nil }
            self.init(type: type, payload: String(trimmed[...end]), target: target, options: Array(parts.dropFirst()))
            return
        }
        let parts = Self.split(rest)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(type: type, payload: parts[0], target: parts[1], options: Array(parts.dropFirst(2)))
    }

    init(type: String, payload: String, target: String, options: [String] = []) {
        self.type = type
        self.payload = payload
        self.target = target
        self.options = options
    }

    static let logic: Set<String> = ["AND", "OR", "NOT"]
    var isLogic: Bool { Self.logic.contains(type) }
    var noResolve: Bool { options.contains { $0.lowercased() == "no-resolve" } }

    /// The conditions of AND/OR/NOT: `((DOMAIN,a.com),(NETWORK,UDP))` → two conditions (no target).
    var conditions: [RoutingRule] {
        guard isLogic else { return [] }
        var inner = Substring(payload)
        guard inner.first == "(", inner.last == ")" else { return [] }
        inner = inner.dropFirst().dropLast()
        var result: [RoutingRule] = []
        while let start = inner.firstIndex(of: "(") {
            let part = inner[start...]
            guard let end = Self.closing(of: part) else { break }
            let body = String(part[part.index(after: start)..<end])
            if let condition = Self.condition(body) { result.append(condition) }
            inner = inner[inner.index(after: end)...]
        }
        return result
    }

    /// `DOMAIN,a.com` or a nested `AND,((…),(…))` as a condition: the target stays empty.
    static func condition(_ text: String) -> RoutingRule? {
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let type = text[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
        let rest = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        if logic.contains(type) { return RoutingRule(type: type, payload: rest, target: "") }
        let parts = split(rest)
        guard let payload = parts.first, !payload.isEmpty else { return nil }
        return RoutingRule(type: type, payload: payload, target: "", options: Array(parts.dropFirst()))
    }

    private static func split(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The index of the `)` closing the `(` the text starts with.
    private static func closing(of text: Substring) -> Substring.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}

/// Where a rule or a connection sends traffic.
enum TrafficRoute: Equatable, Hashable, Sendable {
    case direct
    case block
    /// PASS: the rule only lets the next ones decide.
    case pass
    /// Through the VPN: a server or a group of the subscription (or ours).
    case vpn(String)

    init(target: String) {
        switch target.uppercased() {
        case "DIRECT": self = .direct
        case "REJECT", "REJECT-DROP": self = .block
        case "PASS": self = .pass
        default: self = .vpn(target)
        }
    }

    var title: String {
        switch self {
        case .direct: String(localized: "Напрямую")
        case .block: String(localized: "Блок")
        case .pass: String(localized: "Дальше по правилам")
        case .vpn(let name): name
        }
    }

    /// The filter of «Соединения» and the summary bar.
    enum Kind: String, CaseIterable, Sendable { case direct, vpn, block }

    var kind: Kind {
        switch self {
        case .direct: .direct
        case .block: .block
        case .pass, .vpn: .vpn
        }
    }
}

extension RoutingRule {
    var route: TrafficRoute { TrafficRoute(target: target) }

    /// What the rule looks at, in words: «Домен и поддомены», «Страна по IP».
    var typeTitle: String { Self.title(type: type) }

    static func title(type: String) -> String {
        switch type.uppercased() {
        case "DOMAIN": String(localized: "Домен")
        case "DOMAIN-SUFFIX": String(localized: "Домен и поддомены")
        case "DOMAIN-KEYWORD": String(localized: "Домен содержит")
        case "DOMAIN-REGEX": String(localized: "Домен по шаблону")
        case "DOMAIN-WILDCARD": String(localized: "Домен по маске")
        case "GEOSITE": String(localized: "Категория сайтов")
        case "GEOIP": String(localized: "Страна по адресу")
        case "SRC-GEOIP": String(localized: "Страна источника")
        case "IP-ASN": String(localized: "Сеть (ASN)")
        case "SRC-IP-ASN": String(localized: "Сеть источника (ASN)")
        case "IP-CIDR", "IP-CIDR6": String(localized: "Адреса")
        case "IP-SUFFIX": String(localized: "Адреса по окончанию")
        case "SRC-IP-CIDR", "SRC-IP-SUFFIX": String(localized: "Адрес источника")
        case "DST-PORT": String(localized: "Порт")
        case "SRC-PORT": String(localized: "Порт источника")
        case "IN-PORT", "IN-TYPE", "IN-USER", "IN-NAME": String(localized: "Вход ядра")
        case "PROCESS-NAME", "PROCESS-NAME-WILDCARD": String(localized: "Программа")
        case "PROCESS-NAME-REGEX": String(localized: "Программа по шаблону")
        case "PROCESS-PATH", "PROCESS-PATH-WILDCARD", "PROCESS-PATH-REGEX": String(localized: "Путь программы")
        case "UID": String(localized: "Пользователь")
        case "NETWORK": String(localized: "Протокол")
        case "DSCP": String(localized: "Метка DSCP")
        case "RULE-SET": String(localized: "Набор правил")
        case "AND": String(localized: "Все условия")
        case "OR": String(localized: "Любое условие")
        case "NOT": String(localized: "Не")
        case "MATCH": String(localized: "Всё остальное")
        case "SUB-RULE": String(localized: "Вложенные правила")
        default: type
        }
    }

    /// The payload as people read it: conditions of a logic rule as «Протокол UDP и Порт 443».
    var payloadText: String {
        guard isLogic else { return payload }
        let parts = conditions.map { "\($0.typeTitle) \($0.payloadText)" }
        switch type {
        case "AND": return parts.joined(separator: String(localized: " и "))
        case "OR": return parts.joined(separator: String(localized: " или "))
        default: return parts.joined(separator: ", ")
        }
    }
}
