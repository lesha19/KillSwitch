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

    /// A new link that was kept but not applied (the password was cancelled or refused) is said:
    /// the core still runs the old servers, the next update takes the new link.
    func testKeptButNotAppliedIsSaid() {
        XCTAssertNil(SubscriptionChange.Outcome.applied.notice)
        XCTAssertNil(SubscriptionChange.Outcome.notKept.notice)
        XCTAssertEqual(SubscriptionChange.Outcome.keptNotApplied.notice,
                       "Новая подписка сохранена, но не применена: VPN пока работает со старыми серверами. Нажми «Обновить» в настройках VPN, чтобы применить (спросит пароль).")
    }

    /// Replacing while the main way is Xray with a service that has no Xray config: the advice of
    /// a refresh («выбери запасной») would fetch the old link again, so the replace says what to do.
    func testReplaceWithoutXrayConfigSaysWhatToDo() {
        let expected = UserError(title: "Эта подписка не для основного способа подключения",
                                 message: "Переключи способ подключения на запасной в настройках VPN, затем добавь ссылку снова. Текущая подписка осталась.")
        XCTAssertEqual(SubscriptionChange.replace.xrayFailure(raw: XrayProfile.Failure.notXray.errorDescription!), expected)
        XCTAssertEqual(SubscriptionChange.replace.xrayFailure(raw: "HTTP 404"), expected)
        XCTAssertNil(SubscriptionChange.replace.xrayFailure(raw: "offline: timed out"))
        XCTAssertNil(SubscriptionChange.same.xrayFailure(raw: XrayProfile.Failure.notXray.errorDescription!))
    }
}
