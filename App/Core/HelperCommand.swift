import Foundation

/// What the privileged daemon (ADR 0010) may run for the app: the operations that went through
/// passwordless sudo or the admin password before, nothing else. Each one becomes a fixed program
/// (`/Library/KillSwitch/ks`, or the bundled install.sh / uninstall.sh) with an argument vector,
/// never a shell line. The daemon checks `isValid` again before it runs anything; the rules mirror
/// Helper/ks (valid_addr, valid_name, splitapps_parse, `pause`, `set`), which checks once more.
enum HelperCommand: Equatable, Sendable {
    // Never widen the rules: what the sudoers line of Helper/install.sh allows without a password.
    case state, probe, protectionOn, netRestore
    case coreState, coreOn, coreOff, coreProxies
    /// Two byte totals of the core for the menu bar speed (`ks core traffic`).
    case coreTraffic
    /// The core's connections and rule provider sizes for «Трафик» (`ks core connections`).
    case coreConnections
    case coreSelect(group: String, proxy: String)
    case coreDelay(String)
    /// Refused by ks (exit 3) if the profile brings new servers: the subscription auto-update.
    case coreRefresh(profile: String)
    /// «Собрать отчёт» (ADR 0021): the redacted archive into this folder. Through the daemon the
    /// app opens the file and the daemon gives ks its own folder (`Executor`) and the uid of the
    /// user who asked: ks takes only that user's crash reports.
    case diagReport(directory: String, uid: UInt32? = nil)

    // Widen or edit what may leave the Mac without the VPN: behind the authorization right.
    case protectionOff
    case pause(minutes: Int)
    case setSwitch(String, Bool)
    case setSplitApps([String])
    /// nil turns «Двойной VPN» off.
    case setMultihop(String?)
    /// The own DNS-over-HTTPS server (ADR 0031), used by the core through the VPN; nil clears it.
    case setDoH(String?)
    /// Own addresses of sites (ADR 0033), "name=IPv4" each; [] clears them.
    case setHosts([String])
    /// The way of connecting (ADR 0020); the subscription is imported again for it.
    case setCore(CoreChoice)
    case allow(String), unallow(String)
    case serverAdd(String), serverRemove(String)
    case coreImport(profile: String)
    /// The daemon puts the connecting user here (audit token), whatever the app said.
    case install(user: String, servers: [String])
    case uninstall
    /// After an app update (ADR 0012): the verified bundle's `install.sh --upgrade`, without the
    /// right. The daemon runs it only with a helper not older than the installed one
    /// (HelperUpgrade); it keeps the sudoers user and the protection state and never drops the VPN.
    case upgrade
    /// «Сбросить настройки» (#17): damaged settings files, which block everything, back to the defaults.
    case repair

    enum Program: Equatable, Sendable { case ks, install, uninstall, upgrade }

    var program: Program {
        switch self {
        case .install: .install
        case .uninstall: .uninstall
        case .upgrade: .upgrade
        default: .ks
        }
    }

    var needsAuthorization: Bool {
        switch self {
        case .state, .probe, .protectionOn, .netRestore, .coreState, .coreOn, .coreOff, .coreProxies, .coreTraffic, .coreConnections,
             .coreSelect, .coreDelay, .coreRefresh, .diagReport, .upgrade:
            false
        default:
            true
        }
    }

    /// KS-11: the daemon serves every local account (ssh sessions too, through the CLI) and sudoers
    /// grants the passwordless commands to one user only. Those that change something, and the
    /// live connections (every user's traffic), run only for `mayChangeWithoutPassword`; reading
    /// the state stays open. Commands behind the right are authorized by the admin's password.
    var onlyForConsoleUser: Bool {
        switch self {
        case .protectionOn, .netRestore, .coreOn, .coreOff, .coreSelect, .coreRefresh, .upgrade, .coreConnections: true
        default: false
        }
    }

    /// Root, or the user at the Mac's console who is install.sh's sudoers user (any user at the
    /// console when that entry is unknown). Another account, or an ssh session while someone else
    /// or nobody is at the console (`console` 0 or nil), is refused.
    static func mayChangeWithoutPassword(caller: uid_t, console: uid_t?, installer: uid_t?) -> Bool {
        if caller == 0 { return true }
        guard let console, console != 0, caller == console else { return false }
        return installer == nil || caller == installer
    }

    /// The daemon could not run this bundled script (no verified copy of the app, 0.14.2): nothing
    /// ran, so the app runs it behind the password prompt instead (ADR 0002), after its own check
    /// of the bundle. `ks` commands are not retried: there failedToRun means the helper is missing.
    func fallsBackToPassword(_ reply: HelperReply) -> Bool {
        program != .ks && reply.status == HelperReply.failedToRun
    }

    /// The arguments after the program.
    var arguments: [String] {
        switch self {
        case .state: ["state"]
        case .probe: ["probe"]
        case .protectionOn: ["on"]
        case .netRestore: ["netrestore"]
        case .coreState: ["core", "state"]
        case .coreOn: ["core", "on"]
        case .coreOff: ["core", "off"]
        case .coreProxies: ["core", "proxies"]
        case .coreTraffic: ["core", "traffic"]
        case .coreConnections: ["core", "connections"]
        case .coreSelect(let group, let proxy): ["core", "select", group, proxy]
        case .coreDelay(let name): ["core", "delay", name]
        case .coreRefresh(let profile): ["core", "refresh", profile]
        case .diagReport(let directory, let uid): ["diag", "report", directory] + (uid.map { [String($0)] } ?? [])
        case .protectionOff: ["off"]
        case .pause(let minutes): ["pause", String(minutes)]
        case .setSwitch(let key, let on): ["set", key, on ? "1" : "0"]
        case .setSplitApps(let names): ["set", "splitapps", names.joined(separator: ",")]
        case .setMultihop(let entry): ["set", "multihop", entry ?? Self.multihopOff]
        case .setDoH(let url): ["set", "doh", url ?? ""]
        case .setHosts(let entries): ["set", "hosts", entries.joined(separator: ",")]
        case .setCore(let core): ["set", "core", core.rawValue]
        case .allow(let address): ["allow", address]
        case .unallow(let address): ["unallow", address]
        case .serverAdd(let address): ["server-add", address]
        case .serverRemove(let address): ["server-remove", address]
        case .coreImport(let profile): ["core", "import", profile]
        case .install(let user, let servers): [user] + servers
        case .uninstall: []
        case .upgrade: ["--upgrade"]
        case .repair: ["repair"]
        }
    }

    var isValid: Bool {
        switch self {
        case .state, .probe, .protectionOn, .netRestore, .coreState, .coreOn, .coreOff, .coreProxies, .coreTraffic, .coreConnections,
             .protectionOff, .uninstall, .upgrade, .repair:
            true
        case .coreSelect(let group, let proxy): Self.isName(group) && Self.isName(proxy)
        case .coreDelay(let name): Self.isName(name)
        case .coreRefresh(let profile), .coreImport(let profile): Self.isProfilePath(profile)
        case .diagReport(let directory, _): Self.isProfilePath(directory)
        case .pause(let minutes): (0...9999).contains(minutes)
        case .setSwitch(let key, _): Self.switchKeys.contains(key)
        case .setSplitApps(let names):
            names.count <= Self.maxSplitApps && Set(names).count == names.count && names.allSatisfy(Self.isSplitApp)
        case .setMultihop(let entry): entry.map { Self.isName($0) && $0 != Self.multihopOff } ?? true
        case .setDoH(let url): url.map(Self.isDoH) ?? true
        case .setHosts(let entries):
            entries.count <= Self.maxHosts && entries.allSatisfy(Self.isHostsEntry)
                && Set(entries.map { $0.split(separator: "=").first.map { $0.lowercased() } ?? "" }).count == entries.count
        case .setCore: true
        case .allow(let address), .serverAdd(let address): Self.isAddress(address)
        case .unallow(let address), .serverRemove(let address): Self.isListedAddress(address)
        case .install(let user, let servers):
            Self.isUser(user) && servers.count <= Self.maxInstallServers && servers.allSatisfy(Self.isAddress)
        }
    }

    // MARK: the argv the app builds (Batch, Onboarding, KillSwitchControl)

    /// A command as the app writes it: `[helper, ks arguments…]` or (AdminScript.bundled)
    /// `["/bin/bash", "-p", <…/install.sh>, user, servers…]` / `["/bin/bash", "-p", <…/uninstall.sh>]`.
    /// Nil for anything else or a value the daemon would refuse. The script's path only names which
    /// one: the daemon runs its own verified copy, never a path from the app.
    init?(command: [String], helper: String) {
        guard let first = command.first else { return nil }
        if first == helper {
            self.init(ks: Array(command.dropFirst()))
            return
        }
        guard first == "/bin/bash", command.count >= 3, command[1] == "-p" else { return nil }
        let command = Array(command.dropFirst())
        if command[1].hasSuffix("/install.sh"), command.count >= 3 {
            self = .install(user: command[2], servers: Array(command.dropFirst(3)))
        } else if command[1].hasSuffix("/uninstall.sh"), command.count == 2 {
            self = .uninstall
        } else {
            return nil
        }
        guard isValid else { return nil }
    }

    /// `ks <arguments>` as a command; nil for what the daemon does not run.
    init?(ks arguments: [String]) {
        let command: HelperCommand
        switch arguments {
        case ["state"]: command = .state
        case ["probe"]: command = .probe
        case ["on"]: command = .protectionOn
        case ["netrestore"]: command = .netRestore
        case ["repair"]: command = .repair
        case ["off"]: command = .protectionOff
        case ["core", "state"]: command = .coreState
        case ["core", "on"]: command = .coreOn
        case ["core", "off"]: command = .coreOff
        case ["core", "proxies"]: command = .coreProxies
        case ["core", "traffic"]: command = .coreTraffic
        case ["core", "connections"]: command = .coreConnections
        default:
            switch (arguments.first, arguments.count) {
            case ("pause", 2):
                guard arguments[1].allSatisfy(\.isASCII), let minutes = Int(arguments[1]) else { return nil }
                command = .pause(minutes: minutes)
            case ("set", 3):
                switch arguments[1] {
                case "splitapps":
                    let list = arguments[2]
                    command = .setSplitApps(list.isEmpty ? [] : list.split(separator: ",", omittingEmptySubsequences: false)
                        .map(String.init))
                case "multihop":
                    command = .setMultihop(arguments[2] == Self.multihopOff ? nil : arguments[2])
                case "doh":
                    command = .setDoH(arguments[2].isEmpty ? nil : arguments[2])
                case "hosts":
                    command = .setHosts(arguments[2].isEmpty ? [] : arguments[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init))
                case "core":
                    guard let core = CoreChoice(rawValue: arguments[2]) else { return nil }
                    command = .setCore(core)
                default:
                    guard ["0", "1"].contains(arguments[2]) else { return nil }
                    command = .setSwitch(arguments[1], arguments[2] == "1")
                }
            case ("allow", 2): command = .allow(arguments[1])
            case ("unallow", 2): command = .unallow(arguments[1])
            case ("server-add", 2): command = .serverAdd(arguments[1])
            case ("server-remove", 2): command = .serverRemove(arguments[1])
            case ("core", 3) where arguments[1] == "delay": command = .coreDelay(arguments[2])
            case ("core", 3) where arguments[1] == "import": command = .coreImport(profile: arguments[2])
            case ("core", 3) where arguments[1] == "refresh": command = .coreRefresh(profile: arguments[2])
            case ("diag", 3) where arguments[1] == "report": command = .diagReport(directory: arguments[2])
            case ("core", 4) where arguments[1] == "select": command = .coreSelect(group: arguments[2], proxy: arguments[3])
            default: return nil
            }
        }
        guard command.isValid else { return nil }
        self = command
    }

    // MARK: how root runs it (0.12.1)

    /// The whole environment of what the daemon runs: the system tools and nothing of its own or
    /// the app's (the same as AdminScript.environment; ks_clean_env and install.sh reset the rest).
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// `/bin/bash` arguments for a bundled script: `-p` ignores BASH_ENV, ENV, SHELLOPTS and
    /// exported functions, as AdminScript.bundled.
    static func scriptArguments(_ script: String, _ arguments: [String]) -> [String] { ["-p", script] + arguments }

    // MARK: checks

    static let multihopOff = "off"
    /// `ks set <key> 0|1`; all behind the right, «Блокировать рекламу» (adblock) too: it changes
    /// what the core refuses, and only an admin turns that on or off, as with the password before.
    /// «Подробная диагностика» (diag, ADR 0021) too: it changes what the core records.
    /// «Пробовать другой отпечаток и транспорт» (escalate, ADR 0030) too: it changes the core's config.
    /// The blocked categories (ADR 0031) are switches too: adblock, blockadult, blocksocial, blockbetting.
    static let switchKeys: Set<String> = ["lan", "tailscale", "dns", "direct", "wifiguard", "adblock", "diag", "failover", "escalate",
                                          "blockadult", "blocksocial", "blockbetting"]

    /// ks hosts_parse (ADR 0033): at most 50 "name=IPv4" entries.
    static let maxHosts = 50
    /// Names KillSwitch itself needs (updates, the probes, the leak test), with their subdomains.
    static let reservedHostNames = ["github.com", "githubusercontent.com", "cp.cloudflare.com", "ipify.org", "mullvad.net", "bash.ws"]

    /// ks hosts_parse: an exact DNS name of two labels or more (not .local or localhost, not one of
    /// `reservedHostNames`) and an IPv4 address without leading zeros, not this network, loopback,
    /// link-local, 198.18/15 (our TUN) or multicast and up. Case does not matter (ks lower-cases).
    static func isHostsEntry(_ entry: String) -> Bool {
        let parts = entry.split(separator: "=", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let name = parts[0].lowercased(), address = String(parts[1])
        let octet = /(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/
        guard address.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              address.split(separator: ".").allSatisfy({ $0.wholeMatch(of: octet) != nil }) else { return false }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        let (a, b) = (octets[0], octets[1])
        guard a != 0, a != 127, a < 224, !(a == 169 && b == 254), !(a == 198 && (18...19).contains(b)) else { return false }
        let label = /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ $0.wholeMatch(of: label) != nil }),
              labels.last?.first.map({ ("a"..."z").contains($0) }) == true,
              labels.last != "local", labels.last != "localhost" else { return false }
        return !reservedHostNames.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// ks valid_doh (ADR 0031): https, a public host name or IPv4 address, an optional port and
    /// path; no user, query or fragment, nothing local (the server is reached through the VPN).
    static func isDoH(_ text: String) -> Bool {
        guard text.utf8.count <= 256,
              let match = text.wholeMatch(of: /https:\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(\/(?:[A-Za-z0-9._~\/-]|%[0-9A-Fa-f]{2})*)?/) else { return false }
        if let port = match.2 {
            guard let number = Int(port), (1...65535).contains(number) else { return false }
        }
        let host = String(match.1)
        if host.wholeMatch(of: /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/) != nil {
            // no leading zeros (as isHostsEntry): Xray refuses such an address in a rule
            let octet = /(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/
            guard host.split(separator: ".").allSatisfy({ $0.wholeMatch(of: octet) != nil }) else { return false }
            let octets = host.split(separator: ".").compactMap { Int($0) }
            let (a, b) = (octets[0], octets[1])
            // this network, private, loopback, link-local, CGNAT, 198.18/15 (our TUN), multicast and up
            return ![0, 10, 127].contains(a) && a < 224 && !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && b == 168) && !(a == 100 && (64...127).contains(b)) && !(a == 198 && (18...19).contains(b))
        }
        let label = /[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?/
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ $0.wholeMatch(of: label) != nil }),
              labels.last?.first?.isLetter == true else { return false }
        return !["local", "localhost", "internal", "lan"].contains(String(labels.last!).lowercased()) && !host.lowercased().hasSuffix(".home.arpa")
    }
    static let maxSplitApps = 50
    static let maxInstallServers = 512

    /// ks valid_name: non-empty, at most 256 bytes (the daemon runs ks in the C locale), no control characters.
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && !hasControl(text)
    }

    /// ks valid_addr: an IPv4 address or network in dotted form, or anything IPv6-shaped (pfctl -n
    /// checks it after). Bounded: the longest IPv6 text with a prefix is 49 characters.
    static func isAddress(_ text: String) -> Bool {
        guard isListedAddress(text), text.utf8.count <= 49 else { return false }
        return text.contains(":") || text.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?/) != nil
    }

    /// Removal: any entry of the address shape install.sh or an older ks let into the lists.
    static func isListedAddress(_ text: String) -> Bool {
        text.utf8.count <= 64 && text.wholeMatch(of: /[0-9A-Fa-f:.]+(\/[0-9]{1,3})?/) != nil
    }

    /// ks splitapps_parse: an app bundle's absolute path (at most 255 bytes, `.app`, no empty, `.`
    /// or `..` parts) or a process name (at most 64 bytes, no slash); no list separator, no
    /// control characters, nothing for ks to trim.
    static func isSplitApp(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.contains(","), !hasControl(entry),
              entry.trimmingCharacters(in: .whitespaces) == entry else { return false }
        guard entry.hasPrefix("/") else { return entry.utf8.count <= 64 && !entry.contains("/") }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return entry.utf8.count <= 255 && entry.hasSuffix(".app") && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The daemon writes profiles to its own directory; the path is absolute and one line.
    static func isProfilePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 1024 && !hasControl(path)
    }

    /// A macOS short user name as install.sh's valid_user takes it into sudoers (which also wants
    /// an existing account with uid 500 or more): never the keyword ALL.
    static func isUser(_ name: String) -> Bool {
        name != "ALL" && name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_.-]{0,31}/) != nil
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
