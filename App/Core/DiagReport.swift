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
}
