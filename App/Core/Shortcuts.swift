import Foundation

/// «Быстрые команды» (App Intents: Shortcuts, Spotlight, Siri): Подключить, Отключить, Сменить
/// страну, Статус. Only what the main button would do without the window; anything that needs it
/// (install, repair, a subscription, another VPN) is said back instead of done.
enum Shortcuts {
    enum Decision: Equatable {
        case run
        /// Nothing to do; said back.
        case done(String)
        case refused(String)
    }

    static let busy = String(localized: "KillSwitch занят. Попробуй через минуту.")

    static func connect(status: Status, busy isBusy: Bool, coreConfigured: Bool) -> Decision {
        switch status {
        case .protected, .connectedUnprotected: return .done(String(localized: "VPN уже подключён"))
        case .connecting, .stuck: return .done(String(localized: "VPN уже подключается"))
        default: break
        }
        guard status.primary == .connect, status.primaryEnabled else {
            return .refused(String(localized: "Не подключилось: \(status.title). Открой KillSwitch."))
        }
        guard coreConfigured else { return .refused(String(localized: "Не подключилось: нет подписки. Открой KillSwitch.")) }
        return isBusy ? .refused(busy) : .run
    }

    static func disconnect(status: Status, busy isBusy: Bool) -> Decision {
        guard vpnRuns(status) else { return .done(String(localized: "VPN и так не подключён")) }
        return isBusy ? .refused(busy) : .run
    }

    /// Our core runs: connected, connecting, or stuck on a server that does not answer (its main
    /// button is «Выбрать другой сервер…», «Отключить» is the second one).
    static func vpnRuns(_ status: Status) -> Bool {
        status.primary == .disconnect || status.primary == .cancel || status.secondary == .disconnect
    }

    /// «Защищено, сервер LT-Vilnius»: spoken by Siri too, so without emoji.
    static func statusText(status: Status, server: String?) -> String {
        guard status == .protected, let server else { return status.title }
        return String(localized: "\(status.title), сервер \(ServerName.spoken(server))")
    }

    static func chosen(_ name: String, connected: Bool) -> String {
        let server = ServerName.spoken(name)
        return connected ? String(localized: "Сервер: \(server)")
                         : String(localized: "Выбран сервер \(server). Он включится при следующем подключении.")
    }

    /// The parameter of «Сменить страну»: the list of «Серверы» (ServerPicker).
    static func servers(_ proxies: CoreProxies?) -> [ServerPicker.Entry] {
        proxies.map(ServerPicker.entries) ?? []
    }

    static func servers(_ proxies: CoreProxies?, matching query: String) -> [ServerPicker.Entry] {
        ServerPicker.search(servers(proxies), query)
    }

    static func servers(_ proxies: CoreProxies?, named names: [String]) -> [ServerPicker.Entry] {
        servers(proxies).filter { names.contains($0.name) }
    }
}
