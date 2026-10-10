import Foundation

/// System notifications (spec §7): what each event says, which button it carries and which
/// switch in Settings → Общие turns it off. The same event goes out at most once in 10 minutes.
enum UserNotice: Equatable {
    case vpnDropped(protected: Bool)
    case reconnected(server: String?)
    /// Failover moved to another server of the same country (names as displayed).
    case serverSwitched(from: String, to: String)
    /// No server of the chosen country answers; another country is the person's choice.
    case serversDown(country: String)
    case autoConnectNeedsPassword
    case subscriptionEnding(days: Int, title: String?, expire: Date)
    case trafficLow(used: Int64, total: Int64)
    case newServers
    case pauseEnded
    case serviceOff
    case macOSUpdated

    static let interval: TimeInterval = 600

    /// The Settings switch (a UserDefaults key, on by default); nil = always shown.
    enum Setting: String {
        case connection = "notifyVPNDropped"
        case subscription = "notifySubscription"
        case pause = "notifyPauseEnded"
        case service = "notifyServiceOff"
    }

    enum Action: String {
        case connect, openApp, renew, approve, openLoginItems, check

        var title: String {
            switch self {
            case .connect: "Подключить"
            case .openApp: "Открыть KillSwitch"
            case .renew: "Продлить…"
            case .approve: "Разрешить…"
            case .openLoginItems: "Открыть"
            case .check: "Проверить"
            }
        }
    }

    /// For the 10-minute rule: both kinds of a drop are one event.
    var key: String {
        switch self {
        case .vpnDropped: "vpnDropped"
        case .reconnected: "reconnected"
        case .serverSwitched: "serverSwitched"
        case .serversDown: "serversDown"
        case .autoConnectNeedsPassword: "autoConnect"
        case .subscriptionEnding(let days, _, _): "ending\(days)"
        case .trafficLow: "traffic"
        case .newServers: "newServers"
        case .pauseEnded: "pauseEnded"
        case .serviceOff: "serviceOff"
        case .macOSUpdated: "macOS"
        }
    }

    var setting: Setting? {
        switch self {
        case .vpnDropped, .reconnected, .autoConnectNeedsPassword, .serverSwitched, .serversDown: .connection
        case .subscriptionEnding, .trafficLow, .newServers: .subscription
        case .pauseEnded: .pause
        case .serviceOff: .service
        case .macOSUpdated: nil
        }
    }

    var action: Action? {
        switch self {
        case .vpnDropped: .connect
        case .autoConnectNeedsPassword, .serversDown: .openApp
        case .subscriptionEnding: .renew
        case .newServers: .approve
        case .serviceOff: .openLoginItems
        case .macOSUpdated: .check
        case .reconnected, .serverSwitched, .trafficLow, .pauseEnded: nil
        }
    }

    var title: String {
        switch self {
        case .vpnDropped: "VPN оборвался"
        case .reconnected: "VPN снова работает"
        case .serverSwitched: "VPN переключился на другой сервер"
        case .serversDown(let country): "Серверы «\(country)» не отвечают"
        case .autoConnectNeedsPassword: "VPN не подключился сам"
        case .subscriptionEnding(let days, _, _): "Подписка кончается через " + Russian.plural(days, "день", "дня", "дней")
        case .trafficLow: "Трафик почти закончился"
        case .newServers: "В подписке новые серверы"
        case .pauseEnded: "Защита снова включена"
        case .serviceOff: "Служба KillSwitch выключена"
        case .macOSUpdated: "macOS обновилась"
        }
    }

    var body: String { body(calendar: .current) }

    func body(calendar: Calendar) -> String {
        switch self {
        case .vpnDropped(let protected):
            protected ? "Интернет закрыт, пока VPN не подключится. Ничего не утекает."
                      : "Защита выключена — программы идут в интернет напрямую."
        case .reconnected(let server): server ?? "Интернет снова идёт через VPN."
        case .serverSwitched(let from, let to): "«\(from)» не отвечал. Теперь — «\(to)»."
        case .serversDown: "Выбери другую страну или «Самый быстрый»."
        case .autoConnectNeedsPassword: "Службу нужно обновить."
        case .subscriptionEnding(_, let title, let expire):
            "\(title ?? "Подписка") до \(Self.day(expire, calendar: calendar))."
        case .trafficLow(let used, let total): Russian.traffic(used: used, total: total) + "."
        case .newServers: "Разреши их, чтобы обновление применилось."
        case .pauseEnded: "Пауза закончилась."
        case .serviceOff: "Включи её в Объектах входа."
        case .macOSUpdated: "Перезагрузи Mac и запусти проверку утечек."
        }
    }

    /// 3 when three days or less are left, 1 at one day or less: one notice per threshold.
    static func endingThreshold(secondsLeft: TimeInterval) -> Int? {
        guard secondsLeft > 0 else { return nil }
        if secondsLeft <= 86400 { return 1 }
        if secondsLeft <= 3 * 86400 { return 3 }
        return nil
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }
}
