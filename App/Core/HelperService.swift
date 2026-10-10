import ServiceManagement

/// Whether the privileged daemon can be used (ADR 0010), from its SMAppService status.
enum HelperService {
    enum Availability: Equatable, Sendable {
        /// Registered and allowed: changes go through the daemon.
        case ready
        /// Not registered yet (an install from before the daemon, or never set up).
        case needsRegistration
        /// Registered, waiting for the switch in System Settings › Login Items (or switched off there).
        case needsApproval
        /// This build has no daemon in its bundle: the admin password, as before.
        case unavailable
    }

    /// `daemonBundled`: the app carries the daemon's plist (Contents/Library/LaunchDaemons). A daemon
    /// that was never registered can read `.notFound` rather than `.notRegistered` (seen in 0.14.1:
    /// it was then never registered); with the plist in the bundle that only means "register it".
    static func availability(_ status: SMAppService.Status, daemonBundled: Bool) -> Availability {
        switch status {
        case .enabled: .ready
        case .notRegistered: .needsRegistration
        case .requiresApproval: .needsApproval
        case .notFound: daemonBundled ? .needsRegistration : .unavailable
        @unknown default: .unavailable
        }
    }

    enum LaunchStep: Equatable, Sendable { case nothing, register }

    /// At launch: a helper installed before the daemon existed (or whose registration was lost)
    /// gets it registered, once. `register()` needs no password; macOS may then want the switch in
    /// Login Items. Without the helper the wizard registers it with the first install.
    static func launchStep(helperInstalled: Bool, availability: Availability) -> LaunchStep {
        helperInstalled && availability == .needsRegistration ? .register : .nothing
    }

    /// The daemon just became usable (switched on in Login Items) and the installed helper is not
    /// the bundled one: start the passwordless upgrade (ADR 0012) now.
    static func upgradeWhenReady(previous: Availability, current: Availability, helperOutdated: Bool) -> Bool {
        helperOutdated && previous != .ready && current == .ready
    }

    static let approvalBannerInterval: TimeInterval = 86400

    /// The banner asking for the switch in Login Items: not more often than once a day. Also while
    /// the daemon is still not registered (the launch registration did not take): never a password.
    static func showApprovalBanner(helperInstalled: Bool, availability: Availability, lastShown: Date?, now: Date) -> Bool {
        guard helperInstalled, availability == .needsApproval || availability == .needsRegistration else { return false }
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= approvalBannerInterval
    }
}
