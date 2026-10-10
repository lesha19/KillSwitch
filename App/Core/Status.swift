import Foundation

/// The kill switch as the helper reports it (`ks state`).
enum Protection: Equatable {
    case unknown
    case notInstalled
    case on
    case off
    case paused(until: Date)

    var isPaused: Bool { if case .paused = self { true } else { false } }

    /// Format stored for the widget.
    var stored: String {
        switch self {
        case .on: "on"
        case .off, .unknown: "off"
        case .paused(let until): "paused:\(Int(until.timeIntervalSince1970))"
        case .notInstalled: "notInstalled"
        }
    }
}

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
    case otherVPN
    case connecting
    case stuck
    case protected
    case connectedUnprotected
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
        if input.foreignVPN || input.connection == .otherApp { return .otherVPN }
        let protectedNow = input.protection == .on
        switch input.connection {
        case .connecting:
            if let since = input.connectingSince, input.now.timeIntervalSince(since) > stuckAfter { return .stuck }
            return .connecting
        case .connected:
            return protectedNow ? .protected : .connectedUnprotected
        default:
            if protectedNow { return .blocked }
            if case .paused(let until) = input.protection { return .unprotected(pausedUntil: until) }
            return .unprotected(pausedUntil: nil)
        }
    }

    // MARK: presentation

    enum Tone: Equatable { case neutral, warning, good }

    /// What the summary line may mention.
    struct Detail: Equatable {
        var server: String?
        var ping: Int?
    }

    enum Action: Equatable {
        case install, repair, openLoginItems, addSubscription, connect, cancel, disconnect, chooseServer
        case enableProtection, resumeProtection

        var title: String {
            switch self {
            case .install: "Начать настройку…"
            case .repair: "Восстановить службу…"
            case .openLoginItems: "Открыть Объекты входа"
            case .addSubscription: "Добавить подписку…"
            case .connect: "Подключить"
            case .cancel: "Отменить"
            case .disconnect: "Отключить"
            case .chooseServer: "Выбрать другой сервер…"
            case .enableProtection: "Включить защиту"
            case .resumeProtection: "Возобновить защиту"
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
        case .connectedUnprotected: "MenuBarConnectedUnprotected"
        case .blocked: "MenuBarBlocked"
        case .unprotected(let until): until == nil ? "MenuBarDisconnected" : "MenuBarPaused"
        }
    }

    var title: String {
        switch self {
        case .checking: "Проверка…"
        case .notInstalled: "KillSwitch не установлен"
        case .broken: "Нужна починка"
        case .needsSetup: "Добавь подписку"
        case .otherVPN: "Работает другой VPN"
        case .connecting: "Подключение…"
        case .stuck: "Подключение затянулось"
        case .protected: "Защищено"
        case .connectedUnprotected: "Подключено без защиты"
        case .blocked: "Интернет заблокирован"
        case .unprotected: "Без VPN и без защиты"
        }
    }

    var accessibilityLabel: String { "KillSwitch: " + title }

    var tone: Tone {
        switch self {
        case .protected: .good
        case .broken, .otherVPN, .stuck, .connectedUnprotected, .unprotected: .warning
        case .checking, .notInstalled, .needsSetup, .connecting, .blocked: .neutral
        }
    }

    func line(_ detail: Detail) -> String {
        switch self {
        case .checking: ""
        case .notInstalled: "Установка займёт минуту и попросит пароль один раз."
        case .broken(.serviceOff): "Её выключили в Системных настройках. Правила пока действуют, но следить за ними некому."
        case .broken(.vpnMissing): "В службе не хватает VPN — так бывает после старой версии."
        case .broken(.needsAccess): "После обновления KillSwitch службе нужны новые права."
        case .needsSetup: "Без неё VPN не к чему подключаться."
        case .otherVPN: "Отключи другой VPN: два VPN мешают друг другу."
        case .connecting: detail.server ?? ""
        case .stuck: "Сервер не отвечает. Попробуй другой."
        case .protected:
            [detail.server, detail.ping.map { "\($0) мс" }].compactMap { $0 }.joined(separator: " · ")
        case .connectedUnprotected: "Если VPN оборвётся, программы пойдут в интернет напрямую."
        case .blocked: "VPN не подключён, поэтому интернет закрыт. Ничего не утекает."
        case .unprotected(let until):
            "Программы ходят в интернет напрямую." + (until.map { " Пауза до \(Self.time($0))." } ?? "")
        }
    }

    var primary: Action {
        switch self {
        case .checking, .blocked, .unprotected, .otherVPN: .connect
        case .notInstalled: .install
        case .broken(.serviceOff): .openLoginItems
        case .broken: .repair
        case .needsSetup: .addSubscription
        case .connecting: .cancel
        case .stuck: .chooseServer
        case .protected, .connectedUnprotected: .disconnect
        }
    }

    var primaryEnabled: Bool {
        switch self {
        case .checking, .otherVPN: false
        default: true
        }
    }

    var secondary: Action? {
        switch self {
        case .stuck: .disconnect
        case .connectedUnprotected: .enableProtection
        case .unprotected(let until): until == nil ? .enableProtection : .resumeProtection
        default: nil
        }
    }

    /// One of each, for previews and the screenshot renderer.
    static func examples(now: Date) -> [Status] {
        [.checking, .notInstalled, .broken(.serviceOff), .needsSetup, .otherVPN, .connecting, .stuck, .protected,
         .connectedUnprotected, .blocked, .unprotected(pausedUntil: nil), .unprotected(pausedUntil: now + 25 * 60)]
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
