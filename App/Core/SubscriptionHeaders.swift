import Foundation

/// `subscription-userinfo: upload=…; download=…; total=…; expire=…` (bytes, unix time; 0 = no limit).
struct SubscriptionUsage: Codable, Equatable {
    var upload: Int64
    var download: Int64
    var total: Int64?
    var expire: Date?

    var used: Int64 { upload + download }  // both at most 2^53 (clamped), so no overflow

    /// KS-13: the provider controls these numbers and the status is saved, so a value that traps
    /// would crash every launch. Bytes are kept in 0…2^53, the expiry up to the end of year 9999.
    static let maxBytes: Int64 = 1 << 53
    static let maxExpire: Int64 = 253_402_300_799

    private static func number(_ text: String) -> Int64? {
        if let value = Int64(text) { return min(max(value, 0), maxBytes) }
        guard let value = Double(text), value.isFinite else { return nil }
        return Int64(min(max(value, 0), Double(maxBytes)))
    }

    init?(header: String?) {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let number = Self.number(pair[1]) {
                values[pair[0].lowercased()] = number
            }
        }
        guard !values.isEmpty, values.keys.contains(where: { ["upload", "download", "total", "expire"].contains($0) }) else { return nil }
        self.init(upload: values["upload"] ?? 0, download: values["download"] ?? 0, total: values["total"],
                  expire: values["expire"].map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    private init(upload: Int64, download: Int64, total: Int64?, expire: Date?) {
        let bytes = { (value: Int64) in min(max(value, 0), Self.maxBytes) }
        self.upload = bytes(upload)
        self.download = bytes(download)
        self.total = total.map(bytes).flatMap { $0 > 0 ? $0 : nil }
        let seconds = expire?.timeIntervalSince1970 ?? 0
        self.expire = seconds.isFinite && seconds >= 1 ? Date(timeIntervalSince1970: min(seconds, Double(Self.maxExpire))) : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(upload: container.decode(Int64.self, forKey: .upload), download: container.decode(Int64.self, forKey: .download),
                      total: container.decodeIfPresent(Int64.self, forKey: .total), expire: container.decodeIfPresent(Date.self, forKey: .expire))
    }
}

enum SubscriptionHeaders {
    /// The core the helper installs (Helper/fetch-mihomo.sh); keep in step with it.
    static let coreVersion = "1.19.32"
    static let defaultInterval: TimeInterval = 12 * 3600

    /// Remnawave picks the response format by User-Agent with anchored rules: only a UA that
    /// starts with "mihomo" gets mihomo YAML (one that merely contains it gets base64). The panel's
    /// reverse proxy may also filter by User-Agent: StorkVPN's Caddy passes anything containing
    /// "mihomo" and blocks "KillSwitch/1.0", "Clash" and "sing-box".
    static func userAgent(appVersion: String, osVersion: String) -> String {
        "mihomo/\(coreVersion) (KillSwitch/\(appVersion); macOS \(osVersion))"
    }

    /// Headers Remnawave reads for its per-device (HWID) limit, same names as Happ and the mihomo
    /// clients send. No text/html in Accept: Remnawave's browser rule would answer with a web page.
    static func request(appVersion: String, hwid: String, osVersion: String, model: String) -> [String: String] {
        [
            "User-Agent": userAgent(appVersion: appVersion, osVersion: osVersion),
            "Accept": "application/yaml, text/plain, */*",
            "x-hwid": hwid,
            "x-device-os": "macOS",
            "x-ver-os": osVersion,
            "x-device-model": "\(model) KillSwitch",
        ]
    }

    /// Remnawave ignores an x-hwid outside ^[A-Za-z0-9=-]{10,64}$ (and then refuses the request).
    static func isValidHWID(_ hwid: String) -> Bool {
        hwid.wholeMatch(of: /[A-Za-z0-9=-]{10,64}/) != nil
    }

    /// Remnawave's device limit answers by header (status and body vary): `x-hwid-max-devices-reached`
    /// when the subscription has no free device slot, `x-hwid-not-supported` when x-hwid was missing
    /// or invalid (an empty body). Returns the header's name; UserError words it.
    static func hwidProblem(headers: [String: String]) -> String? {
        func flag(_ name: String) -> Bool { headers[name]?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }
        return ["x-hwid-max-devices-reached", "x-hwid-not-supported"].first(where: flag)
    }

    static let minInterval: TimeInterval = 3600
    static let maxInterval: TimeInterval = 30 * 24 * 3600

    /// `profile-update-interval` is in hours.
    static func updateInterval(_ header: String?) -> TimeInterval {
        clampedInterval(header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { $0 * 3600 })
    }

    /// The provider controls the header and the status is saved (like KS-13): kept in an hour …
    /// 30 days, so no later arithmetic on it can trap; nan, inf and ≤ 0 mean the default.
    static func clampedInterval(_ seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds.isFinite, seconds > 0 else { return defaultInterval }
        return min(max(seconds, minInterval), maxInterval)
    }

    static let maxTitleLength = 64

    /// `profile-title`, plain or `base64:…`: the sender of announcements and notifications, so
    /// cleaned like them (KS-20): one line, no control or bidi characters, at most 64 characters.
    static func title(_ header: String?) -> String? {
        ProviderInfo.text(header, maxLines: 1, maxLength: maxTitleLength)
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
