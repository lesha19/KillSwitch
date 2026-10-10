import Foundation
import XCTest

final class ProfileConverterTests: XCTestCase {
    private let yaml = """
    mixed-port: 7890
    external-controller: 127.0.0.1:9090
    secret: hunter2
    tun:
      enable: true
    dns:
      enable: true
    proxies:
      - name: "🇩🇪 Германия"
        type: vless
        server: de.example.com
        port: 443
        uuid: 11111111-2222-3333-4444-555555555555
        udp: yes
        reality-opts:
          short-id: "12:34"
          public-key: abc
      - {name: "🇳🇱 Нидерланды", type: trojan, server: 1.2.3.4, port: 8443, password: on, short: 0x1F}
    proxy-groups:
      - name: PROXY
        type: select
        proxies: ["🇩🇪 Германия", "🇳🇱 Нидерланды"]
    rule-providers:
      ru:
        type: http
        behavior: domain
        url: https://example.com/ru.yaml
        interval: 86400
    rules:
      - DOMAIN-SUFFIX,ru,DIRECT
      - MATCH,PROXY
    listeners:
      - name: in
        type: socks
        port: 1080
    """

    func testKeepsOnlyTheFourKeys() throws {
        let profile = try ProfileConverter.profile(fromSubscription: yaml)
        XCTAssertEqual(Set(profile.keys), ["proxies", "proxy-groups", "rules", "rule-providers"])
    }

    func testJSONRoundTripsAndKeepsTypes() throws {
        let data = try ProfileConverter.json(ProfileConverter.profile(fromSubscription: yaml))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proxies = try XCTUnwrap(object["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 2)
        XCTAssertEqual(proxies[0]["port"] as? Int, 443)
        XCTAssertEqual(proxies[0]["name"] as? String, "🇩🇪 Германия")
        // YAML 1.2 like mihomo: "yes"/"on" stay strings, "12:34" is not sexagesimal
        XCTAssertEqual(proxies[0]["udp"] as? String, "yes")
        XCTAssertEqual((proxies[0]["reality-opts"] as? [String: Any])?["short-id"] as? String, "12:34")
        XCTAssertEqual(proxies[1]["password"] as? String, "on")
        XCTAssertEqual(proxies[1]["short"] as? Int, 31)
        let rules = try XCTUnwrap(object["rules"] as? [String])
        XCTAssertEqual(rules.last, "MATCH,PROXY")
    }

    func testTrueFalseAreBooleans() throws {
        let profile = try ProfileConverter.profile(fromSubscription: """
        proxies:
          - {name: a, type: ss, server: 1.1.1.1, port: 1, cipher: aes-128-gcm, password: x, udp: true, tfo: false}
        """)
        let proxy = try XCTUnwrap((profile["proxies"] as? [[String: Any]])?.first)
        XCTAssertEqual(proxy["udp"] as? Bool, true)
        XCTAssertEqual(proxy["tfo"] as? Bool, false)
    }

    func testRejectsProfileWithoutProxies() {
        XCTAssertThrowsError(try ProfileConverter.profile(fromSubscription: "rules:\n  - MATCH,DIRECT\n"))
    }

    func testRejectsHTML() {
        XCTAssertThrowsError(try ProfileConverter.profile(fromSubscription: "<!DOCTYPE html><html><body>hi</body></html>"))
    }

    func testBase64LinkListBecomesProfile() throws {
        let links = """
        trojan://pass@5.6.7.8:443?sni=a.example#One
        ss://\(Data("aes-256-gcm:pw".utf8).base64EncodedString())@9.9.9.9:8388#Two
        """
        let body = Data(links.utf8).base64EncodedString()
        let profile = try ProfileConverter.profile(fromSubscription: body)
        let proxies = try XCTUnwrap(profile["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.map { $0["name"] as? String }, ["One", "Two"])
        let groups = try XCTUnwrap(profile["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["proxies"] as? [String], ["One", "Two"])
        XCTAssertEqual(profile["rules"] as? [String], ["MATCH,\(ProfileMerger.defaultGroup)"])
    }
}
