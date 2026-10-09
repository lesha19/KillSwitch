import AppKit
import Foundation
import Observation
import ServiceManagement
import WidgetKit

/// Talks to the root helper `/Library/KillSwitch/ks` through passwordless sudo
/// (granted to this user for that one script by Helper/install.sh).
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
    func turnOff() { run(["off"]) }
    func pause(minutes: Int) { run(["pause", String(minutes)]) }

    func install() { runAsAdmin(script: "install.sh", args: [NSUserName()]) }
    func uninstall() { runAsAdmin(script: "uninstall.sh", args: []) }

    func refresh() {
        vpnUp = Self.dropwebTunnelUp()
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

    /// Runs a bundled helper script as root; macOS asks for the password once.
    private func runAsAdmin(script: String, args: [String]) {
        guard let path = Bundle.main.path(forResource: script, ofType: nil, inDirectory: "Helper") else {
            error = "Не найден \(script) внутри программы"
            return
        }
        let command = (["/bin/bash", path] + args).map { "quoted form of \"\($0)\"" }.joined(separator: " & \" \" & ")
        let source = "do shell script \(command) with administrator privileges"
        busy = true
        Task {
            var info: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&info)
            if let info, (info[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = user cancelled
                error = info[NSAppleScript.errorMessage] as? String ?? "Ошибка установки"
            } else if output != nil {
                error = nil
            }
            busy = false
            refresh()
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
