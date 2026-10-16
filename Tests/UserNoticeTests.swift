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

    /// #85: the VPN on and its core not running for 5 minutes; always shown, whatever the switches.
    func testVPNStuck() {
        XCTAssertEqual(UserNotice.vpnStuck.title, "Интернет закрыт: VPN не подключается")
        XCTAssertEqual(UserNotice.vpnStuck.body, "VPN не подключается уже 5 минут, а KillSwitch держит интернет закрытым, чтобы ничего не утекло. Выбери другой сервер или нажми «Отключить VPN».")
        XCTAssertEqual(UserNotice.vpnStuck.action, .openApp)
        XCTAssertNil(UserNotice.vpnStuck.setting)
    }

    /// Auto-connect found Happ up: it does not stop it silently, it says so (ADR 0009).
    func testAnotherVPNAtAutoConnect() {
        let notice = UserNotice.otherVPN(name: "Happ")
        XCTAssertEqual(notice.title, "Работает другой VPN (Happ)")
        XCTAssertEqual(notice.body, "KillSwitch не подключился сам, чтобы не выключать его без спроса. Переключиться можно в KillSwitch.")
        XCTAssertEqual(UserNotice.otherVPN(name: nil).title, "Работает другой VPN")
        XCTAssertEqual(notice.action, .openApp)
        XCTAssertEqual(notice.setting, .connection)
        XCTAssertEqual(notice.key, UserNotice.otherVPN(name: nil).key)
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

    func testDoubleVPNTurnedOffByItself() {
        // ADR 0027: the helper turned it off (the entry left the subscription…): loud, not silent
        let notice = UserNotice.doubleVPNOff(entry: "🇩🇪 Германия")
        XCTAssertEqual(notice.title, "Двойной VPN выключен")
        XCTAssertEqual(notice.body, "Сервер входа «🇩🇪 Германия» больше не подходит. VPN работает через один сервер.")
        XCTAssertEqual(notice.action, .openApp)
        XCTAssertEqual(notice.setting, .connection)
        XCTAssertTrue(Multihop.turnedOffByItself(was: "🇩🇪 Германия", now: nil, asked: false))
        XCTAssertFalse(Multihop.turnedOffByItself(was: "🇩🇪 Германия", now: nil, asked: true), "the person turned it off")
        XCTAssertFalse(Multihop.turnedOffByItself(was: nil, now: nil, asked: false))
        XCTAssertFalse(Multihop.turnedOffByItself(was: "A", now: "B", asked: false))
    }
}
