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

    // MARK: tunnels by the routing table

    /// An address of a network interface (getifaddrs), IPv4 or IPv6 without the `%scope`.
    struct Address: Equatable {
        var interface: String
        var address: String
    }

    /// Another VPN's tunnel interfaces beyond the 198.18 address (TunnelAddress): utun, ipsec and
    /// ppp interfaces with a default or wide route outside an interface scope (`netstat -rn`), as
    /// the watchdog's `foreign_tuns` (Helper/ks) sees them. Wide: IPv4 /8 or larger but not 10/8
    /// (corporate VPNs), IPv6 /3 or larger. Ours (198.18.128.1) and Tailscale's (an address in
    /// 100.64/10 or fd7a:115c:a1e0::/48, exit node or not) are not another VPN. Sorted.
    static func tunnels(routes: String, addresses: [Address]) -> [String] {
        let excluded = Set(addresses.filter { $0.address == TunnelAddress.own || isTailscale($0.address) }.map(\.interface))
        var found = Set<String>()
        var v6 = false
        for line in routes.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Internet6:") { v6 = true; continue }
            if line.hasPrefix("Internet:") { v6 = false; continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4, fields[3].wholeMatch(of: /(utun|ipsec|ppp)[0-9]+/) != nil,
                  !excluded.contains(fields[3]), !fields[2].contains("I") else { continue }
            if isWide(fields[0], v6: v6) { found.insert(fields[3]) }
        }
        return found.sorted()
    }

    private static func isWide(_ destination: String, v6: Bool) -> Bool {
        if destination == "default" { return true }
        if v6 {
            guard let slash = destination.lastIndex(of: "/"), let length = Int(destination[destination.index(after: slash)...])
            else { return false }
            return length <= 3
        }
        if destination == "10" || destination == "10/8" { return false }
        let length: Int
        if let slash = destination.lastIndex(of: "/") {
            guard let value = Int(destination[destination.index(after: slash)...]) else { return false }
            length = value
        } else {
            length = 8 * destination.split(separator: ".").count   // netstat drops trailing zero octets
        }
        return length <= 8
    }

    /// 100.64.0.0/10 or fd7a:115c:a1e0::/48.
    static func isTailscale(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
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
        String(localized: "Работает другой VPN") + (name.map { " (\($0))" } ?? "")
    }

    static func buttonTitle(_ remedy: Remedy, name: String?) -> String {
        switch remedy {
        case .stop: String(localized: "Отключить \(name ?? String(localized: "другой VPN")) и подключить KillSwitch")
        case .openApp: String(localized: "Открыть \(name ?? String(localized: "программу VPN"))")
        case .none: String(localized: "Подключить")
        }
    }

    static func stopFailed(name: String?) -> String {
        if let name { return String(localized: "Не получилось отключить \(name) отсюда. Отключи его в самом \(name), потом нажми «Подключить».") }
        return String(localized: "Не получилось отключить другой VPN отсюда. Отключи его в его программе, потом нажми «Подключить».")
    }
}
