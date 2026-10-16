import XCTest

/// #55: the content filter blocks only while the helper is installed, and removing the helper
/// from the app turns the filter off.
final class FilterGateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "FilterGateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appending(path: name).path(percentEncoded: false) }

    func testInstalledHelperBlocks() throws {
        try Data("#!/bin/bash\n".utf8).write(to: dir.appending(path: "ks"))
        XCTAssertTrue(FilterGate.blocks(helperAt: path("ks")))
    }

    /// uninstall.sh removed /Library/KillSwitch: no pf rules behind the filter, nothing to protect.
    func testRemovedHelperBlocksNothing() {
        XCTAssertFalse(FilterGate.blocks(helperAt: path("ks")))
        XCTAssertFalse(FilterGate.blocks(helperAt: path("KillSwitch/ks")))
    }

    /// `/Library/KillSwitch` replaced by a file: no helper either.
    func testHelperUnderAFileIsRemoved() throws {
        try Data().write(to: dir.appending(path: "KillSwitch"))
        XCTAssertFalse(FilterGate.blocks(helperAt: path("KillSwitch/ks")))
    }

    /// Cannot tell (no permission to look, as a sandbox refusal would be): keep blocking.
    func testUnknownKeepsBlocking() throws {
        try XCTSkipIf(geteuid() == 0, "root looks into a mode 000 directory: no refusal to test")
        let locked = dir.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data().write(to: locked.appending(path: "ks"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }
        XCTAssertTrue(FilterGate.blocks(helperAt: path("locked/ks")))
    }

    // MARK: wiring, read from the sources (NetworkExtension does not run in unit tests)

    private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The body of the function whose declaration starts with `head`, `//` comments removed.
    private func code(_ head: String, in file: String) throws -> String {
        let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: head), "\(head) not found in \(file)")
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        return text[start.upperBound..<end.lowerBound].split(separator: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// The filter asks the gate before anything can drop a flow, and lets the flow out without it.
    func testTheFilterAsksTheGateFirst() throws {
        let body = try code("override func handleNewFlow(", in: "Filter/FilterDataProvider.swift")
        let gate = try XCTUnwrap(body.range(of: "!Self.gateBlocks() { return .allow() }"), "the gate is not asked")
        let drop = try XCTUnwrap(body.range(of: ".drop()"))
        XCTAssertLessThan(gate.lowerBound, drop.lowerBound)
        XCTAssertFalse(body[..<gate.lowerBound].contains("return"))
    }

    /// «Удалить KillSwitch из системы…»: the filter is switched off once uninstall.sh ran and before
    /// the app reports done, not left to a later refresh that a quit app never runs.
    func testRemovingTheHelperTurnsTheFilterOff() throws {
        let body = try code("    func uninstall() {", in: "App/KillSwitchControl.swift")
        let script = try XCTUnwrap(body.range(of: "runBundled(\"uninstall.sh\""))
        let off = try XCTUnwrap(body.range(of: "await filter.turnOff()"), "the filter is not switched off")
        XCTAssertLessThan(script.lowerBound, off.lowerBound)
        XCTAssertFalse(body[..<off.lowerBound].contains("return"))
    }
}
