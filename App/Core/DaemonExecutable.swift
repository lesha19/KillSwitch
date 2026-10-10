import Darwin
import Foundation

/// Where the root daemon (ADR 0010) runs from, and the app bundle around it.
enum DaemonExecutable {
    /// This process's executable as the kernel knows it: absolute, the file that runs. Not
    /// `Bundle.main`: launchd starts an SMAppService daemon as `Contents/MacOS/KillSwitchHelper`
    /// (relative, `launchctl print`: "program identifier … resolve program"), and the path
    /// CFBundle works from may then be that relative one, so 0.14.2's daemon found no app
    /// (`verifiedCopy` nil, «повреждена» on an intact app).
    static func current() -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `…/X.app/Contents/MacOS/KillSwitchHelper` → `…/X.app`; nil for anything else (a relative
    /// path, the app's own executable, a helper outside an app).
    static func appBundle(executable path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: path)   // the kernel's path has no symlinks left
        let macOS = executable.deletingLastPathComponent()
        let bundle = macOS.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.lastPathComponent == HelperIdentity.executable,
              macOS.path.hasSuffix(".app/Contents/MacOS"),
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }
}
