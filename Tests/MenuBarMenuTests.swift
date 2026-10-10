import XCTest

final class MenuBarMenuTests: XCTestCase {
    /// A click opens the popover; the right button or ⌃-click opens the compact menu (ADR 0011).
    func testWhichClickOpensWhat() {
        XCTAssertEqual(MenuBarMenu.click(rightButton: false, controlKey: false), .popover)
        XCTAssertEqual(MenuBarMenu.click(rightButton: true, controlKey: false), .menu)
        XCTAssertEqual(MenuBarMenu.click(rightButton: false, controlKey: true), .menu)
    }

    private func titles(_ entries: [MenuBarMenu.Entry?]) -> [String] {
        entries.map { $0?.title ?? "—" }
    }

    func testDisconnectedMenu() {
        let entries = MenuBarMenu.entries(status: .blocked, busy: false, coreConfigured: true, fastestAvailable: true)
        XCTAssertEqual(titles(entries), ["Подключить", "Самый быстрый", "—", "Открыть KillSwitch", "Проверка утечек", "—", "Выход"])
        XCTAssertTrue(entries.compactMap { $0 }.allSatisfy(\.enabled))
        XCTAssertEqual(entries.first??.item, .connect)
    }

    func testConnectedMenuDisconnects() {
        let entries = MenuBarMenu.entries(status: .protected, busy: false, coreConfigured: true, fastestAvailable: true)
        XCTAssertEqual(entries.first??.item, .disconnect)
        XCTAssertEqual(entries.first??.title, "Отключить")
        let connecting = MenuBarMenu.entries(status: .connecting, busy: false, coreConfigured: true, fastestAvailable: true)
        XCTAssertEqual(connecting.first??.item, .disconnect)
    }

    /// Like the main button: nothing to connect to, another VPN up, or the helper busy.
    func testConnectIsDisabledWhenTheMainButtonWouldBe() {
        func connect(_ status: Status, busy: Bool = false, configured: Bool = true) -> MenuBarMenu.Entry? {
            MenuBarMenu.entries(status: status, busy: busy, coreConfigured: configured, fastestAvailable: true).first ?? nil
        }
        XCTAssertEqual(connect(.blocked, configured: false)?.enabled, false)
        XCTAssertEqual(connect(.blocked, busy: true)?.enabled, false)
        XCTAssertEqual(connect(.otherVPN(blocksDirect: true))?.enabled, false)
        XCTAssertEqual(connect(.needsSetup)?.enabled, false)
        XCTAssertEqual(connect(.unprotected(pausedUntil: nil))?.enabled, true)
    }

    func testFastestNeedsAFastestEntry() {
        let entries = MenuBarMenu.entries(status: .protected, busy: false, coreConfigured: true, fastestAvailable: false)
        XCTAssertEqual(entries.compactMap { $0 }.first { $0.item == .fastest }?.enabled, false)
    }
}
