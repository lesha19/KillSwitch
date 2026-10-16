import Darwin
import Foundation

/// `killswitch://` links (#23, ADR 0029). Any web page or program can open one, so a link is
/// input from a stranger: it is parsed strictly, it reaches only the CLI's commands that need no
/// administrator (`commands`), it never turns protection off or pauses it, and the only thing it
/// does without asking is connecting. Adding a subscription, and disconnecting while protection
/// is on, wait for the person in the window; disconnecting while protection is off is refused.
enum DeepLink: Equatable {
    /// A section of the window, «Начало работы» or the window as it is (ADR 0008).
    case show(Route)
    case add(Subscription)
    case connect, disconnect, toggle

    /// A subscription link from `killswitch://add?url=…`: a key to the person's subscription.
    struct Subscription: Equatable {
        let url: String
        /// Where the app will connect, as the window shows it: the host in lower case ASCII (an
        /// international name in its xn-- form, an address as it is) and the port unless 443.
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
        /// `killswitch:` that is not a URL Foundation can take apart.
        case malformed
        case unknownCommand
        /// A known command with a parameter it does not take, or a bad value.
        case badParameters
    }

    /// The CLI commands (ADR 0025) a link can lead to. Both run without the right, as for the CLI
    /// and Shortcuts; `protection off` and `pause` are deliberately not reachable from a link.
    static let commands: [CLI.Command] = [.connect, .disconnect]

    /// How the app runs a link command; nil for every other CLI command.
    enum Action: Equatable {
        /// `KillSwitchControl.coreOnAutomatically`: never the password prompt.
        case connectAutomatically
        case disconnect
    }

    static func action(for command: CLI.Command) -> Action? {
        switch command {
        case .connect: .connectAutomatically
        case .disconnect: .disconnect
        default: nil
        }
    }

    /// The longest subscription link taken from a link.
    static let maxURLLength = 2048

    static func parse(_ url: URL) -> Result<DeepLink, Rejection> {
        guard url.scheme?.lowercased() == "killswitch" else { return .failure(.notOurs) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.malformed) }
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

    /// A plain https link: printable ASCII only (no lookalike letters, no line breaks), a host
    /// name or address (`displayHost`), and no user name, which would make
    /// `https://bank.com@other.host` read as bank.com.
    private static func subscription(_ value: String) -> Subscription? {
        guard value.count <= maxURLLength, value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let host = components.encodedHost.flatMap(displayHost) else { return nil }
        let port = components.port.flatMap { $0 == 443 ? nil : $0 }
        return Subscription(url: value, host: host + (port.map { ":\($0)" } ?? ""))
    }

    /// A DNS name (at most 253 characters, labels of 1–63 letters, digits and inner hyphens, at
    /// least two, the last of letters or xn--), a dotted-quad IPv4 address without leading zeros,
    /// or a bracketed IPv6 address. Not `0x7f.1`, `2130706433`, `127.1`: resolvers read those as
    /// addresses the person would not recognise.
    private static func displayHost(_ encoded: String) -> String? {
        let host = encoded.lowercased()
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), host.count > 2 else { return nil }
            var address = in6_addr()
            return inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &address) == 1 ? host : nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) {
            let valid = labels.allSatisfy { ($0 == "0" || $0.first != "0") && $0.count <= 3 && Int($0)! <= 255 }
            return valid ? host : nil
        }
        guard host.count <= 253, labels.count >= 2, let top = labels.last,
              top.hasPrefix("xn--") || top.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let isLabel: (Substring) -> Bool = { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { ("0"..."9").contains($0) || ("a"..."z").contains($0) || $0 == "-" }
        }
        return labels.allSatisfy(isLabel) ? host : nil
    }

    // MARK: what the app does

    /// What waits for the person in the window.
    enum Confirmation: Equatable {
        case add(Subscription)
        case disconnect
    }

    /// A question of a link in the window, one at a time (Router.linkRequest). Dropped when nobody
    /// saw it before the app lost the front, or after `timeout`, so it never pops up later out of
    /// context or blocks the next link (or an update's quit) for good. Times are seconds of system
    /// uptime (`ProcessInfo.systemUptime`): a clock change moves neither the timeout nor the pace.
    struct Request: Equatable, Identifiable {
        let id = UUID()
        let confirmation: Confirmation
        let created: TimeInterval
        /// The sheet appeared.
        var shown = false

        static let timeout: TimeInterval = 120

        init(_ confirmation: Confirmation, at created: TimeInterval) {
            self.confirmation = confirmation
            self.created = created
        }

        /// `busy`: a subscription it confirmed is being fetched; the sheet stays until it answers.
        func isStale(now: TimeInterval, resignedActive: Bool, busy: Bool) -> Bool {
            guard !busy else { return false }
            return now - created > Self.timeout || (resignedActive && !shown)
        }
    }

    /// One acting link every `interval`: a page that opens them in a loop cannot keep taking the
    /// front, stack questions or keep the app from ever being idle for an update.
    struct Throttle {
        static let interval: TimeInterval = 2
        private var last: TimeInterval?

        mutating func allows(at now: TimeInterval) -> Bool {
            if let last, now >= last, now - last < Self.interval { return false }
            last = now
            return true
        }
    }

    /// Sections change nothing (the widget opens `killswitch://home`): only the rest is paced.
    var isPaced: Bool {
        if case .show = self { return false }
        return true
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
        /// Not possible now: the main screen shows the state.
        case refused(String)
    }

    /// A subscription always asks, in any state. Connecting runs as the shortcut «Подключить VPN»
    /// does: it only adds the tunnel, protection stays as it is. Disconnecting asks while
    /// protection is on (it cuts the internet) and is refused while protection is off or paused:
    /// the traffic would go out without the VPN, as if the link had turned protection off.
    static func plan(_ link: DeepLink, status: Status, busy: Bool, coreConfigured: Bool, protectionOn: Bool) -> Plan {
        switch link {
        case .show(let route): .show(route)
        case .add(let subscription): .confirm(.add(subscription))
        case .connect: connect(status: status, busy: busy, coreConfigured: coreConfigured)
        case .disconnect: disconnect(status: status, busy: busy, protectionOn: protectionOn, confirmed: false)
        case .toggle:
            vpnRuns(status) ? disconnect(status: status, busy: busy, protectionOn: protectionOn, confirmed: false)
                            : connect(status: status, busy: busy, coreConfigured: coreConfigured)
        }
    }

    /// After «Отключить» / «Добавить» in the window: the state is checked again, it may have changed.
    static func confirmed(_ confirmation: Confirmation, status: Status, busy: Bool, protectionOn: Bool) -> Plan {
        switch confirmation {
        case .add(let subscription): .add(subscription)
        case .disconnect: disconnect(status: status, busy: busy, protectionOn: protectionOn, confirmed: true)
        }
    }

    private static func connect(status: Status, busy: Bool, coreConfigured: Bool) -> Plan {
        switch Shortcuts.connect(status: status, busy: busy, coreConfigured: coreConfigured) {
        case .run: .run(.connect)
        case .done(let text): .done(text)
        case .refused(let text): .refused(text)
        }
    }

    private static func disconnect(status: Status, busy: Bool, protectionOn: Bool, confirmed: Bool) -> Plan {
        guard vpnRuns(status) else { return .done(String(localized: "VPN и так не подключён")) }
        guard protectionOn else { return .refused(String(localized: "Ссылка не отключает VPN, пока защита выключена или на паузе.")) }
        if busy { return .refused(Shortcuts.busy) }
        return confirmed ? .run(.disconnect) : .confirm(.disconnect)
    }

    private static func vpnRuns(_ status: Status) -> Bool { Shortcuts.vpnRuns(status) }

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
