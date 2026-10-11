import Foundation

/// Saved state of the last successful fetch (VPNClient.Status); no secrets in it.
struct SubscriptionStatus: Codable, Equatable {
    var title: String?
    var usage: SubscriptionUsage?
    var serverInterval: TimeInterval = SubscriptionHeaders.defaultInterval
    var lastUpdate: Date?
    /// The service's page (`profile-web-page-url` or `support-url`), for «Открыть кабинет».
    var accountURL: URL?
    /// Which link and way the last fetched profile came from (#11); nil before 0.16.
    var source: SubscriptionSource?
    /// Announcement, support contacts and `hide-url` from the last fetch (#22, #26).
    var provider: ProviderInfo?

    /// For Settings › Подписка; the interval is clamped, so this cannot trap.
    var serverIntervalHours: Int { Int(SubscriptionHeaders.clampedInterval(serverInterval) / 3600) }
}

extension SubscriptionStatus {
    /// A status saved by an older build may hold a provider's huge interval: clamped on reading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        usage = try container.decodeIfPresent(SubscriptionUsage.self, forKey: .usage)
        serverInterval = SubscriptionHeaders.clampedInterval(try container.decodeIfPresent(TimeInterval.self, forKey: .serverInterval))
        lastUpdate = try container.decodeIfPresent(Date.self, forKey: .lastUpdate)
        accountURL = try container.decodeIfPresent(URL.self, forKey: .accountURL)
        source = try container.decodeIfPresent(SubscriptionSource.self, forKey: .source)
        provider = try container.decodeIfPresent(ProviderInfo.self, forKey: .provider)
    }
}
