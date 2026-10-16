import Darwin
import XCTest

/// Where the root daemon finds the app it runs install.sh / `upgrade` from (ADR 0010, 0012).
final class DaemonExecutableTests: XCTestCase {
    func testTheHelperInsideAnAppGivesThatApp() {
        XCTAssertEqual(DaemonExecutable.appBundle(executable: "/Applications/KillSwitch.app/Contents/MacOS/KillSwitchHelper")?.path,
                       "/Applications/KillSwitch.app")
        XCTAssertEqual(DaemonExecutable.appBundle(executable: "/Users/a/Apps/Kill Switch.app/Contents/MacOS/KillSwitchHelper")?.path,
                       "/Users/a/Apps/Kill Switch.app")
    }

    /// 0.14.2 on the owner's Mac: launchd starts the daemon as `Contents/MacOS/KillSwitchHelper`
    /// (relative). A path made from that, or the app's own executable, is not the daemon in an app.
    func testAnythingElseGivesNoBundle() {
        for path in ["Contents/MacOS/KillSwitchHelper",                          // argv[0] under launchd
                     "/Contents/MacOS/KillSwitchHelper",                         // the same against cwd /
                     "/Applications/KillSwitch.app/Contents/MacOS/KillSwitch",   // CFBundleExecutable
                     "/Applications/KillSwitch/Contents/MacOS/KillSwitchHelper", // not an .app
                     "/Applications/KillSwitch.app/Contents/Resources/KillSwitchHelper",
                     "/usr/local/bin/KillSwitchHelper", ""] {
            XCTAssertNil(DaemonExecutable.appBundle(executable: path), path)
        }
    }

    /// The kernel's path of this process: absolute and the running file, whatever argv[0] says.
    func testCurrentIsTheAbsolutePathOfThisProcess() throws {
        let current = try XCTUnwrap(DaemonExecutable.current())
        XCTAssertTrue(current.hasPrefix("/"), current)
        var size = UInt32(4096)
        var raw = [CChar](repeating: 0, count: Int(size))
        XCTAssertEqual(_NSGetExecutablePath(&raw, &size), 0)
        let expected = try XCTUnwrap(realpath(raw, nil))
        defer { free(expected) }
        XCTAssertEqual(current, String(cString: expected))
    }

    /// #84: the daemon writes its app's path for the watchdog (ks app_guard), which removes protection
    /// once that path is gone for ten minutes. Only an app in /Applications and only into an installed
    /// helper's folder: an app on a DMG, a late volume or in ~/Downloads is never recorded (never
    /// taken for gone), nor a translocated one.
    func testRecordAppWritesTheBundlePathForTheWatchdog() throws {
        let dir = try XCTUnwrap(PrivateDirectory.make())
        defer { PrivateDirectory.remove(dir) }
        let record = dir.appendingPathComponent("app").path
        func recorded() -> String? { try? String(contentsOfFile: record, encoding: .utf8) }
        DaemonExecutable.recordApp(executable: "/Applications/KillSwitch.app/Contents/MacOS/KillSwitchHelper", directory: dir.path)
        XCTAssertEqual(recorded(), "/Applications/KillSwitch.app\n")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: record)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o644)
        DaemonExecutable.recordApp(executable: "/Applications/Tools/Kill Switch.app/Contents/MacOS/KillSwitchHelper", directory: dir.path)
        XCTAssertEqual(recorded(), "/Applications/Tools/Kill Switch.app\n", "a moved app is followed")
        for path in ["/Volumes/KillSwitch/KillSwitch.app/Contents/MacOS/KillSwitchHelper",
                     "/Users/a/Downloads/KillSwitch.app/Contents/MacOS/KillSwitchHelper",
                     "/Applications/../Volumes/KillSwitch.app/Contents/MacOS/KillSwitchHelper",
                     "/private/var/folders/x/AppTranslocation/1234/d/KillSwitch.app/Contents/MacOS/KillSwitchHelper",
                     "Contents/MacOS/KillSwitchHelper"] {
            DaemonExecutable.recordApp(executable: path, directory: dir.path)
            XCTAssertEqual(recorded(), "/Applications/Tools/Kill Switch.app\n", path)
        }
        let missing = dir.appendingPathComponent("not-installed").path
        DaemonExecutable.recordApp(executable: "/Applications/KillSwitch.app/Contents/MacOS/KillSwitchHelper", directory: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing), "no folder made for a helper that is not installed")
        XCTAssertEqual(DaemonExecutable.appRecord, "/Library/KillSwitch/app")
    }
}
