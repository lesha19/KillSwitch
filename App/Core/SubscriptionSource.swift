import Foundation

/// Where the last subscription update came from (#11, like Mullvad's API access methods): the
/// link itself, the same link through the VPN, or the backup link the person entered, both ways.
enum SubscriptionSource: String, Codable, Equatable, Sendable {
    case primary, primaryViaVPN, backup, backupViaVPN

    /// The core's loopback HTTP listener (Helper/ks FETCH_PORT): every connection goes to the
    /// profile's proxies, so a host that is blocked, or that the profile sends DIRECT, is still
    /// reached through the VPN.
    static let proxyPort = 47890

    var viaVPN: Bool { self == .primaryViaVPN || self == .backupViaVPN }
    var usesBackup: Bool { self == .backup || self == .backupViaVPN }

    /// Each link directly first; through the VPN only while our core runs.
    static func order(hasBackup: Bool, vpnRunning: Bool) -> [SubscriptionSource] {
        let all: [SubscriptionSource] = hasBackup ? [.primary, .primaryViaVPN, .backup, .backupViaVPN] : [.primary, .primaryViaVPN]
        return vpnRunning ? all : all.filter { !$0.viaVPN }
    }

    var label: String {
        switch self {
        case .primary: String(localized: "основная ссылка")
        case .primaryViaVPN: String(localized: "основная ссылка через VPN")
        case .backup: String(localized: "резервная ссылка")
        case .backupViaVPN: String(localized: "резервная ссылка через VPN")
        }
    }

    /// `URLSessionConfiguration.connectionProxyDictionary` for the listener.
    static var proxy: [AnyHashable: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort]
    }
}
