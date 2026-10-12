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
        XCTAssertEqual(Status.summary(input { $0.connection = .otherApp }), .otherVPN(blocksDirect: true))
    }

    func testOtherVPNNextToOurs() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.foreignVPN = true }), .otherVPN(blocksDirect: true))
    }

    /// The field report of 0.11: Happ up, protection on, Russian sites dead. Never «Защищено».
    func testOtherVPNWithProtectionIsAWarningNotProtected() {
        let status = Status.summary(input { $0.connection = .otherApp; $0.protection = .on })
        XCTAssertEqual(status, .otherVPN(blocksDirect: true))
        XCTAssertEqual(status.tone, .warning)
        XCTAssertNotEqual(status.title, Status.protected.title)
    }

    func testOtherVPNWithoutProtectionBlocksNothing() {
        XCTAssertEqual(Status.summary(input { $0.connection = .otherApp; $0.protection = .off }), .otherVPN(blocksDirect: false))
        XCTAssertEqual(Status.summary(input { $0.connection = .otherApp; $0.protection = .paused(until: now + 60) }),
                       .otherVPN(blocksDirect: false))
    }

    /// ADR 0018: protection stands by while another VPN is up and ours is not running; it blocks
    /// nothing, and the line says it will come back.
    func testOtherVPNWhileProtectionStandsBy() {
        let status = Status.summary(input { $0.connection = .otherApp; $0.standby = true })
        XCTAssertEqual(status, .otherVPN(blocksDirect: false, standby: true))
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(status.line(Status.Detail()),
                       "KillSwitch не подключён. Пока работает другой VPN, защита ему не мешает и включится, когда он отключится.")
        XCTAssertEqual(status.primary, .replaceOtherVPN)
        XCTAssertEqual(Status.summary(input { $0.connection = .otherApp; $0.standby = true; $0.protection = .off }),
                       .otherVPN(blocksDirect: false), "standby means nothing while protection is off")
    }

    func testConnecting() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-5) }), .connecting())
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting }), .connecting())
    }

    func testStuckAfterFifteenSeconds() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-15) }), .connecting())
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.connectingSince = now.addingTimeInterval(-16) }), .stuck())
    }

    func testProtected() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected }), .protected)
    }

    /// ADR 0035: while the VPN is on nothing leaks whatever the protection switch says.
    func testConnectedIsProtectedWhateverTheSwitch() {
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.protection = .off; $0.vpnOn = true }), .protected)
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.protection = .paused(until: now + 600); $0.vpnOn = true }), .protected)
    }

    /// The core runs and its tunnel is up but the VPN target is gone and protection is off (a helper
    /// before 0.20, or a Disconnect that raced a Connect): nothing blocks, so not «Защищено».
    func testConnectedWithoutTheVPNTargetIsNotProtected() {
        let status = Status.summary(input { $0.connection = .connected; $0.protection = .off })
        XCTAssertEqual(status, .unblocked())
        XCTAssertEqual(Status.summary(input { $0.connection = .connected; $0.protection = .paused(until: now + 60) }), .unblocked())
        XCTAssertEqual(Status.summary(input { $0.connection = .connected }), .protected, "protection on blocks by itself")
        XCTAssertEqual(status.title, "Трафик может идти мимо VPN")
        XCTAssertEqual(status.line(Status.Detail()), "VPN подключён, но правила защиты не загружены.")
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(status.primary, .enableProtection, "the fix is the main button")
        XCTAssertEqual(status.secondary, .disconnect)
        XCTAssertNotEqual(status.icon, Status.protected.icon)
    }

    /// ADR 0035: the VPN on, its tunnel was up since «Подключить» and is gone (an update, a crash, a
    /// restart, a server switch): the internet is closed until it is back or «Отключить VPN», whatever
    /// the protection switch says.
    func testReconnecting() {
        func on(_ change: (inout Status.Input) -> Void = { _ in }) -> Status.Input {
            input { $0.vpnOn = true; $0.tunnelWasUp = true; change(&$0) }
        }
        XCTAssertEqual(Status.summary(on()), .reconnecting)
        XCTAssertEqual(Status.summary(on { $0.protection = .off }), .reconnecting)
        XCTAssertEqual(Status.summary(on { $0.protection = .paused(until: now + 600) }), .reconnecting)
        XCTAssertEqual(Status.summary(on { $0.connection = .connecting }), .reconnecting, "the core is up, the tunnel not yet")
        XCTAssertEqual(Status.summary(on { $0.connection = .connecting; $0.connectingSince = now - 60 }), .reconnecting)
        XCTAssertEqual(Status.reconnecting.title, "Интернет закрыт: VPN переподключается")
        XCTAssertEqual(Status.reconnecting.line(Status.Detail()), "Ничего не утекает: интернет откроется, когда VPN подключится.")
        XCTAssertEqual(Status.reconnecting.primary, .disconnectVPN)
        XCTAssertEqual(Status.Action.disconnectVPN.title, "Отключить VPN")
        XCTAssertNil(Status.reconnecting.secondary)
        XCTAssertEqual(Status.reconnecting.tone, .neutral)
        XCTAssertEqual(Status.reconnecting.icon, Status.blocked.icon)
    }

    /// ADR 0035, like Mullvad: a first connect (no tunnel yet since «Подключить») is «Подключение…»
    /// then «Подключение затянулось» as before, saying the internet is closed meanwhile, with
    /// «Отключить VPN»; a core that did not start counts as connecting too.
    func testFirstConnectWithTheVPNOn() {
        for protection in [Protection.on, .off, .paused(until: now + 600)] {
            for connection in [Connection.connecting, .disconnected] {
                func at(_ since: TimeInterval) -> Status {
                    Status.summary(input { $0.vpnOn = true; $0.protection = protection; $0.connection = connection; $0.connectingSince = now - since })
                }
                XCTAssertEqual(at(5), .connecting(closed: true), "\(protection) \(connection)")
                XCTAssertEqual(at(16), .stuck(closed: true), "\(protection) \(connection)")
            }
        }
        XCTAssertEqual(Status.summary(input { $0.vpnOn = true }), .connecting(closed: true), "not tracked yet")
        let connecting = Status.connecting(closed: true), stuck = Status.stuck(closed: true)
        XCTAssertEqual(connecting.title, "Подключение…")
        XCTAssertEqual(stuck.title, "Подключение затянулось")
        XCTAssertEqual(connecting.line(Status.Detail(server: "🇱🇹 Литва")), "Интернет закрыт, пока VPN подключается")
        XCTAssertEqual(connecting.homeLine(Status.Detail()), "Интернет закрыт, пока VPN подключается")
        XCTAssertEqual(stuck.line(Status.Detail()), "Сервер не отвечает, интернет закрыт. Попробуй другой.")
        XCTAssertEqual(connecting.primary, .disconnectVPN)
        XCTAssertNil(connecting.secondary)
        XCTAssertEqual(stuck.primary, .chooseServer)
        XCTAssertEqual(stuck.secondary, .disconnectVPN)
        XCTAssertEqual(connecting.icon, Status.connecting().icon)
        XCTAssertEqual(stuck.tone, .warning)
    }

    /// ADR 0035: the VPN on and the watchdog says our rules do not block (pf refused them at
    /// «Подключить», say): the leak outranks connecting, stuck, reconnecting and connected — never
    /// «Ничего не утекает» or «Защищено» then. The fix is «Восстановить службу…», the way out
    /// «Отключить VPN».
    func testRulesMissingOutranksTheVPNStates() {
        for connection in [Connection.connecting, .disconnected, .connected, .otherApp] {
            for since in [5.0, 60] {
                for tunnelWasUp in [false, true] {
                    let status = Status.summary(input {
                        $0.vpnOn = true; $0.rulesMissing = true; $0.connection = connection
                        $0.connectingSince = now - since; $0.tunnelWasUp = tunnelWasUp; $0.protection = .off
                    })
                    XCTAssertEqual(status, .unblocked(vpnOn: true), "\(connection) \(since) \(tunnelWasUp)")
                }
            }
        }
        XCTAssertEqual(Status.summary(input { $0.rulesMissing = true; $0.connection = .connecting }), .connecting(),
                       "only with the VPN on (a helper before 0.20 says nothing about it)")
        let status = Status.unblocked(vpnOn: true)
        XCTAssertEqual(status.title, "Трафик может идти мимо VPN")
        XCTAssertEqual(status.line(Status.Detail()), "VPN включён, но правила защиты не загружены.")
        XCTAssertEqual(status.primary, .repair)
        XCTAssertEqual(status.secondary, .disconnectVPN)
        XCTAssertEqual(status.tone, .warning)
        XCTAssertEqual(Shortcuts.connect(status: status, busy: false, coreConfigured: true),
                       .refused("Не подключилось: Трафик может идти мимо VPN. Открой KillSwitch."))
    }

    /// The VPN on and another program's VPN up: that state, with «Отключить VPN» as the way out
    /// (ours blocks everything around it).
    func testOtherVPNWhileOursIsOn() {
        let status = Status.summary(input { $0.vpnOn = true; $0.connection = .otherApp })
        XCTAssertEqual(status, .otherVPN(blocksDirect: true, vpnOn: true))
        XCTAssertEqual(Status.summary(input { $0.vpnOn = true; $0.tunnelWasUp = true; $0.connection = .otherApp; $0.protection = .off }),
                       .otherVPN(blocksDirect: true, vpnOn: true))
        XCTAssertEqual(status.primary, .replaceOtherVPN)
        XCTAssertEqual(status.secondary, .disconnectVPN)
        XCTAssertNil(Status.otherVPN(blocksDirect: true).secondary)
        XCTAssertEqual(status.line(Status.Detail()), "KillSwitch включён, поэтому интернет мимо него закрыт. Отключи один из двух VPN.")
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
        XCTAssertEqual(Status.summary(input { $0.connection = .connecting; $0.foreignVPN = true }), .otherVPN(blocksDirect: true))
    }

    // MARK: what the user sees

    func testConnectedAndBlockedLookDifferent() {
        XCTAssertNotEqual(Status.protected.icon, Status.blocked.icon)
    }

    func testProtectedAndUnprotectedStatesDifferInShape() {
        let icons = [Status.protected, .unblocked(), .blocked, .unprotected(pausedUntil: nil)].map(\.icon)
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
        XCTAssertEqual(Status.otherVPN(blocksDirect: true).title, "Работает другой VPN")
        XCTAssertEqual(Status.connecting().title, "Подключение…")
        XCTAssertEqual(Status.stuck().title, "Подключение затянулось")
        XCTAssertEqual(Status.protected.title, "Защищено")
        XCTAssertEqual(Status.blocked.title, "Интернет заблокирован")
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).title, "Без VPN и без защиты")
    }

    func testVoiceOverLabel() {
        XCTAssertEqual(Status.blocked.accessibilityLabel, "KillSwitch: Интернет заблокирован")
    }

    func testBlockedIsNotAlarming() {
        XCTAssertEqual(Status.blocked.tone, .neutral)
        XCTAssertEqual(Status.protected.tone, .good)
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).tone, .warning)
    }

    func testLines() {
        let server = Status.Detail(server: "🇱🇹 Литва", ping: 37)
        XCTAssertEqual(Status.protected.line(server), "🇱🇹 Литва · 37 мс")
        XCTAssertEqual(Status.protected.line(Status.Detail(server: "🇱🇹 Литва")), "🇱🇹 Литва")
        XCTAssertEqual(Status.connecting().line(server), "🇱🇹 Литва")
        XCTAssertEqual(Status.blocked.line(server), "VPN не подключён, поэтому интернет закрыт. Ничего не утекает.")
        XCTAssertEqual(Status.otherVPN(blocksDirect: true).line(server),
                       "KillSwitch не подключён. Сайты, которые тот VPN пускает напрямую (часто российские), защита блокирует.")
        XCTAssertEqual(Status.otherVPN(blocksDirect: false).line(server), "KillSwitch не подключён: два VPN не работают вместе.")
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).line(server), "Программы ходят в интернет напрямую.")
        XCTAssertTrue(Status.unprotected(pausedUntil: now).line(server).hasPrefix("Программы ходят в интернет напрямую. Пауза до "))
        XCTAssertEqual(Status.broken(.serviceOff).line(server),
                       "Её выключили в Системных настройках. Защита пока действует, но следить за ней некому.")
    }

    func testHomeLineLeavesTheServerToItsRow() {
        let server = Status.Detail(server: "🇱🇹 Литва", ping: 37)
        XCTAssertEqual(Status.protected.homeLine(server), "Интернет только через VPN")
        XCTAssertFalse(Status.connecting().homeLine(server).contains("Литва"))
        XCTAssertEqual(Status.blocked.homeLine(server), Status.blocked.line(server))
    }

    func testOtherVPNIsNamedOnTheMainScreen() {
        let happ = Status.Detail(otherVPN: "Happ")
        let status = Status.otherVPN(blocksDirect: true)
        XCTAssertEqual(status.homeTitle(happ), "Работает другой VPN (Happ)")
        XCTAssertEqual(status.homeTitle(Status.Detail()), "Работает другой VPN")
        XCTAssertEqual(status.homeLine(happ), status.line(happ))
        XCTAssertEqual(Status.protected.homeTitle(happ), "Защищено")
        var failed = happ
        failed.otherVPNStopFailed = true
        XCTAssertEqual(status.homeLine(failed), OtherVPN.stopFailed(name: "Happ"))
    }

    func testActions() {
        XCTAssertEqual(Status.notInstalled.primary, .install)
        XCTAssertEqual(Status.broken(.vpnMissing).primary, .repair)
        XCTAssertEqual(Status.broken(.serviceOff).primary, .openLoginItems)
        XCTAssertEqual(Status.needsSetup.primary, .addSubscription)
        XCTAssertEqual(Status.otherVPN(blocksDirect: true).primary, .replaceOtherVPN)
        XCTAssertTrue(Status.otherVPN(blocksDirect: true).primaryEnabled)
        XCTAssertEqual(Status.connecting().primary, .cancel)
        XCTAssertEqual(Status.stuck().primary, .chooseServer)
        XCTAssertEqual(Status.stuck().secondary, .disconnect)
        XCTAssertEqual(Status.protected.primary, .disconnect)
        XCTAssertNil(Status.protected.secondary)
        XCTAssertEqual(Status.blocked.primary, .connect)
        XCTAssertEqual(Status.unprotected(pausedUntil: nil).secondary, .enableProtection)
        XCTAssertEqual(Status.unprotected(pausedUntil: now).secondary, .resumeProtection)
        XCTAssertEqual(Status.Action.resumeProtection.title, "Возобновить защиту")
        XCTAssertEqual(Status.Action.install.title, "Начать настройку…")
    }
}
