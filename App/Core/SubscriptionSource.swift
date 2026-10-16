import Foundation

/// Where the last subscription update came from (#11, like Mullvad's API access methods): the
/// link itself or the same link through the VPN (the backup link is gone, ADR 0036).
enum SubscriptionSource: String, Codable, Equatable, Sendable {
    case primary, primaryViaVPN

    /// The core's loopback HTTP listener (Helper/ks FETCH_PORT): every connection goes to the
    /// profile's proxies, so a host that is blocked, or that the profile sends DIRECT, is still
    /// reached through the VPN.
    static let proxyPort = 47890

    var viaVPN: Bool { self == .primaryViaVPN }

    /// Directly first; through the VPN only while our core runs.
    static func order(vpnRunning: Bool) -> [SubscriptionSource] {
        vpnRunning ? [.primary, .primaryViaVPN] : [.primary]
    }

    var label: String {
        switch self {
        case .primary: String(localized: "основная ссылка")
        case .primaryViaVPN: String(localized: "основная ссылка через VPN")
        }
    }

    /// `URLSessionConfiguration.connectionProxyDictionary` for the listener.
    static var proxy: [AnyHashable: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort]
    }
}
