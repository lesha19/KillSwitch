import Foundation

/// The watchdog's state file (`/Library/KillSwitch/daemon-state`, Helper/ks `publish_state`): what
/// `ks state` and `ks core state` would answer, read without sudo. Lines `key=value`; the daemon
/// rewrites it only when something changes and removes it when it stops.
struct DaemonState: Equatable {
    static let path = "/Library/KillSwitch/daemon-state"

    var pid: pid_t
    var protection: Protection
    var coreRunning: Bool
    /// `vpn:<utuns> ts:<utuns>`: changes with every tunnel that comes or goes.
    var tunnels: String

    /// Nil unless it names the daemon's pid and the protection state.
    init?(text: String) {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let raw = values["pid"], let pid = pid_t(raw), pid > 1,
              let word = values["protection"], !word.isEmpty else { return nil }
        self.pid = pid
        protection = Self.protection(word)
        coreRunning = values["core"] == "on"
        tunnels = values["tunnels"] ?? ""
    }

    /// The word of `ks state` (and of the state file): on | off | paused:<epoch>.
    static func protection(_ text: String) -> Protection {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if word == "on" { return .on }
        if word.hasPrefix("paused:"), let epoch = TimeInterval(word.dropFirst(7)) {
            return .paused(until: Date(timeIntervalSince1970: epoch))
        }
        return .off
    }

    /// Whether a process with this pid exists. The daemon runs as root, so signal 0 from the user
    /// is refused with EPERM: that still means it is there.
    static func alive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The file, if its writer still runs; nil means: ask the helper the old way.
    static func read(path: String = path) -> DaemonState? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let state = DaemonState(text: text), alive(state.pid) else { return nil }
        return state
    }
}
