import Foundation

/// The one notice of the main screen besides an error (spec §5.1, priorities 2–7).
enum HomeNotice: Equatable {
    case otherVPN
    /// Nothing answers and `ks probe` says why (NetworkCause).
    case network(NetworkCause)
    /// No server of the chosen country answers (Failover.State.countryDown).
    case serversDown(country: String)
    case expired
    case ending(days: Int)
    case trafficLow(used: Int64, total: Int64)
    case newServers
    /// KS-12: the update changes what goes past the VPN (DIRECT rules, DNS), not the servers.
    case routingChanged
    /// The same, but from the person's routing profile (ADR 0034), named (nil: none in use now);
    /// `subscriptionToo`: the provider changed its part as well (the helper says, re-review F4).
    case profileRouting(name: String?, subscriptionToo: Bool)
    /// «Защита неполная»: the macOS filter is not working (skipped in the wizard, removed, failed).
    case filterOff
    /// The bundled filter waits for the switch in System Settings; the old one keeps working.
    case filterUpdateWaiting
    /// The daemon (ADR 0010) waits for the switch in Login Items: until then a password every time.
    case helperApproval

    struct Input: Equatable {
        var otherVPN: Bool
        var usage: SubscriptionUsage?
        /// A subscription update waits for the user to let new servers out.
        var newServers: Bool
        /// The waiting update changes what goes past the VPN (RefreshOutcome.routingChanged).
        var routingChanged = false
        /// Which part of that change is the routing profile's (RefreshOutcome.routingChanged).
        var routingSource: RoutingChangeSource = .subscription
        var routingProfileName: String?
        var filterIncomplete: Bool
        /// «Не напоминать» on the filter notice.
        var filterDismissed: Bool
        var now: Date
        /// The country whose servers all stopped answering.
        var serversDown: String?
        var networkCause: NetworkCause? = nil
        var filterUpdateWaiting = false
        /// HelperService.showApprovalBanner, not dismissed.
        var helperApproval = false
    }

    static let endingDays = 3
    static let trafficShare = 0.9

    static func pick(_ input: Input) -> HomeNotice? {
        if input.otherVPN { return .otherVPN }
        if let cause = input.networkCause { return .network(cause) }
        if let country = input.serversDown { return .serversDown(country: country) }
        if let expire = input.usage?.expire {
            let left = expire.timeIntervalSince(input.now)
            if left <= 0 { return .expired }
            if left <= TimeInterval(endingDays) * 86400 { return .ending(days: max(1, Int((left / 86400).rounded(.up)))) }
        }
        if let usage = input.usage, let total = usage.total, total > 0, Double(usage.used) >= Double(total) * trafficShare {
            return .trafficLow(used: usage.used, total: total)
        }
        if input.newServers {
            guard input.routingChanged else { return .newServers }
            return input.routingSource == .subscription ? .routingChanged
                : .profileRouting(name: input.routingProfileName, subscriptionToo: input.routingSource == .both)
        }
        if input.filterIncomplete && !input.filterDismissed { return .filterOff }
        if input.filterUpdateWaiting { return .filterUpdateWaiting }
        if input.helperApproval { return .helperApproval }
        return nil
    }

    var title: String {
        switch self {
        case .otherVPN: String(localized: "Работает другой VPN.")
        case .network(let cause): cause.title + "."
        case .serversDown(let country): String(localized: "Серверы «\(country)» не отвечают.")
        case .expired: String(localized: "Подписка закончилась.")
        case .ending(let days): String(localized: "Подписка кончается через \(Russian.plural(days, String(localized: "день"), String(localized: "дня"), String(localized: "дней"))).")
        case .trafficLow(let used, let total): String(localized: "Трафик почти закончился: \(Russian.traffic(used: used, total: total)).")
        case .newServers: String(localized: "В подписке новые серверы.")
        case .routingChanged: String(localized: "Подписка меняет правила «напрямую».")
        case .profileRouting(let name?, false): String(localized: "Профиль «\(name)» меняет, что идёт мимо VPN.")
        case .profileRouting(nil, false): String(localized: "Профиль маршрутизации меняет, что идёт мимо VPN.")
        case .profileRouting(let name?, true): String(localized: "Подписка и профиль «\(name)» меняют, что идёт мимо VPN.")
        case .profileRouting(nil, true): String(localized: "Подписка и профиль маршрутизации меняют, что идёт мимо VPN.")
        case .filterOff: String(localized: "Защита неполная.")
        case .filterUpdateWaiting: String(localized: "Разреши обновление фильтра KillSwitch.")
        case .helperApproval: String(localized: "Разреши KillSwitch в Объектах входа, чтобы не вводить пароль каждый раз.")
        }
    }

    var message: String {
        switch self {
        case .otherVPN: String(localized: "Отключи его: два VPN мешают друг другу.")
        case .network(let cause): cause.message
        case .serversDown: String(localized: "Другие страны KillSwitch сам не включает: выбери страну или «Самый быстрый».")
        case .expired: String(localized: "VPN работает со старыми серверами, пока они пускают.")
        case .ending, .trafficLow: ""
        case .newServers: String(localized: "Разреши им работать при включённой защите.")
        case .routingChanged: String(localized: "Часть трафика пойдёт мимо VPN. Разреши, только если доверяешь провайдеру.")
        case .profileRouting(_, false): String(localized: "Новые правила заработают после пароля администратора, до подтверждения действуют прежние.")
        case .profileRouting(_, true): String(localized: "Часть изменений — от провайдера: разреши, только если доверяешь ему. До подтверждения действуют прежние правила.")
        case .filterOff: String(localized: "Защита macOS выключена. Рекомендуем включить второй уровень.")
        case .filterUpdateWaiting: String(localized: "Системные настройки › Основные › Объекты входа и расширения › Сетевые расширения. Пока работает прежняя версия.")
        case .helperApproval: ""
        }
    }
}

/// Russian words around numbers.
enum Russian {
    /// «1 день», «2 дня», «5 дней».
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = abs(n) % 100, units = abs(n) % 10
        let word = (11...14).contains(tens) ? many : units == 1 ? one : (2...4).contains(units) ? few : many
        return "\(n) \(word)"
    }

    /// «38,5 из 100 ГБ», or just the used amount without a limit.
    static func traffic(used: Int64, total: Int64?) -> String {
        guard let total else { return bytes(used) }
        let unit = Self.unit(for: max(used, total))
        return String(localized: "\(number(used, unit)) из \(number(total, unit)) \(unit.name)")
    }

    static func bytes(_ count: Int64) -> String {
        let unit = Self.unit(for: count)
        return "\(number(count, unit)) \(unit.name)"
    }

    private static func unit(for count: Int64) -> (name: String, size: Double) {
        let units: [(String, Double)] = [(String(localized: "ТБ"), 0x1p40), (String(localized: "ГБ"), 0x1p30), (String(localized: "МБ"), 0x1p20), (String(localized: "КБ"), 0x1p10)]
        return units.first { Double(count) >= $0.1 } ?? (String(localized: "Б"), 1)
    }

    /// One decimal under 100, none above; a comma, as in Russian.
    private static func number(_ count: Int64, _ unit: (name: String, size: Double)) -> String {
        let value = Double(count) / unit.size
        let rounded = value >= 100 ? value.rounded() : (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return text.replacingOccurrences(of: ".", with: ",")
    }
}

/// «Not more often than once per `interval` for the same key» (VoiceOver announcements,
/// notifications).
struct Throttle {
    let interval: TimeInterval
    private var last: [String: Date] = [:]

    init(interval: TimeInterval) { self.interval = interval }

    mutating func allow(_ key: String, now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < interval { return false }
        last[key] = now
        return true
    }
}
