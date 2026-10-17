import Foundation

/// Each subscription lives on its own schedule (ADR 0036, decision 7): its own interval, its own
/// retry after a failure, its own error. Pure, for VPNClient and its tests.
enum SubscriptionRefresh {
    /// What the person chose in Settings (hours, 0 = not chosen), else what the provider asked for
    /// (`profile-update-interval`, kept in the status).
    static func interval(of status: SubscriptionStatus, appHours: Int) -> TimeInterval {
        appHours > 0 ? TimeInterval(appHours) * 3600 : status.serverInterval
    }

    /// The subscriptions to fetch now, in list order. `retryAt` is per subscription: one that failed
    /// waits for its own retry and holds the others back from nothing.
    static func due(_ list: [Subscription], retryAt: [String: Date], appHours: Int, now: Date) -> [String] {
        list.filter {
            UpdateSchedule(lastUpdate: $0.status.lastUpdate, retryAt: retryAt[$0.id])
                .isDue(interval: interval(of: $0.status, appHours: appHours), now: now)
        }.map(\.id)
    }

    /// The subscription whose profile the helper runs was deleted: the VPN keeps running that
    /// profile (and blocking) until another server is picked, which the person is asked to do.
    static func activeWasRemoved(active: String, list: [Subscription], coreConfigured: Bool) -> Bool {
        coreConfigured && active != ServerID.own && !list.contains { $0.id == active }
    }
}
