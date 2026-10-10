import XCTest

final class TunnelAddressTests: XCTestCase {
    func testOurTunnel() {
        XCTAssertEqual(TunnelAddress.kind("198.18.128.1"), .own)
    }

    func testOtherVPNTunnels() {
        XCTAssertEqual(TunnelAddress.kind("198.18.0.1"), .other)   // dropweb, Happ
        XCTAssertEqual(TunnelAddress.kind("198.18.255.254"), .other)
    }

    func testNotAVPNTunnel() {
        XCTAssertNil(TunnelAddress.kind("100.101.102.103"))  // Tailscale
        XCTAssertNil(TunnelAddress.kind("198.19.0.1"))
        XCTAssertNil(TunnelAddress.kind("not an address"))
    }
}
