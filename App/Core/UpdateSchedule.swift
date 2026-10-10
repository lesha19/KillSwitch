import Foundation

/// When VPNClient fetches the subscription again. `lastUpdate` is the last time a fetched profile
/// reached the core (or the core already had it); a fetch the helper did not take (password
/// needed, new servers to confirm, a failure) leaves it alone and tries again in an hour.
struct UpdateSchedule: Equatable {
    enum Result: Equatable {
        case applied
        /// Fetched, but not in the core.
        case notApplied
        case fetchFailed(offline: Bool)
    }

    var lastUpdate: Date?
    var retryAt: Date?

    /// No network: the next 10-minute tick of VPNClient's timer; anything else an hour.
    static let offlineRetry: TimeInterval = 540
    static let retry: TimeInterval = 3600

    mutating func record(_ result: Result, now: Date) {
        switch result {
        case .applied:
            lastUpdate = now
            retryAt = nil
        case .notApplied:
            retryAt = now.addingTimeInterval(Self.retry)
        case .fetchFailed(let offline):
            retryAt = now.addingTimeInterval(offline ? Self.offlineRetry : Self.retry)
        }
    }

    func isDue(interval: TimeInterval, now: Date) -> Bool {
        if let lastUpdate, lastUpdate.addingTimeInterval(interval) > now { return false }
        if let retryAt, retryAt > now { return false }
        return true
    }
}
