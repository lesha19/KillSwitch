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
}
