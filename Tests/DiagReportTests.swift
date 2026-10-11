import XCTest

/// «Собрать отчёт» (ADR 0021): the archive's name on the Desktop, and the only file the daemon
/// copies out of its private folder.
final class DiagReportTests: XCTestCase {
    func testFileNameHasTheDateAndMinute() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7, minute: 5))!
        XCTAssertEqual(DiagReport.fileName(for: date, timeZone: calendar.timeZone), "KillSwitch-report-2026-10-09-0705.tar.gz")
    }

    func testOnlyTheArchiveKsMadeInThatFolder() {
        let dir = "/private/var/root/tmp/killswitch.abc"
        XCTAssertEqual(DiagReport.archive(printed: "\(dir)/KillSwitch-report-2026-10-09-0705.tar.gz\n", in: dir),
                       "\(dir)/KillSwitch-report-2026-10-09-0705.tar.gz")
        for printed in ["/etc/master.passwd", "\(dir)/../x/KillSwitch-report-2026-10-09-0705.tar.gz",
                        "\(dir)/sub/KillSwitch-report-2026-10-09-0705.tar.gz", "\(dir)/KillSwitch-report-x.tar.gz",
                        "\(dir)/KillSwitch-report-2026-10-09-0705.tar.gz.evil", "", "\(dir)/a\n\(dir)/KillSwitch-report-2026-10-09-0705.tar.gz"] {
            XCTAssertNil(DiagReport.archive(printed: printed, in: dir), printed)
        }
    }
}
