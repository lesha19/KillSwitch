import XCTest
@testable import KillSwitch

final class OnboardingTests: XCTestCase {
    func testFirstRunHasEveryStep() {
        XCTAssertEqual(Onboarding.steps(installed: false, hasServers: false, filterOn: false),
                       [.welcome, .subscription, .install, .filter, .done])
    }

    func testWorkingFilterIsNotAskedAgain() {
        XCTAssertEqual(Onboarding.steps(installed: false, hasServers: false, filterOn: true),
                       [.welcome, .subscription, .install, .done])
    }

    /// «Добавить подписку…» after the service is installed: the subscription, then one password to load it.
    func testInstalledWithoutServersStartsAtSubscription() {
        XCTAssertEqual(Onboarding.steps(installed: true, hasServers: false, filterOn: false),
                       [.subscription, .install, .filter, .done])
    }

    func testEverythingDoneLeavesTheFinish() {
        XCTAssertEqual(Onboarding.steps(installed: true, hasServers: true, filterOn: true), [.done])
    }

    /// One password: install.sh, the import and connecting run as one admin command.
    func testInstallIsOneCommandChain() {
        let commands = Onboarding.commands(installScript: "/App/Helper/install.sh", user: "alex", servers: ["1.2.3.4"],
                                           helper: "/Library/KillSwitch/ks", profile: "/tmp/p.json")
        XCTAssertEqual(commands, [
            ["/bin/bash", "-p", "/App/Helper/install.sh", "alex", "1.2.3.4"],
            ["/Library/KillSwitch/ks", "core", "import", "/tmp/p.json"],
            ["/Library/KillSwitch/ks", "core", "on"],
        ])
        XCTAssertEqual(AdminScript.source(commands).components(separatedBy: "\" && \"").count, 3)
    }

    func testAlreadyInstalledOnlyImportsAndConnects() {
        let commands = Onboarding.commands(installScript: nil, user: "alex", servers: [], helper: "/ks", profile: "/tmp/p.json")
        XCTAssertEqual(commands, [["/ks", "core", "import", "/tmp/p.json"], ["/ks", "core", "on"]])
    }

    func testCheckedSubscriptionLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let expire = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let found = Onboarding.Found(title: "StorkVPN · Премиум", servers: 6, expire: expire)
        XCTAssertEqual(found.line(calendar: calendar), "Подписка «StorkVPN · Премиум»: 6 серверов, до 2 ноября")
        XCTAssertEqual(Onboarding.Found(title: nil, servers: 1, expire: nil).line(calendar: calendar), "Подписка: 1 сервер")
        XCTAssertEqual(Onboarding.Found(title: nil, servers: 2, expire: nil, ownServers: true).line(calendar: calendar),
                       "Свои серверы: 2 сервера")
    }

    func testNextNeedsAServer() {
        XCTAssertFalse(Onboarding.Found(title: "X", servers: 0, expire: nil).ready)
        XCTAssertTrue(Onboarding.Found(title: "X", servers: 3, expire: nil).ready)
    }
}
