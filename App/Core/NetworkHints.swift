import Foundation

/// Tips next to the leak test and in «О программе»: things on this Mac that change how the
/// protection works, said without blocking anything. «Частный узел iCloud» (iCloud Private Relay)
/// and overlay networks (Tailscale, ZeroTier, NetBird).
enum NetworkHints {
    enum Hint: Equatable {
        case privateRelay
        case overlay(String)

        var title: String {
            switch self {
            case .privateRelay: "Включён «Частный узел iCloud»"
            case .overlay(let name): "Работает \(name)"
            }
        }

        var text: String {
            switch self {
            case .privateRelay:
                "Safari и часть запросов системы идут через серверы Apple, а не через VPN. При включённой защите они могут не открываться, а без защиты — обходят VPN. Лучше выключить его в настройках iCloud."
            case .overlay("Tailscale"):
                "Сеть Tailscale (100.64.0.0/10) идёт мимо VPN — так задумано (Защита › Что можно без VPN). Выходной узел Tailscale защита не пропускает."
            case .overlay(let name):
                "Сеть \(name) идёт мимо VPN, только если её адреса разрешены в «Адреса без VPN» (Дополнительно) или это домашняя сеть. Остальное идёт только через VPN."
            }
        }
    }

    // MARK: iCloud Private Relay

    /// `PrivacyProxyServiceStatus` from the keyed archive the system keeps in
    /// com.apple.networkserviceproxy (`NSPServiceStatusManagerInfo`). Not a public format: nil
    /// when it is not there. Nothing else of that domain is read (it also holds a location hash).
    static func relayStatus(archive: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for case let object as [String: Any] in objects {
            if let status = object["PrivacyProxyServiceStatus"] as? Int { return status }
        }
        return nil
    }

    /// The service's states are Unknown, Disabled, Active, Outage, … in the system's order;
    /// only Active (2) is «on». Unreadable: nil.
    static func relayOn(status: Int?) -> Bool? {
        status.map { $0 == 2 }
    }

    // MARK: overlay networks

    /// Running overlay networks: Tailscale by its addresses on a tunnel (100.64.0.0/10 or
    /// fd7a:115c:a1e0::/48), the others by their running app.
    static func overlays(addresses: [OtherVPN.Address], runningApps: [String]) -> [String] {
        var result: [String] = []
        let tunnel = /(utun|ipsec|ppp|feth|zt)[0-9]+/
        if addresses.contains(where: { $0.interface.wholeMatch(of: tunnel) != nil && OtherVPN.isTailscale($0.address) }) {
            result.append("Tailscale")
        }
        let apps = Set(runningApps.map { $0.lowercased() })
        for (name, appNames) in knownApps where !result.contains(name) && !apps.isDisjoint(with: appNames) {
            result.append(name)
        }
        return result
    }

    private static let knownApps: [(String, Set<String>)] = [
        ("Tailscale", ["tailscale"]), ("ZeroTier", ["zerotier one", "zerotier"]), ("NetBird", ["netbird", "netbird-ui"]),
    ]

    static func hints(relayOn: Bool?, overlays: [String]) -> [Hint] {
        (relayOn == true ? [.privateRelay] : []) + overlays.map(Hint.overlay)
    }
}
