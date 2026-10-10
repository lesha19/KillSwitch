import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications
import WidgetKit

/// Talks to the root helper `/Library/KillSwitch/ks`.
/// Reading the state, turning protection on and driving the core go through passwordless sudo
/// (Helper/install.sh grants `ks state`, `ks on`, `ks core on|off|state|proxies|select|delay|refresh`);
/// everything that loosens protection asks for the admin password, so another program running
/// as the user cannot do it silently. The password prompt only ever follows a click: calls made
/// by timers pass `interactive: false` and give up instead (see `callHelper`).
@MainActor
@Observable
final class KillSwitchControl {
    typealias State = Protection

    private(set) var state: State = .unknown
    /// Any VPN tunnel is up (ours, dropweb's, Happ's): what pf and the filter let traffic into.
    private(set) var vpnUp = false
    /// Our core's tunnel (198.18.128.1) is up.
    private(set) var ownTunnelUp = false
    private(set) var error: String? {
        didSet { if let error, error != oldValue { recentErrors = Array((recentErrors + [error]).suffix(5)) } }
    }
    /// Server choice and latency tests; kept apart from `error`, which refresh() resets every 3 s.
    private(set) var coreError: String? {
        didSet { if let coreError, coreError != oldValue { recentErrors = Array((recentErrors + [coreError]).suffix(5)) } }
    }
    /// For «Скопировать диагностику».
    private(set) var recentErrors: [String] = []
    private(set) var busy = false
    private(set) var allowLAN = true
    private(set) var allowTailscale = true
    private(set) var wifiGuard = true
    private(set) var allowRouterDNS = false
    private(set) var exceptions: [String] = []
    private(set) var allowDirect = false
    private(set) var servers: [String] = []          // /Library/KillSwitch/servers
    private(set) var foundServers: [String] = []     // from dropweb profiles and Happ's config
    private(set) var daemonProblem = false
    /// `sudo -n ks state` wants a password: the helper was installed by an older app.
    private(set) var needsRepair = false
    /// When the current connection attempt started; nil unless connecting.
    private(set) var connectingSince: Date?
    /// Moves on with every refresh while connecting, so «Подключение затянулось» shows up in time.
    private(set) var clock = Date()
    private(set) var events: [String] = []
    private(set) var leakResults: [LeakResult] = []
    private(set) var externalIP: String?
    private(set) var leakRunning = false
    /// Our own VPN core (mihomo run by the root daemon), see `ks core`.
    private(set) var coreInstalled = false
    private(set) var coreConfigured = false
    private(set) var coreRunning = false
    /// «Российские сайты — напрямую (мимо VPN)»: the core sends Russian sites around the tunnel.
    private(set) var coreDirect = false
    /// «Раздельный туннель»: process names that go around the VPN (only with coreDirect).
    private(set) var splitApps: [String] = []
    /// «Двойной VPN»: the entry server; the exit is the selected one. Nil = off.
    private(set) var multihopEntry: String?
    /// Set while another VPN's TUN is up next to our core (see `foreignVPNFile`).
    private(set) var foreignVPN: String?
    /// Groups and servers of the running core, from `ks core proxies`.
    private(set) var proxies: CoreProxies?
    private var proxiesLoading = false
    private var proxiesLoadedAt = Date.distantPast
    /// `ks core proxies` failed while the core runs (shown instead of the server list).
    private(set) var proxiesError: String?
    /// Results of the user's latency tests (ms, `CoreDelay.timeout` = no answer); fresher than
    /// the core's history, which `delay(of:)` falls back to.
    private(set) var measured: [String: Int] = [:]
    /// Groups whose latency test is running; `allGroupsKey` while the whole list is tested.
    private(set) var testing: Set<String> = []
    static let allGroupsKey = "\u{0}all"

    struct LeakResult: Identifiable {
        let interface: String
        let leaked: Bool
        var id: String { interface }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Second layer, see FilterControl.
    let filter = FilterControl()

    private let helper = "/Library/KillSwitch/ks"
    private var timer: Timer?

    init() {
        notifyIfMacOSUpdated()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        listenForWidget()
    }

    func turnOn() { run(["on"]) }
    func turnOff() { runAsAdmin([helper, "off"]) }
    func pause(minutes: Int) { runAsAdmin([helper, "pause", String(minutes)]) }

    func set(_ key: String, _ on: Bool) { runAsAdmin([helper, "set", key, on ? "1" : "0"]) }
    func addException(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        runAsAdmin([helper, "allow", trimmed])
    }
    func removeException(_ address: String) { runAsAdmin([helper, "unallow", address]) }

    /// Always a click: the list decides what goes around the VPN.
    func setSplitApps(_ names: [String]) { runAsAdmin([helper, "set", "splitapps", SplitApps.argument(names)]) }
    /// `entry` nil turns «Двойной VPN» off. Always a click.
    func setMultihop(entry: String?) { runAsAdmin([helper, "set", "multihop", entry ?? Multihop.off]) }

    /// VPN servers are reachable by any process (Happ's tunnel runs as the ordinary user and
    /// cannot be told apart from other apps), so only these addresses are let out.
    func allowFoundServers() {
        let missing = foundServers.filter { !servers.contains($0) }
        guard !missing.isEmpty else { return }
        let script = missing.map { "\(helper) server-add \($0)" }.joined(separator: " && ")
        runAsAdmin(["/bin/sh", "-c", script])
    }
    func removeServer(_ address: String) { runAsAdmin([helper, "server-remove", address]) }

    /// Starting and stopping never widen the rules, so they go without a password.
    func coreOn() { run(["core", "on"]) }
    func coreOff() { run(["core", "off"]) }

    /// «Подключаться автоматически»: like coreOn, but never shows the password prompt; if the
    /// helper wants a password, a notification says so instead. True when the core was started.
    func coreOnAutomatically() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false; refresh() }
        switch await callHelper(["core", "on"], interactive: false) {
        case .ok:
            error = nil
            return true
        case .needsPassword:
            notify(.autoConnectNeedsPassword)
        case .failed(let message):
            error = message.isEmpty ? "Не получилось подключиться автоматически" : message
        case .cancelled:
            break
        }
        return false
    }

    enum ImportResult: Equatable { case ok, cancelled, needsPassword, failed(String) }

    /// Hands a profile (JSON: proxies, proxy-groups, rules, rule-providers) to the helper, which
    /// writes the full core config and lets the servers out. The config decides what goes around
    /// the VPN, so unless sudoers allows it, this asks for the password; `allowPassword: false`
    /// (automatic updates) never shows the prompt.
    func coreImport(file: String, allowPassword: Bool) async -> ImportResult {
        busy = true
        defer { busy = false; refresh() }
        switch await callHelper(["core", "import", file], interactive: allowPassword) {
        case .ok: measured = [:]; return .ok
        case .needsPassword: return .needsPassword
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message.isEmpty ? "Не получилось" : message)
        }
    }

    /// Subscription auto-update: the same as import, but through passwordless sudo only and
    /// refused by the helper (exit 3) if the profile brings new server addresses. Never prompts.
    func coreRefresh(file: String) async -> RefreshOutcome {
        busy = true
        defer { busy = false; refresh() }
        let result = await Self.exec("/usr/bin/sudo", ["-n", helper, "core", "refresh", file])
        let outcome = RefreshOutcome(status: result.status, output: result.output)
        if outcome == .applied { measured = [:] }
        return outcome
    }

    /// Picks a server in a selector group of the running core. Always a click.
    func coreSelect(group: String, proxy: String) {
        busy = true
        Task {
            await select(group: group, proxy: proxy)
            busy = false
        }
    }

    private func select(group: String, proxy: String) async {
        switch await callHelper(["core", "select", group, proxy], interactive: true) {
        case .ok: coreError = nil
        case .failed(let message): coreError = message
        case .needsPassword, .cancelled: break
        }
        loadProxies(force: true)
    }

    /// Latency shown for a server or group: the user's last test, else the core's history.
    func delay(of name: String) -> Int? {
        if let value = measured[name] { return value == CoreDelay.timeout ? nil : value }
        return proxies?.delay(name)
    }

    /// The last test got no answer from this one.
    func timedOut(_ name: String) -> Bool { measured[name] == CoreDelay.timeout }

    /// «Проверить пинг» for one group (`ks core delay <group>`); true when results came back.
    @discardableResult
    func testDelay(group: CoreProxies.Group) async -> Bool {
        await runDelay(group: group) == .done
    }

    /// «Проверить пинг» for the whole list. A refused or cancelled password stops it, so the
    /// prompt shows at most once; a group where nothing answered does not.
    func testAllDelays() async {
        guard let groups = proxies?.groups, !testing.contains(Self.allGroupsKey) else { return }
        testing.insert(Self.allGroupsKey)
        defer { testing.remove(Self.allGroupsKey) }
        for group in groups {
            if await runDelay(group: group) == .refused { break }
        }
    }

    private enum DelayOutcome { case done, failed, refused }

    private func runDelay(group: CoreProxies.Group) async -> DelayOutcome {
        guard coreRunning, !testing.contains(group.name) else { return .failed }
        testing.insert(group.name)
        defer { testing.remove(group.name) }
        switch await callHelper(["core", "delay", group.name], interactive: true, separateStderr: true) {
        case .ok(let output):
            do {
                measured.merge(try CoreDelay.parse(Data(output.utf8), members: group.all)) { $1 }
                coreError = nil
                loadProxies(force: true)
                return .done
            } catch CoreDelay.Failure.core {
                // mihomo answers an error when no member replied
                for name in group.all { measured[name] = CoreDelay.timeout }
                coreError = "Ни один сервер группы «\(group.name)» не ответил."
                return .failed
            } catch {
                coreError = error.localizedDescription
                return .failed
            }
        case .failed(let message):
            coreError = CoreDelay.Failure.core(message.isEmpty ? "ядро не ответило" : message).errorDescription
            return .failed
        case .needsPassword, .cancelled:
            return .refused
        }
    }

    /// «Лучший»: tests a selector group and picks its fastest member.
    func selectBest(group: CoreProxies.Group) async {
        guard group.selectable, await testDelay(group: group) else { return }
        guard let best = CoreDelay.best(of: group.all, delays: measured) else {
            coreError = "Ни один сервер группы «\(group.name)» не ответил."
            return
        }
        if best != group.now {
            busy = true
            await select(group: group.name, proxy: best)
            busy = false
        }
    }

    /// `ks core proxies`, at most every 5 s unless forced; only while the core runs.
    /// Runs from the 3 s timer too, so it never asks for the password.
    func loadProxies(force: Bool = false) {
        guard coreRunning else { proxies = nil; proxiesError = nil; measured = [:]; return }
        guard !proxiesLoading, force || Date().timeIntervalSince(proxiesLoadedAt) > 5 else { return }
        proxiesLoading = true
        Task {
            let result = await callHelper(["core", "proxies"], interactive: false, separateStderr: true)
            proxiesLoading = false
            proxiesLoadedAt = Date()
            switch result {
            case .ok(let output):
                let order = UserDefaults.standard.stringArray(forKey: Self.groupOrderKey) ?? []
                if let parsed = try? CoreProxies(data: Data(output.utf8), order: order) {
                    proxiesError = nil
                    if parsed != proxies { proxies = parsed }
                } else {
                    proxiesError = "Ядро вернуло непонятный список серверов."
                }
            case .needsPassword:
                proxiesError = "Нет доступа к ядру без пароля. Нажми «Обновить защиту» внизу окна."
            case .failed(let message):
                proxiesError = message.isEmpty ? "Не получилось получить список серверов." : message
            case .cancelled:
                break
            }
        }
    }

    /// Group names in profile order, written by VPNClient on import (mihomo's JSON has no order).
    static let groupOrderKey = "coreGroupOrder"

    private static func sudoWantsPassword(_ output: String) -> Bool {
        RefreshOutcome.sudoWantsPassword(output)
    }

    enum HelperResult: Equatable { case ok(String), needsPassword, cancelled, failed(String) }

    /// `ks <args>` through passwordless sudo; if sudoers does not allow it (older helper), the
    /// admin prompt follows only when `interactive` — a user's click, never a timer.
    private func callHelper(_ args: [String], interactive: Bool, separateStderr: Bool = false) async -> HelperResult {
        let result = await Self.exec("/usr/bin/sudo", ["-n", helper] + args, separateStderr: separateStderr)
        if result.status == 0 { return .ok(result.output) }
        guard Self.sudoWantsPassword(result.output) else { return .failed(result.output) }
        guard interactive else { return .needsPassword }
        switch await adminRun([helper] + args) {
        case .ok(let output): return .ok(output)
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Also used to upgrade the installed helper: install.sh keeps settings and lists.
    func install() { runBundled("install.sh", [NSUserName()] + foundServers) }
    func uninstall() { runBundled("uninstall.sh", []) }

    func refresh() {
        let wasVPNUp = vpnUp
        let tunnels = Self.vpnTunnels()
        vpnUp = !tunnels.isEmpty
        ownTunnelUp = tunnels.contains(.own)
        if wasVPNUp && !vpnUp && state == .on { notify(.vpnDropped) }
        readSettings()
        checkDaemon()
        guard FileManager.default.fileExists(atPath: helper) else {
            publish(.notInstalled)
            return
        }
        coreInstalled = FileManager.default.fileExists(atPath: "/Library/KillSwitch/core/mihomo")
        coreConfigured = FileManager.default.fileExists(atPath: "/Library/KillSwitch/core/config.yaml")
        if coreInstalled {
            Task {
                // "on", possibly followed by more words in later helpers
                coreRunning = await Self.exec("/usr/bin/sudo", ["-n", helper, "core", "state"]).output.hasPrefix("on")
                trackConnecting()
                loadProxies()
            }
        } else {
            coreRunning = false
            proxies = nil
        }
        foreignVPN = coreRunning ? Self.readForeignVPN() : nil
        trackConnecting()
        Task {
            let result = await Self.exec("/usr/bin/sudo", ["-n", helper, "state"])
            guard result.status == 0 else {
                needsRepair = Self.sudoWantsPassword(result.output)
                if !needsRepair { error = result.output.isEmpty ? "Нет доступа к защите" : result.output }
                return
            }
            needsRepair = false
            error = nil
            publish(Self.parse(result.output))
        }
    }

    private func trackConnecting() {
        guard connection == .connecting else { connectingSince = nil; return }
        if connectingSince == nil { connectingSince = Date() }
        clock = Date()
    }

    private func publish(_ new: State) {
        let defaults = Shared.defaults
        let changed = new != state || defaults?.bool(forKey: Shared.vpnKey) != vpnUp
        if case .paused = state, new == .on { notify(.pauseEnded) }
        state = new
        syncFilter()
        guard changed else { return }
        defaults?.set(new.stored, forKey: Shared.stateKey)
        defaults?.set(vpnUp, forKey: Shared.vpnKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A click (or the widget): may fall back to the password prompt.
    private func run(_ args: [String]) {
        busy = true
        Task {
            switch await callHelper(args, interactive: true) {
            case .ok: error = nil
            case .failed(let message): error = message.isEmpty ? "Не получилось" : message
            case .needsPassword, .cancelled: break
            }
            busy = false
            refresh()
        }
    }

    private func runBundled(_ script: String, _ args: [String]) {
        guard let path = Bundle.main.path(forResource: script, ofType: nil, inDirectory: "Helper") else {
            error = "Не найден \(script) внутри программы"
            return
        }
        runAsAdmin(["/bin/bash", path] + args)
    }

    /// Runs a command as root; macOS asks for the admin password every time.
    private func runAsAdmin(_ command: [String]) {
        busy = true
        Task {
            switch await adminRun(command) {
            case .ok: error = nil
            case .cancelled: break
            case .failed(let message): error = message
            }
            busy = false
            refresh()
        }
    }

    private enum AdminResult { case ok(String), cancelled, failed(String) }

    private func adminRun(_ command: [String]) async -> AdminResult {
        let source = AdminScript.source([command])
        var info: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&info)
        if let info {
            if (info[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }   // user cancelled
            return .failed(info[NSAppleScript.errorMessage] as? String ?? "Не получилось")
        }
        guard let output else { return .failed("Не получилось") }
        // do shell script turns line ends into \r
        return .ok((output.stringValue ?? "").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// What the content filter lets out while no VPN tunnel is up, mirroring the pf settings.
    private func syncFilter() {
        var addresses = servers + exceptions
        if allowTailscale {
            addresses += Self.readLines("/Library/KillSwitch/tsrelays").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        }
        let config: [String: AnyHashable] = [
            "addresses": addresses, "lan": allowLAN, "tailscale": allowTailscale, "direct": allowDirect,
        ]
        filter.sync(config: config, enabled: state == .on)
    }

    /// Settings files are root-owned but world-readable.
    private func readSettings() {
        let settings = (try? String(contentsOfFile: "/Library/KillSwitch/settings", encoding: .utf8)) ?? ""
        var values: [String: String] = [:]
        for line in settings.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        allowLAN = (values["lan"] ?? "1") == "1"
        allowTailscale = (values["tailscale"] ?? "1") == "1"
        wifiGuard = (values["wifiguard"] ?? "1") == "1"
        allowRouterDNS = (values["dns"] ?? "0") == "1"
        allowDirect = (values["direct"] ?? "0") == "1"
        coreDirect = (values["coredirect"] ?? "0") == "1"
        splitApps = SplitApps.parse(setting: values["splitapps"])
        multihopEntry = Multihop.entry(setting: values["multihop"])
        exceptions = Self.readLines("/Library/KillSwitch/allow")
        servers = Self.readLines("/Library/KillSwitch/servers")
        let dropweb = Self.readDropwebServers()
        foundServers = dropweb + Self.readHappServers().filter { !dropweb.contains($0) }
    }

    private static func readLines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Plain IPs only: these go into a root command, and profiles/configs are user-writable.
    private static func isPlainIP(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9A-Fa-f:.]{2,45}/) != nil
            && (text.contains(":") || text.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){3}/) != nil)
    }

    /// ASSUMPTION (helper contract, written in parallel): while our core runs and another VPN's
    /// TUN is up, the helper keeps a world-readable file naming it (e.g. "utun5"), and removes it
    /// otherwise. Same pattern as the other state files in /Library/KillSwitch.
    static let foreignVPNFile = "/Library/KillSwitch/core/foreign-vpn"

    private static func readForeignVPN() -> String? {
        guard let text = try? String(contentsOfFile: foreignVPNFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// `server: <ip>` lines from dropweb's profiles.
    private static func readDropwebServers() -> [String] {
        let dir = NSHomeDirectory() + "/Library/Application Support/org.dropweb.vpn/profiles"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".yaml") }.sorted()
        var found: [String] = []
        for file in files {
            let text = (try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)) ?? ""
            for match in text.matches(of: /(?m)^[ \t-]*server:[ \t]*["']?([0-9A-Fa-f:.]{2,45})["']?[ \t]*$/) {
                let address = String(match.1)
                if isPlainIP(address) && !found.contains(address) { found.append(address) }
            }
        }
        return found
    }

    /// Server addresses from Happ's connected Xray config.
    private static func readHappServers() -> [String] {
        let path = NSHomeDirectory() + "/Library/Group Containers/group.su.ffg.happ/Library/Preferences/group.su.ffg.happ.plist"
        guard let prefs = NSDictionary(contentsOfFile: path),
              let json = (prefs["connectedConfigJson"] as? String)?.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let outbounds = config["outbounds"] as? [[String: Any]] else { return [] }
        var servers: [String] = []
        for outbound in outbounds {
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            let entries = (settings["vnext"] as? [[String: Any]] ?? []) + (settings["servers"] as? [[String: Any]] ?? [])
            // Happ's config is user-writable and these go into a root command: plain IPs only.
            // Subscriptions often give a host name: its current addresses are what the tunnel dials.
            for case let address as String in entries.compactMap({ $0["address"] }) {
                for ip in isPlainIP(address) ? [address] : resolve(address)
                where isPlainIP(ip) && !servers.contains(ip) {
                    servers.append(ip)
                }
            }
        }
        return servers
    }

    /// Last known addresses of each host name. Lookups run off the main thread at most once a
    /// minute per name: refresh() runs every 3 s and without a network a lookup can hang.
    private static var resolved: [String: (ips: [String], at: Date)] = [:]

    private static func resolve(_ host: String) -> [String] {
        let cached = resolved[host]
        if cached == nil || Date().timeIntervalSince(cached!.at) > 60 {
            resolved[host] = (cached?.ips ?? [], Date())
            Task.detached {
                let ips = lookup(host)
                await MainActor.run { if !ips.isEmpty { resolved[host] = (ips, Date()) } }
            }
        }
        return cached?.ips ?? []
    }

    /// Addresses of a host name through the system resolver, without the TUN fake-IP range
    /// 198.18.0.0/15 (a VPN answering DNS itself would hand those out).
    nonisolated private static func lookup(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf)
            if !ip.hasPrefix("198.18.") && !ip.hasPrefix("198.19.") && !result.contains(ip) { result.append(ip) }
        }
        return result
    }

    enum Event { case vpnDropped, pauseEnded, daemonOff, macOSUpdated, autoConnectNeedsPassword }

    private func notify(_ event: Event) {
        let defaults = UserDefaults.standard
        let content = UNMutableNotificationContent()
        switch event {
        case .vpnDropped:
            guard defaults.object(forKey: "notifyVPNDropped") as? Bool ?? true else { return }
            content.title = "VPN отключился"
            content.body = "Интернет перекрыт, пока VPN не подключится снова."
        case .pauseEnded:
            guard defaults.object(forKey: "notifyPauseEnded") as? Bool ?? true else { return }
            content.title = "Пауза закончилась"
            content.body = "Защита снова включена."
        case .daemonOff:
            content.title = "Служба защиты выключена"
            content.body = "Включи её в Системных настройках → Основные → Объекты входа."
        case .macOSUpdated:
            content.title = "macOS обновилась"
            content.body = "Перезагрузи Mac и проверь утечки в KillSwitch"
        case .autoConnectNeedsPassword:
            content.title = "VPN не подключился сам"
            content.body = "Для этого нужен пароль. Подключись в KillSwitch вручную или нажми там «Обновить защиту»."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private func notifyIfMacOSUpdated() {
        let current = ProcessInfo.processInfo.operatingSystemVersionString
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: "lastOSVersion"), last != current { notify(.macOSUpdated) }
        defaults.set(current, forKey: "lastOSVersion")
    }

    /// The daemon (ks watch) is what keeps the rules in place; BTM can switch it off in System Settings.
    private func checkDaemon() {
        guard FileManager.default.fileExists(atPath: helper) else { daemonProblem = false; return }
        Task {
            let disabled = await Self.exec("/bin/launchctl", ["print-disabled", "system"]).output
            let running = await Self.exec("/bin/launchctl", ["print", "system/local.killswitch"]).status == 0
            let isDisabled = disabled.contains("\"local.killswitch\" => disabled") || disabled.contains("\"local.killswitch\" => true")
            daemonProblem = isDisabled || !running
            let defaults = UserDefaults.standard
            if daemonProblem {
                if !defaults.bool(forKey: "daemonWarned") {
                    defaults.set(true, forKey: "daemonWarned")
                    notify(.daemonOff)
                }
            } else {
                defaults.set(false, forKey: "daemonWarned")
            }
        }
    }

    func refreshEvents() {
        events = Array(Self.readLines("/Library/KillSwitch/events.log").suffix(15))
    }

    /// Tries to reach 1.1.1.1 straight through the physical interfaces, as an ordinary user.
    /// A reply means the filter has a hole.
    func checkLeak() {
        guard !leakRunning else { return }
        leakRunning = true
        leakResults = []
        Task {
            var interfaces = ["en0"]
            let route = await Self.exec("/sbin/route", ["-n", "get", "default"]).output
            if let match = route.firstMatch(of: /interface:[ \t]*([A-Za-z0-9]+)/) {
                let name = String(match.1)
                if !name.hasPrefix("utun") && !interfaces.contains(name) { interfaces.append(name) }
            }
            for name in interfaces {
                let result = await Self.exec("/usr/bin/curl", ["-s", "-m", "6", "-o", "/dev/null", "--interface", name, "https://1.1.1.1"])
                leakResults.append(LeakResult(interface: name, leaked: result.status == 0))
            }
            let ip = await Self.exec("/usr/bin/curl", ["-s", "-m", "6", "https://api.ipify.org"]).output
            externalIP = Self.isPlainIP(ip) ? ip : nil
            refreshEvents()
            leakRunning = false
        }
    }

    private func listenForWidget() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for command in Shared.Command.allCases {
            CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
                guard let observer, let raw = name?.rawValue as String? else { return }
                let control = Unmanaged<KillSwitchControl>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in control.handle(notification: raw) }
            }, command.notificationName as CFString, nil, .deliverImmediately)
        }
    }

    private func handle(notification: String) {
        switch Shared.Command.allCases.first(where: { $0.notificationName == notification }) {
        case .on: turnOn()
        case .off: turnOff()
        case .pause5: pause(minutes: 5)
        case nil: break
        }
    }

    private static func parse(_ text: String) -> State {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if word == "on" { return .on }
        if word.hasPrefix("paused:"), let epoch = TimeInterval(word.dropFirst(7)) {
            return .paused(until: Date(timeIntervalSince1970: epoch))
        }
        return .off
    }

    /// VPN TUN interfaces (our core, dropweb, Happ) use an address in 198.18.0.0/16; the exact one varies.
    /// VPN tunnels that are up, by their utun's IPv4 address (TunnelAddress).
    private static func vpnTunnels() -> [TunnelAddress.Kind] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [TunnelAddress.Kind] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name).hasPrefix("utun"), ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            let octets = withUnsafeBytes(of: sin.sin_addr) { Array($0) }
            if let kind = TunnelAddress.kind(octets.map(String.init).joined(separator: ".")) { result.append(kind) }
        }
        return result
    }

    /// `separateStderr`: stdout only on success (JSON), stderr on failure.
    private static func exec(_ tool: String, _ args: [String], separateStderr: Bool = false) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            let errPipe = separateStderr ? Pipe() : pipe
            process.standardOutput = pipe
            process.standardError = errPipe
            // read while running: /proxies JSON is larger than the pipe buffer
            let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            let errReader = Task.detached { separateStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data() }
            process.terminationHandler = { p in
                Task {
                    let out = await reader.value, err = await errReader.value
                    let data = p.terminationStatus == 0 || !separateStderr ? out : err
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (p.terminationStatus, text))
                }
            }
            do { try process.run() } catch {
                try? pipe.fileHandleForWriting.close()      // ends the readers
                try? errPipe.fileHandleForWriting.close()
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
