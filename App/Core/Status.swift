import Foundation

/// What our VPN connection is doing.
enum Connection: Equatable {
    case unavailable    // helper or core not installed
    case disconnected
    case connecting     // core started, tunnel not up yet
    case connected
    case otherApp       // a tunnel is up, but not ours (Happ, dropweb…)
}

/// The one answer to «am I safe?» (spec §2): the menu bar icon, the title, the summary line, the
/// main button and the VoiceOver label all come from it. The first matching row wins.
enum Status: Equatable {
    enum Problem: Equatable {
        /// The background service is switched off (Login Items) or not running.
        case serviceOff
        /// The helper is there, the VPN in it is not (installed by an old version).
        case vpnMissing
        /// The helper does not let the app in without a password (installed by an old version).
        case needsAccess
    }

    case checking
    case notInstalled
    case broken(Problem)
    case needsSetup
    /// Another program's VPN carries the traffic instead of ours (ADR 0009). With protection on,
    /// whatever that VPN sends around itself (often Russian sites) is blocked.
    /// `standby`: protection is on but lets everything out until that VPN goes (ADR 0018).
    /// `vpnOn`: ours is on (ADR 0035) and blocks everything around it; «Отключить VPN» is the way out.
    case otherVPN(blocksDirect: Bool, standby: Bool = false, vpnOn: Bool = false)
    /// `closed`: the VPN is on (ADR 0035) and its tunnel has not been up since «Подключить», so the
    /// internet is closed meanwhile (Mullvad's Connecting); false only with a helper before 0.20.
    case connecting(closed: Bool = false)
    case stuck(closed: Bool = false)
    /// Connected: nothing leaks whatever the protection switch says (ADR 0035).
    case protected
    /// Connected, but neither the VPN target nor protection makes pf block (a helper before 0.20, or
    /// a Disconnect that raced a Connect): traffic may leave past the VPN.
    /// `vpnOn`: the VPN is on (ADR 0035) and the watchdog says our rules do not block (pf refused
    /// them), connected or not: «Восстановить службу…», or «Отключить VPN».
    case unblocked(vpnOn: Bool = false)
    /// The VPN is on (from «Подключить» to «Отключить», ADR 0035), its tunnel was up and is gone (a
    /// drop, a restart, an update, a server switch): the internet stays closed until it is back or
    /// «Отключить VPN».
    case reconnecting
    case blocked
    case unprotected(pausedUntil: Date?)

    struct Input: Equatable {
        var protection: Protection
        var connection: Connection
        /// Another program's VPN runs next to ours.
        var foreignVPN: Bool
        var daemonProblem: Bool
        var coreInstalled: Bool
        /// The helper asked for a password where it should not (`sudo -n` refused).
        var needsRepair: Bool
        /// A subscription or own servers (or a profile already imported).
        var hasServers: Bool
        /// When the current connection attempt started.
        var connectingSince: Date?
        var now: Date
        /// The watchdog stands by: another VPN is up and ours is not running (ADR 0018).
        var standby = false
        /// The VPN is on (`/Library/KillSwitch/vpn-on`, ADR 0035): pf blocks whatever the switch says.
        var vpnOn = false
        /// Our tunnel has been up since «Подключить» (the VPN target written): a tunnel gone now is
        /// a reconnect, not the first connect.
        var tunnelWasUp = false
        /// The VPN on and the watchdog says our rules do not block (DaemonState.blocking).
        var rulesMissing = false
    }

    /// «Подключение…» turns into «Подключение затянулось» after this many seconds.
    static let stuckAfter: TimeInterval = 15

    static func summary(_ input: Input) -> Status {
        switch input.protection {
        case .notInstalled: return .notInstalled
        case .unknown: return .checking
        default: break
        }
        if input.daemonProblem { return .broken(.serviceOff) }
        if !input.coreInstalled { return .broken(.vpnMissing) }
        if input.needsRepair { return .broken(.needsAccess) }
        if !input.hasServers { return .needsSetup }
        let protectedNow = input.protection == .on
        // a leak outranks every state of the VPN (ADR 0035): never «Ничего не утекает» then
        if input.vpnOn && input.rulesMissing { return .unblocked(vpnOn: true) }
        if input.foreignVPN || input.connection == .otherApp {
            if input.vpnOn { return .otherVPN(blocksDirect: true, vpnOn: true) }   // never standby (ADR 0035)
            return .otherVPN(blocksDirect: protectedNow && !input.standby, standby: protectedNow && input.standby)
        }
        if input.vpnOn && input.connection != .connected {
            if input.tunnelWasUp { return .reconnecting }
            return connecting(input, closed: true)   // the first connect, or a core that did not start
        }
        switch input.connection {
        case .connecting:
            return connecting(input, closed: false)
        case .connected:
            return protectedNow || input.vpnOn ? .protected : .unblocked()
        default:
            if protectedNow { return .blocked }
            if case .paused(let until) = input.protection { return .unprotected(pausedUntil: until) }
            return .unprotected(pausedUntil: nil)
        }
    }

    private static func connecting(_ input: Input, closed: Bool) -> Status {
        if let since = input.connectingSince, input.now.timeIntervalSince(since) > stuckAfter { return .stuck(closed: closed) }
        return .connecting(closed: closed)
    }

    // MARK: presentation

    enum Tone: Equatable { case neutral, warning, good }

    /// What the summary line may mention.
    struct Detail: Equatable {
        var server: String?
        var ping: Int?
        /// The core moved to another server of the country lately (Failover), names displayed.
        var switched: Failover.Switch?
        /// The other VPN's name (OtherVPN.name), nil = unknown.
        var otherVPN: String?
        /// «Отключить … и подключить KillSwitch» could not stop it.
        var otherVPNStopFailed = false
    }

    enum Action: Equatable {
        case install, repair, openLoginItems, addSubscription, connect, cancel, disconnect, chooseServer
        /// The way out of «Интернет закрыт: VPN переподключается» (ADR 0035): «ks core off».
        case disconnectVPN
        case enableProtection, resumeProtection
        /// Stop the other VPN, then connect ours; the main screen names it (OtherVPN.buttonTitle).
        case replaceOtherVPN

        var title: String {
            switch self {
            case .install: String(localized: "Начать настройку…")
            case .repair: String(localized: "Восстановить службу…")
            case .openLoginItems: String(localized: "Открыть Объекты входа")
            case .addSubscription: String(localized: "Добавить подписку…")
            case .connect: String(localized: "Подключить")
            case .cancel: String(localized: "Отменить")
            case .disconnect: String(localized: "Отключить")
            case .disconnectVPN: String(localized: "Отключить VPN")
            case .chooseServer: String(localized: "Выбрать другой сервер…")
            case .enableProtection: String(localized: "Включить защиту")
            case .resumeProtection: String(localized: "Возобновить защиту")
            case .replaceOtherVPN: OtherVPN.buttonTitle(.stop, name: nil)
            }
        }
    }

    /// Template image in Assets.xcassets. Protected, connected-unprotected, blocked and
    /// unprotected differ in shape, not only in colour (the menu bar has none).
    var icon: String {
        switch self {
        case .checking, .notInstalled: "MenuBarIdle"
        case .broken: "MenuBarWarning"
        case .needsSetup: "MenuBarSetup"
        case .otherVPN: "MenuBarOtherVPN"
        case .connecting, .stuck: "MenuBarConnecting"
        case .protected: "MenuBarConnected"
        case .unblocked: "MenuBarConnectedUnprotected"
        case .blocked, .reconnecting: "MenuBarBlocked"
        case .unprotected(let until): until == nil ? "MenuBarDisconnected" : "MenuBarPaused"
        }
    }

    var title: String {
        switch self {
        case .checking: String(localized: "Проверка…")
        case .notInstalled: String(localized: "KillSwitch не установлен")
        case .broken: String(localized: "Нужна починка")
        case .needsSetup: String(localized: "Добавь подписку")
        case .otherVPN: String(localized: "Работает другой VPN")
        case .connecting: String(localized: "Подключение…")
        case .stuck: String(localized: "Подключение затянулось")
        case .protected: String(localized: "Защищено")
        case .unblocked: String(localized: "Трафик может идти мимо VPN")
        case .reconnecting: String(localized: "Интернет закрыт: VPN переподключается")
        case .blocked: String(localized: "Интернет заблокирован")
        case .unprotected: String(localized: "Без VPN и без защиты")
        }
    }

    var accessibilityLabel: String { "KillSwitch: " + title }

    var tone: Tone {
        switch self {
        case .protected: .good
        case .broken, .otherVPN, .stuck, .unblocked, .unprotected: .warning
        case .checking, .notInstalled, .needsSetup, .connecting, .reconnecting, .blocked: .neutral
        }
    }

    func line(_ detail: Detail) -> String {
        switch self {
        case .checking: ""
        case .notInstalled: String(localized: "Установка займёт минуту и попросит пароль один раз.")
        case .broken(let problem): UserError.problem(problem).message
        case .needsSetup: String(localized: "Без неё VPN не к чему подключаться.")
        case .otherVPN(_, _, vpnOn: true):
            String(localized: "KillSwitch включён, поэтому интернет мимо него закрыт. Отключи один из двух VPN.")
        case .otherVPN(_, standby: true, _):
            String(localized: "KillSwitch не подключён. Пока работает другой VPN, защита ему не мешает и включится, когда он отключится.")
        case .otherVPN(let blocksDirect, _, _):
            blocksDirect ? String(localized: "KillSwitch не подключён. Сайты, которые тот VPN пускает напрямую (часто российские), защита блокирует.")
                         : String(localized: "KillSwitch не подключён: два VPN не работают вместе.")
        case .connecting(closed: true): Self.closedWhileConnecting
        case .connecting: detail.server ?? ""
        case .stuck(closed: true): String(localized: "Сервер не отвечает, интернет закрыт. Попробуй другой.")
        case .stuck: String(localized: "Сервер не отвечает. Попробуй другой.")
        case .protected:
            [detail.server, detail.ping.map { String(localized: "\($0) мс") }].compactMap { $0 }.joined(separator: " · ")
        case .unblocked(vpnOn: true): String(localized: "VPN включён, но правила защиты не загружены.")
        case .unblocked: String(localized: "VPN подключён, но правила защиты не загружены.")
        case .reconnecting: String(localized: "Ничего не утекает: интернет откроется, когда VPN подключится.")
        case .blocked: String(localized: "VPN не подключён, поэтому интернет закрыт. Ничего не утекает.")
        case .unprotected(let until):
            String(localized: "Программы ходят в интернет напрямую.") + (until.map { String(localized: " Пауза до \(Self.time($0)).") } ?? "")
        }
    }

    private static var closedWhileConnecting: String { String(localized: "Интернет закрыт, пока VPN подключается") }

    /// The main screen names the other VPN.
    func homeTitle(_ detail: Detail) -> String {
        if case .otherVPN = self { return OtherVPN.title(name: detail.otherVPN) }
        return title
    }

    /// Under the title of the main screen, which shows the server in its own row.
    func homeLine(_ detail: Detail) -> String {
        switch self {
        case .protected:
            String(localized: "Интернет только через VPN") + (detail.switched.map {
                String(localized: ". В \(Self.time($0.at)) «\($0.from)» перестал отвечать — переключились на «\($0.to)».")
            } ?? "")
        case .connecting(closed: true): Self.closedWhileConnecting
        case .connecting: String(localized: "Сервер скоро ответит")
        case .otherVPN where detail.otherVPNStopFailed: OtherVPN.stopFailed(name: detail.otherVPN)
        default: line(detail)
        }
    }

    var primary: Action {
        switch self {
        case .checking, .blocked, .unprotected: .connect
        case .otherVPN: .replaceOtherVPN
        case .notInstalled: .install
        case .broken(.serviceOff): .openLoginItems
        case .broken: .repair
        case .needsSetup: .addSubscription
        case .connecting(closed: true): .disconnectVPN
        case .connecting: .cancel
        case .stuck: .chooseServer
        case .protected: .disconnect
        case .unblocked(vpnOn: true): .repair   // as the red notice: pf refused the rules
        case .unblocked: .enableProtection   // the fix (ADR 0035): the rules back
        case .reconnecting: .disconnectVPN
        }
    }

    var primaryEnabled: Bool {
        switch self {
        case .checking: false
        default: true
        }
    }

    var secondary: Action? {
        switch self {
        case .stuck(let closed): closed ? .disconnectVPN : .disconnect
        case .otherVPN(_, _, vpnOn: true): .disconnectVPN
        case .unblocked(let vpnOn): vpnOn ? .disconnectVPN : .disconnect
        case .unprotected(let until): until == nil ? .enableProtection : .resumeProtection
        default: nil
        }
    }

    /// One of each, for previews and the screenshot renderer.
    static func examples(now: Date) -> [Status] {
        [.checking, .notInstalled, .broken(.serviceOff), .needsSetup, .otherVPN(blocksDirect: true), .connecting(), .stuck(), .protected,
         .unblocked(), .reconnecting, .blocked, .unprotected(pausedUntil: nil), .unprotected(pausedUntil: now + 25 * 60)]
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
