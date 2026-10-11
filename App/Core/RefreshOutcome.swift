import Foundation

/// The helper's answer to `sudo -n ks core refresh <json>` (subscription auto-update, no prompt).
enum RefreshOutcome: Equatable {
    case applied
    /// Exit 3: the profile brings server addresses pf does not let out yet. Only `ks core import`
    /// with the admin password may open them, after the user confirms.
    case newServers
    /// Exit 3 too (KS-12), but the profile changes what goes past the VPN (DIRECT rules, DNS
    /// outside the tunnel): the admin approves that, not new servers (ADR 0013).
    case routingChanged
    /// sudoers does not allow `core refresh` (helper older than 0.7).
    case needsPassword
    case failed(String)

    /// In ks's refusal (refresh_check) for a DIRECT/DNS change only.
    static let routingMarker = "(DIRECT)"

    init(status: Int32, output: String) {
        if status == 0 {
            self = .applied
        } else if status == 3 {
            self = output.contains(Self.routingMarker) ? .routingChanged : .newServers
        } else if Self.sudoWantsPassword(output) {
            self = .needsPassword
        } else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .failed(message.isEmpty ? String(localized: "Не получилось") : message)
        }
    }

    static func sudoWantsPassword(_ output: String) -> Bool {
        output.hasPrefix("sudo:") || output.contains("a password is required")
    }
}
