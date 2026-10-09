import Foundation
import Observation

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
    }

    private(set) var state: State = .unknown
    private(set) var vpnUp = false
    private(set) var error: String?
    private(set) var busy = false

    private let helper = "/Library/KillSwitch/ks"
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func turnOn() { run(["on"]) }
    func turnOff() { run(["off"]) }
    func pause(minutes: Int) { run(["pause", String(minutes)]) }

    func refresh() {
        vpnUp = Self.dropwebTunnelUp()
        guard FileManager.default.fileExists(atPath: helper) else {
            state = .notInstalled
            return
        }
        Task {
            let result = await Self.sudo(helper, ["state"])
            guard result.status == 0 else {
                error = result.output.isEmpty ? "Нет доступа к защите" : result.output
                return
            }
            error = nil
            state = Self.parse(result.output)
        }
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            let result = await Self.sudo(helper, args)
            error = result.status == 0 ? nil : result.output
            busy = false
            refresh()
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

    private static func sudo(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", path] + args
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
