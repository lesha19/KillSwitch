import XCTest

/// #16: «Бета-версии» lets Sparkle take the appcast items of the "beta" channel (release.sh,
/// KS_CHANNEL=beta); off, only the default channel, which Sparkle always includes.
final class UpdateChannelTests: XCTestCase {
    func testChannels() {
        XCTAssertEqual(UpdateChannel.allowed(beta: true), ["beta"])
        XCTAssertEqual(UpdateChannel.allowed(beta: false), [])
    }

    func testOffUntilChosen() {
        let defaults = UserDefaults(suiteName: "UpdateChannelTests-\(UUID().uuidString)")!
        XCTAssertFalse(UpdateChannel.isBeta(defaults))
        defaults.set(true, forKey: UpdateChannel.betaKey)
        XCTAssertTrue(UpdateChannel.isBeta(defaults))
    }
}
