import Foundation
import XCTest

final class LeakCheckTests: XCTestCase {
    // MARK: parsing

    func testPlainIP() {
        XCTAssertEqual(LeakCheck.plainIP(" 203.0.113.7\n"), "203.0.113.7")
        XCTAssertEqual(LeakCheck.plainIP("2001:db8::1"), "2001:db8::1")
        XCTAssertNil(LeakCheck.plainIP("<html>blocked</html>"))
        XCTAssertNil(LeakCheck.plainIP("999.1.1.1"))
        XCTAssertNil(LeakCheck.plainIP(""))
    }

    func testMullvad() {
        let json = #"{"ip":"1.2.3.46","country":"Lithuania","city":"Šiauliai","mullvad_exit_ip":false,"organization":"UAB Cherry Servers"}"#
        let address = LeakCheck.mullvad(Data(json.utf8))
        XCTAssertEqual(address, LeakCheck.Address(ip: "1.2.3.46", country: "Lithuania", org: "UAB Cherry Servers"))
        XCTAssertNil(LeakCheck.mullvad(Data("nope".utf8)))
        XCTAssertNil(LeakCheck.mullvad(Data(#"{"ip":"x"}"#.utf8)))
    }

    func testDNSID() {
        XCTAssertEqual(LeakCheck.dnsID("3lbe3w2ad02tkb67\n"), "3lbe3w2ad02tkb67")
        XCTAssertNil(LeakCheck.dnsID("a.b"))                 // would change the probed domain
        XCTAssertNil(LeakCheck.dnsID("<html>"))
        XCTAssertNil(LeakCheck.dnsID("ab"))
    }

    func testProbeNames() {
        XCTAssertEqual(LeakCheck.probeNames(id: "abc12345", count: 3), ["1.abc12345.bash.ws", "2.abc12345.bash.ws", "3.abc12345.bash.ws"])
    }

    func testBashWs() throws {
        let json = """
        [{"ip":"1.2.3.46","country":"lt","country_name":"Lithuania","asn":"AS16125 UAB Cherry Servers","org":"UAB Cherry Servers","type":"ip"},
         {"ip":"5.6.7.97","country":"de","country_name":"Germany","asn":"AS60068 DataCamp Limited","org":"DataCamp Limited","type":"dns"},
         {"ip":"2001:db8:6ea0:2::2c","country":"de","country_name":"Germany","asn":"AS60068 DataCamp Limited","org":"DataCamp Limited","type":"dns"},
         {"ip":"5.6.7.97","country":"de","country_name":"Germany","asn":"AS60068 DataCamp Limited","org":"DataCamp Limited","type":"dns"},
         {"ip":"DNS may be leaking.","country":"","country_name":"","asn":"","org":"","type":"conclusion"}]
        """
        let report = try LeakCheck.bashWs(Data(json.utf8))
        XCTAssertEqual(report.exit, LeakCheck.Address(ip: "1.2.3.46", country: "Lithuania", org: "UAB Cherry Servers"))
        XCTAssertEqual(report.resolvers.map(\.ip), ["5.6.7.97", "2001:db8:6ea0:2::2c"])   // duplicates dropped
        XCTAssertEqual(report.resolvers.first?.country, "Germany")
        XCTAssertEqual(report.resolvers.first?.org, "DataCamp Limited")
        XCTAssertThrowsError(try LeakCheck.bashWs(Data("{}".utf8)))
    }

    func testBashWsSkipsGarbageIPs() throws {
        let report = try LeakCheck.bashWs(Data(#"[{"ip":"<b>x</b>","type":"dns"},{"ip":"1.1.1.1","type":"dns"}]"#.utf8))
        XCTAssertEqual(report.resolvers.map(\.ip), ["1.1.1.1"])
        XCTAssertNil(report.exit)
    }

    // MARK: verdict

    private let home = LeakCheck.Direct(ipv4: "95.24.1.2", ipv6: "2001:db8:1370:1::5", org: "PJSC Rostelecom")
    private let exit = LeakCheck.Address(ip: "1.2.3.46", country: "Lithuania", org: "UAB Cherry Servers")
    private let vpnDNS = LeakCheck.Resolver(ip: "5.6.7.97", country: "Germany", org: "DataCamp Limited")

    private func input(ipv4: [String?]? = nil, ipv6: LeakCheck.Address? = nil, resolvers: [LeakCheck.Resolver]? = nil,
                       direct: LeakCheck.Direct? = nil, connected: Bool = true) -> LeakCheck.Input {
        LeakCheck.Input(vpnConnected: connected, ipv4: ipv4 ?? [exit.ip, exit.ip], exit: exit, ipv6: ipv6,
                        resolvers: resolvers ?? [vpnDNS], direct: direct ?? home)
    }

    func testClean() {
        let verdict = LeakCheck.verdict(input())
        XCTAssertEqual(verdict.findings, [])
        XCTAssertTrue(verdict.clean)
        XCTAssertEqual(verdict.title, "Утечек нет")
    }

    func testRealIPv4() {
        let verdict = LeakCheck.verdict(input(ipv4: [home.ipv4, home.ipv4]))
        XCTAssertEqual(verdict.findings, [.realIPv4])
        XCTAssertFalse(verdict.clean)
    }

    func testEndpointsDisagree() {
        XCTAssertEqual(LeakCheck.verdict(input(ipv4: [exit.ip, "203.0.113.9"])).findings, [.ipv4Mismatch(["1.2.3.46", "203.0.113.9"])])
        // one endpoint not answering is not a leak
        XCTAssertEqual(LeakCheck.verdict(input(ipv4: [exit.ip, nil])).findings, [])
    }

    func testISPResolver() {
        let isp = LeakCheck.Resolver(ip: "213.234.192.8", country: "Russia", org: "PJSC Rostelecom")
        XCTAssertEqual(LeakCheck.verdict(input(resolvers: [vpnDNS, isp])).findings, [.dnsLeak(["213.234.192.8"])])
    }

    func testResolverIsHomeAddress() {
        let router = LeakCheck.Resolver(ip: "95.24.1.2", country: nil, org: nil)
        XCTAssertEqual(LeakCheck.verdict(input(resolvers: [router])).findings, [.dnsLeak(["95.24.1.2"])])
    }

    func testIPv6() {
        // the home network's /64: a leak
        let homeV6 = LeakCheck.Address(ip: "2001:db8:1370:1::77", country: "Russia", org: nil)
        XCTAssertEqual(LeakCheck.verdict(input(ipv6: homeV6)).findings, [.ipv6Leak("2001:db8:1370:1::77")])
        // same provider as the VPN exit: through the tunnel
        let vpnV6 = LeakCheck.Address(ip: "2a02:6ea0::1", country: "Lithuania", org: "UAB Cherry Servers")
        XCTAssertEqual(LeakCheck.verdict(input(ipv6: vpnV6)).findings, [])
        // unknown: the core has IPv6 off, so it should not be there at all
        let other = LeakCheck.Address(ip: "2001:db8::9", country: nil, org: nil)
        XCTAssertEqual(LeakCheck.verdict(input(ipv6: other)).findings, [.ipv6Unexpected("2001:db8::9")])
    }

    func testWithoutHomeReference() {
        let isp = LeakCheck.Resolver(ip: "213.234.192.8", country: "Russia", org: "PJSC Rostelecom")
        let input = LeakCheck.Input(vpnConnected: true, ipv4: [exit.ip, exit.ip], exit: exit, ipv6: nil, resolvers: [isp], direct: nil)
        let verdict = LeakCheck.verdict(input)
        XCTAssertEqual(verdict.findings, [])
        XCTAssertTrue(verdict.clean)
        XCTAssertTrue(verdict.needsHomeReference)
    }

    func testNoDNSAnswer() {
        XCTAssertEqual(LeakCheck.verdict(input(resolvers: [])).findings, [.dnsUnknown])
        XCTAssertTrue(LeakCheck.verdict(input(resolvers: [])).clean)        // a warning, not a leak
    }

    func testNoInternet() {
        let verdict = LeakCheck.verdict(LeakCheck.Input(vpnConnected: false, ipv4: [nil, nil], exit: nil, ipv6: nil, resolvers: [], direct: home))
        XCTAssertEqual(verdict.findings, [.offline])
        XCTAssertTrue(verdict.clean)
    }

    func testVPNOffRemembersHome() {
        let mine = LeakCheck.Address(ip: "95.24.1.2", country: "Russia", org: "PJSC Rostelecom")
        let v6 = LeakCheck.Address(ip: "2001:db8:1370:1::5", country: "Russia", org: "PJSC Rostelecom")
        let input = LeakCheck.Input(vpnConnected: false, ipv4: [mine.ip, mine.ip], exit: mine, ipv6: v6, resolvers: [], direct: nil)
        let verdict = LeakCheck.verdict(input)
        XCTAssertEqual(verdict.findings, [.vpnOff])
        XCTAssertEqual(verdict.home, LeakCheck.Direct(ipv4: "95.24.1.2", ipv6: "2001:db8:1370:1::5", org: "PJSC Rostelecom"))
        XCTAssertNil(LeakCheck.verdict(self.input()).home)       // only learnt with the VPN off
    }

    func testDescriptionsHaveNoKeysOrURLs() {
        for finding: LeakCheck.Finding in [.realIPv4, .ipv4Mismatch(["1.1.1.1"]), .ipv6Leak("2001:db8::1"),
                                           .ipv6Unexpected("2001:db8::1"), .dnsLeak(["1.1.1.1"]), .dnsUnknown, .offline, .vpnOff] {
            XCTAssertFalse(finding.text.isEmpty)
            XCTAssertFalse(finding.text.contains("http"))
        }
    }
}
