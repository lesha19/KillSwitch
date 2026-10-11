import Foundation

/// «Собрать отчёт» (ADR 0021): `ks diag report <folder>` writes one redacted archive there. The app
/// names its file on the Desktop the way ks does; the daemon copies out only that archive from its
/// own private folder.
enum DiagReport {
    /// `KillSwitch-report-YYYY-MM-DD-HHMM.tar.gz`, as ks names it.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "KillSwitch-report-\(formatter.string(from: date)).tar.gz"
    }

    /// The path ks printed, if it is an archive directly in `directory`; nil for anything else.
    static func archive(printed: String, in directory: String) -> String? {
        let path = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix(directory + "/") else { return nil }
        let name = String(path.dropFirst(directory.count + 1))
        guard name.wholeMatch(of: /KillSwitch-report-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.tar\.gz/) != nil else { return nil }
        return path
    }

    /// Who may have the report through the daemon: the journal holds every user's connections
    /// (the access log), so only root, the user at the Mac, or the one install.sh put into
    /// sudoers (who can run `ks diag report` through sudo anyway).
    static func mayCollect(caller: uid_t, console: uid_t?, installer: uid_t?) -> Bool {
        caller == 0 || caller == console || caller == installer
    }

    /// The user of our sudoers entry, as install.sh's `sudoers_user` reads it.
    static func sudoersUser(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            if let match = line.wholeMatch(of: /([A-Za-z_][A-Za-z0-9_.-]{0,31}) ALL=\(root\) NOPASSWD: .*/) {
                return String(match.1)
            }
        }
        return nil
    }

    /// The owner of the console: the user logged in at the Mac (root at the login window).
    static func consoleUser() -> uid_t? {
        var info = stat()
        return stat("/dev/console", &info) == 0 ? info.st_uid : nil
    }

    /// The uid of the user install.sh put into sudoers (/etc/sudoers.d/killswitch, root's file).
    static func installingUser(sudoers: String = "/etc/sudoers.d/killswitch") -> uid_t? {
        guard let text = try? String(contentsOfFile: sudoers, encoding: .utf8), let name = sudoersUser(text) else { return nil }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwnam_r(name, &entry, &buffer, buffer.count, &result) == 0, result != nil else { return nil }
        return entry.pw_uid
    }
}
