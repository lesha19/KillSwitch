import Foundation

/// A pane of «Настройки» in the sidebar of the window (spec §5.4).
enum SettingsPane: String, CaseIterable {
    case general, vpn, protection, advanced

    var title: String {
        switch self {
        case .general: "Общие"
        case .vpn: "VPN"
        case .protection: "Защита"
        case .advanced: "Дополнительно"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .vpn: "network"
        case .protection: "lock.shield"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// A section of the one window of the app (spec §3, ADR 0008), picked in its sidebar.
enum AppSection: Hashable {
    case home, servers, leakTest, log, about
    case settings(SettingsPane)

    /// The sidebar above «Настройки»; «О программе» closes the list.
    static let sidebar: [AppSection] = [.home, .servers, .leakTest, .log]
    static let settingsPanes: [AppSection] = SettingsPane.allCases.map { .settings($0) }

    var title: String {
        switch self {
        case .home: "Главная"
        case .servers: "Серверы"
        case .leakTest: "Проверка утечек"
        case .log: "Журнал защиты"
        case .about: "О программе"
        case .settings(let pane): pane.title
        }
    }

    var symbol: String {
        switch self {
        case .home: "shield.lefthalf.filled"
        case .servers: "globe"
        case .leakTest: "checkmark.shield"
        case .log: "list.bullet.rectangle"
        case .about: "info.circle"
        case .settings(let pane): pane.symbol
        }
    }

    /// Stable text for UserDefaults and links: «home», «settings.vpn».
    var id: String {
        switch self {
        case .home: "home"
        case .servers: "servers"
        case .leakTest: "leaks"
        case .log: "log"
        case .about: "about"
        case .settings(let pane): "settings." + pane.rawValue
        }
    }

    init?(id: String) {
        if id.hasPrefix("settings.") {
            guard let pane = SettingsPane(rawValue: String(id.dropFirst("settings.".count))) else { return nil }
            self = .settings(pane)
            return
        }
        guard let section = (Self.sidebar + [.about]).first(where: { $0.id == id }) else { return nil }
        self = section
    }
}

/// What a button, shortcut, notification or link asks the app to show.
enum Route: Equatable {
    /// Bring the window to the front as it is.
    case window
    case section(AppSection)
    /// «Начало работы», a sheet on the window.
    case onboarding
}

/// Which section each way into the app opens. Everything goes to the one window; nothing opens
/// a second one.
enum Navigation {
    /// Menu items and their shortcuts: ⌘0, ⌘,, ⌘L, ⇧⌘L, «Помощь → Как это работает».
    enum Command { case openWindow, settings, servers, leakTest, help }

    static func route(_ command: Command, lastSettingsPane: String? = nil) -> Route {
        switch command {
        case .openWindow: .window
        case .settings: .section(.settings(lastSettingsPane.flatMap(SettingsPane.init) ?? .general))
        case .servers: .section(.servers)
        case .leakTest: .section(.leakTest)
        case .help: .section(.about)
        }
    }

    /// A click on a notification or its button; nil = done without the window.
    static func route(notification action: UserNotice.Action?, hasAccountURL: Bool) -> Route? {
        switch action {
        case .check: .section(.leakTest)
        case .renew: hasAccountURL ? nil : .section(.home)
        case .openApp, nil: .section(.home)
        case .connect, .approve, .openLoginItems: nil
        }
    }

    /// The button of an error banner; nil = done where the banner is.
    static func route(error action: UserError.Action) -> Route? {
        action == .editSubscription ? .section(.settings(.vpn)) : nil
    }

    /// The main button of the home screen; nil = done where the button is.
    static func route(status action: Status.Action) -> Route? {
        action == .install || action == .addSubscription ? .onboarding : nil
    }

    /// `killswitch://settings/vpn` and the like (the widget opens `killswitch://home`).
    static func route(url: URL) -> Route? {
        guard url.scheme == "killswitch" else { return nil }
        switch url.host() ?? "" {
        case "setup": return .onboarding
        case "settings":
            let pane = url.pathComponents.dropFirst().first.flatMap(SettingsPane.init) ?? .general
            return .section(.settings(pane))
        case let host:
            return AppSection(id: host).map(Route.section) ?? .window
        }
    }
}
