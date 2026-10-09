import Foundation

/// Things both the app and the widget need to agree on.
enum Shared {
    static let appGroup = "YR58655PJ7.killswitch"
    static let stateKey = "state"          // "on" | "off" | "paused:<epoch>" | "notInstalled"
    static let vpnKey = "vpnUp"

    /// Darwin notifications the widget posts; the running app performs the action.
    enum Command: String, CaseIterable {
        case on, off, pause5
        var notificationName: String { "local.lesha.killswitch.\(rawValue)" }
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
}
