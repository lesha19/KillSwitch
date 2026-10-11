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

    /// The journal holds every user's connections (access log): only the one at the Mac or the one
    /// install.sh put into sudoers (who can run `ks diag report` through sudo anyway) gets it.
    func testOnlyTheConsoleOrInstallingUserMayCollect() {
        XCTAssertTrue(DiagReport.mayCollect(caller: 501, console: 501, installer: 502))
        XCTAssertTrue(DiagReport.mayCollect(caller: 502, console: 501, installer: 502))
        XCTAssertTrue(DiagReport.mayCollect(caller: 0, console: nil, installer: nil))
        XCTAssertFalse(DiagReport.mayCollect(caller: 503, console: 501, installer: 502))
        XCTAssertFalse(DiagReport.mayCollect(caller: 503, console: nil, installer: nil))
    }

    /// The installing user as install.sh's sudoers_user reads it from its own entry.
    func testInstallingUserFromTheSudoersEntry() {
        let entry = """
            Defaults!/Library/KillSwitch/ks secure_path="/usr/bin:/bin:/usr/sbin:/sbin", env_reset
            alex.z ALL=(root) NOPASSWD: /Library/KillSwitch/ks state, /Library/KillSwitch/ks diag report *
            """
        XCTAssertEqual(DiagReport.sudoersUser(entry), "alex.z")
        XCTAssertNil(DiagReport.sudoersUser("ALL ALL=(ALL) ALL"))
        XCTAssertNil(DiagReport.sudoersUser("%admin ALL=(root) NOPASSWD: /bin/ls"))
        XCTAssertNil(DiagReport.sudoersUser(""))
    }

    /// The daemon names the user who asked: ks takes crash reports of that user only.
    func testTheDaemonPassesTheCallersUid() {
        XCTAssertEqual(HelperCommand.diagReport(directory: "/private/tmp/d", uid: 501).arguments, ["diag", "report", "/private/tmp/d", "501"])
        XCTAssertTrue(HelperCommand.diagReport(directory: "/private/tmp/d", uid: 501).isValid)
        XCTAssertFalse(HelperCommand.diagReport(directory: "/private/tmp/d", uid: 501).needsAuthorization)
        XCTAssertNil(HelperCommand(ks: ["diag", "report", "/a", "501"]))   // never from the app
    }
}
