import Foundation

/// A server of a subscription, or of «Свои серверы» (ADR 0036, decision 3): «Литва» of two
/// subscriptions are two servers. `name` is what the core calls it in that subscription's profile.
struct ServerID: Codable, Hashable, Sendable {
    /// The subscription's id (Subscription.id), or `ServerID.own`.
    var subscription: String
    var name: String

    /// The reserved pseudo-subscription «Свои серверы».
    static let own = "own"

    var isOwn: Bool { subscription == Self.own }

    /// One line of a text store (favourites, recents, the chosen server): `<subscription>\t<name>`.
    /// In favourites and recents the name may be the server's identity key (ServerIdentity).
    var stored: String { "\(subscription)\t\(name)" }

    /// Nil for a line stored before ADR 0036 (a bare name).
    init?(stored: String) {
        let parts = stored.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(subscription: String(parts[0]), name: String(parts[1]))
    }

    init(subscription: String, name: String) {
        self.subscription = subscription
        self.name = name
    }
}
