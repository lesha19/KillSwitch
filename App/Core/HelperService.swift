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

    static func availability(_ status: SMAppService.Status) -> Availability {
        switch status {
        case .enabled: .ready
        case .notRegistered: .needsRegistration
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}
