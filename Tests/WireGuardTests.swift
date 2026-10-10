import Foundation
import XCTest

final class WireGuardTests: XCTestCase {
    // throwaway keys, 32 bytes each
    private let priv = "eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU="
    private let pub = "Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo="
    private let psk = "31aIhAPwktDGpH4JDhA8GNvjFXEf/a6+UaQRyOAiyfM="

    private var conf: String {
        """
        # comment
        [Interface]
        PrivateKey = \(priv)
        Address = 10.66.66.2/32, fd42:42:42::2/128
        DNS = 1.1.1.1, 1.0.0.1
        MTU = 1380

        [Peer]
        PublicKey = \(pub)
        PresharedKey = \(psk)
        Endpoint = wg.example.com:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """
    }

    func testLinkWithAmneziaWG() throws {
        let p = try WireGuard.parse(link: "wireguard://\(priv)@1.2.3.4:51820?publickey=\(pub)&address=10.0.0.2/32&jc=4&jmin=40&jmax=70&s1=15&s2=68&h1=100-200&i1=%3Cr%2032%3E#A")
        let awg = try XCTUnwrap(p["amnezia-wg-option"] as? [String: Any])
        XCTAssertEqual(awg["jc"] as? Int, 4)
        XCTAssertEqual(awg["s2"] as? Int, 68)
        XCTAssertEqual(awg["h1"] as? String, "100-200")
        XCTAssertEqual(awg["i1"] as? String, "<r 32>")
        XCTAssertNil(try WireGuard.parse(link: "wireguard://\(priv)@1.2.3.4:51820?publickey=\(pub)&address=10.0.0.2")["amnezia-wg-option"])
        XCTAssertThrowsError(try WireGuard.parse(link: "wireguard://\(priv)@1.2.3.4:51820?publickey=\(pub)&address=10.0.0.2&jc=-1"))
    }

    func testConf() throws {
        let p = try WireGuard.parse(conf: conf, name: "Дом")
        XCTAssertEqual(p["type"] as? String, "wireguard")
        XCTAssertEqual(p["name"] as? String, "Дом")
        XCTAssertEqual(p["private-key"] as? String, priv)
        XCTAssertEqual(p["public-key"] as? String, pub)
        XCTAssertEqual(p["pre-shared-key"] as? String, psk)
        XCTAssertEqual(p["server"] as? String, "wg.example.com")
        XCTAssertEqual(p["port"] as? Int, 51820)
        XCTAssertEqual(p["ip"] as? String, "10.66.66.2")
        XCTAssertEqual(p["ipv6"] as? String, "fd42:42:42::2")
        XCTAssertEqual(p["allowed-ips"] as? [String], ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(p["mtu"] as? Int, 1380)
        XCTAssertEqual(p["persistent-keepalive"] as? Int, 25)
        XCTAssertEqual(p["udp"] as? Bool, true)
        XCTAssertNil(p["dns"])                       // DNS is the core's, not the file's
        XCTAssertNil(p["remote-dns-resolve"])
    }

    func testConfDefaultsAndIPv6Endpoint() throws {
        let p = try WireGuard.parse(conf: """
        [Interface]
        PrivateKey=\(priv)
        Address=172.16.0.2
        [Peer]
        PublicKey=\(pub)
        Endpoint=[2001:db8::1]:2408
        Reserved = 1, 2, 3
        """, name: nil)
        XCTAssertEqual(p["server"] as? String, "2001:db8::1")
        XCTAssertEqual(p["port"] as? Int, 2408)
        XCTAssertEqual(p["name"] as? String, "WireGuard 2001:db8::1")
        XCTAssertEqual(p["allowed-ips"] as? [String], ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(p["reserved"] as? [Int], [1, 2, 3])
        XCTAssertNil(p["ipv6"])
        XCTAssertNil(p["mtu"])
    }

    func testConfErrors() {
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1", name: nil))
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)", name: nil))
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = short\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1", name: nil))
        // several peers: each needs its own Endpoint and AllowedIPs (mihomo routes by them)
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1\nAllowedIPs = 10.1.0.0/16\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:2", name: nil))
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1\nAllowedIPs = 10.1.0.0/16\n[Peer]\nPublicKey = \(pub)\nAllowedIPs = 0.0.0.0/0", name: nil))
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1\nAllowedIPs = 10.1.0.0/16\n[Peer]\nPublicKey = bad\nEndpoint = h:2\nAllowedIPs = 0.0.0.0/0", name: nil))
    }

    func testAmneziaWG() throws {
        let p = try WireGuard.parse(conf: """
        [Interface]
        PrivateKey = \(priv)
        Address = 10.8.1.2/32
        Jc = 4
        Jmin = 40
        Jmax = 70
        S1 = 52
        S2 = 81
        S3 = 30
        S4 = 12
        H1 = 1376502731
        H2 = 100-200
        H3 = 3
        H4 = 4
        I1 = <b 0xf6ab3267fa><c><b 0xf6ab><t><r 10><wt 10>
        Itime = 120
        [Peer]
        PublicKey = \(pub)
        Endpoint = 203.0.113.9:51820
        AllowedIPs = 0.0.0.0/0
        """, name: "Amnezia")
        XCTAssertEqual(p["type"] as? String, "wireguard")
        let awg = try XCTUnwrap(p["amnezia-wg-option"] as? [String: Any])
        XCTAssertEqual(awg["jc"] as? Int, 4)
        XCTAssertEqual(awg["jmin"] as? Int, 40)
        XCTAssertEqual(awg["jmax"] as? Int, 70)
        XCTAssertEqual(awg["s1"] as? Int, 52)
        XCTAssertEqual(awg["s2"] as? Int, 81)
        XCTAssertEqual(awg["s3"] as? Int, 30)
        XCTAssertEqual(awg["s4"] as? Int, 12)
        XCTAssertEqual(awg["h1"] as? String, "1376502731")
        XCTAssertEqual(awg["h2"] as? String, "100-200")       // AmneziaWG 2: a range
        XCTAssertEqual(awg["i1"] as? String, "<b 0xf6ab3267fa><c><b 0xf6ab><t><r 10><wt 10>")
        XCTAssertEqual(awg["itime"] as? Int, 120)
        XCTAssertNil(awg["i2"])
        XCTAssertNil(awg["version"])
    }

    func testPlainWireGuardHasNoAmneziaOption() throws {
        XCTAssertNil(try WireGuard.parse(conf: conf, name: nil)["amnezia-wg-option"])
    }

    func testAmneziaBadNumber() {
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\nJc = many\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1", name: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Jc"))
        }
    }

    func testSeveralPeers() throws {
        let p = try WireGuard.parse(conf: """
        [Interface]
        PrivateKey = \(priv)
        Address = 10.0.0.2/32
        MTU = 1400
        [Peer]
        PublicKey = \(pub)
        PresharedKey = \(psk)
        Endpoint = office.example.com:51820
        AllowedIPs = 10.1.0.0/16, 192.168.50.0/24
        PersistentKeepalive = 25
        [Peer]
        PublicKey = \(psk)
        Endpoint = [2001:db8::2]:443
        AllowedIPs = 0.0.0.0/0
        Reserved = 1,2,3
        """, name: "Офис")
        XCTAssertEqual(p["name"] as? String, "Офис")
        // the first peer stays the top-level server: the helper lets it out and the list shows it
        XCTAssertEqual(p["server"] as? String, "office.example.com")
        XCTAssertEqual(p["port"] as? Int, 51820)
        XCTAssertNil(p["public-key"])
        XCTAssertNil(p["allowed-ips"])
        XCTAssertEqual(p["persistent-keepalive"] as? Int, 25)
        XCTAssertEqual(p["mtu"] as? Int, 1400)
        let peers = try XCTUnwrap(p["peers"] as? [[String: Any]])
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[0]["server"] as? String, "office.example.com")
        XCTAssertEqual(peers[0]["port"] as? Int, 51820)
        XCTAssertEqual(peers[0]["public-key"] as? String, pub)
        XCTAssertEqual(peers[0]["pre-shared-key"] as? String, psk)
        XCTAssertEqual(peers[0]["allowed-ips"] as? [String], ["10.1.0.0/16", "192.168.50.0/24"])
        XCTAssertNil(peers[0]["reserved"])
        XCTAssertEqual(peers[1]["server"] as? String, "2001:db8::2")
        XCTAssertEqual(peers[1]["port"] as? Int, 443)
        XCTAssertEqual(peers[1]["public-key"] as? String, psk)
        XCTAssertNil(peers[1]["pre-shared-key"])
        XCTAssertEqual(peers[1]["reserved"] as? [Int], [1, 2, 3])
    }

    func testPeerReservedBase64BecomesBytes() throws {
        let p = try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1\nAllowedIPs = 10.0.0.0/8\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:2\nAllowedIPs = 0.0.0.0/0\nReserved = U4An", name: nil)
        let peers = try XCTUnwrap(p["peers"] as? [[String: Any]])
        XCTAssertEqual(peers[1]["reserved"] as? [Int], [83, 128, 39])
    }

    func testErrorsDoNotLeakKey() {
        do {
            _ = try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1", name: nil)
            XCTFail("no address")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(priv))
        }
    }

    func testLink() throws {
        let key = priv.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let p = try ProxyLink.parse("wireguard://\(key)@1.2.3.4:51820?publickey=\(pub)&address=10.0.0.2/32,fd00::2/128&mtu=1420&reserved=0,0,0&presharedkey=\(psk)#%F0%9F%87%A9%F0%9F%87%AA%20WG")
        XCTAssertEqual(p["type"] as? String, "wireguard")
        XCTAssertEqual(p["name"] as? String, "🇩🇪 WG")
        XCTAssertEqual(p["private-key"] as? String, priv)
        XCTAssertEqual(p["public-key"] as? String, pub)
        XCTAssertEqual(p["pre-shared-key"] as? String, psk)
        XCTAssertEqual(p["server"] as? String, "1.2.3.4")
        XCTAssertEqual(p["port"] as? Int, 51820)
        XCTAssertEqual(p["ip"] as? String, "10.0.0.2")
        XCTAssertEqual(p["ipv6"] as? String, "fd00::2")
        XCTAssertEqual(p["mtu"] as? Int, 1420)
        XCTAssertEqual(p["reserved"] as? [Int], [0, 0, 0])
    }

    func testLinkUnencodedKeyAndAliases() throws {
        let p = try ProxyLink.parse("wg://\(priv)@[2001:db8::1]:443?publicKey=\(pub)&ip=10.0.0.2&allowedIPs=10.0.0.0/8")
        XCTAssertEqual(p["private-key"] as? String, priv)
        XCTAssertEqual(p["public-key"] as? String, pub)
        XCTAssertEqual(p["server"] as? String, "2001:db8::1")
        XCTAssertEqual(p["allowed-ips"] as? [String], ["10.0.0.0/8"])
    }

    func testConfThroughProxyLink() throws {
        let p = try ProxyLink.parse(conf)
        XCTAssertEqual(p["type"] as? String, "wireguard")
        XCTAssertEqual(p["name"] as? String, "WireGuard wg.example.com")
    }
}
