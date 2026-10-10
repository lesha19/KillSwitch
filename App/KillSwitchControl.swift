import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications
import WidgetKit

/// Talks to the root helper `/Library/KillSwitch/ks`.
/// Reading the state, turning protection on and driving the core go through passwordless sudo
/// (Helper/install.sh grants `ks state`, `ks on`, `ks netrestore`, `ks core on|off|state|proxies|select|delay|refresh`);
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
    private(set) var error: UserError? {
        didSet { if let error, error != oldValue { remember(error) } }
    }
    /// Server choice and latency tests; kept apart from `error` (the helper and the actions).
    private(set) var coreError: UserError? {
        didSet { if let coreError, coreError != oldValue { remember(coreError) } }
    }
    /// Raw texts of the last errors, for «Скопировать диагностику».
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
    private(set) var manualServers: [String] = []    // /Library/KillSwitch/servers-manual
    private(set) var daemonProblem = false
    /// The service is gone and left the network services off (its boot guard): «Включить сеть».
    private(set) var networkLeftOff = false
    /// `sudo -n ks state` wants a password: the helper was installed by an older app.
    private(set) var needsRepair = false
    /// The installed helper is not the one this app carries (HelperVersion): «Восстановить службу…».
    private(set) var helperOutdated = false
    /// Modification date of the installed helper when it was last compared.
    private var helperComparedAt: Date?
    /// When the current connection attempt started; nil unless connecting.
    private(set) var connectingSince: Date?
    /// Moves on with every refresh while connecting, so «Подключение затянулось» shows up in time.
    private(set) var clock = Date()
    private(set) var events: [String] = []
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
    private(set) var proxiesError: UserError?
    /// Results of the user's latency tests (ms, `CoreDelay.timeout` = no answer); fresher than
    /// the core's history, which `delay(of:)` falls back to.
    private(set) var measured: [String: Int] = [:]
    /// Groups whose latency test is running; `allGroupsKey` while the whole list is tested.
    private(set) var testing: Set<String> = []
    static let allGroupsKey = "\u{0}all"

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = UserError(title: "Не получилось изменить запуск при входе", message: error.localizedDescription,
                                       details: error.localizedDescription)
            }
        }
    }

    /// Second layer, see FilterControl.
    let filter = FilterControl()

    private let helper = "/Library/KillSwitch/ks"
    private var timer: Timer?
    /// Changes in /Library/KillSwitch: the watchdog rewrites its state file there (DaemonState).
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: Task<Void, Never>?
    /// The popover, the window or Settings is open: the timer runs every 3 s and the server list
    /// stays fresh; otherwise the app mostly waits for the watchdog's state file to change.
    private var openViews = 0
    /// The watchdog's state file is there and its writer runs: no sudo polling.
    private var daemonStateLive = false
    /// The error the last failed state read showed: the next good read clears it, not an action's.
    private var statePollError: UserError?

    init() {
        notifyIfMacOSUpdated()
        refresh()
        listenForWidget()
    }

    func viewAppeared() {
        openViews += 1
        if openViews == 1 { refresh() }
    }

    func viewDisappeared() {
        openViews = max(0, openViews - 1)
        scheduleTimer()
    }

    /// The timer is the fallback: with a live state file it only moves the clock and catches what
    /// the watchdog does not publish (settings files, the other VPN's tunnel).
    private func scheduleTimer() {
        let interval: TimeInterval = openViews > 0 ? 3 : daemonStateLive ? 30 : 10
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The helper replaces its files by rename, which changes the directory: one refresh per burst.
    private func watchHelperDirectory() {
        guard watcher == nil else { return }
        let fd = open("/Library/KillSwitch", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.helperDirectoryChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func helperDirectoryChanged() {
        if !FileManager.default.fileExists(atPath: "/Library/KillSwitch") {   // uninstalled
            watcher?.cancel()
            watcher = nil
        }
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func turnOn() { run(["on"]) }
    func turnOff() { runAsAdmin([helper, "off"]) }
    func pause(minutes: Int) { runAsAdmin([helper, "pause", String(minutes)]) }

    /// «Пауза до переподключения»: a day-long pause that the app ends as soon as the VPN connects
    /// again (after a drop, when it was connected at the time); without the app the helper ends it
    /// after a day anyway.
    func pauseUntilReconnect() {
        UserDefaults.standard.set(connection == .connected ? "afterDrop" : "armed", forKey: Self.resumeKey)
        pause(minutes: 24 * 60)
    }

    private static let resumeKey = "resumeProtectionOnConnect"

    private func resumeIfReconnected() {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: Self.resumeKey) else { return }
        guard state.isPaused else {
            if state == .on || state == .off { defaults.removeObject(forKey: Self.resumeKey) }
            return
        }
        if connection == .connected {
            guard mode == "armed" else { return }
            defaults.removeObject(forKey: Self.resumeKey)
            turnOn()
        } else if mode == "afterDrop" {
            defaults.set("armed", forKey: Self.resumeKey)
        }
    }

    func set(_ key: String, _ on: Bool) { runAsAdmin([helper, "set", key, on ? "1" : "0"]) }

    /// «Что можно без VPN»: the switches of the sheet, all changes behind one password.
    var switches: [String: Bool] {
        ["lan": allowLAN, "tailscale": allowTailscale, "dns": allowRouterDNS, "wifiguard": wifiGuard]
    }
    func setSwitches(_ values: [String: Bool]) { runAsAdmin(batch: Batch.settings(helper: helper, old: switches, new: values)) }
    /// «Адреса без VPN»: the edited list, one password.
    func setExceptions(_ list: [String]) {
        runAsAdmin(batch: Batch.list(helper: helper, add: "allow", remove: "unallow", old: exceptions, new: list))
    }

    /// Always a click: the list decides what goes around the VPN.
    func setSplitApps(_ names: [String]) { runAsAdmin([helper, "set", "splitapps", SplitApps.argument(names)]) }
    /// `entry` nil turns «Двойной VPN» off. Always a click.
    func setMultihop(entry: String?) { runAsAdmin([helper, "set", "multihop", entry ?? Multihop.off]) }

    /// «Адреса серверов для других VPN-программ»: VPN servers are reachable by any process (Happ's
    /// tunnel runs as the ordinary user and cannot be told apart from other apps), so only these
    /// addresses are let out. The edited list, one password.
    func setManualServers(_ list: [String]) {
        runAsAdmin(batch: Batch.list(helper: helper, add: "server-add", remove: "server-remove", old: manualServers, new: list))
    }

    /// Starting and stopping never widen the rules, so they go without a password.
    /// Connects, then applies the server chosen while disconnected.
    func coreOn() {
        busy = true
        Task {
            switch await callHelper(["core", "on"], interactive: true) {
            case .ok:
                error = nil
                await applyPendingChoice()
            case .failed(let message): error = UserError.from(raw: message.isEmpty ? "ks core on: failed" : message, context: .helper)
            case .needsPassword, .cancelled: break
            }
            busy = false
            refresh()
        }
    }

    /// A server picked while disconnected (ServerPicker path), applied by the next «Подключить».
    private(set) var pendingChoice: ServerPicker.Entry? = KillSwitchControl.loadPending()
    /// The server of the last connection, shown while disconnected.
    private(set) var lastServer = UserDefaults.standard.string(forKey: "lastServer")

    private static let pendingKey = "pendingServer"

    /// «Выбор сервера»: switches the running core at once, or remembers the choice for «Подключить».
    func choose(_ entry: ServerPicker.Entry) {
        guard coreRunning else {
            pendingChoice = entry
            if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
            return
        }
        busy = true
        Task {
            for step in entry.path { await select(group: step.group, proxy: step.proxy) }
            busy = false
        }
    }

    /// The core's API comes up a moment after `ks core on`: a few tries, then give up quietly
    /// (the core keeps its own last choice).
    private func applyPendingChoice() async {
        guard let entry = pendingChoice else { return }
        pendingChoice = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        for step in entry.path {
            for attempt in 0..<6 {
                if case .ok = await callHelper(["core", "select", step.group, step.proxy], interactive: false) { break }
                if attempt < 5 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        loadProxies(force: true)
    }

    private static func loadPending() -> ServerPicker.Entry? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(ServerPicker.Entry.self, from: data)
    }
    func coreOff() {
        disconnecting = true
        run(["core", "off"])
    }

    /// «Отключить» was pressed: the tunnel going down is no drop.
    private var disconnecting = false
    /// Our tunnel dropped by itself; «VPN снова работает» follows when it is back.
    private var dropped = false

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
            error = UserError.from(raw: message.isEmpty ? "Не получилось подключиться автоматически" : message, context: .helper)
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
        case .failed(let message): coreError = UserError.from(raw: message, context: .helper)
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
                coreError = UserError.from(raw: "no server of \(group.name) answered", context: .latency)
                return .failed
            } catch {
                coreError = UserError.from(raw: error.localizedDescription, context: .helper)
                return .failed
            }
        case .failed(let message):
            coreError = UserError.from(raw: message.isEmpty ? "no answer" : message, context: .latency)
            return .failed
        case .needsPassword, .cancelled:
            return .refused
        }
    }

    /// «Лучший»: tests a selector group and picks its fastest member.
    func selectBest(group: CoreProxies.Group) async {
        guard group.selectable, await testDelay(group: group) else { return }
        guard let best = CoreDelay.best(of: group.all, delays: measured) else {
            coreError = UserError.from(raw: "no server of \(group.name) answered", context: .latency)
            return
        }
        if best != group.now {
            busy = true
            await select(group: group.name, proxy: best)
            busy = false
        }
    }

    /// `ks core proxies`, at most every 5 s while the app is open (every minute otherwise) unless
    /// forced; only while the core runs. Runs from the timer too, so it never asks for the password.
    func loadProxies(force: Bool = false) {
        guard coreRunning else { proxies = nil; proxiesError = nil; measured = [:]; return }
        let interval: TimeInterval = openViews > 0 ? 5 : 60
        guard !proxiesLoading, force || Date().timeIntervalSince(proxiesLoadedAt) > interval else { return }
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
                    if let server = currentServer, server != lastServer {
                        lastServer = server
                        UserDefaults.standard.set(server, forKey: "lastServer")
                    }
                } else {
                    proxiesError = UserError.from(raw: "proxies: not a JSON list", context: .serverList)
                }
            case .needsPassword:
                proxiesError = UserError.problem(.needsAccess)
            case .failed(let message):
                proxiesError = UserError.from(raw: message.isEmpty ? "proxies: no answer" : message, context: .serverList)
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
        switch await adminRun([[helper] + args]) {
        case .ok(let output): return .ok(output)
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Also used to upgrade the installed helper: install.sh keeps settings and lists.
    func install() {
        readFoundServers()
        runBundled("install.sh", [NSUserName()] + foundServers)
    }

    /// The service is on this Mac (the helper may still be broken or switched off).
    var serviceInstalled: Bool { FileManager.default.fileExists(atPath: helper) }

    /// «Начало работы», step «Установка»: install.sh (unless the service is there), the import of
    /// `profile` and connecting, as one admin command — one password, and the protection that
    /// install.sh turns on never finds the Mac without a VPN.
    func setUp(profile: String) async -> Bool {
        let installed = serviceInstalled
        var script: String?
        if !installed {
            guard let path = Bundle.main.path(forResource: "install.sh", ofType: nil, inDirectory: "Helper") else {
                error = UserError.problem(.vpnMissing)
                return false
            }
            script = path
        }
        busy = true
        defer { busy = false; refresh() }
        if script != nil, !(await Self.bundleIntact()) {
            error = .damagedApp
            return false
        }
        readFoundServers()
        let commands = Onboarding.commands(installScript: script, user: NSUserName(), servers: foundServers, helper: helper,
                                           profile: profile)
        switch await adminRun(commands) {
        case .ok:
            error = nil
            measured = [:]
            await applyPendingChoice()
            return true
        case .cancelled:
            return false
        case .failed(let message):
            error = UserError.from(raw: message, context: installed ? .helper : .install)
            return false
        }
    }
    func uninstall() { runBundled("uninstall.sh", []) }

    func refresh() {
        let wasVPNUp = vpnUp
        let tunnels = Self.vpnTunnels()
        vpnUp = !tunnels.isEmpty
        let wasOwnUp = ownTunnelUp
        let manual = disconnecting
        ownTunnelUp = tunnels.contains(.own)
        if wasOwnUp && !ownTunnelUp {
            if !disconnecting {
                dropped = true
                // with protection on the drop is told above, for any tunnel
                if state != .on { notify(.vpnDropped(protected: false)) }
            }
            disconnecting = false
        } else if !wasOwnUp && ownTunnelUp {
            if dropped { notify(.reconnected(server: lastServer.map(ServerName.display))) }
            dropped = false
            disconnecting = false
        }
        if wasVPNUp && !vpnUp && state == .on && !manual { notify(.vpnDropped(protected: true)) }
        readSettings()
        defer { scheduleTimer() }
        guard FileManager.default.fileExists(atPath: helper) else {
            daemonProblem = false; networkLeftOff = false
            daemonStateLive = false
            helperOutdated = false; helperComparedAt = nil
            publish(.notInstalled)
            return
        }
        watchHelperDirectory()
        compareHelper()
        coreInstalled = FileManager.default.fileExists(atPath: "/Library/KillSwitch/core/mihomo")
        coreConfigured = FileManager.default.fileExists(atPath: "/Library/KillSwitch/core/config.yaml")
        if let daemon = DaemonState.read() {
            // the watchdog runs and says what `ks state` / `ks core state` would: no sudo, no launchctl
            daemonStateLive = true
            daemonRuns(true)
            coreRunning = coreInstalled && daemon.coreRunning
            if !coreRunning { proxies = nil }
            foreignVPN = coreRunning ? Self.readForeignVPN() : nil
            trackConnecting()
            loadProxies()
            needsRepair = false
            clearStatePollError()
            publish(daemon.protection)
            return
        }
        daemonStateLive = false
        checkDaemon()
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
                if !needsRepair {
                    let failure = UserError.from(raw: result.output.isEmpty ? "ks state: no answer" : result.output, context: .helper)
                    error = failure
                    statePollError = failure
                }
                return
            }
            needsRepair = false
            clearStatePollError()
            publish(DaemonState.protection(result.output))
        }
    }

    /// Again only when the installed helper's file changed (install.sh replaces it).
    private func compareHelper() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: helper))?[.modificationDate] as? Date
        guard modified != helperComparedAt else { return }
        helperComparedAt = modified
        let bundled = Bundle.main.path(forResource: "ks", ofType: nil, inDirectory: "Helper").flatMap(FileManager.default.contents(atPath:))
        helperOutdated = HelperVersion.matches(installed: FileManager.default.contents(atPath: helper), bundled: bundled) == false
    }

    private func clearStatePollError() {
        if let statePollError, error == statePollError { error = nil }
        statePollError = nil
    }

    private func trackConnecting() {
        resumeIfReconnected()
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
            case .failed(let message): error = UserError.from(raw: message.isEmpty ? "ks \(args.joined(separator: " ")): failed" : message, context: .helper)
            case .needsPassword, .cancelled: break
            }
            busy = false
            refresh()
        }
    }

    private func runBundled(_ script: String, _ args: [String]) {
        guard let path = Bundle.main.path(forResource: script, ofType: nil, inDirectory: "Helper") else {
            error = UserError.problem(.vpnMissing)
            return
        }
        busy = true
        Task {
            let intact = await Self.bundleIntact()
            busy = false
            guard intact else { error = .damagedApp; return }
            runAsAdmin(["/bin/bash", path] + args, context: script == "install.sh" ? .install : .helper)
        }
    }

    /// The bundle's scripts are about to run as root (BundleSignature); checked off the main thread,
    /// nested code takes a moment.
    private static func bundleIntact() async -> Bool {
        let bundle = Bundle.main.bundleURL
        return await Task.detached(priority: .userInitiated) { BundleSignature.isValid(bundle) }.value
    }

    /// Runs a command as root; macOS asks for the admin password every time.
    private func runAsAdmin(_ command: [String], context: UserError.Context = .helper) {
        runAsAdmin(batch: [command], context: context)
    }

    /// Several commands behind one password; the first failure stops the rest.
    private func runAsAdmin(batch commands: [[String]], context: UserError.Context = .helper) {
        guard !commands.isEmpty else { return }
        busy = true
        Task {
            switch await adminRun(commands) {
            case .ok: error = nil
            case .cancelled: break
            case .failed(let message): error = UserError.from(raw: message, context: context)
            }
            busy = false
            refresh()
        }
    }

    /// The admin prompt and the command run in their own process (AdminScript.run), so the app
    /// keeps drawing while the password is typed and install.sh works.
    private func adminRun(_ commands: [[String]]) async -> AdminScript.Outcome {
        await AdminScript.run(commands)
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
        manualServers = Self.readLines("/Library/KillSwitch/servers-manual")
        if Date().timeIntervalSince(foundServersAt) > 60 { readFoundServers() }
    }

    private var foundServersAt = Date.distantPast

    /// dropweb's profiles and Happ's config: at most once a minute from refresh(), always before
    /// they go into an install.
    private func readFoundServers() {
        foundServersAt = Date()
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

    /// Written by the watchdog (Helper/ks tun_guard, world-readable): while our core runs and another
    /// VPN's TUN takes a default or wide route next to it, the names of those utuns ("utun5"); removed
    /// otherwise.
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
    /// minute per name: refresh() runs every few seconds and without a network a lookup can hang.
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

    private func notify(_ notice: UserNotice) { Notifier.shared.post(notice) }

    private func notifyIfMacOSUpdated() {
        let current = ProcessInfo.processInfo.operatingSystemVersionString
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: "lastOSVersion"), last != current { notify(.macOSUpdated) }
        defaults.set(current, forKey: "lastOSVersion")
    }

    /// The daemon (ks watch) is what keeps the rules in place; BTM can switch it off in System Settings.
    /// Asked only while the watchdog's state file is missing or stale (see DaemonState).
    private func checkDaemon() {
        Task {
            let disabled = await Self.exec("/bin/launchctl", ["print-disabled", "system"]).output
            let running = await Self.exec("/bin/launchctl", ["print", "system/local.killswitch"]).status == 0
            let isDisabled = disabled.contains("\"local.killswitch\" => disabled") || disabled.contains("\"local.killswitch\" => true")
            daemonRuns(!isDisabled && running)
        }
    }

    private func daemonRuns(_ runs: Bool) {
        daemonProblem = !runs
        networkLeftOff = !runs && FileManager.default.fileExists(atPath: "/Library/KillSwitch/wifi-off-by-ks")
        let defaults = UserDefaults.standard
        if daemonProblem {
            if !defaults.bool(forKey: "daemonWarned") {
                defaults.set(true, forKey: "daemonWarned")
                notify(.serviceOff)
            }
        } else if defaults.bool(forKey: "daemonWarned") {
            defaults.set(false, forKey: "daemonWarned")
        }
    }

    private func remember(_ error: UserError) {
        recentErrors = Array((recentErrors + [error.details.isEmpty ? error.title : error.details]).suffix(5))
    }

    func dismissError() { error = nil }

    /// «Включить сеть»: `ks netrestore` turns back on the network services the stopped service
    /// had turned off. Passwordless since 0.9.1; an older sudoers falls back to the prompt.
    func restoreNetwork() { run(["netrestore"]) }

    /// «Перезапустить VPN»: the core is running but its API does not answer.
    func restartCore() {
        busy = true
        Task {
            _ = await callHelper(["core", "off"], interactive: true)
            switch await callHelper(["core", "on"], interactive: true) {
            case .ok: error = nil
            case .failed(let message): error = UserError.from(raw: message, context: .helper)
            case .needsPassword, .cancelled: break
            }
            busy = false
            refresh()
            loadProxies(force: true)
        }
    }

    func refreshEvents() {
        events = Array(Self.readLines("/Library/KillSwitch/events.log").suffix(15))
    }

    /// Part of «Проверка утечек» while protection is on: tries to reach 1.1.1.1 straight through
    /// the physical interfaces, as an ordinary program. The interfaces that answered are a hole.
    func probeDirectExits() async -> [String] {
        var interfaces = ["en0"]
        let route = await Self.exec("/sbin/route", ["-n", "get", "default"]).output
        if let match = route.firstMatch(of: /interface:[ \t]*([A-Za-z0-9]+)/) {
            let name = String(match.1)
            if !name.hasPrefix("utun") && !interfaces.contains(name) { interfaces.append(name) }
        }
        var open: [String] = []
        for name in interfaces {
            let result = await Self.exec("/usr/bin/curl", ["-s", "-m", "6", "-o", "/dev/null", "--interface", name, "https://1.1.1.1"])
            if result.status == 0 { open.append(name) }
        }
        return open
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
        guard let command = Shared.Command(notificationName: notification) else { return }
        guard command.needsConfirmation else { turnOn(); return }
        // the main window asks first (HomeView); a click there may then bring the password prompt
        widgetRequest = command
        Notifier.shared.openWindow?("main")
        NSApp.activate()
    }

    /// Off or pause asked by the widget, waiting for «Выключить» / «Пауза» in the app.
    private(set) var widgetRequest: Shared.Command?

    /// `confirmed`: the request the person agreed to, as the alert showed it; nil cancels.
    func answerWidgetRequest(_ confirmed: Shared.Command?) {
        widgetRequest = nil
        switch confirmed {
        case .off: turnOff()
        case .pause5: pause(minutes: 5)
        case .on, nil: break
        }
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
