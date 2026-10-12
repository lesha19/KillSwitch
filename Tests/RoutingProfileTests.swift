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

    /// Review N1: a profile's link may carry a token, so it is kept in the keychain as the
    /// subscription link is, never in UserDefaults; links stored there before move on first load.
    func testLinksKeptOutOfUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoutingProfileTests-\(UUID().uuidString)"))
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let links = RoutingProfiles.LinkStore(read: { box.data }, write: { box.data = $0; return true })
        var p = try RoutingProfile.parse(incy)
        p.url = "https://example.com/r.json?token=SECRET"
        let hand = try RoutingProfile.parse("{\"Name\":\"B\",\"BlockSites\":[\"domain:ads.example\"]}")
        RoutingProfiles.save([p, hand], defaults, links: links)
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: RoutingProfiles.listKey)), as: UTF8.self).contains("SECRET"))
        XCTAssertTrue(String(decoding: try XCTUnwrap(box.data), as: UTF8.self).contains("SECRET"))
        XCTAssertEqual(RoutingProfiles.load(defaults, links: links), [p, hand])
        XCTAssertEqual(RoutingProfiles.active(defaults)?.id, nil)
        defaults.set(p.id.uuidString, forKey: RoutingProfiles.activeKey)
        XCTAssertEqual(RoutingProfiles.active(defaults)?.name, "RU напрямую")
        RoutingProfiles.save([hand], defaults, links: links)
        XCTAssertNil(box.data, "no links left: nothing in the keychain")

        // stored before: the link in UserDefaults moves to the keychain on load
        defaults.set(try JSONEncoder().encode([p]), forKey: RoutingProfiles.listKey)
        XCTAssertEqual(RoutingProfiles.load(defaults, links: links), [p])
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: RoutingProfiles.listKey)), as: UTF8.self).contains("SECRET"))
        XCTAssertTrue(String(decoding: try XCTUnwrap(box.data), as: UTF8.self).contains("SECRET"))
    }

    /// Re-review nit: a keychain read that fails (locked, an error) is not «no links»: a save
    /// then must not delete them.
    func testFailedKeychainReadKeepsTheLinks() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoutingProfileTests-\(UUID().uuidString)"))
        struct Locked: Error {}
        final class Box: @unchecked Sendable { var data: Data?; var fail = false }
        let box = Box()
        let links = RoutingProfiles.LinkStore(read: { if box.fail { throw Locked() }; return box.data },
                                              write: { box.data = $0; return true })
        var p = try RoutingProfile.parse(incy)
        p.url = "https://example.com/r.json?token=SECRET"
        RoutingProfiles.save([p], defaults, links: links)
        box.fail = true
        var loaded = RoutingProfiles.load(defaults, links: links)
        XCTAssertNil(loaded[0].url, "unknown while the keychain does not answer")
        loaded[0].name = "renamed"
        RoutingProfiles.save(loaded, defaults, links: links)
        XCTAssertTrue(String(decoding: try XCTUnwrap(box.data), as: UTF8.self).contains("SECRET"), "not written over")
        box.fail = false
        RoutingProfiles.save(loaded, defaults, links: links)
        XCTAssertEqual(RoutingProfiles.load(defaults, links: links).first?.url, p.url, "a save after it keeps the link it did not load")
        RoutingProfiles.save([], defaults, links: links)
        XCTAssertNil(box.data, "a profile deleted: its link goes")
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

    /// Re-review F4: the helper says which part of a refused change is the profile's
    /// (refresh_check, direct_parts); the app names it from that, never by guessing.
    func testRefusalSaysWhichPartChanged() {
        let line = { (who: String) in "Профиль меняет, что идёт мимо VPN (DIRECT)\(who): нужно подтверждение паролем администратора\n" }
        XCTAssertEqual(RefreshOutcome(status: 3, output: line(" [profile]")), .routingChanged(.profile))
        XCTAssertEqual(RefreshOutcome(status: 3, output: line(" [subscription]")), .routingChanged(.subscription))
        XCTAssertEqual(RefreshOutcome(status: 3, output: line(" [profile,subscription]")), .routingChanged(.both))
        XCTAssertEqual(RefreshOutcome(status: 3, output: line("")), .routingChanged(.subscription), "an older helper: the subscription's")
    }

    func testNoticesNameTheProfile() {
        var input = HomeNotice.Input(otherVPN: false, usage: nil, newServers: true, filterIncomplete: false, filterDismissed: false, now: Date())
        input.routingChanged = true
        input.routingSource = .profile
        input.routingProfileName = "RU напрямую"
        let notice = HomeNotice.pick(input)
        XCTAssertEqual(notice, .profileRouting(name: "RU напрямую", subscriptionToo: false))
        XCTAssertTrue(notice?.title.contains("«RU напрямую»") == true, notice?.title ?? "")
        // re-review 2 N-B: only the profile's lines differ, but the provider may have moved what
        // they point to (its groups, its freedom outbounds): the text does not rule it out
        XCTAssertTrue(notice?.message.contains("подписк") == true, notice?.message ?? "")
        XCTAssertTrue(notice?.message.contains("До подтверждения действуют прежние") == true, notice?.message ?? "")
        input.routingSource = .both
        let both = HomeNotice.pick(input)
        XCTAssertEqual(both, .profileRouting(name: "RU напрямую", subscriptionToo: true))
        XCTAssertTrue(both?.title.contains("Подписка и профиль «RU напрямую»") == true, both?.title ?? "")
        XCTAssertTrue(both?.message.contains("провайдер") == true, "the provider's part is told")
        input.routingProfileName = nil
        XCTAssertTrue(HomeNotice.pick(input)?.title.contains("профиль маршрутизации") == true, "turned off: no name")
        input.routingSource = .subscription
        XCTAssertEqual(HomeNotice.pick(input), .routingChanged)

        XCTAssertEqual(UserNotice.profileRouting.action, .approve)
        XCTAssertEqual(UserNotice.profileRouting.setting, .subscription)
        XCTAssertNotEqual(UserNotice.profileRouting.key, UserNotice.routingChanged.key)
        XCTAssertFalse(UserNotice.profileRouting.title.contains("Подписка"))
        XCTAssertFalse(UserNotice.profileRouting.body.contains("«напрямую» заработают"), "also when a profile is turned off")
        XCTAssertTrue(UserNotice.profileRouting.body.contains("подписк"), UserNotice.profileRouting.body)
    }

    /// Re-review F5: a fetch holds `updating` (subscription updates, the picker wait for it), so
    /// a host that answers a byte at a time must not keep it: one deadline for the whole fetch.
    func testFetchHasAnOverallDeadline() {
        let c = RoutingProfile.fetchConfiguration()
        XCTAssertEqual(c.timeoutIntervalForResource, 60)
        XCTAssertEqual(c.timeoutIntervalForRequest, 30)
        XCTAssertEqual(c.requestCachePolicy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData)
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
        // review N5: an http link pasted is told apart from text that is no profile at all
        XCTAssertThrowsError(try RoutingProfile.parse(" HTTP://example.com/r.json")) { XCTAssertEqual($0 as? RoutingProfile.Problem, .insecureLink) }
        XCTAssertTrue(RoutingProfile.Problem.insecureLink.message.contains("https"))
        XCTAssertThrowsError(try RoutingProfile.parse("ftp://example.com/r.json")) { XCTAssertEqual($0 as? RoutingProfile.Problem, .notProfile) }
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
