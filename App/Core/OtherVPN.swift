import Foundation

/// Another program's VPN (Happ, v2RayTun, Hiddify…) is up instead of ours (ADR 0009): who it is,
/// and how to turn it off without root. VPN apps built on Network Extension appear in
/// `scutil --nc list`, and `scutil --nc stop <id>` disconnects them as the ordinary user. Apps
/// that run their own TUN (dropweb and other Clash clients) do not appear there: they are known
/// by name only, and the person turns them off in the app.
enum OtherVPN {
    struct Service: Equatable {
        /// The configuration's UUID, what `scutil --nc stop` takes.
        var id: String
        var name: String
        /// The provider's bundle id of a Network Extension VPN ("su.ffg.happ"); nil for PPP/IPSec.
        var provider: String?
        /// Connected or connecting.
        var connected: Bool
    }

    /// `scutil --nc list`, one service per line:
    /// `* (Connected)  59D4…F68F VPN (su.ffg.happ)  "Happ"   [VPN:su.ffg.happ]`.
    static func services(_ output: String) -> [Service] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let match = line.wholeMatch(of: /\s*\*?\s*\(([^)]+)\)\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+.*?\s+"(.*)"\s+\[([^\]]*)\]\s*/)
            else { return nil }
            let status = match.1.trimmingCharacters(in: .whitespaces)
            let kind = String(match.4)
            return Service(id: String(match.2), name: String(match.3).trimmingCharacters(in: .whitespaces),
                           provider: kind.hasPrefix("VPN:") ? String(kind.dropFirst(4)) : nil,
                           connected: status == "Connected" || status == "Connecting")
        }
    }

    /// What «Отключить … и подключить KillSwitch» stops: connected third-party VPN apps.
    /// Tailscale is let through by the kill switch on purpose; Apple's own IKEv2/L2TP are the
    /// person's (work) VPNs and do not take the default route the way Happ does.
    static func stoppable(_ services: [Service]) -> [Service] {
        services.filter { service in
            guard service.connected, let provider = service.provider else { return false }
            return !provider.hasPrefix("io.tailscale.") && !provider.hasPrefix("com.apple.")
        }
    }

    /// VPN apps people in Russia use, as their windows and the Dock name them (lowercased).
    static let knownApps = ["happ", "dropweb", "v2raytun", "hiddify", "streisand", "foxray", "v2box", "shadowrocket",
                            "clash verge", "flclash", "flclashx", "clashx", "mihomo party", "karing", "outline",
                            "amneziavpn", "amnezia", "wireguard", "incy", "sing-box", "nekoray", "prizrak-box"]

    /// The name to show: the VPN configuration's, else a known VPN app that is running; nil means
    /// «другой VPN».
    static func name(services: [Service], runningApps: [String]) -> String? {
        if let service = stoppable(services).first, !service.name.isEmpty { return service.name }
        return runningApps.first { knownApps.contains($0.lowercased()) }
    }

    /// Bundle ids to look the app up by: the provider may be the app itself or its extension
    /// ("com.example.vpn.tunnel" belongs to "com.example.vpn").
    static func appCandidates(provider: String) -> [String] {
        var parts = provider.split(separator: ".").map(String.init)
        var result: [String] = []
        while parts.count >= 2 {
            result.append(parts.joined(separator: "."))
            parts.removeLast()
            if parts.count < 3 { break }
        }
        return result
    }

    /// The main button while another VPN is up.
    enum Remedy: Equatable {
        /// `scutil --nc stop`, then connect ours.
        case stop
        /// It cannot be stopped from here: open the app so the person turns it off there.
        case openApp
        /// Neither: the person has to find it themselves; «Подключить» stays disabled.
        case none
    }

    static func remedy(stoppable: Bool, stopFailed: Bool, appKnown: Bool) -> Remedy {
        if stoppable && !stopFailed { return .stop }
        return appKnown ? .openApp : .none
    }

    static func title(name: String?) -> String {
        "Работает другой VPN" + (name.map { " (\($0))" } ?? "")
    }

    static func buttonTitle(_ remedy: Remedy, name: String?) -> String {
        switch remedy {
        case .stop: "Отключить \(name ?? "другой VPN") и подключить KillSwitch"
        case .openApp: "Открыть \(name ?? "программу VPN")"
        case .none: "Подключить"
        }
    }

    static func stopFailed(name: String?) -> String {
        if let name { return "Не получилось отключить \(name) отсюда. Отключи его в самом \(name), потом нажми «Подключить»." }
        return "Не получилось отключить другой VPN отсюда. Отключи его в его программе, потом нажми «Подключить»."
    }
}
