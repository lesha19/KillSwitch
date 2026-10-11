import XCTest

/// Own servers added by link with the main way of connecting (#33, ADR 0027): each one a host of
/// its own in the Xray array the helper gets.
final class XrayManualTests: XCTestCase {
    private func object(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func outbound(_ link: String) throws -> [String: Any] {
        try XrayManual.outbound(ProxyLink.parse(link))
    }

    func testVLESSRealityBecomesAnXrayOutbound() throws {
        let o = try outbound("vless://00000000-0000-4000-8000-000000000001@lt.example.com:443?security=reality&sni=www.example.com&fp=chrome&pbk=KEY&sid=ab12&flow=xtls-rprx-vision&type=tcp#LT")
        XCTAssertEqual(o["protocol"] as? String, "vless")
        XCTAssertEqual(o["tag"] as? String, "proxy")
        let vnext = try XCTUnwrap((o["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])
        XCTAssertEqual(vnext.first?["address"] as? String, "lt.example.com")
        XCTAssertEqual(vnext.first?["port"] as? Int, 443)
        let user = try XCTUnwrap((vnext.first?["users"] as? [[String: Any]])?.first)
        XCTAssertEqual(user["id"] as? String, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(user["encryption"] as? String, "none")
        XCTAssertEqual(user["flow"] as? String, "xtls-rprx-vision")
        let stream = try XCTUnwrap(o["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "reality")
        let reality = try XCTUnwrap(stream["realitySettings"] as? [String: Any])
        XCTAssertEqual(reality["serverName"] as? String, "www.example.com")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        XCTAssertEqual(reality["publicKey"] as? String, "KEY")
        XCTAssertEqual(reality["shortId"] as? String, "ab12")
    }

    func testTransportsAndOtherProtocols() throws {
        let ws = try outbound("vless://u@h.example:443?security=tls&sni=s.example&type=ws&path=%2Fws&host=w.example#a")
        let stream = try XCTUnwrap(ws["streamSettings"] as? [String: Any])
        XCTAssertEqual(stream["network"] as? String, "ws")
        XCTAssertEqual((stream["wsSettings"] as? [String: Any])?["path"] as? String, "/ws")
        XCTAssertEqual((stream["wsSettings"] as? [String: Any])?["host"] as? String, "w.example")
        XCTAssertEqual((stream["tlsSettings"] as? [String: Any])?["serverName"] as? String, "s.example")

        let upgrade = try outbound("vless://u@h.example:443?type=httpupgrade&path=%2Fu#a")
        XCTAssertEqual((upgrade["streamSettings"] as? [String: Any])?["network"] as? String, "httpupgrade")

        let grpc = try outbound("trojan://pw@h.example:443?type=grpc&serviceName=svc&sni=t.example#a")
        XCTAssertEqual(grpc["protocol"] as? String, "trojan")
        XCTAssertEqual(((grpc["settings"] as? [String: Any])?["servers"] as? [[String: Any]])?.first?["password"] as? String, "pw")
        let grpcStream = try XCTUnwrap(grpc["streamSettings"] as? [String: Any])
        XCTAssertEqual((grpcStream["grpcSettings"] as? [String: Any])?["serviceName"] as? String, "svc")
        XCTAssertEqual(grpcStream["security"] as? String, "tls", "trojan is always TLS")

        let xhttp = try outbound("vless://u@h.example:443?security=reality&pbk=K&sid=1&sni=x.example&type=xhttp&path=%2Fp&mode=packet-up#a")
        let xs = try XCTUnwrap((xhttp["streamSettings"] as? [String: Any])?["xhttpSettings"] as? [String: Any])
        XCTAssertEqual(xs["path"] as? String, "/p")
        XCTAssertEqual(xs["mode"] as? String, "packet-up")

        let ss = try outbound("ss://YWVzLTI1Ni1nY206cGFzcw@h.example:8388#a")
        XCTAssertEqual(ss["protocol"] as? String, "shadowsocks")
        let server = try XCTUnwrap(((ss["settings"] as? [String: Any])?["servers"] as? [[String: Any]])?.first)
        XCTAssertEqual(server["method"] as? String, "aes-256-gcm")
        XCTAssertEqual(server["password"] as? String, "pass")

        let vmess = try outbound("vmess://u@h.example:443?security=tls&type=ws&path=%2F#a")
        let vnext = try XCTUnwrap(((vmess["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first)
        XCTAssertEqual((vnext["users"] as? [[String: Any]])?.first?["security"] as? String, "auto")
    }

    func testWhatOnlyTheOtherWayCanDo() throws {
        for link in ["hysteria2://pw@h.example:443#a", "tuic://u:p@h.example:443#a", "socks5://h.example:1080#a",
                     "ss://YWVzLTI1Ni1nY206cGFzcw@h.example:8388?plugin=obfs-local%3Bobfs%3Dhttp#a",
                     "vless://u@h.example:443?security=tls&allowInsecure=1#a",
                     "vless://u@[2001:db8::1]:443#a"] {
            let proxy = try ProxyLink.parse(link)
            XCTAssertThrowsError(try XrayManual.outbound(proxy), link)
            XCTAssertNotNil(XrayManual.unsupported(proxy), link)
            XCTAssertFalse(XrayManual.unsupported(proxy)!.isEmpty)
        }
        XCTAssertNil(XrayManual.unsupported(try ProxyLink.parse("trojan://pw@h.example:443#a")))
    }

    func testAHostOfItsOwnEverythingThroughIt() throws {
        let host = try XrayManual.host(name: "Варшава (свой)", outbound: outbound("trojan://pw@h.example:443#a"))
        XCTAssertEqual(host["remarks"] as? String, "Варшава (свой)")
        XCTAssertEqual((host["outbounds"] as? [[String: Any]])?.map { $0["protocol"] as? String }, ["trojan"],
                       "one server and nothing else: no rule and no freedom outbound can send anything past the VPN")
        XCTAssertNil(host["routing"])
        let dns = try XCTUnwrap(host["dns"] as? [String: Any])
        XCTAssertEqual(dns["servers"] as? [String], ["1.1.1.1", "8.8.8.8"], "names are resolved through the server")
    }

    func testMergedAfterTheSubscriptionsHosts() throws {
        let subscription = Data(#"[{"remarks":"🇱🇹Литва","outbounds":[{"tag":"LT_1","protocol":"vless"}]},{"outbounds":[{"tag":"x","protocol":"trojan"}]}]"#.utf8)
        let manual: [(name: String, proxy: [String: Any])] = [
            ("Варшава", try ProxyLink.parse("trojan://pw@pl.example:443#a")),
            ("Варшава", try ProxyLink.parse("trojan://pw@pl2.example:443#b")),
            ("Быстрый", try ProxyLink.parse("hysteria2://pw@h.example:443#c")),
        ]
        let merged = try XCTUnwrap(XrayManual.merge(subscription: subscription, manual: manual))
        XCTAssertEqual(merged.servers, ["🇱🇹Литва", "#2", "Варшава (свой)", "Варшава (свой) (2)"])
        XCTAssertEqual(merged.skipped, ["Быстрый"])
        let array = try object(merged.data)
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array[0]["remarks"] as? String, "🇱🇹Литва", "the subscription's hosts first, as they came")
        XCTAssertEqual(try XrayProfile(body: String(decoding: merged.data, as: UTF8.self)).servers, merged.servers)
    }

    func testNamesTheHelperTakes() throws {
        // a link's #fragment, percent-decoded: no control characters, at most 256 bytes with the mark
        let long = String(repeating: "я", count: 300)
        let manual: [(name: String, proxy: [String: Any])] = [
            ("Вар\u{7}шава\n", try ProxyLink.parse("trojan://pw@pl.example:443#a")),
            (long, try ProxyLink.parse("trojan://pw@pl2.example:443#b")),
            (long, try ProxyLink.parse("trojan://pw@pl3.example:443#b")),
        ]
        let merged = try XCTUnwrap(XrayManual.merge(subscription: nil, manual: manual))
        XCTAssertEqual(merged.servers[0], "Варшава (свой)")
        for name in merged.servers {
            XCTAssertLessThanOrEqual(name.utf8.count, 256, name)
            XCTAssertFalse(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        }
        XCTAssertNotEqual(merged.servers[1], merged.servers[2], "still unique after the cut")
    }

    func testAServerNameTheHelperRefusesIsSkippedNotTheImport() throws {
        // Helper/ks host(): letters, digits, dots and dashes; one bad own server must not block the rest
        let proxy = try ProxyLink.parse("trojan://pw@g_x.example.com:443#a")
        XCTAssertNotNil(XrayManual.unsupported(proxy))
        let merged = try XCTUnwrap(XrayManual.merge(subscription: nil, manual: [("A", proxy), ("B", try ProxyLink.parse("trojan://pw@203.0.113.7:443#b"))]))
        XCTAssertEqual(merged.servers, ["B (свой)"])
        XCTAssertEqual(merged.skipped, ["A"])
    }

    func testNothingToAddKeepsTheBodyAsItCame() throws {
        let subscription = Data(#"[{"remarks":"a","outbounds":[]}]"#.utf8)
        XCTAssertEqual(XrayManual.merge(subscription: subscription, manual: [])?.data, subscription)
        XCTAssertNil(XrayManual.merge(subscription: nil, manual: []))
        let only = try XCTUnwrap(XrayManual.merge(subscription: nil, manual: [("PL", try ProxyLink.parse("trojan://pw@pl.example:443#a"))]))
        XCTAssertEqual(only.servers, ["PL (свой)"], "own servers without a subscription")
        XCTAssertNil(XrayManual.merge(subscription: nil, manual: [("Q", try ProxyLink.parse("tuic://u:p@h.example:443#c"))]),
                     "none the main way can use: nothing to import")
    }
}
