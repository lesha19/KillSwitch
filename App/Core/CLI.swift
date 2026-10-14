import Foundation

/// `killswitch`, the command-line client of the daemon (ADR 0025): its arguments, what it sends
/// and what it prints. The XPC side is CLI/main.swift; whether a command needs the right is
/// HelperCommand.needsAuthorization, as for the app.
enum CLI {
    static let usage = """
    usage: killswitch <command>
      status [--json]          protection, VPN and server
      connect                  connect the VPN
      disconnect               disconnect the VPN (protection stays as it is)
      protection on|off        turn protection on; off asks for an administrator
      pause <minutes>          pause protection for 1-9999 minutes; asks for an administrator
      server list [--json]     servers of every subscription, * marks the current one
      server select <name>     switch to a server: its name, part of it, "fastest",
                               or subscription/name when several have it
      version
    """

    enum Command: Equatable {
        case help, version
        case status(json: Bool)
        case connect, disconnect
        case protection(on: Bool)
        case pause(minutes: Int)
        case serverList(json: Bool)
        case serverSelect(String)

        /// The one daemon command of a command that changes something; nil for reads and the
        /// server choice (a few `core select`, see `selection`).
        var daemonCommand: HelperCommand? {
            switch self {
            case .connect: .coreOn
            case .disconnect: .coreOff
            case .protection(let on): on ? .protectionOn : .protectionOff
            case .pause(let minutes): .pause(minutes: minutes)
            case .help, .version, .status, .serverList, .serverSelect: nil
            }
        }
    }

    struct UsageError: Error, Equatable {
        var message: String
    }

    static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
        func refuse(_ text: String) -> Result<Command, UsageError> { .failure(UsageError(message: text)) }
        func json(_ rest: ArraySlice<String>, _ make: (Bool) -> Command) -> Result<Command, UsageError> {
            switch Array(rest) {
            case []: .success(make(false))
            case ["--json"]: .success(make(true))
            default: refuse("unexpected arguments: \(rest.joined(separator: " "))")
            }
        }
        guard let first = arguments.first else { return refuse("no command") }
        let rest = arguments.dropFirst()
        switch first {
        case "help", "-h", "--help", "version", "--version", "connect", "disconnect":
            guard rest.isEmpty else { return refuse("\(first) takes no arguments") }
            switch first {
            case "connect": return .success(.connect)
            case "disconnect": return .success(.disconnect)
            case "version", "--version": return .success(.version)
            default: return .success(.help)
            }
        case "status":
            return json(rest, Command.status)
        case "protection":
            switch Array(rest) {
            case ["on"]: return .success(.protection(on: true))
            case ["off"]: return .success(.protection(on: false))
            default: return refuse("protection on|off")
            }
        case "pause":
            // digits only: Int() would also take "+5"
            guard rest.count == 1, let text = rest.first, !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }),
                  let minutes = Int(text), (1...9999).contains(minutes) else {
                return refuse("pause <minutes>: a whole number from 1 to 9999")
            }
            return .success(.pause(minutes: minutes))
        case "server":
            switch rest.first {
            case "list": return json(rest.dropFirst(), Command.serverList)
            case "select":
                let name = rest.dropFirst().joined(separator: " ")
                guard HelperCommand.isName(name) else { return refuse("server select <name>") }
                return .success(.serverSelect(name))
            default: return refuse("server list|select")
            }
        default:
            return refuse("unknown command: \(first)")
        }
    }

    // MARK: status

    struct Status: Equatable {
        var protection: Protection
        /// The core runs (`ks core state`): connected or connecting.
        var vpn: Bool
        /// The server the traffic goes through now (ServerPicker.selected); nil while the VPN is off.
        var server: String?
        /// The title of the server's subscription (ADR 0036).
        var subscription: String?
    }

    /// Exit codes from sysexits(3).
    enum Exit: Int32 {
        case ok = 0
        case failed = 1
        case usage = 64
        /// EX_UNAVAILABLE: the daemon did not answer.
        case unavailable = 69
        /// EX_NOPERM: no administrator's confirmation for a command behind the right.
        case notAuthorized = 77
    }

    static func exit(for reply: HelperReply) -> Exit {
        if reply.status == 0 { return .ok }
        return reply.needsAuthorization ? .notAuthorized : .failed
    }

    static func json(_ status: Status) -> String {
        struct Out: Encodable {
            let status: Status
            enum Key: String, CodingKey { case protection, paused_until, vpn, server, subscription }
            func encode(to encoder: Encoder) throws {
                var out = encoder.container(keyedBy: Key.self)
                let until: String? = if case .paused(let date) = status.protection {
                    date.formatted(.iso8601)
                } else {
                    nil
                }
                try out.encode(CLI.word(status.protection), forKey: .protection)
                try out.encode(until, forKey: .paused_until)
                try out.encode(status.vpn ? "on" : "off", forKey: .vpn)
                try out.encode(status.server, forKey: .server)
                try out.encode(status.subscription, forKey: .subscription)
            }
        }
        return encode(Out(status: status))
    }

    static func text(_ status: Status, timeZone: TimeZone = .current) -> String {
        let protection: String = switch status.protection {
        case .on: "on"
        case .paused(let until):
            "paused until " + until.formatted(Date.VerbatimFormatStyle(
                format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
        case .off, .unknown: "off"
        case .notInstalled: "not installed"
        }
        let vpn = status.vpn ? "on" + (status.server.map { ", server \($0)" } ?? "") : "off"
        return "Protection: \(protection)\nVPN: \(vpn)"
    }

    private static func word(_ protection: Protection) -> String {
        switch protection {
        case .on: "on"
        case .paused: "paused"
        case .off: "off"
        case .unknown, .notInstalled: "unknown"
        }
    }

    // MARK: servers

    /// The app's defaults domain (the CLI's own is com.lesha19.KillSwitch.cli).
    static let appDefaultsSuite = "com.lesha19.KillSwitch"

    /// `ks core proxies` read as the app reads it, with the profile's group order the app saved:
    /// mihomo's JSON has none, and without it another selector could pass for the main one.
    static func proxies(_ answer: String, appDefaults: UserDefaults?) -> CoreProxies? {
        try? CoreProxies(data: Data(answer.utf8), order: appDefaults?.stringArray(forKey: CoreProxies.groupOrderKey) ?? [])
    }

    enum SelectionError: Error, Equatable {
        case notFound
        /// Several servers match: «subscription/server» of each, in list order.
        case ambiguous([String])
        /// «Title/…» where several subscriptions have that title.
        case sameTitle(String)
    }

    /// The `core select` steps of a server of the running subscription, by the path the core
    /// gives now (never one of the app's list); nil for another subscription's or a gone server.
    static func steps(_ entry: ServerPicker.Entry, running: String, proxies: CoreProxies) -> [ServerPicker.Selection]? {
        guard entry.subscription == running else { return nil }
        return ServerPicker.entries(proxies, subscription: running).first { $0.name == entry.name }?.path
    }

    /// A subscription's title; nil when the app's list does not name it.
    static func title(of id: String, in blocks: [ServerPicker.Block]) -> String? {
        blocks.first { $0.id == id }.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Subscriptions.activeKey: whose profile the helper runs.
    static let activeKey = "activeSubscription"
    /// The app's server list, a block per subscription (VPNClient): the daemon knows only the
    /// running subscription's servers.
    static let serversKey = "cliServers"

    /// The app's list (`serversKey`) with the running subscription's servers from the core
    /// (`proxies`, `ks core proxies`); a running subscription the list does not have goes first,
    /// untitled. Each entry is of its block, whatever the list says.
    static func blocks(_ data: Data?, running: String, proxies: CoreProxies) -> [ServerPicker.Block] {
        var blocks = (data.flatMap { try? JSONDecoder().decode([ServerPicker.Block].self, from: $0) } ?? []).map { block in
            var block = block
            block.entries = block.entries.map { var entry = $0; entry.subscription = block.id; return entry }
            return block
        }
        let live = ServerPicker.entries(proxies, subscription: running)
        if let index = blocks.firstIndex(where: { $0.id == running }) {
            blocks[index].entries = live
        } else {
            blocks.insert(ServerPicker.Block(id: running, title: "", entries: live), at: 0)
        }
        return blocks
    }

    /// «Stork/🇱🇹 Литва»: what `server list` shows and `server select` takes; the name alone when
    /// the subscription has no title.
    static func label(_ entry: ServerPicker.Entry, in blocks: [ServerPicker.Block]) -> String {
        title(of: entry.subscription, in: blocks).map { $0 + "/" + entry.name } ?? entry.name
    }

    /// The server named by the person, in any subscription (ADR 0036): the exact name,
    /// «subscription/server» (the longest title in any case), «fastest» (the running
    /// subscription's), a name or title in any case, else the one entry ServerPicker.search finds.
    /// Found in several: ambiguous.
    static func selection(_ query: String, in blocks: [ServerPicker.Block], running: String) -> Result<ServerPicker.Entry, SelectionError> {
        let entries = blocks.flatMap(\.entries)
        let lowered = query.lowercased()
        func one(_ found: [ServerPicker.Entry]) -> Result<ServerPicker.Entry, SelectionError>? {
            switch found.count {
            case 0: nil
            case 1: .success(found[0])
            default: .failure(.ambiguous(found.map { label($0, in: blocks) }))
            }
        }
        if let exact = one(entries.filter { $0.name == query }) { return exact }
        let titled = blocks.filter { !$0.title.isEmpty && lowered.hasPrefix($0.title.lowercased() + "/") }
        if let longest = titled.map(\.title.count).max() {
            let named = titled.filter { $0.title.count == longest }
            guard named.count == 1 else { return .failure(.sameTitle(named[0].title)) }
            return selection(String(query.dropFirst(longest + 1)), in: named, running: running)
        }
        // «fastest»: the running subscription's, or the one named before «/»
        if lowered == "fastest", let fastest = one(entries.filter { $0.isFastest && ($0.subscription == running || blocks.count == 1) }) {
            return fastest
        }
        return one(entries.filter { $0.name.lowercased() == lowered || $0.title.lowercased() == lowered })
            ?? one(ServerPicker.search(entries, query)) ?? .failure(.notFound)
    }

    /// One line per server, «subscription/server»: `*` marks the current one; the title follows
    /// when it differs.
    static func text(_ blocks: [ServerPicker.Block], current: ServerID?) -> String {
        blocks.flatMap(\.entries).map { entry in
            (entry.server == current ? "* " : "  ") + label(entry, in: blocks) + (entry.title == entry.name ? "" : " — \(entry.title)")
        }.joined(separator: "\n")
    }

    static func json(_ blocks: [ServerPicker.Block], current: ServerID?) -> String {
        struct Row: Encodable {
            let current: Bool
            let fastest: Bool
            let name: String
            let own: Bool
            /// Its subscription's title; left out when the app's list does not name it.
            let subscription: String?
            let title: String
        }
        return encode(blocks.flatMap { block in
            block.entries.map { Row(current: $0.server == current, fastest: $0.isFastest, name: $0.name, own: $0.own,
                                    subscription: title(of: block.id, in: blocks), title: $0.title) }
        })
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // a String and Bool tree cannot fail to encode
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension CLI.Status {
    /// From the answers of `ks state`, `ks core state` and (when the core runs) `ks core proxies`;
    /// `subscription`: the running subscription's title.
    init(state: String, coreState: String, proxies: CoreProxies?, subscription: String? = nil) {
        let running = coreState.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("on")
        let server = running ? proxies.flatMap(ServerPicker.selected) : nil
        self.init(protection: DaemonState.protection(state), vpn: running, server: server, subscription: server == nil ? nil : subscription)
    }
}
