import Foundation

/// «Сети Wi‑Fi» (#39): rules for named Wi-Fi networks, applied when the Mac joins one. A rule can
/// only add protection or pick a server: «Подключаться автоматически» connects there even when
/// the general switch is off, «Предпочитаемый сервер» selects that server. Nothing here turns
/// protection off or pauses it; the kill switch stays fail-closed in every network.
/// The names stay in this Mac's UserDefaults, never in logs or diagnostics.
enum WiFiRules {
    static let key = "wifiRules"

    struct Rule: Codable, Equatable, Identifiable {
        var ssid: String
        var autoConnect = true
        /// The server's name in the core (ServerPicker.Entry.name); nil = keep the current one.
        var server: String?
        /// Whose server it is (ADR 0036): Subscription.id or ServerID.own; nil (a rule of 0.20.0) is the
        /// subscription in use, as in 0.20.0. 0.19's rules go to the first subscription (Subscriptions.migrate).
        var subscription: String?
        var id: String { ssid }
    }

    /// Wi-Fi names are case-sensitive; no name (cable, no Location access) means no rule.
    static func rule(for ssid: String?, in rules: [Rule]) -> Rule? {
        guard let ssid else { return nil }
        return rules.first { $0.ssid == ssid }
    }

    static func adding(_ ssid: String, to rules: [Rule]) -> [Rule] {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, rule(for: name, in: rules) == nil else { return rules }
        return rules + [Rule(ssid: name)]
    }

    enum ServerChoice: Equatable {
        case keep
        case select(ServerPicker.Entry)
        /// The preferred server is no longer in the subscription.
        case missing(String)
    }

    /// `entries` and `current` are of `active`, the subscription in use: a server of another one is
    /// left alone, since a subscription switch is the person's (ADR 0036).
    static func server(for rule: Rule?, entries: [ServerPicker.Entry], current: String?, active: String) -> ServerChoice {
        guard let name = rule?.server, name != current, (rule?.subscription ?? active) == active else { return .keep }
        guard let entry = entries.first(where: { $0.name == name && $0.subscription == active }) else { return .missing(name) }
        return .select(entry)
    }

    static func encode(_ rules: [Rule]) -> Data? { try? JSONEncoder().encode(rules) }

    /// Missing or damaged: no rules, so the general switches decide.
    static func decode(_ data: Data?) -> [Rule] {
        guard let data, let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return rules
    }
}
