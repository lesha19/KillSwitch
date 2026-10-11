import Foundation

/// `killswitch://` links (#23, ADR 0029). Any web page or program can open one, so a link is
/// input from a stranger: it is parsed strictly, it reaches only the CLI's commands that need no
/// administrator (`commands`), it never turns protection off or pauses it, and the only thing it
/// does without asking is connecting. Adding a subscription and disconnecting wait for the person
/// in the window.
enum DeepLink: Equatable {
    /// A section of the window, «Начало работы» or the window as it is (ADR 0008).
    case show(Route)
    case add(Subscription)
    case connect, disconnect, toggle

    /// A subscription link from `killswitch://add?url=…`: a key to the person's subscription.
    struct Subscription: Equatable {
        let url: String
        /// Lower case, ASCII (an international name in its xn-- form): what the window shows.
        let host: String

        /// For the confirmation: the host and the last characters, never the secret part.
        var masked: String {
            // not SubscriptionHeaders.masked: it shows the host as URLComponents decodes it, and a
            // lookalike xn-- name would read as the real one
            let rest = URLComponents(string: url).map { $0.percentEncodedPath + ($0.percentEncodedQuery.map { "?" + $0 } ?? "") } ?? ""
            return "https://\(host)/•••••" + (rest.count > 8 ? String(rest.suffix(4)) : "")
        }
    }

    enum Rejection: Error, Equatable {
        /// Another scheme.
        case notOurs
        case unknownCommand
        /// A known command with a parameter it does not take, or a bad value.
        case badParameters
    }

    /// The CLI commands (ADR 0025) a link can lead to. Both run without the right, as for the CLI
    /// and Shortcuts; `protection off` and `pause` are deliberately not reachable from a link.
    static let commands: [CLI.Command] = [.connect, .disconnect]

    /// The longest subscription link taken from a link.
    static let maxURLLength = 2048

    static func parse(_ url: URL) -> Result<DeepLink, Rejection> {
        guard url.scheme?.lowercased() == "killswitch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.notOurs) }
        let host = (components.host ?? "").lowercased()
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let hasQuery = !(components.percentEncodedQuery ?? "").isEmpty
        guard components.fragment == nil, components.user == nil, components.password == nil, components.port == nil else {
            return known(host) ? .failure(.badParameters) : .failure(.unknownCommand)
        }

        func plain(_ link: DeepLink) -> Result<DeepLink, Rejection> {
            path.isEmpty && !hasQuery ? .success(link) : .failure(.badParameters)
        }
        switch host {
        case "": return plain(.show(.window))
        case "setup": return plain(.show(.onboarding))
        case "connect": return plain(.connect)
        case "disconnect": return plain(.disconnect)
        case "toggle": return plain(.toggle)
        case "settings":
            guard !hasQuery, path.count <= 1 else { return .failure(.badParameters) }
            guard let name = path.first else { return .success(.show(.section(.settings(.general)))) }
            return SettingsPane(rawValue: name).map { .success(.show(.section(.settings($0)))) } ?? .failure(.badParameters)
        case "add":
            guard path.isEmpty, let items = components.queryItems, items.count == 1, items[0].name == "url",
                  let value = items[0].value, let subscription = subscription(value) else { return .failure(.badParameters) }
            return .success(.add(subscription))
        default:
            guard let section = sectionHost(host) else { return .failure(.unknownCommand) }
            return plain(.show(.section(section)))
        }
    }

    private static func sectionHost(_ host: String) -> AppSection? {
        host.contains(".") ? nil : AppSection(id: host)
    }

    private static func known(_ host: String) -> Bool {
        ["", "setup", "connect", "disconnect", "toggle", "settings", "add"].contains(host) || sectionHost(host) != nil
    }

    /// A plain https link: printable ASCII only (no lookalike letters, no line breaks), with a host
    /// and without a user name, which would make `https://bank.com@other.host` read as bank.com.
    private static func subscription(_ value: String) -> Subscription? {
        guard value.count <= maxURLLength, value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.encodedHost?.lowercased(), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:[]").contains($0) })
        else { return nil }
        return Subscription(url: value, host: host)
    }

    // MARK: what the app does

    /// What waits for the person in the window.
    enum Confirmation: Equatable {
        case add(Subscription)
        case disconnect
    }

    enum Plan: Equatable {
        case show(Route)
        /// At once, without the window.
        case run(CLI.Command)
        /// Store the subscription (confirmed), through the checks of a link typed in Settings.
        case add(Subscription)
        case confirm(Confirmation)
        /// Nothing to do.
        case done(String)
        /// Not possible now: the window shows why.
        case refused(String)
    }

    /// A subscription always asks, in any state. Connecting runs as the shortcut «Подключить VPN»
    /// does: it only adds the tunnel, protection stays as it is. Disconnecting asks: with
    /// protection on it cuts the internet, with protection off or paused the traffic goes out
    /// without the VPN.
    static func plan(_ link: DeepLink, status: Status, busy: Bool, coreConfigured: Bool) -> Plan {
        switch link {
        case .show(let route): .show(route)
        case .add(let subscription): .confirm(.add(subscription))
        case .connect: connect(status: status, busy: busy, coreConfigured: coreConfigured)
        case .disconnect: disconnect(status: status, busy: busy, confirmed: false)
        case .toggle:
            vpnRuns(status) ? disconnect(status: status, busy: busy, confirmed: false)
                            : connect(status: status, busy: busy, coreConfigured: coreConfigured)
        }
    }

    /// After «Отключить» / «Добавить» in the window: the state is checked again, it may have changed.
    static func confirmed(_ confirmation: Confirmation, status: Status, busy: Bool) -> Plan {
        switch confirmation {
        case .add(let subscription): .add(subscription)
        case .disconnect: disconnect(status: status, busy: busy, confirmed: true)
        }
    }

    private static func connect(status: Status, busy: Bool, coreConfigured: Bool) -> Plan {
        switch Shortcuts.connect(status: status, busy: busy, coreConfigured: coreConfigured) {
        case .run: .run(.connect)
        case .done(let text): .done(text)
        case .refused(let text): .refused(text)
        }
    }

    private static func disconnect(status: Status, busy: Bool, confirmed: Bool) -> Plan {
        guard vpnRuns(status) else { return .done(String(localized: "VPN и так не подключён")) }
        if busy { return .refused(Shortcuts.busy) }
        return confirmed ? .run(.disconnect) : .confirm(.disconnect)
    }

    /// Our core runs: connected, connecting, or stuck on a server that does not answer.
    private static func vpnRuns(_ status: Status) -> Bool {
        status.primary == .disconnect || status.primary == .cancel || status.secondary == .disconnect
    }

    /// The line under «Отключить VPN?»: what happens to the traffic without the tunnel.
    static func disconnectWarning(status: Status) -> String {
        switch status {
        case .protected: String(localized: "Защита останется включённой: интернет будет закрыт, пока VPN не подключится снова.")
        case .connectedUnprotected: String(localized: "Защита выключена: после отключения трафик пойдёт мимо VPN.")
        default: String(localized: "Если защита включена, интернет будет закрыт; если выключена, трафик пойдёт мимо VPN.")
        }
    }

    /// For the log: the command, and for a subscription only its host.
    var logName: String {
        switch self {
        case .show(let route):
            switch route {
            case .window: "show window"
            case .onboarding: "show setup"
            case .section(let section): "show " + section.id
            }
        case .add(let subscription): "add (\(subscription.host))"
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .toggle: "toggle"
        }
    }
}
