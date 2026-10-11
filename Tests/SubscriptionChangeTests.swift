import XCTest

/// A new subscription link (Settings, QR, `killswitch://add`) replaces the old one only once it
/// answered: a link that fails must not cost the person the key that works (#23 review).
final class SubscriptionChangeTests: XCTestCase {
    func testFirstLinkIsKeptBeforeTheFetch() {
        // a first link that fails to load stays, and the timer tries it again
        XCTAssertEqual(SubscriptionChange.of("https://a.example/s", current: nil), .first)
        XCTAssertTrue(SubscriptionChange.first.storesBeforeFetch)
    }

    func testAnotherLinkReplacesOnlyAfterItAnswered() {
        let change = SubscriptionChange.of("https://b.example/s", current: "https://a.example/s")
        XCTAssertEqual(change, .replace)
        XCTAssertFalse(change.storesBeforeFetch)
        XCTAssertFalse(change.resetsStatusBeforeFetch)
        // a failed fetch of the new link is no failed update of the old one
        XCTAssertFalse(change.recordsFailure)
    }

    func testTheSameLinkIsAnUpdate() {
        XCTAssertEqual(SubscriptionChange.of("https://a.example/s", current: "https://a.example/s"), .same)
        XCTAssertFalse(SubscriptionChange.same.storesBeforeFetch)
        XCTAssertFalse(SubscriptionChange.same.resetsStatusBeforeFetch)
        XCTAssertTrue(SubscriptionChange.same.recordsFailure)
    }

    /// The backup link belongs to the old subscription: a new link is never fetched through it.
    func testANewLinkIsNotFetchedThroughTheOldBackup() {
        XCTAssertEqual(SubscriptionChange.replace.sources(hasBackup: true, vpnRunning: true), [.primary, .primaryViaVPN])
        XCTAssertEqual(SubscriptionChange.first.sources(hasBackup: true, vpnRunning: false), [.primary])
        XCTAssertEqual(SubscriptionChange.same.sources(hasBackup: true, vpnRunning: false), [.primary, .backup])
    }
}
