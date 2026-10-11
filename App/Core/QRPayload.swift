import Foundation

/// What a scanned QR code holds (#24), only to choose the existing way of adding it: a
/// subscription goes to `VPNClient.setURL`, share links and wg-quick text to `VPNClient.addLink`.
/// Both still check it; nothing here accepts a link on their behalf.
enum QRPayload: Equatable, Sendable {
    case subscription(String)
    case servers(String)
    case unrecognized

    /// Schemes `ProxyLink` reads; `http(s)` there is a proxy, but in a QR code it is a subscription.
    private static let serverSchemes: Set<String> = ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic", "anytls",
                                                     "socks", "socks5", "socks5h", "wireguard", "wg"]

    static func classify(_ raw: String) -> QRPayload {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unrecognized }
        if ProxyLink.isWireGuardConf(text) { return .servers(text) }
        guard let end = text.range(of: "://") else { return .unrecognized }
        let scheme = text[..<end.lowerBound].lowercased()
        if serverSchemes.contains(scheme) { return .servers(text) }
        if scheme == "https" || scheme == "http" {
            return text.contains(where: \.isNewline) ? .unrecognized : .subscription(text)
        }
        return wrapped(text).map(QRPayload.subscription) ?? .unrecognized
    }

    /// Several codes in one picture: the first one KillSwitch can add.
    static func first(of payloads: [String]) -> QRPayload {
        payloads.lazy.map(classify).first { $0 != .unrecognized } ?? .unrecognized
    }

    /// For the confirmation before adding: a subscription link is a secret and is shown masked.
    var summary: String {
        switch self {
        case .subscription(let url):
            return SubscriptionHeaders.masked(url)
        case .servers(let text):
            let count = ProxyLink.isWireGuardConf(text) ? 1 : text.split(whereSeparator: \.isNewline).count
            return count == 1 ? String(localized: "один сервер") : String(localized: "серверов: \(count)")
        case .unrecognized:
            return ""
        }
    }

    /// Another client's import link with the subscription inside: `clash://install-config?url=…`,
    /// `sing-box://import-remote-profile?url=…`, `happ://add/https://…`. Only an https link counts.
    private static func wrapped(_ text: String) -> String? {
        if let url = URLComponents(string: text)?.queryItems?.first(where: { $0.name == "url" })?.value,
           url.lowercased().hasPrefix("https://") {
            return url
        }
        guard let start = text.range(of: "https://", options: .caseInsensitive) else { return nil }
        return String(text[start.lowerBound...])
    }
}
