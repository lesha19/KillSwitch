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

    /// The id becomes an argument of `scutil --nc stop`: only a real UUID, never something that
    /// starts with "-" and would be read as an option.
    func testOnlyAUUIDIsAnId() {
        for id in ["------------------------------------", "--nc-stop-0000-4000-8000-0000000000AA", "AAAAAAAA000040008000000000000001----"] {
            let line = "* (Connected)      \(id) VPN (su.ffg.happ)  \"Happ\"   [VPN:su.ffg.happ]"
            XCTAssertEqual(OtherVPN.services(line), [], id)
        }
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

    // MARK: tunnels by the routing table (beyond 198.18)

    /// `netstat -rn` of a Mac with Tailscale (utun11, exit node on), our core (utun19) and the
    /// system's idle utuns, as on the owner's Mac.
    private let baseRoutes = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            192.168.89.254     UGScg                 en0
    default            link#29            UCSIg              utun11
    1                  198.18.128.0       UGSc               utun19
    2/7                198.18.128.0       UGSc               utun19
    128.0/1            198.18.128.0       UGSc               utun19
    100.64/10          link#29            UCS                utun11
    10/8               link#40            UCS                utun24
    192.168.5/24       link#41            UCS                utun25

    Internet6:
    Destination        Gateway            Flags               Netif Expire
    default            fe80::%utun1       UGcIg               utun1
    default            fd7a:115c:a1e0::   UGcg               utun11
    fd00::/8           fe80::%utun30      UGSc               utun30
    ff00::/8           ::1                UmCI               utun30
    """

    private let addresses: [OtherVPN.Address] = [
        .init(interface: "utun11", address: "100.64.111.130"),
        .init(interface: "utun11", address: "fd7a:115c:a1e0::8d3a:7604"),
        .init(interface: "utun19", address: "198.18.128.1"),
        .init(interface: "utun30", address: "10.66.0.2"),
        .init(interface: "en0", address: "192.168.89.10"),
    ]

    func testOursTailscaleAndNarrowRoutesAreNoOtherVPN() {
        XCTAssertEqual(OtherVPN.tunnels(routes: baseRoutes, addresses: addresses), [])
        XCTAssertEqual(OtherVPN.tunnels(routes: "", addresses: []), [])
    }

    func testTunnelsBeyond198AreFound() {
        let wireGuard = baseRoutes.replacingOccurrences(of: "\nInternet6:", with: """
        0/1                10.66.0.1          UGSc               utun30
        128.0/1            10.66.0.1          UGSc               utun30

        Internet6:
        """)
        XCTAssertEqual(OtherVPN.tunnels(routes: wireGuard, addresses: addresses), ["utun30"])
        let ikev2 = baseRoutes.replacingOccurrences(of: "\nInternet6:", with: """
        default            link#50            UCSg               ipsec0
        0/1                link#51            UGSc               ppp0

        Internet6:
        """)
        XCTAssertEqual(OtherVPN.tunnels(routes: ikev2, addresses: addresses), ["ipsec0", "ppp0"])
        let happ = baseRoutes.replacingOccurrences(of: "\nInternet6:", with: """
        default            link#58            UCSg               utun23
        default            198.18.0.1         UGS1cIg            utun23

        Internet6:
        """)
        XCTAssertEqual(OtherVPN.tunnels(routes: happ, addresses: addresses), ["utun23"])
    }

    func testIPv6SplitRoutesCount() {
        let routes = baseRoutes + "\n::/1               fe80::%utun30      UGSc               utun30\n"
        XCTAssertEqual(OtherVPN.tunnels(routes: routes, addresses: addresses), ["utun30"])
    }

    /// Tailscale's exit node takes the default route, but the kill switch lets Tailscale through
    /// on purpose: not «another VPN».
    func testTailscaleExitNodeIsNotOtherVPN() {
        let routes = baseRoutes.replacingOccurrences(of: "UCSIg              utun11", with: "UCSg               utun11")
        XCTAssertEqual(OtherVPN.tunnels(routes: routes, addresses: addresses), [])
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
