import Foundation

/// `subscription-userinfo: upload=…; download=…; total=…; expire=…` (bytes, unix time; 0 = no limit).
struct SubscriptionUsage: Codable, Equatable {
    var upload: Int64
    var download: Int64
    var total: Int64?
    var expire: Date?

    var used: Int64 { upload + download }

    init?(header: String?) {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let number = Int64(pair[1]) ?? Double(pair[1]).map({ Int64($0) }) {
                values[pair[0].lowercased()] = number
            }
        }
        guard !values.isEmpty, values.keys.contains(where: { ["upload", "download", "total", "expire"].contains($0) }) else { return nil }
        upload = values["upload"] ?? 0
        download = values["download"] ?? 0
        total = (values["total"] ?? 0) > 0 ? values["total"] : nil
        expire = (values["expire"] ?? 0) > 0 ? Date(timeIntervalSince1970: TimeInterval(values["expire"]!)) : nil
    }
}

enum SubscriptionHeaders {
    /// Remnawave picks the response format by User-Agent; a mihomo client name gets mihomo YAML.
    /// clash-verge is in Remnawave's default Mihomo rule. The panel's reverse proxy may also
    /// filter by User-Agent (StorkVPN's Caddy did): it has to let this one through.
    static let userAgent = "clash-verge/v2.4.2"
    static let defaultInterval: TimeInterval = 12 * 3600

    /// Headers Remnawave reads for its per-device (HWID) limit, same names as Happ and the mihomo clients send.
    static func request(hwid: String, osVersion: String, model: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/yaml, text/plain, */*",
            "x-hwid": hwid,
            "x-device-os": "macOS",
            "x-ver-os": osVersion,
            "x-device-model": model,
        ]
    }

    /// `profile-update-interval` is in hours.
    static func updateInterval(_ header: String?) -> TimeInterval {
        guard let hours = header.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), hours > 0 else { return defaultInterval }
        return hours * 3600
    }

    /// `profile-title`, plain or `base64:…`.
    static func title(_ header: String?) -> String? {
        guard var text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("base64:"), let decoded = Base64.decode(String(text.dropFirst(7))) { text = decoded }
        return text
    }

    /// The URL is a secret: only the host and the last four characters are shown.
    static func masked(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            return "•••••"
        }
        let rest = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let tail = rest.count > 8 ? String(rest.suffix(4)) : ""
        return "\(scheme)://\(host)/•••••\(tail)"
    }
}
