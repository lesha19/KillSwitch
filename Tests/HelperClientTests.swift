import XCTest

/// XPC runs its reply, error and invalidation blocks on its own queue. In the main-actor
/// HelperClient a block not marked @Sendable is taken for main-actor code and traps there: 0.15
/// crashed at launch in daemonBuild's error handler. HelperClient is not in the test target
/// (it needs the app), so this reads its source.
final class HelperClientTests: XCTestCase {
    func testEveryXPCBlockInHelperClientIsSendable() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("App/HelperClient.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)
        let xpcBlocks = lines.filter {
            $0.contains("remoteObjectProxyWithErrorHandler {") || $0.contains("invalidationHandler = {")
                || $0.contains("interruptionHandler = {") || $0.contains("helper.version {")
        }
        XCTAssertFalse(xpcBlocks.isEmpty)
        for line in xpcBlocks {
            XCTAssertTrue(line.contains("{ @Sendable"), "XPC block not @Sendable: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// KVO calls its handler on the thread that changed the value; Sparkle's `canCheckForUpdates`
    /// is not promised to change on the main thread, so the handler hops there instead of
    /// asserting it (`MainActor.assumeIsolated` traps off main, the 0.15 crash class).
    func testKeyValueObservationsHopToTheMainActor() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("App/Updater.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.contains(".observe(") })
        let handler = lines[start...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }
        XCTAssertFalse(handler.contains { $0.contains("assumeIsolated") }, handler.joined(separator: "\n"))
        XCTAssertTrue(handler.contains { $0.contains("@MainActor in") }, handler.joined(separator: "\n"))
    }
}
