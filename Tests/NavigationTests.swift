import XCTest
@testable import KillSwitch

/// One window (ADR 0008): every button, shortcut, notification and link lands in a section of it.
final class NavigationTests: XCTestCase {
    func testSidebarOrder() {
        XCTAssertEqual(AppSection.sidebar, [.home, .servers, .leakTest, .log])
        XCTAssertEqual(AppSection.settingsPanes, [.settings(.general), .settings(.vpn), .settings(.protection), .settings(.advanced)])
        XCTAssertEqual(AppSection.home.title, "Главная")
        XCTAssertEqual(AppSection.servers.title, "Серверы")
        XCTAssertEqual(AppSection.leakTest.title, "Проверка утечек")
        XCTAssertEqual(AppSection.log.title, "Журнал защиты")
        XCTAssertEqual(AppSection.about.title, "О программе")
        XCTAssertEqual(AppSection.settings(.advanced).title, "Дополнительно")
    }

    func testSectionIDRoundTrips() {
        for section in AppSection.sidebar + AppSection.settingsPanes + [.about] {
            XCTAssertEqual(AppSection(id: section.id), section, section.id)
        }
        XCTAssertEqual(AppSection.settings(.vpn).id, "settings.vpn")
        XCTAssertNil(AppSection(id: "settings.nope"))
        XCTAssertNil(AppSection(id: ""))
    }

    func testShortcutsOpenTheirSection() {
        XCTAssertEqual(Navigation.route(.openWindow), .window)
        XCTAssertEqual(Navigation.route(.servers), .section(.servers))
        XCTAssertEqual(Navigation.route(.leakTest), .section(.leakTest))
        XCTAssertEqual(Navigation.route(.help), .section(.about))
    }

    func testSettingsReopenTheLastPane() {
        XCTAssertEqual(Navigation.route(.settings, lastSettingsPane: nil), .section(.settings(.general)))
        XCTAssertEqual(Navigation.route(.settings, lastSettingsPane: "protection"), .section(.settings(.protection)))
        // the 0.10 «Помощь» tab is gone: its parts live in «Журнал защиты» and «О программе»
        XCTAssertEqual(Navigation.route(.settings, lastSettingsPane: "help"), .section(.settings(.general)))
    }

    func testNotificationButtons() {
        XCTAssertEqual(Navigation.route(notification: .check, hasAccountURL: false), .section(.leakTest))
        XCTAssertEqual(Navigation.route(notification: .openApp, hasAccountURL: false), .section(.home))
        XCTAssertEqual(Navigation.route(notification: nil, hasAccountURL: false), .section(.home))
        XCTAssertEqual(Navigation.route(notification: .renew, hasAccountURL: false), .section(.home))
        // handled without the window: the browser, System Settings, the password prompt
        XCTAssertNil(Navigation.route(notification: .renew, hasAccountURL: true))
        XCTAssertNil(Navigation.route(notification: .connect, hasAccountURL: false))
        XCTAssertNil(Navigation.route(notification: .approve, hasAccountURL: false))
        XCTAssertNil(Navigation.route(notification: .openLoginItems, hasAccountURL: false))
    }

    func testErrorAndStatusButtons() {
        XCTAssertEqual(Navigation.route(error: .editSubscription), .section(.settings(.vpn)))
        XCTAssertNil(Navigation.route(error: .retry))
        XCTAssertNil(Navigation.route(error: .chooseServer))   // the server list of the view showing the error
        XCTAssertEqual(Navigation.route(status: .install), .onboarding)
        XCTAssertEqual(Navigation.route(status: .addSubscription), .onboarding)
        XCTAssertNil(Navigation.route(status: .connect))
        XCTAssertNil(Navigation.route(status: .chooseServer))
    }

    func testLinks() {
        func route(_ link: String) -> Route? { Navigation.route(url: URL(string: link)!) }
        XCTAssertEqual(route("killswitch://home"), .section(.home))
        XCTAssertEqual(route("killswitch://servers"), .section(.servers))
        XCTAssertEqual(route("killswitch://leaks"), .section(.leakTest))
        XCTAssertEqual(route("killswitch://log"), .section(.log))
        XCTAssertEqual(route("killswitch://about"), .section(.about))
        XCTAssertEqual(route("killswitch://settings/vpn"), .section(.settings(.vpn)))
        XCTAssertEqual(route("killswitch://settings"), .section(.settings(.general)))
        XCTAssertEqual(route("killswitch://settings/nope"), .section(.settings(.general)))
        XCTAssertEqual(route("killswitch://setup"), .onboarding)
        XCTAssertEqual(route("killswitch://"), .window)
        XCTAssertEqual(route("killswitch://whatever"), .window)
        XCTAssertNil(route("https://example.com/settings"))
    }
}
