import XCTest

final class BundleSignatureTests: XCTestCase {
    /// Apple's own app passes an Apple requirement, but not ours: the team is part of the check.
    func testRequirementDecides() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        XCTAssertTrue(BundleSignature.isValid(calculator, requirement: "anchor apple"))
        XCTAssertFalse(BundleSignature.isValid(calculator, requirement: BundleSignature.ourTeam))
    }

    /// A bundle whose scripts were swapped (or that was never signed) is refused.
    func testUnsignedBundleIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents/Resources/Helper"), withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: dir.appendingPathComponent("Contents/Resources/Helper/install.sh"), atomically: true, encoding: .utf8)
        XCTAssertFalse(BundleSignature.isValid(dir, requirement: "anchor apple generic"))
        XCTAssertFalse(BundleSignature.isValid(dir.appendingPathComponent("missing"), requirement: "anchor apple generic"))
    }

    func testOurTeamRequirement() {
        XCTAssertEqual(BundleSignature.ourTeam, #"anchor apple generic and certificate leaf[subject.OU] = "YR58655PJ7""#)
    }
}
