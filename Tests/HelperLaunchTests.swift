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

    /// The helper was compared (outdated) while the daemon waited for Login Items: the passwordless
    /// upgrade starts as soon as the switch is on, not only at the next launch.
    func testUpgradeWhenTheDaemonBecomesReady() {
        XCTAssertTrue(HelperService.upgradeWhenReady(previous: .needsApproval, current: .ready, helperOutdated: true))
        XCTAssertTrue(HelperService.upgradeWhenReady(previous: .needsRegistration, current: .ready, helperOutdated: true))
        XCTAssertFalse(HelperService.upgradeWhenReady(previous: .ready, current: .ready, helperOutdated: true))
        XCTAssertFalse(HelperService.upgradeWhenReady(previous: .needsApproval, current: .ready, helperOutdated: false))
        XCTAssertFalse(HelperService.upgradeWhenReady(previous: .needsRegistration, current: .needsApproval, helperOutdated: true))
    }

    /// F3 (#91): a user-owned copy in /Applications with a current helper asks the daemon once to lock it.
    func testAskBundleLockOnlyForAUserOwnedCopyInApplications() {
        let app = "/Applications/KillSwitch.app"
        func ask(_ path: String = app, owner: Int? = 501, _ availability: HelperService.Availability = .ready,
                 outdated: Bool = false, asked: Bool = false) -> Bool {
            HelperService.shouldAskBundleLock(bundlePath: path, ownerID: owner, availability: availability,
                                              helperOutdated: outdated, asked: asked)
        }
        XCTAssertTrue(ask())
        XCTAssertFalse(ask(owner: 0), "already root")
        XCTAssertFalse(ask(owner: nil), "owner unknown")
        XCTAssertFalse(ask("/Users/me/Build/KillSwitch.app"), "only /Applications")
        XCTAssertFalse(ask(app, .needsApproval), "no daemon to ask")
        XCTAssertFalse(ask(outdated: true), "the upgrade path is on its way")
        XCTAssertFalse(ask(asked: true), "once per launch")
    }

    /// The registration at launch did not take (still not registered): the banner too, never a password.
    func testBannerWhileTheDaemonIsStillNotRegistered() {
        XCTAssertTrue(HelperService.showApprovalBanner(helperInstalled: true, availability: .needsRegistration, lastShown: nil, now: now))
        XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: true, availability: .needsRegistration,
                                                        lastShown: now.addingTimeInterval(-3600), now: now))
    }

    func testApprovalBannerOnlyWhileApprovalIsMissing() {
        for availability in [HelperService.Availability.ready, .unavailable] {
            XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: true, availability: availability, lastShown: nil, now: now))
        }
        XCTAssertFalse(HelperService.showApprovalBanner(helperInstalled: false, availability: .needsApproval, lastShown: nil, now: now))
    }
}
