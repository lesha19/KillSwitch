import XCTest

/// ADR 0010 on launch: an installed helper without the daemon registers it once; macOS's switch in
/// Login Items is asked for by a banner at most once a day.
final class HelperLaunchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRegistersWhenTheHelperIsInstalledWithoutTheDaemon() {
        XCTAssertEqual(HelperService.launchStep(helperInstalled: true, availability: .needsRegistration), .register)
    }

    func testNothingWithoutTheHelperOrWhenReady() {
        // the wizard registers it together with the first install
        XCTAssertEqual(HelperService.launchStep(helperInstalled: false, availability: .needsRegistration), .nothing)
        XCTAssertEqual(HelperService.launchStep(helperInstalled: true, availability: .ready), .nothing)
        XCTAssertEqual(HelperService.launchStep(helperInstalled: true, availability: .unavailable), .nothing)
        XCTAssertEqual(HelperService.launchStep(helperInstalled: true, availability: .needsApproval), .nothing)
    }

    func testApprovalBannerOncePerDay() {
        XCTAssertTrue(HelperService.showApprovalBanner(helperInstalled: true, availability: .needsApproval, lastShown: nil, now: now))
        XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: true, availability: .needsApproval,
                                                        lastShown: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(HelperService.showApprovalBanner(helperInstalled: true, availability: .needsApproval,
                                                       lastShown: now.addingTimeInterval(-86400), now: now))
    }

    func testApprovalBannerOnlyWhileApprovalIsMissing() {
        for availability in [HelperService.Availability.ready, .needsRegistration, .unavailable] {
            XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: true, availability: availability, lastShown: nil, now: now))
        }
        XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: false, availability: .needsApproval, lastShown: nil, now: now))
    }
}
