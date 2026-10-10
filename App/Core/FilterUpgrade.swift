import Foundation

/// The content filter after an app update (ADR 0012 addendum): macOS keeps running the extension
/// that was activated, whatever the app now carries, until the app asks for it again. At launch the
/// app compares the activated one with its own and asks only when the bundled one is newer.
enum FilterUpgrade {
    /// One entry of `OSSystemExtensionRequest.propertiesRequest` (what `systemextensionsctl list` shows).
    struct Installed: Equatable, Sendable {
        var shortVersion: String
        var build: String
        var enabled: Bool
        var awaitingApproval: Bool
        var uninstalling: Bool
    }

    enum Decision: Equatable, Sendable {
        /// The user has not turned the filter on (or removed it): launch installs nothing.
        case notActive
        /// The bundled one (or a newer one) runs: no request, nothing asked.
        case current
        /// An activation request; the delegate answers `.replace`.
        case replace
        /// The bundled one was already submitted and waits for the switch in System Settings.
        case awaitingApproval
    }

    static func decide(installed: [Installed], bundledShort: String, bundledBuild: String) -> Decision {
        let active = installed.filter { $0.enabled && !$0.uninstalling }
        guard !active.isEmpty else { return .notActive }
        // an older app copy never puts its filter over a newer one by itself
        guard active.allSatisfy({ compare($0, bundledShort, bundledBuild) == .orderedAscending }) else { return .current }
        if installed.contains(where: { $0.awaitingApproval && $0.shortVersion == bundledShort && $0.build == bundledBuild }) {
            return .awaitingApproval
        }
        return .replace
    }

    /// Build numbers first (CFBundleVersion, the project's CURRENT_PROJECT_VERSION); without them
    /// the marketing versions.
    private static func compare(_ ext: Installed, _ short: String, _ build: String) -> ComparisonResult {
        if let a = Int(ext.build), let b = Int(build) { return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
        if HelperUpgrade.isOlder(ext.shortVersion, than: short) { return .orderedAscending }
        return HelperUpgrade.isOlder(short, than: ext.shortVersion) ? .orderedDescending : .orderedSame
    }
}
