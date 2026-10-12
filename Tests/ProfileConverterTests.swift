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

    func testKeepsOnlyTheRoutingKeys() throws {
        let profile = try ProfileConverter.profile(fromSubscription: yaml)
        // sniffer and dns go to the helper, which takes from them what it validates (ADR 0013)
        XCTAssertEqual(Set(profile.keys), ["proxies", "proxy-groups", "rules", "rule-providers", "dns"])
    }

    func testNamesWhatItLeavesOut() throws {
        let read = try ProfileConverter.read(subscription: yaml)
        XCTAssertEqual(read.leftOut, ["external-controller", "listeners", "mixed-port", "secret", "tun"])
        XCTAssertEqual(try ProfileConverter.read(subscription: "vless://u@h:443#a").leftOut, [])
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

    /// KS-21: aliases are expanded when the YAML is turned into values; a few lines of nested
    /// aliases ("billion laughs") would take all memory. Refused before that, anchors still work.
    func testAliasBombRefused() {
        var yaml = "a0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
        for level in 1...9 {
            yaml += "a\(level): &a\(level) [" + Array(repeating: "*a\(level - 1)", count: 10).joined(separator: ", ") + "]\n"
        }
        yaml += "proxies:\n  - {name: a, type: ss, server: 192.0.2.1, port: 1, cipher: aes-128-gcm, password: p, x: *a9}\n"
        let start = Date()
        XCTAssertThrowsError(try ProfileConverter.read(subscription: yaml)) { error in
            guard case ProfileError.badYAML = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testAnchorsStillWork() throws {
        let yaml = """
        base: &base {type: ss, cipher: aes-128-gcm, password: p, port: 1}
        proxies:
          - {<<: *base, name: a, server: 192.0.2.1}
          - {<<: *base, name: b, server: 192.0.2.2}
        """
        let proxies = try XCTUnwrap(ProfileConverter.read(subscription: yaml).profile["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.map { $0["type"] as? String }, ["ss", "ss"])
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

/// #50: a flat profile of ~19 MB froze the window ~25 s while the main actor parsed it. The app
/// parses through `readInBackground`: the same result, and the main actor stays free meanwhile.
final class ProfileConverterBackgroundTests: XCTestCase {
    private static let big = (1...20_000)
        .map { "vless://00000000-0000-4000-8000-\(String(format: "%012d", $0))@h\($0).example.com:443?security=tls#n\($0)" }
        .joined(separator: "\n")

    func testSameResultAsRead() async throws {
        let body = "vless://u@h:443#a\ntrojan://p@t:443#b"
        let direct = try ProfileConverter.read(subscription: body)
        let background = try await ProfileConverter.readInBackground(subscription: body)
        XCTAssertEqual(background.leftOut, direct.leftOut)
        XCTAssertEqual(try ProfileConverter.json(background.profile), try ProfileConverter.json(direct.profile))
        XCTAssertEqual(background.json, try ProfileConverter.json(direct.profile))
        do {
            _ = try await ProfileConverter.readInBackground(subscription: "<html></html>")
            XCTFail("html accepted")
        } catch {
            XCTAssertEqual(error as? ProfileError, .html)
        }
    }

    @MainActor
    func testMainActorStaysFreeWhileParsing() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let parse = Task { @MainActor in
            let read = try await ProfileConverter.readInBackground(subscription: Self.big)
            return (clock.now, (read.profile["proxies"] as? [Any])?.count ?? 0)
        }
        try await Task.sleep(for: .milliseconds(30))
        let mainFree = await MainActor.run { clock.now }
        let (parsed, count) = try await parse.value
        XCTAssertEqual(count, 20_000)
        XCTAssertGreaterThan(parsed - start, .milliseconds(100), "too small to tell")
        XCTAssertLessThan(mainFree, parsed, "the main actor waited for the parse")
    }
}
