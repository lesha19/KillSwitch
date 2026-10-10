import Foundation
import XCTest

final class AutoConnectTests: XCTestCase {
    private let on = AutoConnect.Settings(enabled: true, skipTrusted: true, trusted: ["Дом", "Office 5G"])
    private let home = AutoConnect.Network(online: true, wifi: true, ssid: "Дом", interfaces: ["en0"])
    private let cafe = AutoConnect.Network(online: true, wifi: true, ssid: "Cafe Free", interfaces: ["en0"])
    private let ready = AutoConnect.Core(ready: true, connected: false, otherVPN: false)

    func testUntrustedConnects() {
        XCTAssertEqual(AutoConnect.decide(on, network: cafe, core: ready), .connect)
    }

    func testTrustedSkips() {
        XCTAssertEqual(AutoConnect.decide(on, network: home, core: ready), .skip(.trusted("Дом")))
    }

    func testTrustedIgnoredWhenOptionOff() {
        var settings = on
        settings.skipTrusted = false
        XCTAssertEqual(AutoConnect.decide(settings, network: home, core: ready), .connect)
    }

    func testUnknownSSIDIsUntrusted() {
        // no Location permission: the name is hidden, so the network counts as untrusted
        let hidden = AutoConnect.Network(online: true, wifi: true, ssid: nil, interfaces: ["en0"])
        XCTAssertEqual(AutoConnect.decide(on, network: hidden, core: ready), .connect)
    }

    func testWiredConnects() {
        let wired = AutoConnect.Network(online: true, wifi: false, ssid: nil, interfaces: ["en5"])
        XCTAssertEqual(AutoConnect.decide(on, network: wired, core: ready), .connect)
    }

    func testSkips() {
        var off = on
        off.enabled = false
        XCTAssertEqual(AutoConnect.decide(off, network: cafe, core: ready), .skip(.disabled))
        let offline = AutoConnect.Network(online: false, wifi: false, ssid: nil, interfaces: [])
        XCTAssertEqual(AutoConnect.decide(on, network: offline, core: ready), .skip(.offline))
        XCTAssertEqual(AutoConnect.decide(on, network: cafe, core: .init(ready: true, connected: true, otherVPN: false)), .skip(.connected))
        XCTAssertEqual(AutoConnect.decide(on, network: cafe, core: .init(ready: false, connected: false, otherVPN: false)), .skip(.notReady))
        XCTAssertEqual(AutoConnect.decide(on, network: cafe, core: .init(ready: true, connected: false, otherVPN: true)), .skip(.otherVPN))
    }

    func testIdentity() {
        XCTAssertEqual(home.identity, "wifi:Дом")
        XCTAssertNotEqual(home.identity, cafe.identity)
        let wired = AutoConnect.Network(online: true, wifi: false, ssid: nil, interfaces: ["en5", "en0"])
        XCTAssertEqual(wired.identity, "if:en0,en5")
        XCTAssertNil(AutoConnect.Network(online: false, wifi: false, ssid: nil, interfaces: []).identity)
    }

    func testTrustedListNormalised() {
        XCTAssertEqual(AutoConnect.normalized([" Дом ", "", "Дом", "Office"]), ["Дом", "Office"])
    }
}
