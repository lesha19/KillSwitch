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
    private(set) var allowRouterDNS = false
    private(set) var exceptions: [String] = []
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

    func install() { runBundled("install.sh", [NSUserName()]) }
    func uninstall() { runBundled("uninstall.sh", []) }

    func refresh() {
        let wasVPNUp = vpnUp
        vpnUp = Self.dropwebTunnelUp()
        if wasVPNUp && !vpnUp && state == .on { notify(.vpnDropped) }
        readSettings()
        guard FileManager.default.fileExists(atPath: helper) else {
            publish(.notInstalled)
            return
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
        allowRouterDNS = (values["dns"] ?? "0") == "1"
        let allow = (try? String(contentsOfFile: "/Library/KillSwitch/allow", encoding: .utf8)) ?? ""
        exceptions = allow.split(separator: "\n").map(String.init)
    }

    enum Event { case vpnDropped, pauseEnded }

    private func notify(_ event: Event) {
        let defaults = UserDefaults.standard
        let content = UNMutableNotificationContent()
        switch event {
        case .vpnDropped:
            guard defaults.object(forKey: "notifyVPNDropped") as? Bool ?? true else { return }
            content.title = "VPN отключился"
            content.body = "Интернет перекрыт, пока dropweb не подключится снова."
        case .pauseEnded:
            guard defaults.object(forKey: "notifyPauseEnded") as? Bool ?? true else { return }
            content.title = "Пауза закончилась"
            content.body = "Защита снова включена."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
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

    /// dropweb's TUN interface carries the gateway address 198.18.0.1.
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
            if sin.sin_addr.s_addr == inet_addr("198.18.0.1"), ifa.ifa_flags & UInt32(IFF_UP) != 0 {
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
