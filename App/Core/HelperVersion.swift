import CryptoKit
import Foundation

/// Whether the installed helper (`/Library/KillSwitch/ks`) is the one this app carries
/// (`Helper/ks` in the bundle). Both are readable by the user, so they are compared byte for byte
/// (SHA-256), without running anything: a helper changed between builds counts even when its
/// version string (`KS_VERSION`, printed by `ks version`) stayed the same.
enum HelperVersion {
    /// Nil when either file is missing (not installed, or a bundle without the helper).
    static func matches(installed: Data?, bundled: Data?) -> Bool? {
        guard let installed, let bundled else { return nil }
        return SHA256.hash(data: installed) == SHA256.hash(data: bundled)
    }

    /// `KS_VERSION="…"` of a helper script; helpers before 0.9.1 have none.
    static func version(of script: Data) -> String? {
        let text = String(decoding: script, as: UTF8.self)
        return text.firstMatch(of: /(?m)^KS_VERSION="([^"\n]+)"/).map { String($0.1) }
    }
}
