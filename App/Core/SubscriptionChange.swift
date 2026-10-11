import Foundation

/// What a subscription link given by the person (Settings, a QR code, `killswitch://add`) does to
/// the one kept in the keychain (#23 review, ADR 0029). A new link replaces the old one only once
/// it answered: a link that fails must not cost the person the key that works.
enum SubscriptionChange: Equatable {
    /// No link yet: kept at once, so a first fetch that fails is tried again by the timer.
    case first
    /// Another link: fetched first; the old link, its status and its cache stay until it answers.
    case replace
    /// The same link again: an update.
    case same

    static func of(_ new: String, current: String?) -> SubscriptionChange {
        guard let current else { return .first }
        return current == new ? .same : .replace
    }

    var storesBeforeFetch: Bool { self == .first }
    /// The status (title, usage, provider texts) belongs to the old link until the new one answered.
    var resetsStatusBeforeFetch: Bool { self == .first }
    /// A failed fetch of a link not kept yet is no failed update of the kept one.
    var recordsFailure: Bool { self != .replace }

    /// The backup link (#11) belongs to the subscription that is kept: a new link is never fetched
    /// through it.
    func sources(hasBackup: Bool, vpnRunning: Bool) -> [SubscriptionSource] {
        SubscriptionSource.order(hasBackup: hasBackup && self == .same, vpnRunning: vpnRunning)
    }
}
