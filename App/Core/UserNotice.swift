import Foundation

/// System notifications (spec §7): what each event says, which button it carries and which
/// switch in Settings → Общие turns it off. The same event goes out at most once in 10 minutes.
enum UserNotice: Equatable {
    case vpnDropped(protected: Bool)
    case reconnected(server: String?)
    /// The chosen server stopped answering; another server is the person's choice (ADR 0036).
    case serversDown(server: String)
    /// The helper turned «Двойной VPN» off by itself: its entry no longer fits (ADR 0027).
    case doubleVPNOff(entry: String)
    case autoConnectNeedsPassword
    /// Auto-connect found another program's VPN up and left it alone (ADR 0009).
    case otherVPN(name: String?)
    case subscriptionEnding(days: Int, title: String?, expire: Date)
    case trafficLow(used: Int64, total: Int64)
    case newServers
    /// KS-12: the update changes what goes past the VPN, not the servers.
    case routingChanged
    case pauseEnded
    case serviceOff
    /// The VPN on and its core not running for 5 minutes: everything stays blocked (#85).
    case vpnStuck
    case macOSUpdated
    /// The app updated itself and the daemon put the new helper in place (ADR 0012).
    case updateInstalled(coreRestarted: Bool)

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
            case .connect: String(localized: "Подключить")
            case .openApp: String(localized: "Открыть KillSwitch")
            case .renew: String(localized: "Продлить…")
            case .approve: String(localized: "Разрешить…")
            case .openLoginItems: String(localized: "Открыть")
            case .check: String(localized: "Проверить")
            }
        }
    }

    /// For the 10-minute rule: both kinds of a drop are one event.
    var key: String {
        switch self {
        case .vpnDropped: "vpnDropped"
        case .reconnected: "reconnected"
        case .serversDown: "serversDown"
        case .doubleVPNOff: "doubleVPNOff"
        case .autoConnectNeedsPassword: "autoConnect"
        case .otherVPN: "otherVPN"
        case .subscriptionEnding(let days, _, _): "ending\(days)"
        case .trafficLow: "traffic"
        case .newServers: "newServers"
        case .routingChanged: "routingChanged"
        case .pauseEnded: "pauseEnded"
        case .serviceOff: "serviceOff"
        case .vpnStuck: "vpnStuck"
        case .macOSUpdated: "macOS"
        case .updateInstalled: "updated"
        }
    }

    var setting: Setting? {
        switch self {
        case .vpnDropped, .reconnected, .autoConnectNeedsPassword, .serversDown, .otherVPN, .doubleVPNOff: .connection
        case .subscriptionEnding, .trafficLow, .newServers, .routingChanged: .subscription
        case .pauseEnded: .pause
        case .serviceOff: .service
        case .macOSUpdated, .updateInstalled, .vpnStuck: nil
        }
    }

    var action: Action? {
        switch self {
        case .vpnDropped: .connect
        case .autoConnectNeedsPassword, .serversDown, .otherVPN, .doubleVPNOff, .vpnStuck: .openApp
        case .subscriptionEnding: .renew
        case .newServers, .routingChanged: .approve
        case .serviceOff: .openLoginItems
        case .macOSUpdated: .check
        case .reconnected, .trafficLow, .pauseEnded, .updateInstalled: nil
        }
    }

    var title: String {
        switch self {
        case .vpnDropped: String(localized: "VPN оборвался")
        case .reconnected: String(localized: "VPN снова работает")
        case .serversDown(let server): String(localized: "Сервер «\(server)» не отвечает")
        case .doubleVPNOff: String(localized: "Двойной VPN выключен")
        case .autoConnectNeedsPassword: String(localized: "VPN не подключился сам")
        case .otherVPN(let name): OtherVPN.title(name: name)
        case .subscriptionEnding(let days, _, _): String(localized: "Подписка кончается через ") + Russian.plural(days, String(localized: "день"), String(localized: "дня"), String(localized: "дней"))
        case .trafficLow: String(localized: "Трафик почти закончился")
        case .newServers: String(localized: "В подписке новые серверы")
        case .routingChanged: String(localized: "Подписка меняет правила «напрямую»")
        case .pauseEnded: String(localized: "Защита снова включена")
        case .serviceOff: String(localized: "Служба KillSwitch выключена")
        case .vpnStuck: String(localized: "Интернет закрыт: VPN не подключается")
        case .macOSUpdated: String(localized: "macOS обновилась")
        case .updateInstalled: String(localized: "Обновление установлено")
        }
    }

    var body: String { body(calendar: .current) }

    func body(calendar: Calendar) -> String {
        switch self {
        case .vpnDropped(let protected):
            protected ? String(localized: "Интернет закрыт, пока VPN не подключится. Ничего не утекает.")
                      : String(localized: "Защита выключена — программы идут в интернет напрямую.")
        case .reconnected(let server): server ?? String(localized: "Интернет снова идёт через VPN.")
        case .serversDown: String(localized: "Выбери другой сервер.")
        case .doubleVPNOff(let entry): String(localized: "Сервер входа «\(entry)» больше не подходит. VPN работает через один сервер.")
        case .autoConnectNeedsPassword: String(localized: "Службу нужно обновить.")
        case .otherVPN: String(localized: "KillSwitch не подключился сам, чтобы не выключать его без спроса. Переключиться можно в KillSwitch.")
        case .subscriptionEnding(_, let title, let expire):
            String(localized: "\(title ?? String(localized: "Подписка")) до \(Self.day(expire, calendar: calendar)).")
        case .trafficLow(let used, let total): Russian.traffic(used: used, total: total) + "."
        case .newServers: String(localized: "Разреши их, чтобы обновление применилось.")
        case .routingChanged: String(localized: "Часть трафика пойдёт мимо VPN. Проверь, прежде чем разрешать.")
        case .pauseEnded: String(localized: "Пауза закончилась.")
        case .serviceOff: String(localized: "Включи её в Объектах входа.")
        case .vpnStuck: String(localized: "VPN не подключается уже 5 минут, а KillSwitch держит интернет закрытым, чтобы ничего не утекло. Выбери другой сервер или нажми «Отключить VPN».")
        case .macOSUpdated: String(localized: "Перезагрузи Mac и запусти проверку утечек.")
        case .updateInstalled(let restarted):
            restarted ? String(localized: "VPN переподключился за секунду, защита не отключалась.")
                      : String(localized: "VPN не прерывался.")
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
