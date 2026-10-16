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
/// With the privileged daemon allowed (ADR 0010, HelperClient) the same commands go through it
/// instead, and the password (or Touch ID) is asked at most once every five minutes; without it,
/// or when it does not answer, sudo and the AppleScript prompt work as before.
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
    private(set) var manualServers: [String] = []    // /Library/KillSwitch/servers-manual
    private(set) var daemonProblem = false
    /// A settings file of the service is damaged and protection blocks the internet; loopback, DHCP and the local network (not its DNS) still work (#83) (#17): «Сбросить настройки».
    private(set) var settingsDamaged = false
    /// The service is gone and left the network services off (its boot guard): «Включить сеть».
    private(set) var networkLeftOff = false
    /// `sudo -n ks state` wants a password: the helper was installed by an older app.
    private(set) var needsRepair = false
    /// The installed helper is not the one this app carries (HelperVersion): «Восстановить службу…».
    private(set) var helperOutdated = false
    /// The daemon is putting the bundled helper in place after an app update (ADR 0012): no
    /// «Восстановить службу…» meanwhile; it shows only if that fails.
    private(set) var upgradingHelper = false
    /// The running daemon is older than this app (it still runs until idle): the app's commands go
    /// around it through sudo, so it leaves and launchd starts the new one.
    private var daemonOutdated = false
    /// The daemon answered that it cannot run the bundled scripts (no verified copy of the app):
    /// install.sh / uninstall.sh go straight to the password prompt, without its right's dialog first.
    private var daemonCannotRunScripts = false
    /// Modification dates of the installed helper and its marker when they were last compared.
    private var helperComparedAt: [Date?]?
    /// When the current connection attempt started; nil unless connecting.
    private(set) var connectingSince: Date?
    /// Moves on with every refresh while connecting, so «Подключение затянулось» shows up in time.
    private(set) var clock = Date()
    private(set) var events: [String] = []
    /// Our own VPN core (mihomo run by the root daemon), see `ks core`.
    private(set) var coreInstalled = false
    private(set) var coreConfigured = false
    private(set) var coreRunning = false
    /// Which way of connecting the helper runs (ADR 0020): Xray («Основной») or mihomo («Запасной»).
    private(set) var coreChoice: CoreChoice = .mihomo
    /// «Блокировать рекламу и трекеры»: the core refuses category-ads-all of the shipped geosite.dat.
    private(set) var adBlock = false
    /// The other blocked categories of the shipped geosite.dat (ADR 0031): adult sites, social networks, betting.
    private(set) var blockAdult = false
    private(set) var blockSocial = false
    private(set) var blockBetting = false
    /// The own DNS-over-HTTPS server (`doh=`, ADR 0031), used by the core through the VPN; nil = none.
    private(set) var ownDoH: String?
    /// «Подробная диагностика» (diag, ADR 0021): Xray records every connection in the local journal.
    private(set) var diagVerbose = false
    /// Xray: a server that stops answering is tried with another TLS fingerprint or another transport
    /// the subscription offers (escalate, ADR 0030); the server itself never changes (ADR 0036).
    private(set) var escalate = true
    /// «Собрать отчёт» is running, and why the last one failed (nil after a good one).
    private(set) var reportBusy = false
    private(set) var reportError: String?
    /// «Раздельный туннель»: process names that go around the VPN (the user's own addition, ADR 0013).
    private(set) var splitApps: [String] = []
    /// «Двойной VPN»: the entry server; the exit is the selected one. Nil = off.
    private(set) var multihopEntry: String?
    /// «Размер пакетов VPN» (ADR 0032): nil = «Авто».
    private(set) var tunnelMTU: Int?
    /// When the person last changed «Двойной VPN» or the way of connecting: an off within two
    /// minutes of it is theirs, any other is the helper's and is told (ADR 0027).
    private var multihopAskedAt: Date?
    /// Set while another VPN's TUN is up next to our core (see `foreignVPNFile`).
    private(set) var foreignVPN: String?
    /// Protection stands by while another VPN is up and ours is not (ADR 0018, the watchdog's file).
    private(set) var protectionStandby = false
    /// The VPN is on, from «Подключить» to «Отключить» (ADR 0035): pf blocks whatever the switch says.
    private(set) var vpnOn = false
    /// Our tunnel has been up since this «Подключить» (ADR 0035): its going is a reconnect, not the
    /// first connect. Kept across launches by the VPN target's content (the epoch of «Подключить»).
    private(set) var tunnelWasUp = false
    private static let tunnelSeenKey = "tunnelSeenForVPNOn"
    /// The VPN is on and the helper says the rules are not loaded: traffic may be leaking.
    private(set) var rulesMissing = false
    /// The watchdog's stuck=1 last read: the notification goes out when it turns on (#85).
    private var vpnStuck = false
    static let vpnOnPath = "/Library/KillSwitch/vpn-on"
    /// The helper's VPN target on disk, for when the watchdog's file does not say.
    private static var vpnOnFile: Bool { FileManager.default.fileExists(atPath: vpnOnPath) }
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
                self.error = UserError(title: String(localized: "Не получилось изменить запуск при входе"), message: error.localizedDescription,
                                       details: error.localizedDescription)
            }
        }
    }

    /// Second layer, see FilterControl.
    let filter = FilterControl()

    /// The privileged daemon (ADR 0010).
    let helperClient = HelperClient()
    /// Its state in System Settings › Login Items; `.needsApproval` shows HelperApprovalNote.
    private(set) var helperAvailability: HelperService.Availability = .unavailable

    /// «Разреши KillSwitch в Объектах входа…» on the main screen, at most once a day (HelperService).
    private(set) var helperApprovalBanner = false

    private func updateHelperAvailability() {
        let current = helperClient.availability
        if current != helperAvailability {
            let previous = helperAvailability
            helperAvailability = current
            if HelperService.upgradeWhenReady(previous: previous, current: current, helperOutdated: helperOutdated) { upgradeHelper() }
        }
        let defaults = UserDefaults.standard
        if HelperService.showApprovalBanner(helperInstalled: FileManager.default.fileExists(atPath: helper), availability: current,
                                            lastShown: defaults.object(forKey: "helperApprovalShown") as? Date, now: Date()) {
            defaults.set(Date(), forKey: "helperApprovalShown")
            helperApprovalBanner = true
        }
    }

    func dismissHelperApprovalBanner() { helperApprovalBanner = false }

    /// ADR 0010 at launch: a helper installed without the daemon (from before 0.13, or its
    /// registration lost) gets it registered once, so Touch ID and the passwordless upgrade work.
    private func registerHelperAtLaunch() {
        let installed = FileManager.default.fileExists(atPath: helper)
        let availability = helperClient.availability
        HelperClient.log.notice("launch: helper installed \(installed, privacy: .public), daemon \(String(describing: availability), privacy: .public)")
        if HelperService.launchStep(helperInstalled: installed, availability: availability) == .register {
            helperClient.register()
        }
        updateHelperAvailability()
    }

    /// «Восстановить службу» and the wizard: registers the daemon when it is not yet. While macOS
    /// waits for the switch in Login Items, this one change still goes through the password prompt.
    private func prepareHelper() {
        if helperClient.availability == .needsRegistration { helperClient.register() }
        updateHelperAvailability()
    }

    private let helper = FilterGate.helperPath
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
    /// A refresh when a boot guard mark's 20 s are up (NetworkMark.recheck): the timer may be 30 s away.
    private var markRecheck: Task<Void, Never>?

    init() {
        notifyIfMacOSUpdated()
        registerHelperAtLaunch()
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

    func turnOn() { run(["on"], userInitiated: true) }
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
            run(["on"], userInitiated: false)   // not a click: passwordless `ks on` or nothing
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
    /// The own DNS-over-HTTPS server; nil clears it. Always a click.
    func setDoH(_ url: String?) { runAsAdmin([helper, "set", "doh", url ?? ""]) }
    /// `entry` nil turns «Двойной VPN» off. Always a click.
    func setMultihop(entry: String?) {
        multihopAskedAt = Date()
        runAsAdmin([helper, "set", "multihop", entry ?? Multihop.off])
    }
    /// `ks set mtu`: the config rebuilt and the VPN restarted (about a second, the protection blocks).
    func setMTU(_ mtu: Int?) { runAsAdmin([helper] + HelperCommand.setMTU(mtu).arguments) }
    /// «Адреса серверов для других VPN-программ»: VPN servers are reachable by any process (Happ's
    /// tunnel runs as the ordinary user and cannot be told apart from other apps), so only these
    /// addresses are let out. The edited list, one password.
    func setManualServers(_ list: [String]) {
        runAsAdmin(batch: Batch.list(helper: helper, add: "server-add", remove: "server-remove", old: manualServers, new: list))
    }

    /// «Перенос настроек» (SettingsBackup, ADR 0024): the root settings as Settings shows them.
    var rootSettings: SettingsBackup.Root {
        .init(switches: switches.merging(["direct": allowDirect, "adblock": adBlock, "diag": diagVerbose,
                                                      "escalate": escalate, "blockadult": blockAdult, "blocksocial": blockSocial,
                                                      "blockbetting": blockBetting]) { $1 },
              exceptions: exceptions, manualServers: manualServers, splitApps: splitApps, doh: ownDoH ?? "", mtu: tunnelMTU ?? 0)
    }
    /// A loaded or reset set of root settings: the commands of their own screens, one password;
    /// `done` after they went through (nothing to run: at once).
    func applySettings(_ new: SettingsBackup.Root, then done: @escaping @MainActor () async -> Void) {
        let commands = SettingsBackup.rootCommands(helper: helper, current: rootSettings, new: new)
        if commands.isEmpty { Task { await done() } } else { runAsAdmin(batch: commands, then: done) }
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
    private(set) var lastServer = UserDefaults.standard.string(forKey: Subscriptions.lastKey).flatMap(ServerID.init(stored:))

    private static let pendingKey = Subscriptions.pendingKey

    /// The subscription (or ServerID.own) whose profile the helper was handed last (ADR 0036);
    /// VPNClient sets it on every import.
    private(set) var activeSubscription = UserDefaults.standard.string(forKey: Subscriptions.activeKey) ?? ServerID.own

    func setActiveSubscription(_ id: String) {
        guard id != activeSubscription else { return }
        activeSubscription = id
        UserDefaults.standard.set(id, forKey: Subscriptions.activeKey)
    }

    /// «Выбор сервера»: switches the running core at once, or remembers the choice for «Подключить».
    func choose(_ entry: ServerPicker.Entry) {
        setChosen(entry.server)
        serversDown = nil
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

    /// «Предпочитаемый сервер» of a Wi-Fi network (WiFiRules): like `choose`, but never asks for a
    /// password, since nobody clicked.
    func chooseAutomatically(_ entry: ServerPicker.Entry) async {
        setChosen(entry.server)
        serversDown = nil
        guard coreRunning else {
            pendingChoice = entry
            if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
            return
        }
        for step in entry.path {
            _ = await callHelper(["core", "select", step.group, step.proxy], interactive: false)
        }
        loadProxies(force: true)
    }

    /// A server of the subscription just imported (VPNClient.choose): chosen as on «Подключить»,
    /// since the core's API may take a moment to come back after the import.
    func chooseImported(_ entry: ServerPicker.Entry) async {
        setChosen(entry.server)
        serversDown = nil
        pendingChoice = entry
        if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
        if coreRunning { await applyPendingChoice() }
    }

    /// A deleted subscription's chosen, last and waiting server (ADR 0036): the home screen no
    /// longer names it. Subscriptions.remove clears what was stored.
    func forget(subscription: String) {
        if chosenServer?.subscription == subscription { chosenServer = nil }
        if lastServer?.subscription == subscription { lastServer = nil }
        if pendingChoice?.subscription == subscription { pendingChoice = nil }
    }

    /// The current server in «Выбор сервера» terms: the running core's choice, else the one
    /// waiting for «Подключить».
    var pickedServer: String? {
        if coreRunning, let proxies { return ServerPicker.selected(proxies) }
        return pendingChoice?.name
    }

    // MARK: the chosen server went silent (nothing switches by itself, ADR 0036)

    /// The server the person picked last.
    private(set) var chosenServer = UserDefaults.standard.string(forKey: KillSwitchControl.chosenKey).flatMap(ServerID.init(stored:))
    /// The chosen server, as displayed, while it does not answer; the person picks what next.
    private(set) var serversDown: String?

    private static let chosenKey = Subscriptions.chosenKey

    private func setChosen(_ server: ServerID?) {
        chosenServer = server
        UserDefaults.standard.set(server?.stored, forKey: Self.chosenKey)
    }

    /// After every server list from the core: tells once when the chosen server stopped answering.
    private func checkServers(_ proxies: CoreProxies) {
        let chosen = chosenServer.flatMap { $0.subscription == activeSubscription ? $0.name : nil }
        let server = NetworkCause.serverDown(chosen: chosen, proxies: proxies)
        if let server, serversDown != server { notify(.serversDown(server: server)) }
        serversDown = server
    }

    // MARK: why nothing works (NetworkCause, ADR 0006)

    /// Set while nothing answers and `ks probe` found why; the home screen's banner.
    private(set) var networkCause: NetworkCause?
    private(set) var probing = false
    private var lastProbe: Date?

    /// After every server list: probes the network (passwordless, at most once a minute) only
    /// while no server answers or the chosen country is down; clears the cause once they answer.
    private func checkNetwork(_ proxies: CoreProxies, force: Bool = false) {
        let answer = NetworkCause.serversAnswer(proxies)
        guard answer == false || serversDown != nil, foreignVPN == nil else { networkCause = nil; return }
        guard !probing, force || NetworkCause.shouldProbe(serversAnswer: answer, serversDown: serversDown != nil,
                                                          last: lastProbe, now: Date(), otherVPN: foreignVPN != nil) else { return }
        probing = true
        lastProbe = Date()
        Task {
            let result = await callHelper(["probe"], interactive: false)
            probing = false
            // an older helper without `ks probe`: no explanation, as before
            guard case .ok(let output) = result, let probe = NetworkCause.Probe(output) else { return }
            networkCause = NetworkCause.classify(probe, serversAnswer: self.proxies.flatMap(NetworkCause.serversAnswer) ?? answer)
        }
    }

    // MARK: another program's VPN (OtherVPN, ADR 0009)

    /// Its name while one is up instead of ours; nil = unknown («другой VPN») or none.
    private(set) var otherVPNName: String?
    /// Its VPN configurations that `scutil --nc stop` can turn off.
    private(set) var otherVPNServices: [OtherVPN.Service] = []
    /// Its app, opened when it cannot be stopped from here.
    private(set) var otherVPNApp: URL?
    /// «Отключить … и подключить KillSwitch» did not bring its tunnel down.
    private(set) var otherVPNStopFailed = false
    private var readingOtherVPN = false
    /// Its tunnel going down after our stop is no drop.
    private var stoppingOtherVPN = false

    var otherVPNActive: Bool { foreignVPN != nil || connection == .otherApp }

    var otherVPNRemedy: OtherVPN.Remedy {
        OtherVPN.remedy(stoppable: !otherVPNServices.isEmpty, stopFailed: otherVPNStopFailed, appKnown: otherVPNApp != nil)
    }

    /// After every refresh while another VPN is up: `scutil --nc list` (read-only, no password)
    /// and the running apps say who it is.
    private func readOtherVPN() {
        guard otherVPNActive else {
            otherVPNName = nil; otherVPNServices = []; otherVPNApp = nil; otherVPNStopFailed = false
            return
        }
        guard !readingOtherVPN else { return }
        readingOtherVPN = true
        Task {
            let services = OtherVPN.services(await Self.exec("/usr/sbin/scutil", ["--nc", "list"]).output)
            let running = NSWorkspace.shared.runningApplications
            otherVPNServices = OtherVPN.stoppable(services)
            otherVPNName = OtherVPN.name(services: services, runningApps: running.compactMap(\.localizedName))
            otherVPNApp = Self.appURL(of: otherVPNServices, running: running)
            readingOtherVPN = false
        }
    }

    private static func appURL(of services: [OtherVPN.Service], running: [NSRunningApplication]) -> URL? {
        for provider in services.compactMap(\.provider) {
            for id in OtherVPN.appCandidates(provider: provider) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
            }
        }
        return running.first { OtherVPN.knownApps.contains(($0.localizedName ?? "").lowercased()) }?.bundleURL
    }

    /// «Отключить Happ и подключить KillSwitch»: `scutil --nc stop` as the user (no password), then
    /// ours once the other tunnel is gone. If it stays up (on-demand rules, an app that refuses),
    /// the main screen says to turn it off in its app and offers to open it.
    func replaceOtherVPN() {
        let ids = otherVPNServices.map(\.id)
        guard !ids.isEmpty else { return }
        busy = true
        otherVPNStopFailed = false
        stoppingOtherVPN = true
        Task {
            for id in ids { _ = await Self.exec("/usr/sbin/scutil", ["--nc", "stop", id]) }
            var gone = false
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if !Self.vpnTunnels().contains(.other) { gone = true; break }
            }
            busy = false
            refresh()
            stoppingOtherVPN = false
            if gone { coreOn() } else { otherVPNStopFailed = true }
        }
    }

    /// «Проверить снова».
    func recheckNetwork() {
        guard let proxies else { return }
        checkNetwork(proxies, force: true)
    }

    /// The core's API comes up a moment after `ks core on`: a few tries, then give up quietly
    /// (the core keeps its own last choice).
    private func applyPendingChoice() async {
        guard let entry = pendingChoice else { return }
        pendingChoice = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        // a server of another subscription waits for its import (VPNClient.choose)
        guard entry.subscription == activeSubscription else { return }
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
        // the VPN stays on (the core did not stop): the next drop is one again
        run(["core", "off"], userInitiated: true) { [self] in disconnecting = false }
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
            await applyPendingChoice()   // a server picked while disconnected, or a network's preferred one
            return true
        case .needsPassword:
            notify(.autoConnectNeedsPassword)
        case .failed(let message):
            error = UserError.from(raw: message.isEmpty ? String(localized: "Не получилось подключиться автоматически") : message, context: .helper)
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
    /// `others`: the other subscriptions' profiles, approved with this one (ADR 0036).
    func coreImport(file: String, others: [String] = [], allowPassword: Bool) async -> ImportResult {
        busy = true
        defer { busy = false; refresh() }
        switch await callHelper(["core", "import", file] + others, interactive: allowPassword) {
        case .ok: measured = [:]; return .ok
        case .needsPassword: return .needsPassword
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message.isEmpty ? String(localized: "Не получилось") : message)
        }
    }

    /// Subscription auto-update: the same as import, but through passwordless sudo only and
    /// refused by the helper (exit 3) if the profile brings new server addresses. Never prompts.
    func coreRefresh(file: String) async -> RefreshOutcome {
        busy = true
        defer { busy = false; refresh() }
        let result = await readHelper(["core", "refresh", file])
        let outcome = RefreshOutcome(status: result.status, output: result.output)
        if outcome == .applied { measured = [:] }
        return outcome
    }

    /// Another subscription's profile, without a prompt: refused by the helper (exit 3) unless the
    /// last import approved its servers and DIRECT (ADR 0036).
    func coreUse(file: String) async -> RefreshOutcome {
        busy = true
        defer { busy = false; refresh() }
        let result = await readHelper(["core", "use", file])
        let outcome = RefreshOutcome(status: result.status, output: result.output)
        if outcome == .applied { measured = [:] }
        return outcome
    }

    /// Picks a server in a selector group of the running core. Always a click.
    func coreSelect(group: String, proxy: String) {
        if group == proxies?.mainGroup?.name { setChosen(ServerID(subscription: activeSubscription, name: proxy)) }
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
        // with Xray the observatory's last probes (ADR 0023)
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
        guard coreRunning else {
            proxies = nil; proxiesError = nil; measured = [:]; serversDown = nil; networkCause = nil
            return
        }
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
                    checkServers(parsed)
                    checkNetwork(parsed)
                    if let name = currentServer, ServerID(subscription: activeSubscription, name: name) != lastServer {
                        lastServer = ServerID(subscription: activeSubscription, name: name)
                        UserDefaults.standard.set(lastServer?.stored, forKey: Subscriptions.lastKey)
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
    static let groupOrderKey = CoreProxies.groupOrderKey

    private static func sudoWantsPassword(_ output: String) -> Bool {
        RefreshOutcome.sudoWantsPassword(output)
    }

    enum HelperResult: Equatable { case ok(String), needsPassword, cancelled, failed(String) }

    /// `ks <args>` through passwordless sudo; if sudoers does not allow it (older helper), the
    /// admin prompt follows only when `interactive` — a user's click, never a timer.
    private func callHelper(_ args: [String], interactive: Bool, separateStderr: Bool = false) async -> HelperResult {
        if helperAvailability == .ready, !daemonOutdated, let command = HelperCommand(ks: args) {
            switch await helperClient.send(command, interactive: interactive) {
            case .reply(let reply):
                if reply.status == 0 { return .ok(reply.text(separateStderr: separateStderr)) }
                if reply.needsAuthorization { return interactive ? .failed(reply.text(separateStderr: false)) : .needsPassword }
                return .failed(reply.text(separateStderr: separateStderr))
            case .cancelled: return .cancelled
            case .unreachable: break   // sudo and the password prompt, as before
            }
        }
        let result = await Self.exec("/usr/bin/sudo", ["-n", helper] + args, separateStderr: separateStderr)
        if result.status == 0 { return .ok(result.output) }
        guard Self.sudoWantsPassword(result.output) else { return .failed(result.output) }
        guard interactive else { return .needsPassword }
        switch await adminRun([[helper] + args], .init(reason: AdminGate.reason([[helper] + args]), userInitiated: interactive)) {
        case .ok(let output): return .ok(output)
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Also used to upgrade the installed helper: install.sh keeps settings and lists.
    func install() {
        prepareHelper()
        runBundled("install.sh", [NSUserName()])
    }

    /// The service is on this Mac (the helper may still be broken or switched off).
    var serviceInstalled: Bool { FileManager.default.fileExists(atPath: helper) }

    /// «Начало работы», step «Установка»: install.sh (unless the service is there), the import of
    /// `profile` and connecting, as one admin command — one password, and the protection that
    /// install.sh turns on never finds the Mac without a VPN.
    func setUp(profile: String, core: CoreChoice? = nil) async -> Bool {
        prepareHelper()
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
        let commands = Onboarding.commands(installScript: script, user: NSUserName(), servers: [], helper: helper,
                                           profile: profile, core: core)
        switch await adminRun(commands, .init(reason: AdminGate.reason(commands), userInitiated: true)) {   // the wizard's button
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
    /// Then the filter is switched off (#55) and the daemon goes too (uninstall.sh removes its authorization right).
    func uninstall() {
        runBundled("uninstall.sh", []) { [self] in
            await filter.turnOff()
            await helperClient.unregister()
            updateHelperAvailability()
        }
    }

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
                // with protection off it is told here; the VPN still on blocks all the same (ADR 0035)
                if state != .on { notify(.vpnDropped(protected: Self.vpnOnFile)) }
            }
            disconnecting = false
        } else if !wasOwnUp && ownTunnelUp {
            NotificationCenter.default.post(name: UpdateRetry.vpnConnected, object: nil)
            if dropped { notify(.reconnected(server: lastServer.map { ServerName.display($0.name) })) }
            dropped = false
            disconnecting = false
        }
        if wasVPNUp && !vpnUp && state == .on && !manual && !stoppingOtherVPN { notify(.vpnDropped(protected: true)) }
        readSettings()
        updateHelperAvailability()
        readOtherTunnels()
        defer { scheduleTimer(); readOtherVPN(); syncSpeed() }
        guard FileManager.default.fileExists(atPath: helper) else {
            // a new install runs the main way when the app carries it (install.sh, ADR 0020)
            coreChoice = Bundle.main.path(forResource: "xray", ofType: nil, inDirectory: "Helper") != nil ? .xray : .mihomo
            daemonProblem = false; networkLeftOff = false
            daemonStateLive = false
            vpnOn = false; rulesMissing = false
            helperOutdated = false; helperComparedAt = nil
            publish(.notInstalled)
            return
        }
        watchHelperDirectory()
        compareHelper()
        coreChoice = CoreChoice.current()
        coreInstalled = FileManager.default.fileExists(atPath: coreChoice.binary)
        coreConfigured = FileManager.default.fileExists(atPath: coreChoice.config)
        if let daemon = DaemonState.read() {
            // the watchdog runs and says what `ks state` / `ks core state` would: no sudo, no launchctl
            daemonStateLive = true
            daemonRuns(true)
            protectionStandby = daemon.standby
            vpnOn = daemon.vpnOn ?? Self.vpnOnFile
            rulesMissing = vpnOn && daemon.blocking == false
            if daemon.stuck && !vpnStuck { notify(.vpnStuck) }   // once each time it gets stuck (#85)
            vpnStuck = daemon.stuck
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
        protectionStandby = false
        vpnOn = Self.vpnOnFile
        checkDaemon()
        if coreInstalled {
            Task {
                // "on", possibly followed by more words in later helpers
                coreRunning = await readHelper(["core", "state"]).output.hasPrefix("on")
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
            let result = await readHelper(["state"])
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
            // without the watchdog's file: "ks state" says on only while the rules are loaded
            rulesMissing = vpnOn && DaemonState.protection(result.output) != .on
            publish(DaemonState.protection(result.output))
        }
    }

    /// Again only when the installed helper's file or install.sh's marker changed (install.sh
    /// replaces them), or while an install may still be running.
    private func compareHelper() {
        let date = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        let modified = date(helper)
        let key = [modified, date(HelperVersion.markerPath)]
        guard key != helperComparedAt else { return }
        helperComparedAt = key
        speedUnavailable = false   // another helper may allow `core traffic`
        let bundled = Bundle.main.path(forResource: "ks", ofType: nil, inDirectory: "Helper").flatMap(FileManager.default.contents(atPath:))
        let check = HelperVersion.check(installed: FileManager.default.contents(atPath: helper), bundled: bundled,
                                        marker: FileManager.default.contents(atPath: HelperVersion.markerPath),
                                        age: modified.map { Date().timeIntervalSince($0) } ?? .infinity)
        if check == .installing { helperComparedAt = nil }   // look again with the next refresh
        helperOutdated = check == .outdated
        if helperOutdated { upgradeHelper() }
    }

    /// ADR 0012: after an app update the daemon puts the new helper in place, without a password
    /// and without dropping the VPN. A daemon of the old build (it has no `upgrade`) is waited out:
    /// it leaves when nothing runs, after two idle minutes (from 0.14 on also as soon as its app was
    /// replaced). Without the daemon, or if it fails, «Восстановить службу…» stays, as before.
    private func upgradeHelper() {
        guard !upgradingHelper, helperClient.availability == .ready else { return }
        upgradingHelper = true
        Task {
            defer { upgradingHelper = false; daemonOutdated = false }
            let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            for _ in 0..<12 {   // 4 minutes: the old daemon's 2 idle minutes and its 30 s timer
                guard helperOutdated else { return }
                if let build = await helperClient.daemonBuild(), HelperUpgrade.daemonIsCurrent(daemonBuild: build, appBuild: app) {
                    daemonOutdated = false
                    switch await helperClient.send(.upgrade, interactive: false) {
                    case .reply(let reply) where reply.status == 0:
                        notify(.updateInstalled(coreRestarted: HelperUpgrade.outcome(reply.stdout) == .coreRestarted))
                        helperComparedAt = nil
                        refresh()
                        return
                    case .reply(let reply):
                        recentErrors.append("helper upgrade: " + reply.text(separateStderr: false))
                        if HelperCommand.upgrade.fallsBackToPassword(reply) { daemonCannotRunScripts = true }
                        return
                    case .cancelled, .unreachable:
                        break
                    }
                } else {
                    daemonOutdated = true
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func clearStatePollError() {
        if let statePollError, error == statePollError { error = nil }
        statePollError = nil
    }

    private func trackConnecting() {
        resumeIfReconnected()
        trackTunnelSeen()
        // the VPN on and our core not running yet (or not starting): connecting as well (Status)
        guard connection == .connecting || vpnOn && connection == .disconnected else { connectingSince = nil; return }
        if connectingSince == nil { connectingSince = Date() }
        clock = Date()
    }

    private func trackTunnelSeen() {
        guard vpnOn, let target = try? String(contentsOfFile: Self.vpnOnPath, encoding: .utf8) else { tunnelWasUp = false; return }
        if ownTunnelUp { UserDefaults.standard.set(target, forKey: Self.tunnelSeenKey) }
        tunnelWasUp = UserDefaults.standard.string(forKey: Self.tunnelSeenKey) == target
    }

    private func publish(_ new: State) {
        let defaults = Shared.defaults
        let changed = new != state || defaults?.bool(forKey: Shared.vpnKey) != ownTunnelUp
        if case .paused = state, new == .on { notify(.pauseEnded) }
        state = new
        settingsDamaged = !DaemonState.lockdown(invalid: try? String(contentsOfFile: DaemonState.invalidPath, encoding: .utf8),
                                                protection: new).isEmpty
        syncFilter()
        guard changed else { return }
        defaults?.set(new.stored, forKey: Shared.stateKey)
        defaults?.set(ownTunnelUp, forKey: Shared.vpnKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// `userInitiated`: a click (or the widget) may fall back to the password prompt; anything else
    /// only tries the passwordless way.
    /// `failed`: run unless the helper did it.
    private func run(_ args: [String], userInitiated: Bool, failed: (() -> Void)? = nil) {
        busy = true
        Task {
            switch await callHelper(args, interactive: userInitiated) {
            case .ok: error = nil
            case .failed(let message):
                error = UserError.from(raw: message.isEmpty ? "ks \(args.joined(separator: " ")): failed" : message, context: .helper)
                failed?()
            case .needsPassword, .cancelled: failed?()
            }
            busy = false
            refresh()
        }
    }

    private func runBundled(_ script: String, _ args: [String], then done: (@MainActor () async -> Void)? = nil) {
        guard let path = Bundle.main.path(forResource: script, ofType: nil, inDirectory: "Helper") else {
            error = UserError.problem(.vpnMissing)
            return
        }
        busy = true
        Task {
            let intact = await Self.bundleIntact()
            busy = false
            guard intact else { error = .damagedApp; return }
            runAsAdmin(batch: [AdminScript.bundled(path, args)], context: script == "install.sh" ? .install : .helper, then: done)
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

    /// Several commands behind one password; the first failure stops the rest. Only the user's
    /// actions call it (AdminGateTests keeps launch and refresh code away from it).
    private func runAsAdmin(batch commands: [[String]], context: UserError.Context = .helper,
                            then done: (@MainActor () async -> Void)? = nil) {
        guard !commands.isEmpty else { return }
        busy = true
        Task {
            switch await adminRun(commands, .init(reason: AdminGate.reason(commands), userInitiated: true)) {
            case .ok:
                error = nil
                await done?()
            case .cancelled: break
            case .failed(let message): error = UserError.from(raw: message, context: context)
            }
            busy = false
            refresh()
        }
    }

    /// Through the daemon when it is allowed: one authorization for the whole batch, none within
    /// five minutes of the last. Otherwise the admin prompt and the command run in their own
    /// process (AdminScript.run), so the app keeps drawing while the password is typed and
    /// install.sh works. Nothing runs and nothing is asked unless AdminGate lets the request through
    /// (a user action); a refused one counts as cancelled.
    private func adminRun(_ commands: [[String]], _ request: AdminGate.Request) async -> AdminScript.Outcome {
        guard AdminGate.permit(request) else { return .cancelled }
        if helperAvailability == .ready {
            let typed = commands.compactMap { HelperCommand(command: $0, helper: helper) }
            let skip = daemonCannotRunScripts && typed.contains { $0.program != .ks }
            if typed.count == commands.count, !skip, let outcome = await daemonRun(typed) { return outcome }
        }
        return await AdminScript.run(commands)
    }

    /// The batch in the daemon, stopping at the first failure like `&&`. Nil when the daemon did
    /// not answer the first command or could not run it (`fallsBackToPassword`), so nothing ran yet
    /// and the password prompt can take over.
    private func daemonRun(_ commands: [HelperCommand]) async -> AdminScript.Outcome? {
        var output: [String] = []
        for (index, command) in commands.enumerated() {
            switch await helperClient.send(command, interactive: true) {
            case .unreachable:
                return index == 0 ? nil : .failed("Служба KillSwitch не ответила")
            case .cancelled:
                return .cancelled
            case .reply(let reply):
                if command.fallsBackToPassword(reply) {
                    recentErrors.append("daemon: " + reply.text(separateStderr: false))
                    daemonCannotRunScripts = true
                    // nothing of this command ran: the password prompt runs it (and the rest)
                    if index == 0 { return nil }
                }
                let text = reply.text(separateStderr: false), failure = reply.failureText(command.program)
                guard reply.status == 0 else { return .failed(failure.isEmpty ? "Не получилось" : failure) }
                if !text.isEmpty { output.append(text) }
            }
        }
        return .ok(output.joined(separator: "\n"))
    }

    /// A passwordless read (`ks state`, `core state`, `core refresh`): the daemon, else sudo -n.
    private func readHelper(_ args: [String]) async -> (status: Int32, output: String) {
        if helperAvailability == .ready, !daemonOutdated, let command = HelperCommand(ks: args), !command.needsAuthorization,
           case .reply(let reply) = await helperClient.send(command, interactive: false) {
            return (reply.status, reply.text(separateStderr: false))
        }
        return await Self.exec("/usr/bin/sudo", ["-n", helper] + args)
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
        adBlock = (values["adblock"] ?? "0") == "1"
        blockAdult = (values["blockadult"] ?? "0") == "1"
        blockSocial = (values["blocksocial"] ?? "0") == "1"
        blockBetting = (values["blockbetting"] ?? "0") == "1"
        ownDoH = values["doh"].flatMap { $0.isEmpty ? nil : $0 }
        diagVerbose = (values["diag"] ?? "0") == "1"
        escalate = (values["escalate"] ?? "1") == "1"
        splitApps = SplitApps.parse(setting: values["splitapps"])
        tunnelMTU = TunnelMTU.value(setting: values["mtu"])
        let entry = Multihop.entry(setting: values["multihop"])
        let asked = multihopAskedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        if Multihop.turnedOffByItself(was: multihopEntry, now: entry, asked: asked), let was = multihopEntry {
            notify(.doubleVPNOff(entry: ServerName.display(was)))
        }
        multihopEntry = entry
        exceptions = Self.readLines("/Library/KillSwitch/allow")
        servers = Self.readLines("/Library/KillSwitch/servers")
        manualServers = Self.readLines("/Library/KillSwitch/servers-manual")
    }

    private static func readLines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
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
        let markAge = NetworkMark.age()
        networkLeftOff = NetworkMark.leftOff(age: markAge, daemonRuns: runs)
        markRecheck?.cancel()
        markRecheck = NetworkMark.recheck(age: markAge, daemonRuns: runs).map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
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
    func restoreNetwork() { run(["netrestore"], userInitiated: true) }
    /// «Сбросить настройки»: `ks repair` (#17), behind the password like any change that opens something.
    func resetSettings() { runAsAdmin([helper, "repair"]) }

    /// «Перезапустить VPN»: the core is running but its API does not answer. One `ks core restart`:
    /// the VPN stays on and pf blocks throughout (ADR 0035), unlike «off» then «on».
    func restartCore() {
        busy = true
        Task {
            switch await callHelper(["core", "restart"], interactive: true) {
            case .ok: error = nil
            case .failed(let message): error = UserError.from(raw: message, context: .helper)
            case .needsPassword, .cancelled: break
            }
            busy = false
            refresh()
            loadProxies(force: true)
        }
    }

    /// «Собрать отчёт» (ADR 0021): `ks diag report` into the Desktop without a password (the daemon,
    /// else sudo), then the archive is shown in Finder.
    func collectReport() {
        guard !reportBusy else { return }
        reportBusy = true
        Task {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? ""
            let result = await readHelper(["diag", "report", desktop])
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            if result.status == 0, path.hasPrefix(desktop + "/"), FileManager.default.fileExists(atPath: path) {
                reportError = nil
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                reportError = result.output.isEmpty ? String(localized: "Не получилось собрать отчёт") : result.output
                recentErrors.append("report: " + result.output)
            }
            reportBusy = false
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
        Router.shared.go(.window)
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

    // MARK: speed in the menu bar (TrafficSpeed)

    /// «Скорость в строке меню» (Settings › Общие), off by default.
    static let speedKey = "menuBarSpeed"
    /// ↓/↑ while connected and the setting is on; nil otherwise.
    private(set) var speed: TrafficSpeed.Speed?
    /// The installed helper does not let `ks core traffic` run without a password.
    private(set) var speedUnavailable = false
    private var speedMeter = TrafficSpeed()
    private var speedTimer: Timer?
    private var readingSpeed = false

    /// Asks the core once a second, only while the setting is on and our VPN is connected.
    func syncSpeed() {
        let wanted = UserDefaults.standard.bool(forKey: Self.speedKey) && connection == .connected && !speedUnavailable
        if wanted, speedTimer == nil {
            speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readSpeed() }
            }
            readSpeed()
        } else if !wanted, let timer = speedTimer {
            timer.invalidate()
            speedTimer = nil
            speed = nil
            speedMeter = TrafficSpeed()
        }
    }

    private func readSpeed() {
        guard !readingSpeed else { return }
        readingSpeed = true
        Task {
            // never the password prompt: a timer asks
            switch await callHelper(["core", "traffic"], interactive: false) {
            case .ok(let output):
                if let totals = TrafficSpeed.Totals(output), let value = speedMeter.add(totals, at: Date()) { speed = value }
            case .needsPassword:
                speedUnavailable = true
                syncSpeed()
            case .failed, .cancelled:
                break
            }
            readingSpeed = false
        }
    }

    // MARK: «Трафик» (ADR 0013)

    /// What the core took from the subscription, left out and added: the helper's report.
    private(set) var routing: RoutingReport?

    func readRouting() {
        routing = RoutingReport.read()
    }

    /// The core's open connections, while «Соединения» is on screen and not paused.
    private(set) var connections: CoreConnections?
    /// The installed helper does not have `ks core connections` (older than this app) or does not
    /// let it run without a password.
    private(set) var connectionsUnavailable = false
    private var connectionsTimer: Timer?
    private var readingConnections = false

    /// Once a second while `on`; the view turns it on when it appears and off when it goes or is paused.
    func watchConnections(_ on: Bool) {
        if on, connectionsTimer == nil {
            connectionsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readConnections() }
            }
            readConnections()
        } else if !on, let timer = connectionsTimer {
            timer.invalidate()
            connectionsTimer = nil
        }
    }

    private func readConnections() {
        guard !readingConnections, coreRunning, coreChoice.hasConnections else { return }
        readingConnections = true
        Task {
            // never the password prompt: a timer asks
            switch await callHelper(["core", "connections"], interactive: false, separateStderr: true) {
            case .ok(let output):
                connections = try? CoreConnections(data: Data(output.utf8))
                connectionsUnavailable = false
            case .needsPassword:
                connectionsUnavailable = true
                watchConnections(false)
            case .failed, .cancelled:
                break
            }
            readingConnections = false
        }
    }

    /// Another VPN's tunnels beyond the 198.18 address (OtherVPN.tunnels): `netstat -rn` as the
    /// user, after every refresh.
    private(set) var otherTunnels: [String] = []
    private var readingTunnels = false

    private func readOtherTunnels() {
        guard !readingTunnels else { return }
        readingTunnels = true
        Task {
            let routes = await Self.exec("/usr/sbin/netstat", ["-rn"]).output
            let found = OtherVPN.tunnels(routes: routes, addresses: Self.interfaceAddresses())
            if found != otherTunnels { otherTunnels = found }
            readingTunnels = false
        }
    }

    /// «Частный узел iCloud» and overlay networks on this Mac (NetworkHints), read when a screen
    /// with tips appears: the system's relay status (only that key) and the interfaces and apps.
    func networkHints() -> [NetworkHints.Hint] {
        let archive = CFPreferencesCopyAppValue("NSPServiceStatusManagerInfo" as CFString,
                                                "com.apple.networkserviceproxy" as CFString) as? Data
        let relay = NetworkHints.relayOn(status: archive.flatMap(NetworkHints.relayStatus))
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return NetworkHints.hints(relayOn: relay, overlays: NetworkHints.overlays(addresses: Self.interfaceAddresses(), runningApps: apps))
    }

    /// IPv4 and IPv6 addresses of every interface, without the `%scope`.
    private static func interfaceAddresses() -> [OtherVPN.Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [OtherVPN.Address] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "%").first.map(String.init) ?? ""
            result.append(OtherVPN.Address(interface: String(cString: ptr.pointee.ifa_name), address: address))
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
