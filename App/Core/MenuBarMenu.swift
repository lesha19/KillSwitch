import Foundation

/// The menu bar icon (ADR 0011): a click opens the main screen as a popover, a right click (or
/// ⌃-click) a compact menu of the few things done most often.
enum MenuBarMenu {
    enum Click: Equatable { case popover, menu }

    static func click(rightButton: Bool, controlKey: Bool) -> Click {
        rightButton || controlKey ? .menu : .popover
    }

    enum Item: Equatable { case connect, disconnect, fastest, openApp, leakTest, quit }

    struct Entry: Equatable {
        var item: Item
        var title: String
        var enabled = true
    }

    /// nil = a separator. «Подключить» is enabled when the main button would connect; «Самый
    /// быстрый» when the server list has one (ServerPicker).
    static func entries(status: Status, busy: Bool, coreConfigured: Bool, fastestAvailable: Bool) -> [Entry?] {
        let connection: Entry
        // the core runs or the VPN is on where the main button does something else (stuck, rules
        // missing, another VPN): its way out, never a disabled «Подключить»
        switch status.secondary == .disconnectVPN || status.secondary == .disconnect ? status.secondary! : status.primary {
        case .disconnect, .cancel:
            connection = Entry(item: .disconnect, title: String(localized: "Отключить"), enabled: !busy)
        case .disconnectVPN:
            connection = Entry(item: .disconnect, title: Status.Action.disconnectVPN.title, enabled: !busy)
        default:
            connection = Entry(item: .connect, title: String(localized: "Подключить"),
                               enabled: status.primary == .connect && status.primaryEnabled && coreConfigured && !busy)
        }
        return [
            connection,
            Entry(item: .fastest, title: ServerPicker.fastestTitle, enabled: fastestAvailable && !busy),
            nil,
            Entry(item: .openApp, title: String(localized: "Открыть KillSwitch")),
            Entry(item: .leakTest, title: String(localized: "Проверка утечек")),
            nil,
            Entry(item: .quit, title: String(localized: "Выход")),
        ]
    }
}
