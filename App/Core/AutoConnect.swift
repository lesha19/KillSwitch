import Foundation

/// «Подключаться автоматически»: whether to start the core when the app starts or the network
/// changes. Untrusted networks always connect; a Wi-Fi whose name is unknown (macOS hides it
/// without Location permission) counts as untrusted.
enum AutoConnect {
    struct Settings: Equatable {
        var enabled: Bool
        /// «Не подключаться в доверенных сетях Wi-Fi».
        var skipTrusted: Bool
        var trusted: [String]
    }

    struct Network: Equatable {
        var online: Bool
        var wifi: Bool
        var ssid: String?
        /// Physical interfaces in use (en0, en5…).
        var interfaces: [String]

        /// Tells one network from another, so a change can be noticed; nil while offline.
        var identity: String? {
            guard online else { return nil }
            if wifi, let ssid { return "wifi:" + ssid }
            return "if:" + interfaces.sorted().joined(separator: ",")
        }
    }

    struct Core: Equatable {
        /// Helper and core installed, a profile imported.
        var ready: Bool
        /// Connected or connecting.
        var connected: Bool
        /// Another program's VPN is up: two tunnels fight, so leave it to the user.
        var otherVPN: Bool
    }

    enum Reason: Equatable {
        case disabled, offline, connected, notReady, otherVPN
        case trusted(String)
    }

    enum Decision: Equatable {
        case connect
        case skip(Reason)
    }

    static func decide(_ settings: Settings, network: Network, core: Core) -> Decision {
        guard settings.enabled else { return .skip(.disabled) }
        guard network.online else { return .skip(.offline) }
        guard core.ready else { return .skip(.notReady) }
        guard !core.connected else { return .skip(.connected) }
        guard !core.otherVPN else { return .skip(.otherVPN) }
        if settings.skipTrusted, network.wifi, let ssid = network.ssid, settings.trusted.contains(ssid) {
            return .skip(.trusted(ssid))
        }
        return .connect
    }

    /// Trimmed, without empties and repeats, order kept.
    static func normalized(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty && !result.contains(name) {
            result.append(name)
        }
        return result
    }
}
