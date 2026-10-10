import Foundation
import XCTest

final class ProxyLinkTests: XCTestCase {
    func testVlessReality() throws {
        let link = "vless://11111111-2222-3333-4444-555555555555@de.example.com:443?type=tcp&security=reality&pbk=PUBKEY&sid=ab12&sni=www.google.com&fp=chrome&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20DE"
        let p = try ProxyLink.parse(link)
        XCTAssertEqual(p["type"] as? String, "vless")
        XCTAssertEqual(p["name"] as? String, "🇩🇪 DE")
        XCTAssertEqual(p["server"] as? String, "de.example.com")
        XCTAssertEqual(p["port"] as? Int, 443)
        XCTAssertEqual(p["uuid"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(p["network"] as? String, "tcp")
        XCTAssertEqual(p["tls"] as? Bool, true)
        XCTAssertEqual(p["servername"] as? String, "www.google.com")
        XCTAssertEqual(p["client-fingerprint"] as? String, "chrome")
        XCTAssertEqual(p["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(p["udp"] as? Bool, true)
        let reality = try XCTUnwrap(p["reality-opts"] as? [String: Any])
        XCTAssertEqual(reality["public-key"] as? String, "PUBKEY")
        XCTAssertEqual(reality["short-id"] as? String, "ab12")
    }

    func testVlessWebSocketTLS() throws {
        let p = try ProxyLink.parse("vless://id@[2001:db8::1]:8443?type=ws&security=tls&path=%2Fws&host=cdn.example.com&sni=cdn.example.com#ws")
        XCTAssertEqual(p["server"] as? String, "2001:db8::1")
        XCTAssertEqual(p["network"] as? String, "ws")
        let ws = try XCTUnwrap(p["ws-opts"] as? [String: Any])
        XCTAssertEqual(ws["path"] as? String, "/ws")
        XCTAssertEqual((ws["headers"] as? [String: String])?["Host"], "cdn.example.com")
        XCTAssertNil(p["reality-opts"])
    }

    func testVlessGrpc() throws {
        let p = try ProxyLink.parse("vless://id@h.example:443?type=grpc&serviceName=svc&security=tls#g")
        XCTAssertEqual((p["grpc-opts"] as? [String: Any])?["grpc-service-name"] as? String, "svc")
    }

    func testTrojan() throws {
        let p = try ProxyLink.parse("trojan://p%40ss@1.2.3.4:443?sni=t.example&allowInsecure=1#T")
        XCTAssertEqual(p["type"] as? String, "trojan")
        XCTAssertEqual(p["password"] as? String, "p@ss")
        XCTAssertEqual(p["sni"] as? String, "t.example")
        XCTAssertEqual(p["skip-cert-verify"] as? Bool, true)
    }

    func testShadowsocksSIP002() throws {
        let user = Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString()
        let p = try ProxyLink.parse("ss://\(user)@5.6.7.8:8388#SS")
        XCTAssertEqual(p["type"] as? String, "ss")
        XCTAssertEqual(p["cipher"] as? String, "chacha20-ietf-poly1305")
        XCTAssertEqual(p["password"] as? String, "secret")
        XCTAssertEqual(p["port"] as? Int, 8388)
    }

    func testShadowsocksPlainUserinfo() throws {
        let p = try ProxyLink.parse("ss://2022-blake3-aes-128-gcm:a%2Bb%3D@5.6.7.8:8388#SS")
        XCTAssertEqual(p["cipher"] as? String, "2022-blake3-aes-128-gcm")
        XCTAssertEqual(p["password"] as? String, "a+b=")
    }

    func testShadowsocksLegacy() throws {
        let all = Data("aes-256-gcm:pw@9.9.9.9:443".utf8).base64EncodedString()
        let p = try ProxyLink.parse("ss://\(all)#Old")
        XCTAssertEqual(p["server"] as? String, "9.9.9.9")
        XCTAssertEqual(p["port"] as? Int, 443)
        XCTAssertEqual(p["password"] as? String, "pw")
        XCTAssertEqual(p["name"] as? String, "Old")
    }

    func testHysteria2() throws {
        let p = try ProxyLink.parse("hysteria2://secret@h.example:443/?sni=h.example&obfs=salamander&obfs-password=op&insecure=1&mport=20000-30000#H")
        XCTAssertEqual(p["type"] as? String, "hysteria2")
        XCTAssertEqual(p["password"] as? String, "secret")
        XCTAssertEqual(p["obfs"] as? String, "salamander")
        XCTAssertEqual(p["obfs-password"] as? String, "op")
        XCTAssertEqual(p["skip-cert-verify"] as? Bool, true)
        XCTAssertEqual(p["ports"] as? String, "20000-30000")
        XCTAssertEqual(try ProxyLink.parse("hy2://s@h.example:443#x")["type"] as? String, "hysteria2")
    }

    func testTuic() throws {
        let p = try ProxyLink.parse("tuic://uuid1:pw@t.example:443?congestion_control=bbr&alpn=h3,h2&sni=t.example&udp_relay_mode=quic#U")
        XCTAssertEqual(p["type"] as? String, "tuic")
        XCTAssertEqual(p["uuid"] as? String, "uuid1")
        XCTAssertEqual(p["password"] as? String, "pw")
        XCTAssertEqual(p["congestion-controller"] as? String, "bbr")
        XCTAssertEqual(p["alpn"] as? [String], ["h3", "h2"])
        XCTAssertEqual(p["udp-relay-mode"] as? String, "quic")
    }

    func testDefaultNameIsHostPort() throws {
        XCTAssertEqual(try ProxyLink.parse("trojan://p@1.2.3.4:443")["name"] as? String, "1.2.3.4:443")
    }

    func testRejectsBadLinks() {
        XCTAssertThrowsError(try ProxyLink.parse("vmess://whatever"))
        XCTAssertThrowsError(try ProxyLink.parse("vless://id@host"))          // no port
        XCTAssertThrowsError(try ProxyLink.parse("vless://@host:443"))        // no uuid
        XCTAssertThrowsError(try ProxyLink.parse("trojan://p@host:99999"))    // bad port
        XCTAssertThrowsError(try ProxyLink.parse("https://example.com"))
    }
}
