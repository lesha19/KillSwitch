import XCTest

/// After an app update the activated filter extension is replaced by the bundled one at launch
/// (ADR 0012 addendum), without asking anything when nothing changed.
final class FilterUpgradeTests: XCTestCase {
    private func ext(_ short: String, _ build: String, enabled: Bool = true, awaiting: Bool = false,
                     uninstalling: Bool = false) -> FilterUpgrade.Installed {
        FilterUpgrade.Installed(shortVersion: short, build: build, enabled: enabled,
                                awaitingApproval: awaiting, uninstalling: uninstalling)
    }

    private func decide(_ installed: [FilterUpgrade.Installed]) -> FilterUpgrade.Decision {
        FilterUpgrade.decide(installed: installed, bundledShort: "0.14.1", bundledBuild: "17")
    }

    /// The measured case: 0.6 (6) activated while the app carries 0.14.1 (17).
    func testOldActiveExtensionIsReplaced() {
        XCTAssertEqual(decide([ext("0.6", "6")]), .replace)
        XCTAssertEqual(decide([ext("0.14", "16")]), .replace)
    }

    func testSameVersionAsksNothing() {
        XCTAssertEqual(decide([ext("0.14.1", "17")]), .current)
        // the old one still listed while macOS finishes the replacement
        XCTAssertEqual(decide([ext("0.6", "6", enabled: false, uninstalling: true), ext("0.14.1", "17")]), .current)
    }

    /// The user never turned the filter on (or removed it): launch does not install it.
    func testNothingActiveIsLeftAlone() {
        XCTAssertEqual(decide([]), .notActive)
        XCTAssertEqual(decide([ext("0.6", "6", enabled: false, uninstalling: true)]), .notActive)
        XCTAssertEqual(decide([ext("0.6", "6", enabled: false, awaiting: true)]), .notActive)
    }

    /// The replacement was already submitted and waits in System Settings: no new request, the banner.
    func testPendingReplacementWaitsForApproval() {
        XCTAssertEqual(decide([ext("0.6", "6"), ext("0.14.1", "17", enabled: false, awaiting: true)]), .awaitingApproval)
    }

    /// An older app copy never puts its older filter over a newer one on its own.
    func testOlderBundleKeepsTheNewerExtension() {
        XCTAssertEqual(decide([ext("0.15", "18")]), .current)
    }

    /// Builds are numbers; without one the marketing versions decide.
    func testVersionsWithoutBuildNumbers() {
        XCTAssertEqual(FilterUpgrade.decide(installed: [ext("0.13", "x")], bundledShort: "0.14", bundledBuild: "y"), .replace)
        XCTAssertEqual(FilterUpgrade.decide(installed: [ext("0.15", "x")], bundledShort: "0.14", bundledBuild: "y"), .current)
    }
}
