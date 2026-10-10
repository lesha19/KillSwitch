import Foundation

/// A JSON value of the report shown as it is (the sniffer, the subscription's DNS policy).
indirect enum JSONValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    /// One line: `443, 8443`, `да`, `+.ru → https://dns.yandex.ru/...`.
    var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): b ? String(localized: "да") : String(localized: "нет")
        case .array(let a): a.map(\.text).joined(separator: ", ")
        case .object(let o): o.keys.sorted().map { "\($0): \(o[$0]!.text)" }.joined(separator: "; ")
        case .null: "—"
        }
    }

    var strings: [String] {
        switch self {
        case .string(let s): [s]
        case .array(let a): a.flatMap(\.strings)
        default: []
        }
    }
}

/// What the helper's generator took from the subscription, left out and added
/// (`/Library/KillSwitch/core/routing.json`, world-readable, no secrets; Helper/ks core_report,
/// ADR 0013).
struct RoutingReport: Decodable, Equatable, Sendable {
    static let path = "/Library/KillSwitch/core/routing.json"

    enum Origin: String, Decodable, Sendable { case subscription, killswitch }

    struct Rule: Decodable, Equatable, Sendable {
        var rule: String
        var from: Origin
        /// Position in the subscription's list (nil for KillSwitch's).
        var index: Int?
    }

    struct Dropped: Decodable, Equatable, Sendable {
        /// profile, rules, sniffer, dns (and «app» for what the app itself left out)
        var section: String
        var item: String
        var reason: String
        var index: Int?
    }

    struct Provider: Decodable, Equatable, Sendable {
        var name: String
        var type: String
        var behavior: String?
        var format: String?
        var host: String?
        var interval: Int?
        var proxy: String?
        var count: Int?
        var payload: [String]?
    }

    struct Group: Decodable, Equatable, Sendable {
        var name: String
        var type: String
        var proxies: [String]
        var from: Origin
        var hidden: Bool?
    }

    struct Proxy: Decodable, Equatable, Sendable {
        var name: String
        var type: String
    }

    struct Pin: Decodable, Equatable, Sendable {
        var host: String
        var address: String
    }

    /// One thing KillSwitch put in or changed: `kind` (dns-group, dns-servers, failover, pinning,
    /// overrides, unbound, provider-path, provider-proxy, sniffer, adblock, splitapps, multihop,
    /// default-rule), a name and its items (names, rules, or host → address for pinning).
    struct Added: Decodable, Equatable, Sendable {
        var kind: String
        var name: String?
        var items: [String]
        var pins: [Pin]

        enum CodingKeys: String, CodingKey { case kind, name, items }

        init(kind: String, name: String? = nil, items: [String] = [], pins: [Pin] = []) {
            self.kind = kind
            self.name = name
            self.items = items
            self.pins = pins
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            pins = (try? c.decode([Pin].self, forKey: .items)) ?? []
            items = pins.isEmpty ? (try? c.decode([String].self, forKey: .items)) ?? [] : []
        }
    }

    struct Sniffer: Decodable, Equatable, Sendable {
        var from: Origin
        var value: JSONValue
    }

    struct DNS: Decodable, Equatable, Sendable {
        var servers: [String]
        var taken: [String: JSONValue]
    }

    var rules: [Rule]
    var dropped: [Dropped]
    var providers: [Provider]
    var groups: [Group]
    var proxies: [Proxy]
    var added: [Added]
    var sniffer: Sniffer
    var dns: DNS
    var egress: [String]

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    /// The report as the helper wrote it, nil when there is none yet (an older helper, no profile).
    static func read(path: String = path) -> RoutingReport? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? RoutingReport(data: data)
    }

    var subscriptionRules: [Rule] { rules.filter { $0.from == .subscription } }
    var ownRules: [Rule] { rules.filter { $0.from == .killswitch } }

    func provider(_ name: String) -> Provider? { providers.first { $0.name == name } }

    /// UserDefaults: the subscription's top-level keys the app does not pass on (ProfileConverter).
    static let leftOutKey = "subscriptionLeftOut"
    /// Keys the app and the helper set themselves; anything else is simply not taken.
    static let managedKeys: Set<String> = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "bind-address", "mode",
        "log-level", "ipv6", "external-controller", "external-controller-unix", "secret", "tun", "profile",
        "find-process-mode", "geodata-mode", "geox-url", "unified-delay", "tcp-concurrent", "interface-name", "routing-mark",
    ]

    /// «Что не взято»: the keys the app left out, then what the helper did not take.
    func dropped(leftOut: [String]) -> [Dropped] {
        leftOut.map { Dropped(section: "app", item: $0, reason: Self.managedKeys.contains($0) ? "managed" : "not-allowed") } + dropped
    }

    /// The app's own part of the window: what KillSwitch added, without the kinds that only
    /// tidied the subscription up (those go with «Что не взято»).
    var additions: [Added] { added.filter { !Self.tidying.contains($0.kind) } }
    var tidied: [Added] { added.filter { Self.tidying.contains($0.kind) } }
    static let tidying: Set<String> = ["unbound", "provider-path"]

    /// The subscription's DNS policy as rows: `direct-nameserver` → its servers.
    var dnsRows: [(key: String, value: String)] {
        dns.taken.keys.sorted().map { ($0, dns.taken[$0]!.text) }
    }

    /// The core may leave the tunnel: pf's egress, with the reasons in words.
    var egressReasons: [String] {
        egress.map {
            switch $0 {
            case "rules": String(localized: "правила подписки отправляют часть сайтов напрямую")
            case "dns": String(localized: "подписка задаёт DNS-серверы вне VPN")
            case "splitapps": String(localized: "ты выбрал программы без VPN")
            default: $0
            }
        }
    }
}

// MARK: texts

extension RoutingReport.Dropped {
    var sectionTitle: String {
        switch section {
        case "rules": String(localized: "Правило")
        case "sniffer": String(localized: "Распознавание сайтов")
        case "dns": "DNS"
        case "app": String(localized: "Раздел подписки")
        default: String(localized: "Раздел подписки")
        }
    }

    /// Why it was not taken, in plain Russian.
    var reasonText: String { Self.reasonText(reason) }

    static func reasonText(_ reason: String) -> String {
        let (code, detail) = reason.firstIndex(of: ":").map { (String(reason[..<$0]), String(reason[reason.index(after: $0)...])) }
            ?? (reason, "")
        switch code {
        case "type": return String(localized: "Ядро не знает тип правила «\(detail)»")
        case "target": return String(localized: "В подписке нет сервера или группы «\(detail)»")
        case "provider": return String(localized: "В подписке нет набора правил «\(detail)»")
        case "sub-rule": return String(localized: "Вложенные правила (SUB-RULE) не поддерживаются")
        case "geodata":
            switch detail {
            case "asn": return String(localized: "Нужна база сетей (ASN), в KillSwitch её нет")
            case "geosite": return String(localized: "Нет базы категорий сайтов (geosite)")
            default: return String(localized: "Нет базы стран (geoip)")
            }
        case "managed": return String(localized: "Это KillSwitch задаёт сам")
        case "not-allowed": return String(localized: "Этого KillSwitch из подписки не берёт")
        case "bad-value": return String(localized: "Значение не прошло проверку")
        case "parse": return String(localized: "Не удалось разобрать правило")
        default: return reason
        }
    }
}

extension RoutingReport.Added {
    var title: String {
        switch kind {
        case "dns-group": String(localized: "Группа \(name ?? "KS-DNS") для DNS")
        case "dns-servers": String(localized: "DNS через VPN")
        case "failover": String(localized: "Запасная группа \(name ?? "")")
        case "pinning": String(localized: "Адреса серверов закреплены")
        case "overrides": String(localized: "Свои настройки серверов")
        case "unbound": String(localized: "Убрана привязка к сетевому интерфейсу")
        case "provider-path": String(localized: "Убран свой путь к набору правил")
        case "provider-proxy": String(localized: "Наборы правил скачиваются через VPN")
        case "sniffer": String(localized: "Распознавание сайтов")
        case "adblock": String(localized: "Блокировка рекламы — твой выбор")
        case "splitapps": String(localized: "Программы без VPN — твой выбор")
        case "multihop": String(localized: "Двойной VPN — твой выбор")
        case "default-rule": String(localized: "Правило по умолчанию")
        default: kind
        }
    }

    /// Why KillSwitch does it.
    var why: String {
        switch kind {
        case "dns-group":
            String(localized: "DNS-запросы и загрузка наборов правил идут только через серверы подписки. Даже если в группе подписки выбрать «Напрямую», они останутся в VPN.")
        case "dns-servers":
            String(localized: "Остальные имена сайтов узнаются через DNS-over-HTTPS внутри VPN: провайдер не видит, куда ты заходишь.")
        case "failover":
            String(localized: "Если выбранный сервер перестанет отвечать, ядро само перейдёт на соседний в той же стране. Куда идут сайты, это не меняет.")
        case "pinning":
            String(localized: "Защита пускает трафик только к известным адресам серверов, поэтому имя сервера заменено его адресом. Шифрование по-прежнему проверяет имя.")
        case "overrides":
            String(localized: "Отпечаток TLS и мультиплексирование, выбранные в «Дополнительно». Маршруты не меняются.")
        case "unbound":
            String(localized: "interface-name и routing-mark из подписки вывели бы трафик мимо туннеля.")
        case "provider-path":
            String(localized: "Ядро хранит наборы правил в своей папке, а не по пути из подписки.")
        case "provider-proxy":
            String(localized: "Подписка не сказала, как их скачивать: KillSwitch качает их через VPN, а не напрямую.")
        case "sniffer":
            String(localized: "В подписке его нет. Без него правила по доменам не срабатывают для программ, которые сами узнают адреса (DNS-over-HTTPS в Firefox). Адрес соединения не меняется, имя нужно только для выбора правила.")
        case "adblock":
            String(localized: "Включено в «Дополнительно»: реклама и трекеры из базы KillSwitch блокируются раньше правил подписки.")
        case "splitapps":
            String(localized: "Выбрано в «Дополнительно»: эти программы идут мимо VPN раньше правил подписки.")
        case "multihop":
            String(localized: "Выбрано на главном экране: все серверы подключаются через входной.")
        case "default-rule":
            String(localized: "В подписке нет правил: всё идёт через её первую группу, а не напрямую, как сделало бы ядро.")
        default: ""
        }
    }

    /// Lines under the title: members, rules, «host → address».
    var lines: [String] { pins.isEmpty ? items : pins.map { "\($0.host) → \($0.address)" } }
}

extension RoutingReport.Provider {
    var typeTitle: String {
        switch type {
        case "http": String(localized: "загружается")
        case "inline": String(localized: "в подписке")
        default: type
        }
    }
}
