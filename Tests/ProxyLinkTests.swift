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

    func testVmessV2rayNBase64() throws {
        let json = #"{"v":"2","ps":"FI vmess","add":"fi.example.com","port":"443","id":"a3482e88-686a-4a58-8126-99c9df64b7bf","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"cdn.example.com","alpn":"h2,http/1.1","fp":"chrome"}"#
        let p = try ProxyLink.parse("vmess://" + Data(json.utf8).base64EncodedString())
        XCTAssertEqual(p["type"] as? String, "vmess")
        XCTAssertEqual(p["name"] as? String, "FI vmess")
        XCTAssertEqual(p["server"] as? String, "fi.example.com")
        XCTAssertEqual(p["port"] as? Int, 443)
        XCTAssertEqual(p["uuid"] as? String, "a3482e88-686a-4a58-8126-99c9df64b7bf")
        XCTAssertEqual(p["alterId"] as? Int, 0)
        XCTAssertEqual(p["cipher"] as? String, "auto")
        XCTAssertEqual(p["tls"] as? Bool, true)
        XCTAssertEqual(p["servername"] as? String, "cdn.example.com")
        XCTAssertEqual(p["client-fingerprint"] as? String, "chrome")
        XCTAssertEqual(p["alpn"] as? [String], ["h2", "http/1.1"])
        XCTAssertEqual(p["network"] as? String, "ws")
        let ws = try XCTUnwrap(p["ws-opts"] as? [String: Any])
        XCTAssertEqual(ws["path"] as? String, "/ws")
        XCTAssertEqual((ws["headers"] as? [String: String])?["Host"], "cdn.example.com")
    }

    func testVmessV2rayNNumbersAndGrpc() throws {
        let json = #"{"ps":"g","add":"1.2.3.4","port":8443,"id":"u1","aid":0,"net":"grpc","path":"svc","tls":""}"#
        let p = try ProxyLink.parse("vmess://" + Data(json.utf8).base64EncodedString())
        XCTAssertEqual(p["port"] as? Int, 8443)
        XCTAssertEqual(p["cipher"] as? String, "auto")
        XCTAssertNil(p["tls"])
        XCTAssertEqual((p["grpc-opts"] as? [String: Any])?["grpc-service-name"] as? String, "svc")
    }

    func testVmessURIForm() throws {
        let p = try ProxyLink.parse("vmess://u1@v.example:443?type=ws&security=tls&path=%2Fa&sni=v.example#V")
        XCTAssertEqual(p["type"] as? String, "vmess")
        XCTAssertEqual(p["uuid"] as? String, "u1")
        XCTAssertEqual(p["tls"] as? Bool, true)
        XCTAssertEqual(p["servername"] as? String, "v.example")
        XCTAssertEqual((p["ws-opts"] as? [String: Any])?["path"] as? String, "/a")
        XCTAssertThrowsError(try ProxyLink.parse("vmess://" + Data(#"{"add":"h","port":"443"}"#.utf8).base64EncodedString()))  // no id
    }

    func testAnyTLS() throws {
        let p = try ProxyLink.parse("anytls://pa%40ss@a.example:443/?sni=real.example&fp=chrome&insecure=1&alpn=h2#A")
        XCTAssertEqual(p["type"] as? String, "anytls")
        XCTAssertEqual(p["password"] as? String, "pa@ss")
        XCTAssertEqual(p["sni"] as? String, "real.example")
        XCTAssertEqual(p["client-fingerprint"] as? String, "chrome")
        XCTAssertEqual(p["skip-cert-verify"] as? Bool, true)
        XCTAssertEqual(p["alpn"] as? [String], ["h2"])
        XCTAssertEqual(p["udp"] as? Bool, true)
        XCTAssertThrowsError(try ProxyLink.parse("anytls://@a.example:443"))
    }

    func testSocks() throws {
        let p = try ProxyLink.parse("socks5://user:p%3Ass@s.example:1080#S")
        XCTAssertEqual(p["type"] as? String, "socks5")
        XCTAssertEqual(p["username"] as? String, "user")
        XCTAssertEqual(p["password"] as? String, "p:ss")
        XCTAssertEqual(p["udp"] as? Bool, true)
        // v2rayN: socks://base64(user:pass)@host:port
        let b = try ProxyLink.parse("socks://\(Data("u:p".utf8).base64EncodedString())@1.2.3.4:1080#B")
        XCTAssertEqual(b["username"] as? String, "u")
        XCTAssertEqual(b["password"] as? String, "p")
        let anonymous = try ProxyLink.parse("socks5h://1.2.3.4:1080")
        XCTAssertNil(anonymous["username"])
    }

    func testHTTPProxy() throws {
        let p = try ProxyLink.parse("https://u:p@h.example:8443#H")
        XCTAssertEqual(p["type"] as? String, "http")
        XCTAssertEqual(p["tls"] as? Bool, true)
        XCTAssertEqual(p["username"] as? String, "u")
        XCTAssertEqual(p["sni"] as? String, "h.example")
        let plain = try ProxyLink.parse("http://1.2.3.4:3128")
        XCTAssertNil(plain["tls"])
        // a subscription address is not a proxy
        XCTAssertThrowsError(try ProxyLink.parse("https://sub.example.com:8443/api/sub/abcdef"))
        XCTAssertThrowsError(try ProxyLink.parse("https://sub.example.com:8443/?token=abc"))
    }

    func testVlessXHTTPExtraWithDownloadSettings() throws {
        let extra = #"{"xPaddingBytes":"100-1000","noGRPCHeader":true,"xmux":{"maxConcurrency":"16-32","hMaxRequestTimes":"600-900","hKeepAlivePeriod":30},"downloadSettings":{"address":"dl.example.com","port":8443,"network":"xhttp","security":"reality","realitySettings":{"serverName":"www.microsoft.com","publicKey":"PBK2","shortId":"ab","fingerprint":"firefox"},"xhttpSettings":{"path":"/down","host":"dl.example.com"}}}"#
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/:,{}\"")
        let link = "vless://id@up.example:443?type=xhttp&security=tls&sni=up.example&path=%2Fup&mode=packet-up&extra=" +
            extra.addingPercentEncoding(withAllowedCharacters: allowed)! + "#X"
        let p = try ProxyLink.parse(link)
        let x = try XCTUnwrap(p["xhttp-opts"] as? [String: Any])
        XCTAssertEqual(x["path"] as? String, "/up")
        XCTAssertEqual(x["mode"] as? String, "packet-up")
        XCTAssertEqual(x["x-padding-bytes"] as? String, "100-1000")
        XCTAssertEqual(x["no-grpc-header"] as? Bool, true)
        let reuse = try XCTUnwrap(x["reuse-settings"] as? [String: Any])
        XCTAssertEqual(reuse["max-concurrency"] as? String, "16-32")
        XCTAssertEqual(reuse["h-max-request-times"] as? String, "600-900")
        XCTAssertEqual(reuse["h-keep-alive-period"] as? Int, 30)
        let d = try XCTUnwrap(x["download-settings"] as? [String: Any])
        XCTAssertEqual(d["server"] as? String, "dl.example.com")
        XCTAssertEqual(d["port"] as? Int, 8443)
        XCTAssertEqual(d["path"] as? String, "/down")
        XCTAssertEqual(d["host"] as? String, "dl.example.com")
        XCTAssertEqual(d["tls"] as? Bool, true)
        XCTAssertEqual(d["servername"] as? String, "www.microsoft.com")
        XCTAssertEqual(d["client-fingerprint"] as? String, "firefox")
        let reality = try XCTUnwrap(d["reality-opts"] as? [String: Any])
        XCTAssertEqual(reality["public-key"] as? String, "PBK2")
        XCTAssertEqual(reality["short-id"] as? String, "ab")
    }

    func testVlessBadExtraIsIgnored() throws {
        let p = try ProxyLink.parse("vless://id@h.example:443?type=xhttp&security=tls&path=%2Fx&extra=%7Bnot-json#X")
        XCTAssertEqual((p["xhttp-opts"] as? [String: Any])?["path"] as? String, "/x")
        XCTAssertNil((p["xhttp-opts"] as? [String: Any])?["download-settings"])
    }

    func testVlessPostQuantum() throws {
        let enc = "mlkem768x25519plus.native.0rtt.Ea85ctZjj5CGgiiRfUQ5HLhbUVEPr_l1VIIBzRNDVHI"
        let p = try ProxyLink.parse("vless://id@h.example:443?type=tcp&security=reality&pbk=PBK&sid=ab&sni=www.microsoft.com&encryption=\(enc)&flow=xtls-rprx-vision#PQ")
        XCTAssertEqual(p["encryption"] as? String, enc)
        XCTAssertNil(try ProxyLink.parse("vless://id@h.example:443?encryption=none#N")["encryption"])
    }

    func testShadowsocksV2rayPlugin() throws {
        let user = Data("aes-128-gcm:pw".utf8).base64EncodedString()
        let p = try ProxyLink.parse("ss://\(user)@5.6.7.8:443?plugin=v2ray-plugin%3Btls%3Bhost%3Dcdn.example%3Bpath%3D%2Fws%3Bmux%3D0#V")
        XCTAssertEqual(p["plugin"] as? String, "v2ray-plugin")
        let opts = try XCTUnwrap(p["plugin-opts"] as? [String: Any])
        XCTAssertEqual(opts["mode"] as? String, "websocket")
        XCTAssertEqual(opts["tls"] as? Bool, true)
        XCTAssertEqual(opts["host"] as? String, "cdn.example")
        XCTAssertEqual(opts["path"] as? String, "/ws")
        XCTAssertEqual(opts["mux"] as? Bool, false)
    }

    func testShadowsocksShadowTLS() throws {
        let p = try ProxyLink.parse("ss://2022-blake3-aes-128-gcm:a%2Bb%3D@5.6.7.8:443?plugin=shadow-tls%3Bhost%3Dcloud.tencent.com%3Bpassword%3Dstls%3Bversion%3D3#S")
        XCTAssertEqual(p["plugin"] as? String, "shadow-tls")
        let opts = try XCTUnwrap(p["plugin-opts"] as? [String: Any])
        XCTAssertEqual(opts["host"] as? String, "cloud.tencent.com")
        XCTAssertEqual(opts["password"] as? String, "stls")
        XCTAssertEqual(opts["version"] as? Int, 3)
        XCTAssertThrowsError(try ProxyLink.parse("ss://\(Data("aes-128-gcm:pw".utf8).base64EncodedString())@5.6.7.8:443?plugin=%2Fusr%2Fbin%2Fevil#E"))
    }

    func testOutputHasOnlyKnownKeysAndNoPaths() throws {
        // what the helper refuses never comes out of a link: no file paths, no interface or dialer
        let links = [
            "vless://id@h.example:443?type=ws&security=tls&path=%2Fws&interface-name=en0&dialer-proxy=DIRECT#a",
            "trojan://p@h.example:443?sni=x&certificate=%2Fetc%2Fhosts#b",
            "anytls://p@h.example:443?interface=en0#c",
        ]
        for link in links {
            let p = try ProxyLink.parse(link)
            for key in ["interface-name", "routing-mark", "dialer-proxy", "certificate", "private-key"] {
                XCTAssertNil(p[key], "\(key) in \(link)")
            }
        }
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
