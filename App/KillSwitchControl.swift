import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications
import WidgetKit

/// Talks to the root helper `/Library/KillSwitch/ks`.
/// Reading the state and turning protection on go through passwordless sudo (Helper/install.sh
/// grants exactly `ks state` and `ks on`); everything that loosens protection asks for the
/// admin password, so another program running as the user cannot do it silently.
@MainActor
@Observable
final class KillSwitchControl {
    enum State: Equatable {
        case unknown
        case notInstalled
        case on
        case off
        case paused(until: Date)

        var symbol: String {
            switch self {
            case .on: "lock.shield.fill"
            case .off, .paused: "shield.slash"
            case .notInstalled, .unknown: "shield"
            }
        }

        var title: String {
            switch self {
            case .on: "Защита включена"
            case .off: "Защита выключена"
            case .paused: "Защита на паузе"
            case .notInstalled: "Защита не установлена"
            case .unknown: "Проверяю…"
            }
        }

        /// Format stored for the widget.
        var stored: String {
            switch self {
            case .on: "on"
            case .off, .unknown: "off"
            case .paused(let until): "paused:\(Int(until.timeIntervalSince1970))"
            case .notInstalled: "notInstalled"
            }
        }
    }

    private(set) var state: State = .unknown
    private(set) var vpnUp = false
    private(set) var error: String?
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
    private(set) var events: [String] = []
    private(set) var leakResults: [LeakResult] = []
    private(set) var externalIP: String?
    private(set) var leakRunning = false
    /// Our own VPN core (mihomo run by the root daemon), see `ks core`.
    private(set) var coreInstalled = false
    private(set) var coreConfigured = false
    private(set) var coreRunning = false

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
    /// The core's config decides what goes around the VPN, so taking a new one asks for the password.
    func coreImport() {
        guard let profile = Self.dropwebProfile() else {
            error = "Не найден профиль dropweb. Обнови подписку в dropweb."
            return
        }
        runAsAdmin([helper, "core", "import", profile])
    }

    /// Also used to upgrade the installed helper: install.sh keeps settings and lists.
    func install() { runBundled("install.sh", [NSUserName()] + foundServers) }
    func uninstall() { runBundled("uninstall.sh", []) }

    func refresh() {
        let wasVPNUp = vpnUp
        vpnUp = Self.dropwebTunnelUp()
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
            Task { coreRunning = await Self.exec("/usr/bin/sudo", ["-n", helper, "core", "state"]).output == "on" }
        } else {
            coreRunning = false
        }
        Task {
            let result = await Self.exec("/usr/bin/sudo", ["-n", helper, "state"])
            guard result.status == 0 else {
                error = result.output.isEmpty ? "Нет доступа к защите" : result.output
                return
            }
            error = nil
            publish(Self.parse(result.output))
        }
    }

    private func publish(_ new: State) {
        let defaults = Shared.defaults
        let changed = new != state || defaults?.bool(forKey: Shared.vpnKey) != vpnUp
        if case .paused = state, new == .on { notify(.pauseEnded) }
        state = new
        guard changed else { return }
        defaults?.set(new.stored, forKey: Shared.stateKey)
        defaults?.set(vpnUp, forKey: Shared.vpnKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            let result = await Self.exec("/usr/bin/sudo", ["-n", helper] + args)
            error = result.status == 0 ? nil : result.output
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
        let quoted = command.map { "quoted form of \"\($0)\"" }.joined(separator: " & \" \" & ")
        let source = "do shell script \(quoted) with administrator privileges"
        busy = true
        Task {
            var info: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&info)
            if let info, (info[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = user cancelled
                error = info[NSAppleScript.errorMessage] as? String ?? "Не получилось"
            } else if output != nil {
                error = nil
            }
            busy = false
            refresh()
        }
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

    /// dropweb's most recently updated profile.
    private static func dropwebProfile() -> String? {
        let dir = NSHomeDirectory() + "/Library/Application Support/org.dropweb.vpn/profiles"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".yaml") }
        let dated = files.map { name -> (String, Date) in
            let path = dir + "/" + name
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            return (path, date)
        }
        return dated.max { $0.1 < $1.1 }?.0
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
            for case let address as String in entries.compactMap({ $0["address"] })
            where isPlainIP(address) && !servers.contains(address) {
                servers.append(address)
            }
        }
        return servers
    }

    enum Event { case vpnDropped, pauseEnded, daemonOff, macOSUpdated }

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

    /// VPN TUN interfaces (dropweb, Happ) use an address in 198.18.0.0/16; the exact one varies.
    private static func dropwebTunnelUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name).hasPrefix("utun") else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            if UInt32(bigEndian: sin.sin_addr.s_addr) & 0xFFFF0000 == 0xC6120000, ifa.ifa_flags & UInt32(IFF_UP) != 0 {
                return true
            }
        }
        return false
    }

    private static func exec(_ tool: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (p.terminationStatus, text))
            }
            do { try process.run() } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
