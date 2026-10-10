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

    /// install.sh's last step (0.15.2): `version …` and `sha256 <hex of ks>`. It used to stop
    /// half-way with the new ks already in place, and comparing ks alone never ran it again.
    static let markerPath = "/Library/KillSwitch/installed"

    /// The marker names exactly this ks: install.sh got to its end. No marker (an older helper, or
    /// an install that stopped) is not complete.
    static func installCompleted(marker: Data?, installed: Data) -> Bool {
        guard let marker else { return false }
        let hex = SHA256.hash(data: installed).map { String(format: "%02x", $0) }.joined()
        return String(decoding: marker, as: UTF8.self).split(separator: "\n")
            .contains { $0.lowercased() == "sha256 " + hex }
    }

    enum Check: Equatable { case current, outdated, installing, unknown }

    /// What the app makes of the files. The right ks without its marker is `installing` for a
    /// while after it was replaced (`age`, seconds): that install.sh may still be running, and
    /// another one must not start next to it.
    static func check(installed: Data?, bundled: Data?, marker: Data?, age: TimeInterval) -> Check {
        guard let same = matches(installed: installed, bundled: bundled), let installed else { return .unknown }
        guard same else { return .outdated }
        if installCompleted(marker: marker, installed: installed) { return .current }
        return age < 120 ? .installing : .outdated
    }

    /// `KS_VERSION="…"` of a helper script; helpers before 0.9.1 have none.
    static func version(of script: Data) -> String? {
        let text = String(decoding: script, as: UTF8.self)
        return text.firstMatch(of: /(?m)^KS_VERSION="([^"\n]+)"/).map { String($0.1) }
    }
}
