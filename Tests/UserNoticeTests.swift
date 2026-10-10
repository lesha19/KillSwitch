import XCTest
@testable import KillSwitch

final class UserNoticeTests: XCTestCase {
    func testDropTellsWhetherProtectionHolds() {
        XCTAssertEqual(UserNotice.vpnDropped(protected: true).title, "VPN оборвался")
        XCTAssertEqual(UserNotice.vpnDropped(protected: true).body, "Интернет закрыт, пока VPN не подключится. Ничего не утекает.")
        XCTAssertEqual(UserNotice.vpnDropped(protected: false).body, "Защита выключена — программы идут в интернет напрямую.")
        XCTAssertEqual(UserNotice.vpnDropped(protected: false).action, .connect)
        XCTAssertEqual(UserNotice.vpnDropped(protected: true).setting, .connection)
    }

    func testReconnectedNamesTheServer() {
        let notice = UserNotice.reconnected(server: "🇱🇹 Литва")
        XCTAssertEqual(notice.title, "VPN снова работает")
        XCTAssertEqual(notice.body, "🇱🇹 Литва")
        XCTAssertNil(notice.action)
    }

    func testSubscriptionEnding() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let expire = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let notice = UserNotice.subscriptionEnding(days: 3, title: "StorkVPN · Премиум", expire: expire)
        XCTAssertEqual(notice.title, "Подписка кончается через 3 дня")
        XCTAssertEqual(notice.body(calendar: calendar), "StorkVPN · Премиум до 2 ноября.")
        XCTAssertEqual(notice.action, .renew)
        XCTAssertEqual(notice.setting, .subscription)
        XCTAssertEqual(UserNotice.subscriptionEnding(days: 1, title: nil, expire: expire).title, "Подписка кончается через 1 день")
    }

    func testRestOfTheTable() {
        XCTAssertEqual(UserNotice.trafficLow(used: 96 << 30, total: 100 << 30).body, "96 из 100 ГБ.")
        XCTAssertEqual(UserNotice.newServers.action, .approve)
        XCTAssertEqual(UserNotice.pauseEnded.title, "Защита снова включена")
        XCTAssertEqual(UserNotice.pauseEnded.setting, .pause)
        XCTAssertEqual(UserNotice.serviceOff.action, .openLoginItems)
        XCTAssertEqual(UserNotice.serviceOff.setting, .service)
        XCTAssertEqual(UserNotice.autoConnectNeedsPassword.body, "Службу нужно обновить.")
        XCTAssertNil(UserNotice.macOSUpdated.setting)
        XCTAssertEqual(UserNotice.macOSUpdated.action, .check)
    }

    /// Thresholds: one notice at 3 days left and one at 1 day, not every update in between.
    func testEndingThresholds() {
        XCTAssertNil(UserNotice.endingThreshold(secondsLeft: 5 * 86400))
        XCTAssertEqual(UserNotice.endingThreshold(secondsLeft: 2.5 * 86400), 3)
        XCTAssertEqual(UserNotice.endingThreshold(secondsLeft: 0.5 * 86400), 1)
        XCTAssertNil(UserNotice.endingThreshold(secondsLeft: -10))
    }

    /// The same event at most once in 10 minutes; different events do not hold each other back.
    func testAntispam() {
        var throttle = Throttle(interval: UserNotice.interval)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let drop = UserNotice.vpnDropped(protected: true)
        XCTAssertTrue(throttle.allow(drop.key, now: start))
        XCTAssertFalse(throttle.allow(drop.key, now: start.addingTimeInterval(9 * 60)))
        XCTAssertTrue(throttle.allow(UserNotice.reconnected(server: nil).key, now: start.addingTimeInterval(60)))
        XCTAssertTrue(throttle.allow(drop.key, now: start.addingTimeInterval(10 * 60)))
        XCTAssertEqual(UserNotice.vpnDropped(protected: false).key, drop.key)
    }
}
