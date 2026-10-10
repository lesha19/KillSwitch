import Foundation

/// The one notice of the main screen besides an error (spec §5.1, priorities 2–7).
enum HomeNotice: Equatable {
    case otherVPN
    /// No server of the chosen country answers (Failover.State.countryDown).
    case serversDown(country: String)
    case expired
    case ending(days: Int)
    case trafficLow(used: Int64, total: Int64)
    case newServers
    /// «Защита неполная»: the macOS filter is not working (skipped in the wizard, removed, failed).
    case filterOff

    struct Input: Equatable {
        var otherVPN: Bool
        var usage: SubscriptionUsage?
        /// A subscription update waits for the user to let new servers out.
        var newServers: Bool
        var filterIncomplete: Bool
        /// «Не напоминать» on the filter notice.
        var filterDismissed: Bool
        var now: Date
        /// The country whose servers all stopped answering.
        var serversDown: String?
    }

    static let endingDays = 3
    static let trafficShare = 0.9

    static func pick(_ input: Input) -> HomeNotice? {
        if input.otherVPN { return .otherVPN }
        if let country = input.serversDown { return .serversDown(country: country) }
        if let expire = input.usage?.expire {
            let left = expire.timeIntervalSince(input.now)
            if left <= 0 { return .expired }
            if left <= TimeInterval(endingDays) * 86400 { return .ending(days: max(1, Int((left / 86400).rounded(.up)))) }
        }
        if let usage = input.usage, let total = usage.total, total > 0, Double(usage.used) >= Double(total) * trafficShare {
            return .trafficLow(used: usage.used, total: total)
        }
        if input.newServers { return .newServers }
        if input.filterIncomplete && !input.filterDismissed { return .filterOff }
        return nil
    }

    var title: String {
        switch self {
        case .otherVPN: "Работает другой VPN."
        case .serversDown(let country): "Серверы «\(country)» не отвечают."
        case .expired: "Подписка закончилась."
        case .ending(let days): "Подписка кончается через \(Russian.plural(days, "день", "дня", "дней"))."
        case .trafficLow(let used, let total): "Трафик почти закончился: \(Russian.traffic(used: used, total: total))."
        case .newServers: "В подписке новые серверы."
        case .filterOff: "Защита неполная."
        }
    }

    var message: String {
        switch self {
        case .otherVPN: "Отключи его: два VPN мешают друг другу."
        case .serversDown: "Другие страны KillSwitch сам не включает: выбери страну или «Самый быстрый»."
        case .expired: "VPN работает со старыми серверами, пока они пускают."
        case .ending, .trafficLow: ""
        case .newServers: "Разреши им работать при включённой защите."
        case .filterOff: "Защита macOS выключена. Рекомендуем включить второй уровень."
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
        return "\(number(used, unit)) из \(number(total, unit)) \(unit.name)"
    }

    static func bytes(_ count: Int64) -> String {
        let unit = Self.unit(for: count)
        return "\(number(count, unit)) \(unit.name)"
    }

    private static func unit(for count: Int64) -> (name: String, size: Double) {
        let units: [(String, Double)] = [("ТБ", 0x1p40), ("ГБ", 0x1p30), ("МБ", 0x1p20), ("КБ", 0x1p10)]
        return units.first { Double(count) >= $0.1 } ?? ("Б", 1)
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
