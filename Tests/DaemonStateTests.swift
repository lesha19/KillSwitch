import XCTest

final class DaemonStateTests: XCTestCase {
    func testParsesTheWatchdogFile() {
        let state = DaemonState(text: "pid=412\nprotection=on\ncore=on\ntunnels=vpn:utun4 ts:utun3\n")
        XCTAssertEqual(state?.pid, 412)
        XCTAssertEqual(state?.protection, .on)
        XCTAssertEqual(state?.coreRunning, true)
        XCTAssertEqual(state?.tunnels, "vpn:utun4 ts:utun3")
    }

    func testPauseAndOff() {
        XCTAssertEqual(DaemonState(text: "pid=9\nprotection=paused:1760000000\ncore=off\ntunnels=vpn: ts:")?.protection,
                       .paused(until: Date(timeIntervalSince1970: 1_760_000_000)))
        XCTAssertEqual(DaemonState(text: "pid=9\nprotection=off\ncore=off")?.protection, .off)
        XCTAssertEqual(DaemonState(text: "pid=9\nprotection=off")?.coreRunning, false)
    }

    func testIncompleteFileIsIgnored() {
        XCTAssertNil(DaemonState(text: ""))
        XCTAssertNil(DaemonState(text: "protection=on"))
        XCTAssertNil(DaemonState(text: "pid=abc\nprotection=on"))
        XCTAssertNil(DaemonState(text: "pid=1\nprotection=on"), "launchd's pid is never the watchdog")
        XCTAssertNil(DaemonState(text: "pid=0\nprotection=on"))
        XCTAssertNil(DaemonState(text: "pid=12\n"))
    }

    func testHelperWord() {
        XCTAssertEqual(DaemonState.protection("on\n"), .on)
        XCTAssertEqual(DaemonState.protection("off"), .off)
        XCTAssertEqual(DaemonState.protection("paused:x"), .off)
    }

    func testAlive() {
        XCTAssertTrue(DaemonState.alive(getpid()))
        XCTAssertFalse(DaemonState.alive(0))
        XCTAssertFalse(DaemonState.alive(1))
        XCTAssertFalse(DaemonState.alive(pid_t(Int32.max)))
    }

    func testReadNeedsALiveWriter() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "pid=\(getpid())\nprotection=on\ncore=off\ntunnels=vpn: ts:\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(DaemonState.read(path: file.path)?.protection, .on)
        try "pid=\(Int32.max)\nprotection=on\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(DaemonState.read(path: file.path), "a file left by a dead daemon")
        XCTAssertNil(DaemonState.read(path: file.path + ".missing"))
    }
}
