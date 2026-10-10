import Foundation

/// The helper's answer to `sudo -n ks core refresh <json>` (subscription auto-update, no prompt).
enum RefreshOutcome: Equatable {
    case applied
    /// Exit 3: the profile brings server addresses pf does not let out yet. Only `ks core import`
    /// with the admin password may open them, after the user confirms.
    case newServers
    /// sudoers does not allow `core refresh` (helper older than 0.7).
    case needsPassword
    case failed(String)

    init(status: Int32, output: String) {
        if status == 0 {
            self = .applied
        } else if status == 3 {
            self = .newServers
        } else if Self.sudoWantsPassword(output) {
            self = .needsPassword
        } else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .failed(message.isEmpty ? "Не получилось" : message)
        }
    }

    static func sudoWantsPassword(_ output: String) -> Bool {
        output.hasPrefix("sudo:") || output.contains("a password is required")
    }
}
