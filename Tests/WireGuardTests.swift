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
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:2", name: nil))
    }

    func testAmneziaRejected() {
        XCTAssertThrowsError(try WireGuard.parse(conf: "[Interface]\nPrivateKey = \(priv)\nAddress = 10.0.0.2\nJc = 4\n[Peer]\nPublicKey = \(pub)\nEndpoint = h:1", name: nil))
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
