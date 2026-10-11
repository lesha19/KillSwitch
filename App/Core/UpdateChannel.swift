import Foundation

/// #16: the Sparkle channels this app takes updates from. «Бета-версии» (off by default) adds
/// "beta": release.sh puts a beta's item into the stable appcast with
/// `<sparkle:channel>beta</sparkle:channel>`; the default channel is always included.
enum UpdateChannel {
    static let betaKey = "updateBetaChannel"
    static let beta = "beta"

    static func allowed(beta: Bool) -> Set<String> { beta ? [Self.beta] : [] }

    static func isBeta(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: betaKey) }
}
