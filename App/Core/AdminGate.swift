import Foundation
import os

/// Every request for an administrator's password passes here: osascript's prompt (ADR 0002) and
/// macOS's dialog for the daemon's right (ADR 0010). Only a direct user action may show one; launch,
/// refresh and timers get "no" and go on without (a banner or a notification asks for the click).
/// Each request is logged with its reason:
/// `log stream --predicate 'subsystem == "com.lesha19.KillSwitch" && category == "admin"'`.
enum AdminGate {
    struct Request: Equatable, Sendable {
        /// What would run, for the log ("ks set lan 0", "install.sh").
        var reason: String
        /// A click (or the widget, a notification button, a shortcut) asked for it just now.
        var userInitiated: Bool
    }

    static let log = Logger(subsystem: "com.lesha19.KillSwitch", category: "admin")

    /// The commands of a request without their values (addresses, names, paths stay out of the log):
    /// "ks set; ks allow", "install.sh".
    static func reason(_ commands: [[String]]) -> String {
        commands.map { command in
            if command.first == "/bin/bash", command.count > 2 { return (command[2] as NSString).lastPathComponent }
            let verb = command.dropFirst().prefix(command.dropFirst().first == "core" ? 2 : 1)
            return ([(command.first.map { ($0 as NSString).lastPathComponent } ?? "")] + verb).joined(separator: " ")
        }.joined(separator: "; ")
    }

    static func allows(_ request: Request) -> Bool { request.userInitiated }

    /// `allows`, logged. True: the prompt may show.
    static func permit(_ request: Request) -> Bool {
        let allowed = allows(request)
        if allowed {
            log.notice("admin prompt requested by a user action: \(request.reason, privacy: .public)")
        } else {
            log.error("admin prompt refused, no user action: \(request.reason, privacy: .public)")
        }
        return allowed
    }
}
