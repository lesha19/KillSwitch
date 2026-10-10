import Foundation

/// The Authorization Services right behind every daemon command that widens the rules (ADR 0010):
/// an administrator's password (or Touch ID, where macOS's dialog offers it) at most once every
/// five minutes. Not shared: the credential lives in the app's own AuthorizationRef only, other
/// programs of the same login session get nothing from it.
enum HelperRight {
    static let name = "com.lesha19.KillSwitch.widen"
    static let timeout = 300

    /// As `authenticate-admin-nonshared`, with our timeout.
    static var definition: [String: Any] {
        [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            "allow-root": false,
            "session-owner": false,
            "shared": false,
            "timeout": timeout,
            "tries": 10000,
            "version": 1,
            "comment": "KillSwitch: changes that let traffic out without the VPN.",
        ]
    }

    /// The keys that decide who gets the right and for how long, as authd stores them.
    private static let decisive = ["class", "group", "authenticate-user", "allow-root", "session-owner", "shared", "timeout"]

    /// The stored right is ours, key by key. `config.add.` lets any user create a right that does
    /// not exist yet, so a definition planted before the daemon's first start must not pass.
    static func matches(_ stored: [String: Any]?) -> Bool {
        guard let stored else { return false }
        let expected = definition
        return decisive.allSatisfy { key in
            guard let have = stored[key] as? NSObject, let want = expected[key] as? NSObject else { return false }
            return have.isEqual(want)
        }
    }
}
