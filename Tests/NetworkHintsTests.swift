import XCTest

final class NetworkHintsTests: XCTestCase {
    /// The system keeps «Частный узел iCloud» status in a keyed archive
    /// (com.apple.networkserviceproxy, NSPServiceStatusManagerInfo).
    private func archive(status: Int?) throws -> Data {
        var top: [String: Any] = ["DiskVersion": 1]
        if let status { top["PrivacyProxyServiceStatus"] = status }
        let plist: [String: Any] = ["$version": 100000, "$archiver": "NSKeyedArchiver",
                                    "$top": ["root": 1], "$objects": ["$null", top]]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func testRelayStatusIsReadFromTheArchive() throws {
        XCTAssertEqual(NetworkHints.relayStatus(archive: try archive(status: 2)), 2)
        XCTAssertNil(NetworkHints.relayStatus(archive: try archive(status: nil)))
        XCTAssertNil(NetworkHints.relayStatus(archive: Data("not a plist".utf8)))
    }

    /// Only «active» counts; disabled, unsupported region (Russia, Belarus), outages do not; an
    /// unreadable status is unknown, not «off».
    func testRelayOn() {
        XCTAssertEqual(NetworkHints.relayOn(status: 2), true)
        XCTAssertEqual(NetworkHints.relayOn(status: 1), false)
        XCTAssertEqual(NetworkHints.relayOn(status: 6), false)
        XCTAssertNil(NetworkHints.relayOn(status: nil))
    }

    func testOverlaysByAddressAndApp() {
        let tailscale = [OtherVPN.Address(interface: "utun11", address: "100.64.111.130")]
        XCTAssertEqual(NetworkHints.overlays(addresses: tailscale, runningApps: []), ["Tailscale"])
        XCTAssertEqual(NetworkHints.overlays(addresses: [.init(interface: "utun4", address: "fd7a:115c:a1e0::1")], runningApps: []),
                       ["Tailscale"])
        XCTAssertEqual(NetworkHints.overlays(addresses: [], runningApps: ["Finder", "ZeroTier One", "NetBird"]), ["ZeroTier", "NetBird"])
        XCTAssertEqual(NetworkHints.overlays(addresses: tailscale, runningApps: ["Tailscale"]), ["Tailscale"])
        XCTAssertEqual(NetworkHints.overlays(addresses: [.init(interface: "en0", address: "100.64.0.5")], runningApps: []), [],
                       "a CGNAT address from the provider on Wi-Fi is no overlay")
        XCTAssertEqual(NetworkHints.overlays(addresses: [], runningApps: ["Safari"]), [])
    }

    func testHints() {
        XCTAssertEqual(NetworkHints.hints(relayOn: true, overlays: ["Tailscale"]), [.privateRelay, .overlay("Tailscale")])
        XCTAssertEqual(NetworkHints.hints(relayOn: nil, overlays: []), [])
        XCTAssertEqual(NetworkHints.hints(relayOn: false, overlays: []), [])
        XCTAssertEqual(NetworkHints.Hint.privateRelay.title, "Включён «Частный узел iCloud»")
        XCTAssertEqual(NetworkHints.Hint.overlay("Tailscale").title, "Работает Tailscale")
        XCTAssertTrue(NetworkHints.Hint.overlay("Tailscale").text.contains("100.64.0.0/10"))
        XCTAssertTrue(NetworkHints.Hint.overlay("ZeroTier").text.contains("Адреса без VPN"))
        XCTAssertTrue(NetworkHints.Hint.overlay("NetBird").text.contains("так задумано"))
    }
}
