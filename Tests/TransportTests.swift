import Foundation
import XCTest

final class TransportTests: XCTestCase {
    private let profile: Profile = [
        "proxies": [
            ["name": "ss", "type": "ss"],
            ["name": "vless", "type": "vless", "client-fingerprint": "chrome", "smux": ["enabled": true, "protocol": "yamux"]],
            ["name": "vision", "type": "vless", "flow": "xtls-rprx-vision"],
            ["name": "trojan", "type": "Trojan"],
            ["name": "hy2", "type": "hysteria2"],
            ["name": "wg", "type": "wireguard"],
        ],
        "proxy-groups": [["name": "P", "type": "select", "proxies": ["ss", "vless"]]],
    ]

    func testWhatEachServerSupportsAndWhatTheSubscriptionSays() {
        let servers = Transport.servers(profile)
        XCTAssertEqual(servers.map(\.name), ["ss", "vless", "vision", "trojan"])   // hy2 and wg: nothing to change
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        XCTAssertEqual(byName["ss"], Transport.Server(name: "ss", canFingerprint: false, canMux: true, fingerprint: nil, mux: nil))
        XCTAssertEqual(byName["vless"], Transport.Server(name: "vless", canFingerprint: true, canMux: true, fingerprint: "chrome", mux: "yamux"))
        XCTAssertEqual(byName["vision"]?.canMux, false)
        XCTAssertEqual(byName["trojan"]?.canFingerprint, true)
    }

    func testMuxWithoutAProtocolIsMihomosDefault() {
        let p: Profile = ["proxies": [["name": "a", "type": "ss", "smux": ["enabled": true]], ["name": "b", "type": "ss", "smux": ["enabled": false]]]]
        XCTAssertEqual(Transport.servers(p).map(\.mux), ["h2mux", Transport.off])
    }

    func testOverridesGoToTheHelperOnlyWhereTheyApply() throws {
        let overrides: [String: Transport.Override] = [
            "vless": .init(fingerprint: "firefox", mux: Transport.off),
            "ss": .init(fingerprint: "chrome", mux: "h2mux"),       // no fingerprint on ss
            "vision": .init(fingerprint: nil, mux: "smux"),         // no mux with a flow
            "gone": .init(fingerprint: "chrome", mux: nil),         // not in the subscription any more
            "trojan": .init(fingerprint: "bogus", mux: "quic"),     // unknown values
        ]
        let sent = try XCTUnwrap(Transport.adding(overrides, to: profile)[Transport.hintKey] as? [String: [String: Any]])
        XCTAssertEqual(Set(sent.keys), ["vless", "ss"])
        XCTAssertEqual(sent["vless"]?["client-fingerprint"] as? String, "firefox")
        XCTAssertEqual((sent["vless"]?["smux"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertNil(sent["ss"]?["client-fingerprint"])
        XCTAssertEqual(sent["ss"]?["smux"] as? [String: AnyHashable], ["enabled": true, "protocol": "h2mux"])
        // the JSON the helper reads: a real boolean
        let json = String(decoding: try ProfileConverter.json(Transport.adding(overrides, to: profile)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""enabled":false"#) || json.contains(#""enabled" : false"#), json)
    }

    func testNoOverridesNoKey() {
        XCTAssertNil(Transport.adding([:], to: profile)[Transport.hintKey])
        XCTAssertNil(Transport.adding(["vless": .init(fingerprint: nil, mux: nil)], to: profile)[Transport.hintKey])
    }

    func testStoredAndReadBack() {
        let overrides: [String: Transport.Override] = ["vless": .init(fingerprint: "safari", mux: nil)]
        XCTAssertEqual(Transport.decode(Transport.encode(overrides)), overrides)
        XCTAssertEqual(Transport.decode(nil), [:])
        XCTAssertEqual(Transport.decode(Data("junk".utf8)), [:])
    }

    func testNamesInTheMenu() {
        XCTAssertEqual(Transport.fingerprintTitle(nil, subscription: "chrome"), "Как в подписке (chrome)")
        XCTAssertEqual(Transport.fingerprintTitle(nil, subscription: nil), "Как в подписке (нет)")
        XCTAssertEqual(Transport.fingerprintTitle("iOS", subscription: nil), "iOS")
        XCTAssertEqual(Transport.muxTitle(nil, subscription: nil), "Как в подписке (выкл.)")
        XCTAssertEqual(Transport.muxTitle(Transport.off, subscription: "h2mux"), "Выкл.")
        XCTAssertEqual(Transport.muxTitle(nil, subscription: "yamux"), "Как в подписке (yamux)")
    }
}
