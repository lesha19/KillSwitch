import XCTest

final class StatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A healthy install with servers, disconnected, protection on.
    private func input(_ change: (inout Status.Input) -> Void = { _ in }) -> Status.Input {
        var input = Status.Input(protection: .on, connection: .disconnected, foreignVPN: false, daemonProblem: false,
                                 coreInstalled: true, needsRepair: false, hasServers: true, connectingSince: nil, now: now)
        change(&input)
        return input
    }

    // MARK: the ten rows of spec §2

    func testNotInstalled() {
        XCTAssertEqual(Status.summary(input { $0.protection = .notInstalled; $0.coreInstalled = false }), .notInstalled)
    }

    func testBrokenWhenTheServiceIsOff() {
        XCTAssertEqual(Status.summary(input { $0.daemonProblem = true }), .broken(.serviceOff))
    }

    func testBrokenWhenTheVPNIsMissing() {
        XCTAssertEqual(Status.summary(input { $0.coreInstalled = false }), .broken(.vpnMissing))
    }

    func testBrokenWithoutPasswordlessAccess() {
        XCTAssertEqual(Status.summary(input { $0.needsRepair = true }), .broken(.needsAccess))
    }

    func testNeedsSetupWithoutSubscriptionOrOwnServers() {
        XCTAssertEqual(Status.summary(input { $0.hasServers = false }), .needsSetup)
    }

    func testOtherVPNWhileOursIsOff() {
        XCTAssertEqual(Status.summary(input { $0.connection = .otherApp }), .otherVPN)
    }

    func testOtherVPNNextToOurs() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.foreignVPN = true }), .otherVPN)
    }

    func testConnecting() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-5) }), .connecting)
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting }), .connecting)
    }

    func testStuckAfterFifteenSeconds() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-15) }), .connecting)
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-16) }), .stuck)
    }

    func testProtected() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected }), .protected)
    }

    func testConnectedUnprotected() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.protection = .off }), .connectedUnprotected)
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.protection = .paused(until: now + 600) }), .connectedUnprotected)
    }

    func testBlocked() {
        XCTAssertEqual(Status.summary(input()), .blocked)
    }

    func testUnprotected() {
        XCTAssertEqual(Status.summary(input { $0.protection = .off }), .unprotected(pausedUntil: nil))
        XCTAssertEqual(Status.summary(input { $0.protection = .paused(until: now + 600) }), .unprotected(pausedUntil: now + 600))
    }

    func testCheckingUntilTheFirstAnswer() {
        XCTAssertEqual(Status.summary(input { $0.protection = .unknown }), .checking)
    }

    // MARK: priorities

    func testNotInstalledBeatsEverything() {
        let status = Status.summary(input {
            $0.protection = .notInstalled; $0.daemonProblem = true; $0.hasServers = false; $0.connection = .otherApp
        })
        XCTAssertEqual(status, .notInstalled)
    }

    func testBrokenBeatsSetupAndOtherVPN() {
        XCTAssertEqual(Status.summary(input { $0.daemonProblem = true; $0.hasServers = false; $0.connection = .otherApp }),
                       .broken(.serviceOff))
    }

    func testSetupBeatsOtherVPN() {
        XCTAssertEqual(Status.summary(input { $0.hasServers = false; $0.connection = .otherApp }), .needsSetup)
    }

    func testOtherVPNBeatsConnectedAndConnecting() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.foreignVPN = true }), .otherVPN)
    }

    // MARK: what the user sees

    func testConnectedAndBlockedLookDifferent() {
        XCTAssertNotEqual(Status.protected.icon, Status.blocked.icon)
    }

    func testProtectedAndUnprotectedStatesDifferInShape() {
        let icons = [Status.protected, .connectedUnprotected, .blocked, .unprotected(pausedUntil: nil)].map(\.icon)
        XCTAssertEqual(Set(icons).count, 4)
        XCTAssertNotEqual(Status.unprotected(pausedUntil: now).icon, Status.blocked.icon)
    }

    func testEveryStatusHasATemplateIcon() {
        for status in Status.examples(now: now) {
            XCTAssertTrue(status.icon.hasPrefix("MenuBar"), "\(status)")
        }
    }

    func testTitles() {
        XCTAssertEqual(Status.notInstalled.title, "KillSwitch не установлен")
        XCTAssertEqual(Status.broken(.serviceOff).title, "Нужна починка")
        XCTAssertEqual(Status.needsSetup.title, "Добавь подписку")
        XCTAssertEqual(Status.otherVPN.title, "Работает другой VPN")
        XCTAssertEqual(Status.connecting.title, "Подключение…")
        XCTAssertEqual(Status.stuck.title, "Подключение затянулось")
        XCTAssertEqual(Status.protected.title, "Защищено")
        XCTAssertEqual(Status.connectedUnprotected.title, "Подключено без защиты")
        XCTAssertEqual(Status.blocked.title, "Интернет заблокирован")
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).title, "Без VPN и без защиты")
    }

    func testVoiceOverLabel() {
        XCTAssertEqual(Status.blocked.accessibilityLabel, "KillSwitch: Интернет заблокирован")
    }

    func testBlockedIsNotAlarming() {
        XCTAssertEqual(Status.blocked.tone, .neutral)
        XCTAssertEqual(Status.protected.tone, .good)
        XCTAssertEqual(Status.connectedUnprotected.tone, .warning)
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).tone, .warning)
    }

    func testLines() {
        let server = Status.Detail(server: "🇱🇹 Литва", ping: 37)
        XCTAssertEqual(Status.protected.line(server), "🇱🇹 Литва · 37 мс")
        XCTAssertEqual(Status.protected.line(Status.Detail(server: "🇱🇹 Литва")), "🇱🇹 Литва")
        XCTAssertEqual(Status.connecting.line(server), "🇱🇹 Литва")
        XCTAssertEqual(Status.blocked.line(server), "VPN не подключён, поэтому интернет закрыт. Ничего не утекает.")
        XCTAssertEqual(Status.otherVPN.line(server), "Отключи другой VPN: два VPN мешают друг другу.")
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).line(server), "Программы ходят в интернет напрямую.")
        XCTAssertTrue(Status.unprotected(pausedUntil: now).line(server).hasPrefix("Программы ходят в интернет напрямую. Пауза до "))
        XCTAssertEqual(Status.broken(.serviceOff).line(server),
                       "Её выключили в Системных настройках. Правила пока действуют, но следить за ними некому.")
    }

    func testHomeLineLeavesTheServerToItsRow() {
        let server = Status.Detail(server: "🇱🇹 Литва", ping: 37)
        XCTAssertEqual(Status.protected.homeLine(server), "Интернет только через VPN")
        XCTAssertFalse(Status.connecting.homeLine(server).contains("Литва"))
        XCTAssertEqual(Status.blocked.homeLine(server), Status.blocked.line(server))
    }

    func testActions() {
        XCTAssertEqual(Status.notInstalled.primary, .install)
        XCTAssertEqual(Status.broken(.vpnMissing).primary, .repair)
        XCTAssertEqual(Status.broken(.serviceOff).primary, .openLoginItems)
        XCTAssertEqual(Status.needsSetup.primary, .addSubscription)
        XCTAssertEqual(Status.otherVPN.primary, .connect)
        XCTAssertFalse(Status.otherVPN.primaryEnabled)
        XCTAssertEqual(Status.connecting.primary, .cancel)
        XCTAssertEqual(Status.stuck.primary, .chooseServer)
        XCTAssertEqual(Status.stuck.secondary, .disconnect)
        XCTAssertEqual(Status.protected.primary, .disconnect)
        XCTAssertNil(Status.protected.secondary)
        XCTAssertEqual(Status.connectedUnprotected.primary, .disconnect)
        XCTAssertEqual(Status.connectedUnprotected.secondary, .enableProtection)
        XCTAssertEqual(Status.blocked.primary, .connect)
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).secondary, .enableProtection)
        XCTAssertEqual(Status.unprotected(pausedUntil: now).secondary, .resumeProtection)
        XCTAssertEqual(Status.Action.resumeProtection.title, "Возобновить защиту")
        XCTAssertEqual(Status.Action.install.title, "Начать настройку…")
    }
}
