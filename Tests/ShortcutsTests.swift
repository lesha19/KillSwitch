import XCTest

/// «Быстрые команды» (Shortcuts, Spotlight, Siri): what each command does in each state, and what
/// it says back.
final class ShortcutsTests: XCTestCase {
    func testConnectRunsLikeTheMainButton() {
        XCTAssertEqual(Shortcuts.connect(status: .blocked, busy: false, coreConfigured: true), .run)
        XCTAssertEqual(Shortcuts.connect(status: .unprotected(pausedUntil: nil), busy: false, coreConfigured: true), .run)
    }

    func testConnectWhenAlreadyConnected() {
        XCTAssertEqual(Shortcuts.connect(status: .protected, busy: false, coreConfigured: true), .done("VPN уже подключён"))
        XCTAssertEqual(Shortcuts.connect(status: .reconnecting, busy: false, coreConfigured: true), .done("VPN уже подключается"))
        XCTAssertEqual(Shortcuts.connect(status: .connecting(), busy: false, coreConfigured: true), .done("VPN уже подключается"))
        XCTAssertEqual(Shortcuts.connect(status: .connecting(closed: true), busy: false, coreConfigured: true), .done("VPN уже подключается"))
    }

    /// A Connect that did not come up (the core did not start, the server does not answer) is not
    /// «уже подключается»: the window has the way out.
    func testConnectWhenStuck() {
        XCTAssertEqual(Shortcuts.connect(status: .stuck(closed: true), busy: false, coreConfigured: true),
                       .refused("Не подключилось: Подключение затянулось. Открой KillSwitch."))
    }

    /// Nothing that needs the window (install, repair, a subscription, another VPN) is done from a
    /// command: it says what is wrong instead.
    func testConnectRefusesWhatNeedsTheWindow() {
        XCTAssertEqual(Shortcuts.connect(status: .needsSetup, busy: false, coreConfigured: false),
                       .refused("Не подключилось: Добавь подписку. Открой KillSwitch."))
        XCTAssertEqual(Shortcuts.connect(status: .otherVPN(blocksDirect: false), busy: false, coreConfigured: true),
                       .refused("Не подключилось: Работает другой VPN. Открой KillSwitch."))
        XCTAssertEqual(Shortcuts.connect(status: .blocked, busy: false, coreConfigured: false),
                       .refused("Не подключилось: нет подписки. Открой KillSwitch."))
        XCTAssertEqual(Shortcuts.connect(status: .blocked, busy: true, coreConfigured: true),
                       .refused("KillSwitch занят. Попробуй через минуту."))
    }

    func testDisconnect() {
        XCTAssertEqual(Shortcuts.disconnect(status: .protected, busy: false), .run)
        XCTAssertEqual(Shortcuts.disconnect(status: .connecting(), busy: false), .run)
        // stuck on a server that does not answer: the core still runs and must be stopped
        XCTAssertEqual(Shortcuts.disconnect(status: .stuck(), busy: false), .run)
        XCTAssertEqual(Shortcuts.disconnect(status: .stuck(closed: true), busy: false), .run)
        XCTAssertEqual(Shortcuts.disconnect(status: .otherVPN(blocksDirect: true, vpnOn: true), busy: false), .run)
        XCTAssertEqual(Shortcuts.disconnect(status: .blocked, busy: false), .done("VPN и так не подключён"))
        XCTAssertEqual(Shortcuts.disconnect(status: .protected, busy: true), .refused("KillSwitch занят. Попробуй через минуту."))
    }

    /// Spoken by Siri too: the server without its emoji.
    func testStatusText() {
        XCTAssertEqual(Shortcuts.statusText(status: .protected, server: "🇱🇹 LT-Vilnius"), "Защищено, сервер LT-Vilnius")
        XCTAssertEqual(Shortcuts.statusText(status: .protected, server: nil), "Защищено")
        XCTAssertEqual(Shortcuts.statusText(status: .blocked, server: "🇱🇹 LT-Vilnius"), "Интернет заблокирован")
    }

    func testChosen() {
        XCTAssertEqual(Shortcuts.chosen("🇩🇪 Germany", connected: true), "Сервер: Germany")
        XCTAssertEqual(Shortcuts.chosen("🇩🇪 Germany", connected: false),
                       "Выбран сервер Germany. Он включится при следующем подключении.")
    }

    private func proxies() throws -> CoreProxies {
        let json = """
        {"proxies": {
          "🚀 Выбор": {"type": "Selector", "now": "🇩🇪 Germany", "all": ["⚡ Авто", "🇩🇪 Germany", "🇱🇹 LT-Vilnius"]},
          "⚡ Авто": {"type": "URLTest", "now": "🇩🇪 Germany", "all": ["🇩🇪 Germany", "🇱🇹 LT-Vilnius"]},
          "🇩🇪 Germany": {"type": "Vless"}, "🇱🇹 LT-Vilnius": {"type": "Vless"}
        }}
        """
        return try CoreProxies(data: Data(json.utf8), order: ["🚀 Выбор", "⚡ Авто"])
    }

    /// The parameter of «Сменить страну»: the list of «Серверы», found by name or by country in
    /// Russian; an unknown name finds nothing.
    func testServersOfTheList() throws {
        let all = Shortcuts.servers(try proxies())
        XCTAssertEqual(all.map(\.title), ["Самый быстрый", ServerName.display("🇩🇪 Germany"), ServerName.display("🇱🇹 LT-Vilnius")])
        XCTAssertEqual(Shortcuts.servers(try proxies(), matching: "литва").map(\.name), ["🇱🇹 LT-Vilnius"])
        XCTAssertEqual(Shortcuts.servers(try proxies(), named: ["🇩🇪 Germany", "🇺🇸 USA"]).map(\.name), ["🇩🇪 Germany"])
    }
}
