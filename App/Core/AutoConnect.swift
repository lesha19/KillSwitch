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
        /// «Сети Wi‑Fi» (WiFiRules).
        var rules: [WiFiRules.Rule] = []
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

    /// A network's own «Подключаться автоматически» connects there even when the general switch is
    /// off or the network is in the trusted list: on a conflict the more protective answer wins.
    static func decide(_ settings: Settings, network: Network, core: Core) -> Decision {
        let ruleConnects = network.wifi && WiFiRules.rule(for: network.ssid, in: settings.rules)?.autoConnect == true
        guard settings.enabled || ruleConnects else { return .skip(.disabled) }
        guard network.online else { return .skip(.offline) }
        guard core.ready else { return .skip(.notReady) }
        guard !core.connected else { return .skip(.connected) }
        guard !core.otherVPN else { return .skip(.otherVPN) }
        if ruleConnects { return .connect }
        if settings.skipTrusted, network.wifi, let ssid = network.ssid, settings.trusted.contains(ssid) {
            return .skip(.trusted(ssid))
        }
        return .connect
    }

    /// «Подключаться автоматически» is on unless the person turned it off (wizard or Settings):
    /// by default the VPN connects in every network.
    static func enabled(stored: Bool?) -> Bool { stored ?? true }

    /// Trusted networks are opt-in: until some are named, no network is trusted.
    static func skipTrusted(stored: Bool?) -> Bool { stored ?? false }

    /// macOS 14 and later give an app the Wi-Fi name (CoreWLAN `ssid()`) only with Location
    /// access; without it every Wi-Fi counts as untrusted, which Settings has to say.
    static func trustedNeedsLocation(skipTrusted: Bool, locationAllowed: Bool) -> Bool {
        skipTrusted && !locationAllowed
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
