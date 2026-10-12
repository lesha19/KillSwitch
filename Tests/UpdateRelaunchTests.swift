import AppKit
import XCTest

/// #35: Sparkle replaces the app only after it quits, and AppKit refuses its Quit Apple event while
/// a window has a sheet («Начало работы», a confirmation). The sheets are closed before Sparkle asks;
/// a newer build on disk next to the running one is relaunched.
final class UpdateRelaunchTests: XCTestCase {
    @MainActor
    func testClosesEverySheet() {
        let window = FakeWindow(sheets: 2), other = FakeWindow(sheets: 0)
        XCTAssertEqual(UpdateRelaunch.closeSheets([window, other]), 2, "a sheet over a sheet too")
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(UpdateRelaunch.closeSheets([window, other]), 0, "nothing left to close")
    }

    func testBuildOnDiskIsReadFromTheFile() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "22"], format: .xml, options: 0).write(to: plist)
        XCTAssertEqual(UpdateRelaunch.buildOnDisk(app), "22")
        // replaced in place, as Sparkle does: the new value, not a cached one
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "23"], format: .xml, options: 0).write(to: plist)
        XCTAssertEqual(UpdateRelaunch.buildOnDisk(app), "23")
        XCTAssertNil(UpdateRelaunch.buildOnDisk(app.appendingPathComponent("missing.app")))
    }

    func testPendingOnlyWhenTheBundleOnDiskIsAnotherBuild() {
        XCTAssertTrue(UpdateRelaunch.isPending(running: "22", onDisk: "23"))
        XCTAssertFalse(UpdateRelaunch.isPending(running: "23", onDisk: "23"))
        XCTAssertFalse(UpdateRelaunch.isPending(running: "23", onDisk: nil), "being replaced right now, or unreadable")
        XCTAssertFalse(UpdateRelaunch.isPending(running: nil, onDisk: "23"))
    }

    func testRelaunchWaitsForThisProcessThenOpensTheBundle() {
        let args = UpdateRelaunch.relaunchArguments(pid: 4242, bundlePath: "/Applications/Kill Switch.app")
        XCTAssertEqual(args.first, "-c")
        XCTAssertEqual(Array(args.suffix(3)), ["sh", "4242", "/Applications/Kill Switch.app"], "passed as arguments, never inside the script")
        XCTAssertTrue(args[1].contains("kill -0 \"$1\""))
        XCTAssertTrue(args[1].contains("/usr/bin/open \"$2\""))
    }

    /// #51: an update relaunch that found the window closed starts the app without it, once.
    func testStartsWithoutWindowOnlySoonAfterTheMark() {
        XCTAssertFalse(UpdateRelaunch.startsWithoutWindow(markedAt: nil, now: 1000))
        XCTAssertTrue(UpdateRelaunch.startsWithoutWindow(markedAt: 1000, now: 1005))
        XCTAssertTrue(UpdateRelaunch.startsWithoutWindow(markedAt: 1000, now: 1000 + UpdateRelaunch.windowlessFor))
        XCTAssertFalse(UpdateRelaunch.startsWithoutWindow(markedAt: 1000, now: 1001 + UpdateRelaunch.windowlessFor),
                       "a relaunch that never came: the next start by hand opens the window")
        XCTAssertFalse(UpdateRelaunch.startsWithoutWindow(markedAt: 1000, now: 900), "the clock went back")
    }
}

@MainActor
private final class FakeWindow: SheetHost {
    private var sheets: [NSWindow]
    init(sheets: Int) { self.sheets = (0..<sheets).map { _ in NSWindow() } }
    var attachedSheet: NSWindow? { sheets.last }
    func endSheet(_ sheet: NSWindow) { sheets.removeAll { $0 === sheet } }
}
