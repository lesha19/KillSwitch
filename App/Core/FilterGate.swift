import Foundation

/// Whether the content filter blocks anything at all (#55). It stands behind the helper's pf rules;
/// once uninstall.sh has removed the helper there is nothing to protect, and a filter that stayed
/// enabled (the app quit, or never ran after the removal) must not cut the Mac off.
enum FilterGate {
    static let helperPath = "/Library/KillSwitch/ks"

    /// The filter is sandboxed and may not read /Library/KillSwitch, but the App Sandbox allows
    /// file-read-metadata everywhere, so stat sees the helper. Only "no such file" counts as removed;
    /// any other failure (a refusal) keeps the filter blocking, as before.
    static func blocks(helperAt path: String = helperPath) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0 else { return true }
        let failure = errno
        return failure != ENOENT && failure != ENOTDIR
    }
}
