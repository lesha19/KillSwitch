import CryptoKit
import XCTest

final class HelperVersionTests: XCTestCase {
    private let script = Data("#!/bin/bash\nset -u\nKS_VERSION=\"0.9.1\"\necho hi\n".utf8)

    func testSameFileMatches() {
        XCTAssertEqual(HelperVersion.matches(installed: script, bundled: script), true)
    }

    /// Any change to the helper in the app (even without a new version string) means the installed
    /// one is not what this app expects: «Восстановить службу…».
    func testAnyDifferenceIsAMismatch() {
        var changed = script
        changed.append(contentsOf: Array("# one more line\n".utf8))
        XCTAssertEqual(HelperVersion.matches(installed: changed, bundled: script), false)
    }

    func testUnknownWhenAFileIsMissing() {
        XCTAssertNil(HelperVersion.matches(installed: nil, bundled: script))
        XCTAssertNil(HelperVersion.matches(installed: script, bundled: nil))
    }

    func testVersionString() {
        XCTAssertEqual(HelperVersion.version(of: script), "0.9.1")
        XCTAssertNil(HelperVersion.version(of: Data("#!/bin/bash\necho old\n".utf8)), "helpers before 0.9.1 carry none")
    }

    /// Helper/ks says the app's version (project.yml MARKETING_VERSION): they are bumped together.
    func testBundledHelperCarriesTheAppVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let app = try XCTUnwrap(project.firstMatch(of: /MARKETING_VERSION: "([^"]+)"/)).1
        XCTAssertEqual(HelperVersion.version(of: try Data(contentsOf: root.appendingPathComponent("Helper/ks"))), String(app))
    }

    // MARK: install.sh's completion marker (0.15.2: an install that stopped half-way)

    private func marker(_ ks: Data, version: String = "0.9.1") -> Data {
        let hex = SHA256.hash(data: ks).map { String(format: "%02x", $0) }.joined()
        return Data("version \(version)\nsha256 \(hex)\n".utf8)
    }

    func testMarkerNamingTheInstalledHelperCompletesTheInstall() {
        XCTAssertTrue(HelperVersion.installCompleted(marker: marker(script), installed: script))
        XCTAssertTrue(HelperVersion.installCompleted(marker: Data(String(decoding: marker(script), as: UTF8.self).uppercased().utf8),
                                                     installed: script), "hex in either case")
    }

    /// No marker (a helper from before 0.15.2, or an install that stopped before its last step),
    /// one naming another ks, or garbage: not complete.
    func testAnythingElseIsIncomplete() {
        var other = script
        other.append(contentsOf: Array("# changed\n".utf8))
        XCTAssertFalse(HelperVersion.installCompleted(marker: nil, installed: script))
        XCTAssertFalse(HelperVersion.installCompleted(marker: marker(other), installed: script))
        XCTAssertFalse(HelperVersion.installCompleted(marker: Data(), installed: script))
        XCTAssertFalse(HelperVersion.installCompleted(marker: Data("sha256 \n".utf8), installed: script))
    }

    func testCheck() {
        var other = script
        other.append(contentsOf: Array("# changed\n".utf8))
        let done = marker(script)
        XCTAssertEqual(HelperVersion.check(installed: script, bundled: script, marker: done, age: 1), .current)
        XCTAssertEqual(HelperVersion.check(installed: other, bundled: script, marker: marker(other), age: 999), .outdated)
        XCTAssertEqual(HelperVersion.check(installed: nil, bundled: script, marker: nil, age: 999), .unknown)
        XCTAssertEqual(HelperVersion.check(installed: script, bundled: nil, marker: nil, age: 999), .unknown)
        // the right ks but no marker: install.sh stopped after replacing it, so it runs again...
        XCTAssertEqual(HelperVersion.check(installed: script, bundled: script, marker: nil, age: 999), .outdated)
        XCTAssertEqual(HelperVersion.check(installed: script, bundled: script, marker: marker(other), age: 999), .outdated)
        // ...unless it was replaced a moment ago: that install may still be running
        XCTAssertEqual(HelperVersion.check(installed: script, bundled: script, marker: nil, age: 30), .installing)
    }
}
