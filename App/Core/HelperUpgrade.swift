import Foundation

/// The helper upgrade after an app update (ADR 0012): the daemon runs the bundled
/// `install.sh --upgrade` without a password, but only with a newer (or the same version's)
/// helper than the installed one, and the app asks only a daemon of its own build for it.
enum HelperUpgrade {
    enum Decision: Equatable, Sendable {
        /// Nothing installed: the full install, with the admin's password.
        case notInstalled
        /// Same file, installed to the end (or no helper in the bundle): nothing to do.
        case current
        case upgrade
        /// The bundle's helper is older than the installed one: refused.
        case downgrade
    }

    /// `completed`: install.sh's marker names the installed ks (HelperVersion.installCompleted); the
    /// same file without it is an install that stopped half-way, run again.
    static func decide(installed: Data?, bundled: Data?, completed: Bool = true) -> Decision {
        guard let installed else { return .notInstalled }
        guard let bundled else { return .current }
        if bundled == installed { return completed ? .current : .upgrade }
        // a bundled helper without a version is from before 0.9.1, older than anything installed since
        guard let new = HelperVersion.version(of: bundled) else { return .downgrade }
        guard let old = HelperVersion.version(of: installed) else { return .upgrade }
        return isOlder(new, than: old) ? .downgrade : .upgrade
    }

    /// Dotted numbers, as install.sh's version_lt: 0.9.1 < 0.13 < 0.13.1 < 0.14; a part that is not
    /// a number counts as 0.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let y = b.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }

    /// The running daemon came with this app (or a newer one): an older one has no `upgrade` and
    /// is waited out (it leaves after two idle minutes).
    static func daemonIsCurrent(daemonBuild: String, appBuild: String) -> Bool {
        guard let daemon = Int(daemonBuild), let app = Int(appBuild) else { return false }
        return daemon >= app
    }

    enum Outcome: Equatable, Sendable { case seamless, coreRestarted }

    /// install.sh prints "core: restarted" when the core's binary, geodata or plist changed.
    static func outcome(_ output: String) -> Outcome {
        output.split(separator: "\n").contains("core: restarted") ? .coreRestarted : .seamless
    }
}
