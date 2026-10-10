import XCTest

final class SplitAppsIntegrityTests: XCTestCase {
    /// An app the user can change (its bundle or the folder it sits in is writable without the
    /// admin password) can be swapped by a program running as the user, and whatever then runs
    /// from that path goes around the VPN.
    func testUserWritableAppsAreFlagged() {
        let writable: Set<String> = ["/Users/me/Applications/Tool.app", "/Users/me/Downloads"]
        let flagged = SplitApps.userWritable(["/Applications/Safari.app", "/Users/me/Applications/Tool.app",
                                              "/Users/me/Downloads/Zoom.app", "Telegram"],
                                             isWritable: { writable.contains($0) })
        XCTAssertEqual(flagged, ["/Users/me/Applications/Tool.app", "/Users/me/Downloads/Zoom.app"])
    }

    /// A process name (lists from before 0.9.1) has no path to check.
    func testNamesAreNotChecked() {
        XCTAssertEqual(SplitApps.userWritable(["Telegram"], isWritable: { _ in true }), [])
    }

    func testWarningText() {
        XCTAssertNil(SplitApps.writableWarning([]))
        XCTAssertEqual(SplitApps.writableWarning(["/Users/me/Downloads/Zoom.app"]),
                       "Zoom можно изменить без пароля администратора, и всё, что запустится из него, пойдёт мимо VPN.")
        XCTAssertEqual(SplitApps.writableWarning(["/a/Zoom.app", "/b/Tool.app"]),
                       "Zoom, Tool можно изменить без пароля администратора, и всё, что запустится из них, пойдёт мимо VPN.")
    }
}
