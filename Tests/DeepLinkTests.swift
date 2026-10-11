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

    // MARK: VPN

    func testVPNCommands() {
        XCTAssertEqual(parse("killswitch://connect"), .success(.connect))
        XCTAssertEqual(parse("killswitch://disconnect"), .success(.disconnect))
        XCTAssertEqual(parse("killswitch://toggle"), .success(.toggle))
        XCTAssertEqual(parse("killswitch://connect?server=x"), .failure(.badParameters))
        XCTAssertEqual(parse("killswitch://toggle/1"), .failure(.badParameters))
    }

    private func plan(_ link: DeepLink, _ status: Status, busy: Bool = false, configured: Bool = true) -> DeepLink.Plan {
        DeepLink.plan(link, status: status, busy: busy, coreConfigured: configured)
    }

    /// Connecting only adds the tunnel (protection stays as it is), so it runs at once, like the
    /// shortcut; it never brings up the password prompt (the app runs it as an automatic connect).
    func testConnectRunsWithoutAsking() {
        XCTAssertEqual(plan(.connect, .blocked), .run(.connect))
        XCTAssertEqual(plan(.connect, .unprotected(pausedUntil: nil)), .run(.connect))
        XCTAssertEqual(plan(.connect, .protected), .done("VPN уже подключён"))
        XCTAssertEqual(plan(.connect, .needsSetup, configured: false), .refused("Не подключилось: Добавь подписку. Открой KillSwitch."))
        XCTAssertEqual(plan(.connect, .blocked, busy: true), .refused("KillSwitch занят. Попробуй через минуту."))
    }

    /// Disconnecting cuts the internet (protection on) or lets it out without the VPN (protection
    /// off or paused): the window asks first.
    func testDisconnectAsks() {
        XCTAssertEqual(plan(.disconnect, .protected), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .connecting), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .connectedUnprotected), .confirm(.disconnect))
        XCTAssertEqual(plan(.disconnect, .blocked), .done("VPN и так не подключён"))
        XCTAssertEqual(plan(.disconnect, .protected, busy: true), .refused("KillSwitch занят. Попробуй через минуту."))
    }

    func testToggleConnectsAtOnceButAsksToDisconnect() {
        XCTAssertEqual(plan(.toggle, .blocked), .run(.connect))
        XCTAssertEqual(plan(.toggle, .protected), .confirm(.disconnect))
        XCTAssertEqual(plan(.toggle, .stuck), .confirm(.disconnect))
        XCTAssertEqual(plan(.toggle, .otherVPN(blocksDirect: false), configured: true),
                       .refused("Не подключилось: Работает другой VPN. Открой KillSwitch."))
    }

    /// A disconnect confirmed later is checked again against the state then.
    func testConfirmedDisconnectIsCheckedAgain() {
        XCTAssertEqual(DeepLink.confirmed(.disconnect, status: .protected, busy: false), .run(.disconnect))
        XCTAssertEqual(DeepLink.confirmed(.disconnect, status: .blocked, busy: false), .done("VPN и так не подключён"))
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
        XCTAssertEqual(parse("killswitch://add?url=https://sub.example.com:8443/s/abc"),
                       .success(.add(.init(url: "https://sub.example.com:8443/s/abc", host: "sub.example.com"))))
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

    /// The question before a link's disconnect says what happens to the traffic.
    func testDisconnectWarning() {
        XCTAssertEqual(DeepLink.disconnectWarning(status: .protected),
                       "Защита останется включённой: интернет будет закрыт, пока VPN не подключится снова.")
        XCTAssertEqual(DeepLink.disconnectWarning(status: .connectedUnprotected),
                       "Защита выключена: после отключения трафик пойдёт мимо VPN.")
        XCTAssertEqual(DeepLink.disconnectWarning(status: .connecting),
                       "Если защита включена, интернет будет закрыт; если выключена, трафик пойдёт мимо VPN.")
    }

    /// Logs name the command, never the link: a subscription link is a key.
    func testLogTextHasNoLink() {
        let subscription = DeepLink.Subscription(url: "https://sub.example.com/s/secretToken123", host: "sub.example.com")
        XCTAssertEqual(DeepLink.add(subscription).logName, "add (sub.example.com)")
        XCTAssertEqual(DeepLink.toggle.logName, "toggle")
        XCTAssertEqual(DeepLink.show(.section(.settings(.vpn))).logName, "show settings.vpn")
    }
}
