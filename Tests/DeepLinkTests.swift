import XCTest

/// `killswitch://` links (#23, ADR 0029): any web page or program can open one, so each is parsed
/// strictly, nothing reaches a command behind the right, and only connecting runs without asking.
final class DeepLinkTests: XCTestCase {
    private func parse(_ link: String) -> Result<DeepLink, DeepLink.Rejection> {
        DeepLink.parse(URL(string: link)!)
    }

    // MARK: sections

    func testSectionLinksOnlyShowASection() {
        XCTAssertEqual(parse("killswitch://home"), .success(.show(.section(.home))))
        XCTAssertEqual(parse("killswitch://servers"), .success(.show(.section(.servers))))
        XCTAssertEqual(parse("killswitch://traffic"), .success(.show(.section(.traffic))))
        XCTAssertEqual(parse("killswitch://leaks"), .success(.show(.section(.leakTest))))
        XCTAssertEqual(parse("killswitch://log"), .success(.show(.section(.log))))
        XCTAssertEqual(parse("killswitch://about/"), .success(.show(.section(.about))))
        XCTAssertEqual(parse("killswitch://settings/vpn"), .success(.show(.section(.settings(.vpn)))))
        XCTAssertEqual(parse("killswitch://settings"), .success(.show(.section(.settings(.general)))))
        XCTAssertEqual(parse("killswitch://setup"), .success(.show(.onboarding)))
        XCTAssertEqual(parse("killswitch://"), .success(.show(.window)))
        XCTAssertEqual(parse("KillSwitch://Home"), .success(.show(.section(.home))))
    }

    func testUnknownLinksDoNothing() {
        XCTAssertEqual(parse("https://example.com/home"), .failure(.notOurs))
        XCTAssertEqual(parse("killswitch://whatever"), .failure(.unknownCommand))
        XCTAssertEqual(parse("killswitch://settings/nope"), .failure(.badParameters))
        XCTAssertEqual(parse("killswitch://home?x=1"), .failure(.badParameters))
        XCTAssertEqual(parse("killswitch://home/extra"), .failure(.badParameters))
    }

    /// Protection is never turned off, paused or widened by a link: those words are not commands.
    func testNoLinkTurnsProtectionOff() {
        for link in ["killswitch://pause?minutes=5", "killswitch://off", "killswitch://protection/off",
                     "killswitch://protection?on=0", "killswitch://disable", "killswitch://allow?address=1.1.1.1",
                     "killswitch://server-add?url=vless://x", "killswitch://uninstall", "killswitch://set?key=lan"] {
            XCTAssertEqual(parse(link), .failure(.unknownCommand), link)
        }
        // and the VPN commands a link can reach never need an administrator
        for command in DeepLink.commands {
            XCTAssertEqual(command.daemonCommand?.needsAuthorization, false, "\(command)")
        }
        XCTAssertFalse(DeepLink.commands.contains(.protection(on: false)))
        XCTAssertFalse(DeepLink.commands.contains(.pause(minutes: 5)))
    }

    /// The app runs a command of a link only through `action`: exactly the link commands have one.
    func testActionsAreExactlyTheLinkCommands() {
        XCTAssertEqual(DeepLink.action(for: .connect), .connectAutomatically)
        XCTAssertEqual(DeepLink.action(for: .disconnect), .disconnect)
        for command: CLI.Command in [.help, .version, .status(json: false), .protection(on: true), .protection(on: false),
                                     .pause(minutes: 5), .serverList(json: false), .serverSelect("x")] {
            XCTAssertNil(DeepLink.action(for: command), "\(command)")
        }
        XCTAssertTrue(DeepLink.commands.allSatisfy { DeepLink.action(for: $0) != nil })
    }

    // MARK: VPN

    func testVPNCommands() {
        XCTAssertEqual(parse("killswitch://connect"), .success(.connect))
        XCTAssertEqual(parse("killswitch://disconnect"), .success(.disconnect))
        XCTAssertEqual(parse("killswitch://toggle"), .success(.toggle))
        XCTAssertEqual(parse("killswitch://connect?server=x"), .failure(.badParameters))
        XCTAssertEqual(parse("killswitch://toggle/1"), .failure(.badParameters))
    }

    private func plan(_ link: DeepLink, _ status: Status, busy: Bool = false, configured: Bool = true,
                      protectionOn: Bool = true) -> DeepLink.Plan {
        DeepLink.plan(link, status: status, busy: busy, coreConfigured: configured, protectionOn: protectionOn)
    }

    /// Connecting only adds the tunnel (protection stays as it is), so it runs at once, like the
    /// shortcut; it never brings up the password prompt (the app runs it as an automatic connect).
    func testConnectRunsWithoutAsking() {
        XCTAssertEqual(plan(.connect, .blocked), .run(.connect))
        XCTAssertEqual(plan(.connect, .unprotected(pausedUntil: nil), protectionOn: false), .run(.connect))
        XCTAssertEqual(plan(.connect, .protected), .done("VPN уже подключён"))
        XCTAssertEqual(plan(.connect, .needsSetup, configured: false), .refused("Не подключилось: Добавь подписку. Открой KillSwitch."))
        XCTAssertEqual(plan(.connect, .blocked, busy: true), .refused("KillSwitch занят. Попробуй через минуту."))
    }

    /// With protection on, disconnecting cuts the internet: the window asks first.
    func testDisconnectAsksWhileProtectionIsOn() {
        XCTAssertEqual(plan(.disconnect, .protected), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .connecting), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .stuck), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .blocked), .done("VPN и так не подключён"))
        XCTAssertEqual(plan(.disconnect, .protected, busy: true), .refused("KillSwitch занят. Попробуй через минуту."))
    }

    /// With protection off or paused, disconnecting would let the traffic out without the VPN —
    /// the same as turning protection off, which no link may do. Refused, even with a question.
    func testNoDisconnectWhileProtectionIsOffOrPaused() {
        let refusal = DeepLink.Plan.refused("Ссылка не отключает VPN, пока защита выключена или на паузе.")
        XCTAssertEqual(plan(.disconnect, .connectedUnprotected, protectionOn: false), refusal)
        XCTAssertEqual(plan(.disconnect, .connecting, protectionOn: false), refusal)
        XCTAssertEqual(plan(.disconnect, .stuck, protectionOn: false), refusal)
        XCTAssertEqual(plan(.toggle, .connectedUnprotected, protectionOn: false), refusal)
        // whatever the summary says, the protection state decides
        XCTAssertEqual(plan(.disconnect, .connectedUnprotected, protectionOn: true), .confirm(.disconnect))
    }

    func testToggleConnectsAtOnceButAsksToDisconnect() {
        XCTAssertEqual(plan(.toggle, .blocked), .run(.connect))
        XCTAssertEqual(plan(.toggle, .protected), .confirm(.disconnect))
        XCTAssertEqual(plan(.toggle, .stuck), .confirm(.disconnect))
        XCTAssertEqual(plan(.toggle, .otherVPN(blocksDirect: false)),
                       .refused("Не подключилось: Работает другой VPN. Открой KillSwitch."))
    }

    /// A disconnect confirmed later is checked again against the state then.
    func testConfirmedDisconnectIsCheckedAgain() {
        XCTAssertEqual(DeepLink.confirmed(.disconnect, status: .protected, busy: false, protectionOn: true), .run(.disconnect))
        XCTAssertEqual(DeepLink.confirmed(.disconnect, status: .blocked, busy: false, protectionOn: true), .done("VPN и так не подключён"))
        XCTAssertEqual(DeepLink.confirmed(.disconnect, status: .protected, busy: false, protectionOn: false),
                       .refused("Ссылка не отключает VPN, пока защита выключена или на паузе."))
    }

    // MARK: add

    func testAddAlwaysAsksAndShowsTheHost() throws {
        let link = parse("killswitch://add?url=https%3A%2F%2Fsub.Example.com%2Fapi%2Fsub%2FsecretToken123")
        let subscription = DeepLink.Subscription(url: "https://sub.Example.com/api/sub/secretToken123", host: "sub.example.com")
        XCTAssertEqual(link, .success(.add(subscription)))
        XCTAssertEqual(plan(.add(subscription), .protected), .confirm(.add(subscription)))
        XCTAssertEqual(plan(.add(subscription), .notInstalled), .confirm(.add(subscription)))
        XCTAssertEqual(plan(.add(subscription), .protected, busy: true), .confirm(.add(subscription)))
        // the secret part is never shown
        XCTAssertFalse(subscription.masked.contains("secretToken"))
        XCTAssertEqual(subscription.masked, "https://sub.example.com/•••••n123")
        // a lookalike name stays in its xn-- form
        XCTAssertEqual(DeepLink.Subscription(url: "https://xn--pple-43d.com/s/abcdefgh", host: "xn--pple-43d.com").masked,
                       "https://xn--pple-43d.com/•••••efgh")
        // unencoded, as many sites write it
        XCTAssertEqual(parse("killswitch://add?url=https://sub.example.com/s/abc"),
                       .success(.add(.init(url: "https://sub.example.com/s/abc", host: "sub.example.com"))))
    }

    /// The host shown is where the app will connect: with its port unless it is 443, and an
    /// address literal as it is.
    func testAddShowsThePortAndAddresses() {
        XCTAssertEqual(parse("killswitch://add?url=https://trusted.com:8443/s"),
                       .success(.add(.init(url: "https://trusted.com:8443/s", host: "trusted.com:8443"))))
        XCTAssertEqual(parse("killswitch://add?url=https://trusted.com:443/s"),
                       .success(.add(.init(url: "https://trusted.com:443/s", host: "trusted.com"))))
        XCTAssertEqual(parse("killswitch://add?url=https://203.0.113.7/s"),
                       .success(.add(.init(url: "https://203.0.113.7/s", host: "203.0.113.7"))))
        XCTAssertEqual(parse("killswitch://add?url=https://[2001:db8::1]:8443/s"),
                       .success(.add(.init(url: "https://[2001:db8::1]:8443/s", host: "[2001:db8::1]:8443"))))
        XCTAssertEqual(DeepLink.Subscription(url: "https://trusted.com:8443/s/abcdefgh", host: "trusted.com:8443").masked,
                       "https://trusted.com:8443/•••••efgh")
    }

    func testAddTakesOnlyAPlainHTTPSLink() {
        for link in [
            "killswitch://add",
            "killswitch://add?url=",
            "killswitch://add?url=http://sub.example.com/s",               // not https
            "killswitch://add?url=vless://uuid@host:443",                   // a server, not a subscription
            "killswitch://add?url=https://",                                // no host
            "killswitch://add?url=https://bank.com@evil.example/s",         // the host would mislead
            "killswitch://add?url=https://user:pass@sub.example.com/s",
            "killswitch://add?url=https://xn--80ak6aa92e.com/s%0Aevil",     // a line break
            "killswitch://add?url=https://sub.example.com/s&url=https://evil.example/s",
            "killswitch://add?url=https://sub.example.com/s&name=x",
            "killswitch://add/more?url=https://sub.example.com/s",
            "killswitch://add?url=https://sub.example.com/" + String(repeating: "a", count: 2100),
        ] {
            XCTAssertEqual(parse(link), .failure(.badParameters), link)
        }
        // a non-ASCII host (lookalike letters) is refused; its punycode form is fine
        XCTAssertEqual(DeepLink.parse(URL(string: "killswitch://add?url=https%3A%2F%2F%D0%B0pple.com%2Fs")!), .failure(.badParameters))
        XCTAssertEqual(parse("killswitch://add?url=https://xn--pple-43d.com/s"),
                       .success(.add(.init(url: "https://xn--pple-43d.com/s", host: "xn--pple-43d.com"))))
    }

    /// A DNS name (labels of letters, digits and hyphens, a TLD of letters) or an address literal;
    /// nothing a resolver could read as a number, nothing too long to show.
    func testAddTakesOnlyARealHostName() {
        let long = String(repeating: "a", count: 60)
        for host in [".", "...", "-", "a..b", "localhost", "0x7f.1", "2130706433", "0x7f000001", "127.1", "1.2.3",
                     "01.2.3.4", "1.2.3.256", "-a.com", "a-.com", "a_b.com", "example.123", "example.0x1",
                     String(repeating: "a", count: 64) + ".com",
                     [long, long, long, long, long].joined(separator: ".") + ".com",   // 300 characters
                     "[2001:db8::zz]", "[1.2.3.4]"] {
            XCTAssertEqual(parse("killswitch://add?url=https://\(host)/s"), .failure(.badParameters), host)
        }
        for host in ["a.co", "sub-1.example.com", "xn--80ak6aa92e.xn--p1ai", "[::1]", "10.0.0.1"] {
            XCTAssertNotNil(try? parse("killswitch://add?url=https://\(host)/s").get(), host)
        }
    }

    /// Logs name the command, never the link: a subscription link is a key.
    func testLogTextHasNoLink() {
        let subscription = DeepLink.Subscription(url: "https://sub.example.com/s/secretToken123", host: "sub.example.com")
        XCTAssertEqual(DeepLink.add(subscription).logName, "add (sub.example.com)")
        XCTAssertEqual(DeepLink.toggle.logName, "toggle")
        XCTAssertEqual(DeepLink.show(.section(.settings(.vpn))).logName, "show settings.vpn")
    }

    // MARK: pacing

    /// A page that opens links in a loop gets one through every 2 seconds. Times are seconds of
    /// system uptime, which a clock change does not move.
    func testOneLinkEveryTwoSeconds() {
        var throttle = DeepLink.Throttle()
        let start: TimeInterval = 1_000
        XCTAssertTrue(throttle.allows(at: start))
        XCTAssertFalse(throttle.allows(at: start + 1))
        XCTAssertFalse(throttle.allows(at: start + 1.9))
        XCTAssertTrue(throttle.allows(at: start + 2.1))
        XCTAssertFalse(throttle.allows(at: start + 3))   // counted from the last one let through
        XCTAssertTrue(throttle.allows(at: start + 4.2))
    }

    /// Opening a section changes nothing: only acting links are paced.
    func testOnlyActingLinksArePaced() {
        XCTAssertFalse(DeepLink.show(.section(.home)).isPaced)
        XCTAssertFalse(DeepLink.show(.window).isPaced)
        XCTAssertTrue(DeepLink.connect.isPaced)
        XCTAssertTrue(DeepLink.toggle.isPaced)
        XCTAssertTrue(DeepLink.add(.init(url: "https://a.co/s", host: "a.co")).isPaced)
    }

    /// A question nobody saw does not pop up later out of context, and none waits forever.
    func testAWaitingQuestionIsDropped() {
        let start: TimeInterval = 1_000
        var request = DeepLink.Request(.disconnect, at: start)
        XCTAssertFalse(request.isStale(now: start + 60, resignedActive: false, busy: false))
        XCTAssertTrue(request.isStale(now: start + 121, resignedActive: false, busy: false))
        XCTAssertTrue(request.isStale(now: start + 5, resignedActive: true, busy: false))
        request.shown = true
        XCTAssertFalse(request.isStale(now: start + 5, resignedActive: true, busy: false))
        XCTAssertTrue(request.isStale(now: start + 121, resignedActive: false, busy: false))
        // never while a subscription it confirmed is being fetched
        XCTAssertFalse(request.isStale(now: start + 500, resignedActive: true, busy: true))
        XCTAssertNotEqual(DeepLink.Request(.disconnect, at: start).id, DeepLink.Request(.disconnect, at: start).id)
    }

    /// «Добавить» / «Заменить» was read when the link came; if the kept subscription changed since,
    /// the sheet shows the new state and wants a second click.
    func testAnAddWhoseSubjectChangedWantsASecondLook() {
        let subscription = DeepLink.Subscription(url: "https://a.co/s", host: "a.co")
        let first = DeepLink.Request(.add(subscription), at: 0, replacing: nil)
        XCTAssertFalse(first.needsSecondLook(current: nil))
        XCTAssertTrue(first.needsSecondLook(current: "https://old.co/•••••"))
        let replace = DeepLink.Request(.add(subscription), at: 0, replacing: "https://old.co/•••••")
        XCTAssertFalse(replace.needsSecondLook(current: "https://old.co/•••••"))
        XCTAssertTrue(replace.needsSecondLook(current: nil))
        XCTAssertTrue(replace.needsSecondLook(current: "https://other.co/•••••"))
        XCTAssertFalse(DeepLink.Request(.disconnect, at: 0).needsSecondLook(current: "https://old.co/•••••"))
    }

    func testAddRefusesImpossiblePorts() {
        for port in ["0", "65536", "99999"] {
            XCTAssertEqual(parse("killswitch://add?url=https://a.co:\(port)/s"), .failure(.badParameters), port)
        }
        XCTAssertEqual(parse("killswitch://add?url=https://a.co:65535/s"),
                       .success(.add(.init(url: "https://a.co:65535/s", host: "a.co:65535"))))
    }
}
