import XCTest

final class HomeNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb: Int64 = 1 << 30

    private func usage(used: Int64 = 0, total: Int64? = nil, expiresIn days: Double? = nil) -> SubscriptionUsage {
        var usage = SubscriptionUsage(header: "upload=0; download=1")!
        usage.download = used
        usage.total = total
        usage.expire = days.map { now.addingTimeInterval($0 * 86400) }
        return usage
    }

    private func input(_ change: (inout HomeNotice.Input) -> Void = { _ in }) -> HomeNotice.Input {
        var input = HomeNotice.Input(otherVPN: false, usage: nil, newServers: false, filterIncomplete: false,
                                     filterDismissed: false, now: now)
        change(&input)
        return input
    }

    func testNothingToSay() {
        XCTAssertNil(HomeNotice.pick(input()))
        XCTAssertNil(HomeNotice.pick(input { $0.usage = usage(used: 10 * gb, total: 100 * gb, expiresIn: 20) }))
    }

    func testPriorities() {
        let everything = input {
            $0.otherVPN = true
            $0.usage = usage(used: 99 * gb, total: 100 * gb, expiresIn: -1)
            $0.newServers = true
            $0.filterIncomplete = true
        }
        XCTAssertEqual(HomeNotice.pick(everything), .otherVPN)
        var next = everything; next.otherVPN = false
        XCTAssertEqual(HomeNotice.pick(next), .expired)
        next.usage = usage(used: 99 * gb, total: 100 * gb, expiresIn: 2)
        XCTAssertEqual(HomeNotice.pick(next), .ending(days: 2))
        next.usage = usage(used: 99 * gb, total: 100 * gb, expiresIn: 30)
        XCTAssertEqual(HomeNotice.pick(next), .trafficLow(used: 99 * gb, total: 100 * gb))
        next.usage = nil
        XCTAssertEqual(HomeNotice.pick(next), .newServers)
        next.newServers = false
        XCTAssertEqual(HomeNotice.pick(next), .filterOff)
        next.filterDismissed = true
        XCTAssertNil(HomeNotice.pick(next))
    }

    /// The two approvals in System Settings come last: the old filter keeps working meanwhile, and
    /// without the daemon every change only asks for the password.
    func testApprovalsComeLast() {
        let both = input {
            $0.filterUpdateWaiting = true
            $0.helperApproval = true
        }
        XCTAssertEqual(HomeNotice.pick(both), .filterUpdateWaiting)
        XCTAssertEqual(HomeNotice.pick(input { $0.helperApproval = true }), .helperApproval)
        XCTAssertEqual(HomeNotice.pick(input { $0.helperApproval = true; $0.newServers = true }), .newServers)
        XCTAssertEqual(HomeNotice.pick(input { $0.filterUpdateWaiting = true; $0.filterIncomplete = true }), .filterOff)
        XCTAssertEqual(HomeNotice.helperApproval.title, "Разреши KillSwitch в Объектах входа, чтобы не вводить пароль каждый раз.")
    }

    func testEndingCountsWholeDaysFromThreeDaysOut() {
        XCTAssertEqual(HomeNotice.pick(input { $0.usage = usage(expiresIn: 3) }), .ending(days: 3))
        XCTAssertEqual(HomeNotice.pick(input { $0.usage = usage(expiresIn: 0.4) }), .ending(days: 1))
        XCTAssertNil(HomeNotice.pick(input { $0.usage = usage(expiresIn: 3.5) }))
    }

    func testTrafficFromNinetyPercent() {
        XCTAssertNil(HomeNotice.pick(input { $0.usage = usage(used: 89 * gb, total: 100 * gb) }))
        XCTAssertEqual(HomeNotice.pick(input { $0.usage = usage(used: 90 * gb, total: 100 * gb) }),
                       .trafficLow(used: 90 * gb, total: 100 * gb))
    }

    func testTexts() {
        XCTAssertEqual(HomeNotice.otherVPN.title, "Работает другой VPN.")
        XCTAssertEqual(HomeNotice.otherVPN.message, "Отключи его: два VPN мешают друг другу.")
        XCTAssertEqual(HomeNotice.expired.title, "Подписка закончилась.")
        XCTAssertEqual(HomeNotice.ending(days: 2).title, "Подписка кончается через 2 дня.")
        XCTAssertEqual(HomeNotice.ending(days: 1).title, "Подписка кончается через 1 день.")
        XCTAssertEqual(HomeNotice.trafficLow(used: 96 * gb, total: 100 * gb).title, "Трафик почти закончился: 96 из 100 ГБ.")
        XCTAssertEqual(HomeNotice.newServers.title, "В подписке новые серверы.")
        XCTAssertEqual(HomeNotice.filterOff.title, "Защита неполная.")
        XCTAssertEqual(HomeNotice.filterOff.message, "Защита macOS выключена. Рекомендуем включить второй уровень.")
    }

    func testPlural() {
        XCTAssertEqual(Russian.plural(1, "день", "дня", "дней"), "1 день")
        XCTAssertEqual(Russian.plural(2, "день", "дня", "дней"), "2 дня")
        XCTAssertEqual(Russian.plural(5, "день", "дня", "дней"), "5 дней")
        XCTAssertEqual(Russian.plural(11, "день", "дня", "дней"), "11 дней")
        XCTAssertEqual(Russian.plural(21, "день", "дня", "дней"), "21 день")
        XCTAssertEqual(Russian.plural(24, "минута", "минуты", "минут"), "24 минуты")
    }

    func testTraffic() {
        XCTAssertEqual(Russian.traffic(used: 38 * gb + gb / 2, total: 100 * gb), "38,5 из 100 ГБ")
        XCTAssertEqual(Russian.traffic(used: 512 << 20, total: nil), "512 МБ")
        XCTAssertEqual(Russian.bytes(3 * gb), "3 ГБ")
    }

    func testThrottle() {
        var throttle = Throttle(interval: 5)
        XCTAssertTrue(throttle.allow("a", now: now))
        XCTAssertFalse(throttle.allow("a", now: now + 4))
        XCTAssertTrue(throttle.allow("b", now: now + 4))
        XCTAssertTrue(throttle.allow("a", now: now + 5))
    }
}
