import XCTest

/// The content filter's address decisions (Filter/FilterDataProvider uses AddressMatch).
final class AddressMatchTests: XCTestCase {
    func testIPv4Networks() {
        XCTAssertTrue(AddressMatch.matches("10.1.2.3", "10.0.0.0/8"))
        XCTAssertFalse(AddressMatch.matches("11.0.0.1", "10.0.0.0/8"))
        XCTAssertTrue(AddressMatch.matches("172.31.255.255", "172.16.0.0/12"))
        XCTAssertFalse(AddressMatch.matches("172.32.0.0", "172.16.0.0/12"))
        XCTAssertTrue(AddressMatch.matches("192.168.89.254", "192.168.0.0/16"))
        XCTAssertTrue(AddressMatch.matches("8.8.8.8", "0.0.0.0/0"))
    }

    func testSingleAddressesAndPrefixEdges() {
        XCTAssertTrue(AddressMatch.matches("203.0.113.7", "203.0.113.7"))
        XCTAssertFalse(AddressMatch.matches("203.0.113.8", "203.0.113.7"))
        XCTAssertTrue(AddressMatch.matches("203.0.113.7", "203.0.113.7/32"))
        XCTAssertTrue(AddressMatch.matches("203.0.113.6", "203.0.113.7/31"))
        XCTAssertFalse(AddressMatch.matches("203.0.113.8", "203.0.113.7/31"))
    }

    func testIPv6() {
        XCTAssertTrue(AddressMatch.matches("fe80::1", "fe80::/10"))
        XCTAssertTrue(AddressMatch.matches("febf::1", "fe80::/10"))
        XCTAssertFalse(AddressMatch.matches("fec0::1", "fe80::/10"))
        XCTAssertTrue(AddressMatch.matches("fd7a:115c:a1e0::5", "fd7a:115c:a1e0::/48"))
        XCTAssertTrue(AddressMatch.matches("2001:db8::1", "2001:db8::1"))
    }

    func testNothingMatchesAcrossFamiliesOrBadInput() {
        XCTAssertFalse(AddressMatch.matches("10.0.0.1", "::/0"))
        XCTAssertFalse(AddressMatch.matches("::ffff:10.0.0.1", "10.0.0.0/8"))
        XCTAssertFalse(AddressMatch.matches("example.com", "0.0.0.0/0"), "a name is never an address")
        XCTAssertFalse(AddressMatch.matches("10.0.0.1", "10.0.0.0/33"))
        XCTAssertFalse(AddressMatch.matches("10.0.0.1", "10.0.0.0/-1"))
        XCTAssertFalse(AddressMatch.matches("10.0.0.1", "10.0.0.0/x"))
        XCTAssertFalse(AddressMatch.matches("10.0.0.1", ""))
    }

    func testLocal() {
        XCTAssertTrue(AddressMatch.isLocal("127.0.0.1", lan: false))
        XCTAssertTrue(AddressMatch.isLocal("169.254.3.4", lan: false))
        XCTAssertTrue(AddressMatch.isLocal("224.0.0.251", lan: false))
        XCTAssertTrue(AddressMatch.isLocal("::1", lan: false))
        XCTAssertTrue(AddressMatch.isLocal("ff02::fb", lan: false))
        XCTAssertFalse(AddressMatch.isLocal("192.168.1.1", lan: false), "the LAN only when allowed")
        XCTAssertTrue(AddressMatch.isLocal("192.168.1.1", lan: true))
        XCTAssertFalse(AddressMatch.isLocal("100.64.0.1", lan: true), "Tailscale is not the LAN")
        XCTAssertFalse(AddressMatch.isLocal("1.1.1.1", lan: true))
    }
}
