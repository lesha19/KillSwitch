import XCTest
@testable import KillSwitch

/// Named routing profiles (ADR 0034, #30): what the app reads (the Happ/INCY routing format, as
/// JSON, base64 or a happ:// / incy:// link) and what it hands the helper ("x-ks-routing").
final class RoutingProfileTests: XCTestCase {
    private let incy = """
    {"Name":"RU напрямую","GlobalProxy":"true","RouteOrder":"block-direct-proxy",
     "DirectSites":["geosite:category-ru","domain:yandex.ru"],"DirectIp":["geoip:ru"],
     "ProxySites":["geosite:youtube"],"ProxyIp":[],"BlockSites":["geosite:category-ads-all"],"BlockIp":[],
     "RemoteDNSType":"DoH","RemoteDNSDomain":"https://dns.example/dns-query","DnsHosts":{"a.example":"1.2.3.4"},
     "Geoipurl":"https://example.com/geoip.dat","DomainStrategy":"IPIfNonMatch","FakeDNS":"false","LastUpdated":"1"}
    """

    func testReadsTheRoutingFormat() throws {
        let p = try RoutingProfile.parse(incy)
        XCTAssertEqual(p.name, "RU напрямую")
        XCTAssertEqual(p.direct, .init(sites: ["geosite:category-ru", "domain:yandex.ru"], ips: ["geoip:ru"]))
        XCTAssertEqual(p.proxy, .init(sites: ["geosite:youtube"], ips: []))
        XCTAssertEqual(p.block, .init(sites: ["geosite:category-ads-all"], ips: []))
        XCTAssertEqual(p.order, ["block", "direct", "proxy"])
        XCTAssertTrue(p.sendsDirect)
        // what KillSwitch does not take is named, never applied
        XCTAssertEqual(Set(p.ignored), ["DNS", "DnsHosts", "Geoipurl", "DomainStrategy"])
    }

    func testLinksAndBase64() throws {
        let b64 = Data(incy.utf8).base64EncodedString()
        for text in [b64, "happ://routing/add/\(b64)", "happ://routing/onadd/\(b64)", "incy://routing/add/\(b64)", "  \(incy)\n"] {
            XCTAssertEqual(try RoutingProfile.parse(text).name, "RU напрямую", String(text.prefix(30)))
        }
        // base64url without padding, as such links often are
        let url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try RoutingProfile.parse("happ://routing/add/\(url)").name, "RU напрямую")
    }

    func testRefusesWhatIsNotAProfile() {
        XCTAssertThrowsError(try RoutingProfile.parse("hello"))
        XCTAssertThrowsError(try RoutingProfile.parse("{\"Name\":\"x\"}"), "nothing in it")
        XCTAssertThrowsError(try RoutingProfile.parse("{\"Name\":\"x\",\"DirectSites\":\"geosite:ru\"}"), "a list must be a list")
        XCTAssertThrowsError(try RoutingProfile.parse("{\"Name\":\"x\",\"DirectSites\":[\"a\\nb\"]}"), "control characters")
        let many = (0...10_000).map { "\"domain:a\($0).example\"" }.joined(separator: ",")
        XCTAssertThrowsError(try RoutingProfile.parse("{\"Name\":\"x\",\"DirectSites\":[\(many)]}"), "more than 10000 entries")
    }

    func testGlobalProxyOffIsNotTaken() throws {
        // the format's «everything else direct»: never by a profile, the subscription decides the rest
        let p = try RoutingProfile.parse("{\"Name\":\"x\",\"GlobalProxy\":\"false\",\"BlockSites\":[\"domain:ads.example\"]}")
        XCTAssertEqual(p.ignored, ["GlobalProxy"])
        XCTAssertFalse(p.sendsDirect)
        XCTAssertEqual(p.order, ["block", "proxy", "direct"], "the format's default order")
    }

    func testNameIsCleaned() throws {
        XCTAssertEqual(try RoutingProfile.parse("{\"Name\":\"  \",\"BlockIp\":[\"10.0.0.0/8\"]}").name, "Профиль")
        let long = String(repeating: "я", count: 100)
        XCTAssertEqual(try RoutingProfile.parse("{\"Name\":\"\(long)\",\"BlockIp\":[\"10.0.0.0/8\"]}").name.count, 64)
        // the helper counts code points (Helper/ks routing_hint): a flag is one character of two
        let flags = String(repeating: "🇷🇺", count: 40)
        XCTAssertLessThanOrEqual(try RoutingProfile.parse("{\"Name\":\"\(flags)\",\"BlockIp\":[\"10.0.0.0/8\"]}").name.unicodeScalars.count, 64)
    }

    func testHintForTheHelper() throws {
        let p = try RoutingProfile.parse(incy)
        let hint = p.hint
        XCTAssertEqual(hint["name"] as? String, "RU напрямую")
        XCTAssertEqual(hint["order"] as? [String], ["block", "direct", "proxy"])
        XCTAssertEqual((hint["direct"] as? [String: [String]])?["ips"], ["geoip:ru"])
        XCTAssertNil((hint["proxy"] as? [String: [String]])?["ips"], "empty lists left out")
        XCTAssertNil((hint["block"] as? [String: [String]])?["ips"])

        let profile: Profile = ["proxies": [], "rules": ["MATCH,DIRECT"]]
        XCTAssertEqual((RoutingProfiles.adding(p, to: profile)["x-ks-routing"] as? [String: Any])?["name"] as? String, "RU напрямую")
        XCTAssertNil(RoutingProfiles.adding(nil, to: profile)["x-ks-routing"], "«Как в подписке»: nothing added")
    }

    func testHintForXray() throws {
        let p = try RoutingProfile.parse(incy)
        let panel = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": []], ["remarks": "B", "outbounds": []]])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingProfiles.addingXray(p, to: panel)) as? [[String: Any]])
        XCTAssertEqual((out[0]["x-ks-routing"] as? [String: Any])?["name"] as? String, "RU напрямую", "in the first config")
        XCTAssertNil(out[1]["x-ks-routing"])
        XCTAssertEqual(RoutingProfiles.addingXray(nil, to: panel), panel, "«Как в подписке»: the panel's bytes as they are")
        XCTAssertEqual(RoutingProfiles.addingXray(p, to: Data("{}".utf8)), Data("{}".utf8), "not an array: left alone")
    }

    /// Review S6: a subscription's own "x-ks-routing" would be applied and shown as the person's
    /// profile; it is taken out of every config whatever the person chose.
    func testSubscriptionCannotBringItsOwnProfile() throws {
        let p = try RoutingProfile.parse(incy)
        let theirs: [String: Any] = ["name": "Мой выбор", "direct": ["sites": ["domain:example.com"]]]
        let panel = try JSONSerialization.data(withJSONObject: [["remarks": "A", "outbounds": [], "x-ks-routing": theirs],
                                                                ["remarks": "B", "outbounds": [], "x-ks-routing": theirs]])
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingProfiles.addingXray(nil, to: panel)) as? [[String: Any]])
        XCTAssertEqual(none.count, 2)
        XCTAssertTrue(none.allSatisfy { $0["x-ks-routing"] == nil }, "«Как в подписке»: none left")
        XCTAssertEqual(none[1]["remarks"] as? String, "B")
        let ours = try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingProfiles.addingXray(p, to: panel)) as? [[String: Any]])
        XCTAssertEqual((ours[0]["x-ks-routing"] as? [String: Any])?["name"] as? String, "RU напрямую", "the person's, not theirs")
        XCTAssertNil(ours[1]["x-ks-routing"])

        let profile: Profile = ["proxies": [], "rules": ["MATCH,DIRECT"], "x-ks-routing": theirs]
        XCTAssertNil(RoutingProfiles.adding(nil, to: profile)["x-ks-routing"], "mihomo: taken out too")
        XCTAssertEqual((RoutingProfiles.adding(p, to: profile)["x-ks-routing"] as? [String: Any])?["name"] as? String, "RU напрямую")
    }

    func testStoredList() throws {
        var p = try RoutingProfile.parse(incy)
        p.url = "https://example.com/routing.json"
        let data = try JSONEncoder().encode([p])
        XCTAssertEqual(try JSONDecoder().decode([RoutingProfile].self, from: data), [p])
    }

    func testUpdateKeepsIdentity() throws {
        var old = try RoutingProfile.parse(incy)
        old.url = "https://example.com/r.json"
        let new = try RoutingProfile.parse("{\"Name\":\"Новое\",\"BlockSites\":[\"domain:ads.example\"]}")
        let updated = old.updated(with: new, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(updated.id, old.id)
        XCTAssertEqual(updated.url, old.url)
        XCTAssertEqual(updated.name, "Новое")
        XCTAssertEqual(updated.fetched, Date(timeIntervalSince1970: 100))
        XCTAssertNil(updated.error)
    }

    /// Review S4: a fetch takes up to 30 s, the list can change meanwhile (a profile deleted or
    /// added); its result goes back by id, never by the position it had.
    func testFetchResultGoesBackById() throws {
        let a = try RoutingProfile.parse("{\"Name\":\"A\",\"BlockSites\":[\"domain:a.example\"]}")
        let b = try RoutingProfile.parse("{\"Name\":\"B\",\"BlockSites\":[\"domain:b.example\"]}")
        let c = try RoutingProfile.parse("{\"Name\":\"C\",\"BlockSites\":[\"domain:c.example\"]}")
        // fetched B while it was second; A was deleted meanwhile
        let list = RoutingProfiles.changing(b.id, in: [b, c]) { $0.name = "B2" }
        XCTAssertEqual(list.map(\.name), ["B2", "C"])
        XCTAssertEqual(list.map(\.id), [b.id, c.id])
        // B itself was deleted meanwhile: nothing comes back, nothing else is touched
        XCTAssertEqual(RoutingProfiles.changing(b.id, in: [a, c]) { $0.name = "B2" }, [a, c])
    }

    /// Review S5: a change that waits for the admin is named after where it comes from. The
    /// profile applied last is kept (RoutingProfiles.recordApplied); the one chosen now differs.
    func testWhereAWaitingChangeComesFrom() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoutingProfileTests-\(UUID().uuidString)"))
        let direct = try RoutingProfile.parse(incy)
        let safe = try RoutingProfile.parse("{\"Name\":\"Без рекламы\",\"BlockSites\":[\"domain:ads.example\"]}")
        // nothing applied yet («Как в подписке»)
        XCTAssertEqual(RoutingProfiles.changeSource(active: nil, defaults), .subscription)
        XCTAssertEqual(RoutingProfiles.changeSource(active: direct, defaults), .profile(name: "RU напрямую"))
        XCTAssertEqual(RoutingProfiles.changeSource(active: safe, defaults), .subscription, "it sends nothing direct: the subscription does")
        RoutingProfiles.recordApplied(direct, defaults)
        XCTAssertEqual(RoutingProfiles.changeSource(active: direct, defaults), .subscription, "the same profile: the subscription changed")
        XCTAssertEqual(RoutingProfiles.changeSource(active: nil, defaults), .profileOff, "turned off: its rules stay until the password")
        XCTAssertEqual(RoutingProfiles.changeSource(active: safe, defaults), .profileOff)
        var narrower = direct
        narrower.direct.ips = []
        XCTAssertEqual(RoutingProfiles.changeSource(active: narrower, defaults), .profile(name: "RU напрямую"), "updated from its link")
        RoutingProfiles.recordApplied(nil, defaults)
        XCTAssertEqual(RoutingProfiles.changeSource(active: nil, defaults), .subscription)
    }

    func testNoticesNameTheProfile() {
        var input = HomeNotice.Input(otherVPN: false, usage: nil, newServers: true, filterIncomplete: false, filterDismissed: false, now: Date())
        input.routingChanged = true
        input.routingSource = .profile(name: "RU напрямую")
        let notice = HomeNotice.pick(input)
        XCTAssertEqual(notice, .profileRouting(.profile(name: "RU напрямую")))
        XCTAssertTrue(notice?.title.contains("«RU напрямую»") == true, notice?.title ?? "")
        XCTAssertFalse(notice?.message.contains("провайдер") == true, "not the provider's doing")
        XCTAssertTrue(notice?.message.contains("прежние") == true, "the old rules stay until the password")
        input.routingSource = .profileOff
        XCTAssertTrue(HomeNotice.pick(input)?.message.contains("прежнего профиля") == true)
        input.routingSource = .subscription
        XCTAssertEqual(HomeNotice.pick(input), .routingChanged)

        XCTAssertEqual(UserNotice.profileRouting.action, .approve)
        XCTAssertEqual(UserNotice.profileRouting.setting, .subscription)
        XCTAssertNotEqual(UserNotice.profileRouting.key, UserNotice.routingChanged.key)
        XCTAssertFalse(UserNotice.profileRouting.title.contains("Подписка"))
    }

    func testDueForUpdate() throws {
        var p = try RoutingProfile.parse(incy)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(p.due(now: now), "no link: never fetched")
        p.url = "https://example.com/r.json"
        XCTAssertTrue(p.due(now: now), "never fetched")
        p.fetched = now.addingTimeInterval(-3600)
        XCTAssertFalse(p.due(now: now))
        p.fetched = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(p.due(now: now), "once a day")
    }

    func testOnlyHTTPSLinks() {
        XCTAssertNotNil(RoutingProfile.sourceURL("https://example.com/r.json"))
        XCTAssertNil(RoutingProfile.sourceURL("http://example.com/r.json"))
        XCTAssertNil(RoutingProfile.sourceURL("file:///etc/passwd"))
        XCTAssertNil(RoutingProfile.sourceURL("happ://routing/add/xyz"))
    }

    func testReportNamesTheProfile() throws {
        let json = """
        {"version":1,"rules":[{"rule":"DOMAIN-SUFFIX,ru,DIRECT","from":"profile","profile":"RU напрямую"},
        {"rule":"MATCH,A","from":"subscription","index":0}],"dropped":[],"providers":[],"groups":[],"proxies":[],"added":[],
        "sniffer":{"from":"killswitch","value":{}},"dns":{"servers":[],"taken":{}},"egress":["rules"]}
        """
        let report = try JSONDecoder().decode(RoutingReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.rules[0].from, .profile)
        XCTAssertEqual(report.rules[0].profile, "RU напрямую")
        XCTAssertEqual(report.profileRules.count, 1)
        XCTAssertEqual(report.subscriptionRules.count, 1)
    }
}
