import Foundation
import XCTest

final class OtherVPNTests: XCTestCase {
    /// `scutil --nc list` with Happ and Tailscale connected (the owner's Mac, 0.11), plus a
    /// disabled L2TP and a disconnected IKEv2 service.
    private let list = """
    Available network connection services in the current set (*=enabled):
    * (Connected)      AAAAAAAA-0000-4000-8000-000000000001 VPN (su.ffg.happ)  "Happ"                           [VPN:su.ffg.happ]
    * (Connected)      BBBBBBBB-0000-4000-8000-000000000002 VPN (io.tailscale.ipn.macos) "Tailscale"                      [VPN:io.tailscale.ipn.macos]
      (Disconnected)   0A6E1D52-0D7B-4E7C-9C55-0B8E8E5C1F01 PPP --> L2TP       "Work L2TP"                       [PPP/L2TP]
    * (Disconnected)   1B2C3D4E-0000-4000-8000-00000000AA01 VPN (com.apple.neplugin.IKEv2) "Office"             [VPN:com.apple.neplugin.IKEv2]
    """

    func testServicesAreRead() {
        let services = OtherVPN.services(list)
        XCTAssertEqual(services.count, 4)
        XCTAssertEqual(services[0], OtherVPN.Service(id: "AAAAAAAA-0000-4000-8000-000000000001", name: "Happ",
                                                     provider: "su.ffg.happ", connected: true))
        XCTAssertEqual(services[1].provider, "io.tailscale.ipn.macos")
        XCTAssertEqual(services[2], OtherVPN.Service(id: "0A6E1D52-0D7B-4E7C-9C55-0B8E8E5C1F01", name: "Work L2TP",
                                                     provider: nil, connected: false))
        XCTAssertFalse(services[3].connected)
    }

    func testNothingUsableIsEmpty() {
        XCTAssertEqual(OtherVPN.services(""), [])
        XCTAssertEqual(OtherVPN.services("Available network connection services in the current set (*=enabled):\n"), [])
        XCTAssertEqual(OtherVPN.services("scutil: command not found"), [])
    }

    func testConnectingCountsAsUp() {
        let line = #"* (Connecting)     AAAAAAAA-0000-4000-8000-000000000001 VPN (su.ffg.happ)  "Happ"   [VPN:su.ffg.happ]"#
        XCTAssertEqual(OtherVPN.services(line).first?.connected, true)
    }

    func testANameWithQuotesAndSpaces() {
        let line = #"* (Connected)      AAAAAAAA-0000-4000-8000-000000000001 VPN (com.example.vpn)  "My "best" VPN"   [VPN:com.example.vpn]"#
        XCTAssertEqual(OtherVPN.services(line).first?.name, #"My "best" VPN"#)
    }

    /// Tailscale is let through by the kill switch on purpose; Apple's built-in VPNs are the
    /// person's own (work) and do not take the 198.18 address.
    func testOnlyConnectedThirdPartyVPNsAreStopped() {
        XCTAssertEqual(OtherVPN.stoppable(OtherVPN.services(list)).map(\.name), ["Happ"])
        let tailscaleOnly = OtherVPN.services(list).filter { $0.name != "Happ" }
        XCTAssertEqual(OtherVPN.stoppable(tailscaleOnly), [])
    }

    func testTheNameComesFromTheService() {
        XCTAssertEqual(OtherVPN.name(services: OtherVPN.services(list), runningApps: []), "Happ")
    }

    /// dropweb and other Clash-style apps run their own TUN without a VPN configuration.
    func testTheNameFallsBackToAKnownRunningApp() {
        XCTAssertEqual(OtherVPN.name(services: [], runningApps: ["Finder", "dropweb", "Safari"]), "dropweb")
        XCTAssertEqual(OtherVPN.name(services: [], runningApps: ["V2RAYTUN"]), "V2RAYTUN")
        XCTAssertNil(OtherVPN.name(services: [], runningApps: ["Finder", "Safari"]))
    }

    func testAppBundleCandidates() {
        XCTAssertEqual(OtherVPN.appCandidates(provider: "su.ffg.happ"), ["su.ffg.happ"])
        XCTAssertEqual(OtherVPN.appCandidates(provider: "com.example.vpn.tunnel"), ["com.example.vpn.tunnel", "com.example.vpn"])
        XCTAssertEqual(OtherVPN.appCandidates(provider: "single"), [])
    }

    // MARK: what the main button does

    func testRemedy() {
        XCTAssertEqual(OtherVPN.remedy(stoppable: true, stopFailed: false, appKnown: true), .stop)
        XCTAssertEqual(OtherVPN.remedy(stoppable: true, stopFailed: true, appKnown: true), .openApp)
        XCTAssertEqual(OtherVPN.remedy(stoppable: false, stopFailed: false, appKnown: true), .openApp)
        XCTAssertEqual(OtherVPN.remedy(stoppable: false, stopFailed: false, appKnown: false), .none)
    }

    func testTexts() {
        XCTAssertEqual(OtherVPN.title(name: "Happ"), "Работает другой VPN (Happ)")
        XCTAssertEqual(OtherVPN.title(name: nil), "Работает другой VPN")
        XCTAssertEqual(OtherVPN.buttonTitle(.stop, name: "Happ"), "Отключить Happ и подключить KillSwitch")
        XCTAssertEqual(OtherVPN.buttonTitle(.stop, name: nil), "Отключить другой VPN и подключить KillSwitch")
        XCTAssertEqual(OtherVPN.buttonTitle(.openApp, name: "Happ"), "Открыть Happ")
        XCTAssertEqual(OtherVPN.buttonTitle(.none, name: nil), "Подключить")
        XCTAssertEqual(OtherVPN.stopFailed(name: "Happ"),
                       "Не получилось отключить Happ отсюда. Отключи его в самом Happ, потом нажми «Подключить».")
        XCTAssertEqual(OtherVPN.stopFailed(name: nil),
                       "Не получилось отключить другой VPN отсюда. Отключи его в его программе, потом нажми «Подключить».")
    }
}
