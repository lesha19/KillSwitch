import XCTest

/// «Трафик»: the subscription's rules as the window shows them, the helper's report, the live
/// connections and «Проверить адрес» (ADR 0013).
final class RoutingRuleTests: XCTestCase {
    func testPlainRule() throws {
        let rule = try XCTUnwrap(RoutingRule("DOMAIN-SUFFIX, ru ,DIRECT"))
        XCTAssertEqual(rule.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rule.payload, "ru")
        XCTAssertEqual(rule.route, .direct)
        XCTAssertEqual(rule.typeTitle, "Домен и поддомены")
    }

    func testOptionsAndTargets() throws {
        let geoip = try XCTUnwrap(RoutingRule("GEOIP,RU,DIRECT,no-resolve"))
        XCTAssertTrue(geoip.noResolve)
        XCTAssertEqual(RoutingRule("MATCH,🚀 Выбор")?.route, .vpn("🚀 Выбор"))
        XCTAssertEqual(RoutingRule("MATCH,🚀 Выбор")?.payload, "")
        XCTAssertEqual(RoutingRule("DOMAIN,a.com,REJECT")?.route, .block)
        XCTAssertEqual(RoutingRule("DOMAIN,a.com,reject-drop")?.route.kind, .block)
        XCTAssertEqual(RoutingRule("DOMAIN,a.com,PASS")?.route, .pass)
        XCTAssertNil(RoutingRule("DOMAIN"))
        XCTAssertNil(RoutingRule("DOMAIN,a.com"))
        XCTAssertNil(RoutingRule("MATCH,"))
    }

    func testLogicRule() throws {
        let rule = try XCTUnwrap(RoutingRule("AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"))
        XCTAssertEqual(rule.payload, "((NETWORK,UDP),(DST-PORT,443))")
        XCTAssertEqual(rule.route, .block)
        XCTAssertEqual(rule.conditions.map(\.type), ["NETWORK", "DST-PORT"])
        XCTAssertEqual(rule.payloadText, "Протокол UDP и Порт 443")
        let nested = try XCTUnwrap(RoutingRule("OR,((DOMAIN,a.example),(AND,((NETWORK,TCP),(DST-PORT,80)))),Сервер"))
        XCTAssertEqual(nested.conditions.map(\.type), ["DOMAIN", "AND"])
        XCTAssertEqual(nested.conditions[1].conditions.count, 2)
        XCTAssertNil(RoutingRule("AND,(NETWORK,UDP"))
    }
}

final class RoutingReportTests: XCTestCase {
    /// Trimmed from what Helper/ks core_report writes for Helper/tests/fixtures/ok-routing.json.
    static let sample = Data("""
    {"version":1,
     "rules":[{"rule":"GEOSITE,category-ads-all,REJECT","from":"killswitch"},
              {"rule":"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT","from":"subscription","index":0},
              {"rule":"RULE-SET,ru-inline,DIRECT","from":"subscription","index":2},
              {"rule":"MATCH,Сервер","from":"subscription","index":13}],
     "dropped":[{"section":"profile","item":"mixed-port","reason":"managed"},
                {"section":"rules","index":5,"item":"FOO,bar,DIRECT","reason":"type:FOO"},
                {"section":"rules","index":6,"item":"DOMAIN,x.example,NoSuchGroup","reason":"target:NoSuchGroup"},
                {"section":"rules","index":9,"item":"IP-ASN,13335,DIRECT","reason":"geodata:asn"},
                {"section":"dns","item":"direct-nameserver: system","reason":"bad-value"}],
     "providers":[{"name":"ru-http","type":"http","behavior":"domain","format":"mrs","host":"rules.example.com","interval":86400,"proxy":"KS-DNS"},
                  {"name":"ru-inline","type":"inline","behavior":"domain","count":2,"payload":["+.yandex.ru","+.vk.com"]}],
     "groups":[{"name":"Сервер","type":"select","proxies":["LT","DE","DIRECT"],"from":"subscription"},
               {"name":"KS-DNS","type":"fallback","proxies":["LT","DE"],"from":"killswitch","hidden":true}],
     "proxies":[{"name":"LT","type":"vless"},{"name":"DE","type":"trojan"}],
     "added":[{"kind":"dns-group","name":"KS-DNS","items":["LT","DE"]},
              {"kind":"pinning","items":[{"host":"de.example.com","address":"203.0.113.20"}]},
              {"kind":"unbound","items":["LT"]},
              {"kind":"adblock","items":["GEOSITE,category-ads-all,REJECT"]},
              {"kind":"loop-guard","items":["IP-CIDR,198.18.0.0/16,REJECT,no-resolve"]}],
     "sniffer":{"from":"subscription","value":{"enable":true,"sniff":{"TLS":{"ports":[443,8443]}}}},
     "dns":{"servers":["https://1.1.1.1/dns-query#KS-DNS"],
            "taken":{"direct-nameserver":["77.88.8.8"],"respect-rules":true,"nameserver-policy":{"+.ru":["https://dns.yandex.ru/..."]}}},
     "egress":["rules","dns"]}
    """.utf8)

    func testDecodesTheHelpersReport() throws {
        let report = try RoutingReport(data: Self.sample)
        XCTAssertEqual(report.subscriptionRules.map(\.index), [0, 2, 13], "the subscription's order is kept")
        XCTAssertEqual(report.ownRules.map(\.rule), ["GEOSITE,category-ads-all,REJECT"])
        XCTAssertEqual(report.provider("ru-inline")?.payload, ["+.yandex.ru", "+.vk.com"])
        XCTAssertEqual(report.provider("ru-http")?.typeTitle, "загружается")
        XCTAssertEqual(report.groups.last?.hidden, true)
        XCTAssertEqual(report.sniffer.from, .subscription)
        XCTAssertEqual(report.egress, ["rules", "dns"])
    }

    func testAddedSplitsTidyingAndPins() throws {
        let report = try RoutingReport(data: Self.sample)
        XCTAssertEqual(report.additions.map(\.kind), ["dns-group", "pinning", "adblock", "loop-guard"])
        XCTAssertEqual(report.tidied.map(\.kind), ["unbound"])
        XCTAssertEqual(report.additions[1].lines, ["de.example.com → 203.0.113.20"])
        XCTAssertEqual(report.additions[0].lines, ["LT", "DE"])
        for added in report.added { XCTAssertFalse(added.why.isEmpty, added.kind) }
        XCTAssertEqual(report.additions[2].title, "Блокировка — твой выбор")
        XCTAssertEqual(report.additions[3].title, "Защита от петли")
    }

    /// ADR 0031: the own DoH server, named by its host only (its path can hold an account id).
    func testOwnDoHAddition() throws {
        let added = try JSONDecoder().decode(RoutingReport.Added.self, from: Data(#"{"kind":"doh","items":["dns.example.com"]}"#.utf8))
        XCTAssertEqual(added.title, "Свой DNS-over-HTTPS — твой выбор")
        XCTAssertEqual(added.lines, ["dns.example.com"])
        XCTAssertFalse(added.why.isEmpty)
    }

    /// ADR 0033: own addresses of sites, named as the person's choice.
    func testOwnHostsAddition() throws {
        let added = try JSONDecoder().decode(RoutingReport.Added.self, from: Data(#"{"kind":"hosts","items":["nas.lan → 192.168.1.10"]}"#.utf8))
        XCTAssertEqual(added.title, "Свои адреса сайтов — твой выбор")
        XCTAssertFalse(added.why.isEmpty)
    }

    func testDroppedReasonsInWords() throws {
        let report = try RoutingReport(data: Self.sample)
        XCTAssertEqual(report.dropped.map(\.reasonText), [
            "Это KillSwitch задаёт сам",
            "Ядро не знает тип правила «FOO»",
            "В подписке нет сервера или группы «NoSuchGroup»",
            "Нужна база сетей (ASN), в KillSwitch её нет",
            "Значение не прошло проверку",
        ])
        XCTAssertEqual(RoutingReport.Dropped.reasonText("something-new"), "something-new")
        // the own DoH and own addresses of sites replace the template's (ADR 0031, 0033): never the raw code
        XCTAssertEqual(RoutingReport.Dropped.reasonText("own-doh"), "Вместо него — твой DNS-over-HTTPS")
        XCTAssertEqual(RoutingReport.Dropped.reasonText("own-hosts"), "Вместо него — твой адрес сайта")
    }

    func testTakenDNSAndEgressAsText() throws {
        let report = try RoutingReport(data: Self.sample)
        XCTAssertEqual(report.dnsRows.map(\.key), ["direct-nameserver", "nameserver-policy", "respect-rules"])
        XCTAssertEqual(report.dnsRows.map(\.value), ["77.88.8.8", "+.ru: https://dns.yandex.ru/...", "да"])
        XCTAssertEqual(report.sniffer.value.text, "enable: да; sniff: TLS: ports: 443, 8443")
        XCTAssertEqual(report.egressReasons.count, 2)
    }

    func testKeysTheAppLeftOutComeFirst() throws {
        let report = try RoutingReport(data: Self.sample)
        let dropped = report.dropped(leftOut: ["listeners", "tun"])
        XCTAssertEqual(dropped.prefix(2).map(\.reasonText), ["Этого KillSwitch из подписки не берёт", "Это KillSwitch задаёт сам"])
        XCTAssertEqual(dropped.prefix(2).map(\.sectionTitle), ["Раздел подписки", "Раздел подписки"])
        XCTAssertEqual(dropped.count, report.dropped.count + 2)
    }

    func testNoReportFromAnOlderHelper() {
        XCTAssertNil(RoutingReport.read(path: "/nonexistent/routing.json"))
    }
}

final class CoreConnectionsTests: XCTestCase {
    static let sample = Data("""
    {"connections":[
      {"id":"a","host":"ya.ru","ip":"5.255.255.242","port":"443","network":"tcp","process":"Safari",
       "processPath":"/Applications/Safari.app/Contents/MacOS/Safari","rule":"DomainSuffix","rulePayload":"ru",
       "chains":["DIRECT"],"upload":100,"download":900,"start":"2026-10-10T10:00:00.123456789+03:00"},
      {"id":"b","host":"","ip":"142.250.1.1","port":"443","network":"udp","process":"",
       "processPath":"/usr/local/bin/curl","rule":"Match","rulePayload":"",
       "chains":["🇳🇱 NL 1","Сервер"],"upload":10,"download":40,"start":"2026-10-10T07:00:05Z"},
      {"id":"c","host":"ads.example","ip":"","port":"443","network":"tcp","process":"Firefox",
       "processPath":"","rule":"GeoSite","rulePayload":"category-ads-all",
       "chains":["REJECT"],"upload":0,"download":0,"start":"2026-10-10T07:00:01Z"}],
     "uploadTotal":1,"downloadTotal":2,"providers":{"ru-http":{"count":1234,"updatedAt":"2026-10-10T09:00:00Z"}}}
    """.utf8)

    func testDecodes() throws {
        let list = try CoreConnections(data: Self.sample)
        let safari = list.connections[0]
        XCTAssertEqual(safari.route, .direct)
        XCTAssertEqual(safari.ruleText, "Домен и поддомены: ru")
        XCTAssertEqual(safari.bundlePath, "/Applications/Safari.app")
        XCTAssertEqual(try XCTUnwrap(safari.startDate).timeIntervalSince1970, 1_791_615_600.123, accuracy: 0.001)
        let curl = list.connections[1]
        XCTAssertEqual(curl.route, .vpn("🇳🇱 NL 1"))
        XCTAssertEqual(curl.group, "Сервер")
        XCTAssertEqual(curl.destination, "142.250.1.1")
        XCTAssertEqual(curl.programName, "curl")
        XCTAssertNil(curl.bundlePath)
        XCTAssertEqual(curl.ruleText, "Всё остальное")
        XCTAssertEqual(curl.duration(now: Date(timeIntervalSince1970: 1_791_615_615)), 10)
        XCTAssertEqual(list.providers["ru-http"]?.count, 1234)
    }

    func testRuleTypes() {
        XCTAssertEqual(CoreConnections.Connection.ruleType("GeoIP"), "GEOIP")
        XCTAssertEqual(CoreConnections.Connection.ruleType("IPCIDR6"), "IP-CIDR")
        XCTAssertEqual(CoreConnections.Connection.ruleType("RuleSet"), "RULE-SET")
        XCTAssertEqual(CoreConnections.Connection.ruleType("Unknown"), "Unknown")
    }

    func testFilterSearchAndSummary() throws {
        let list = try CoreConnections(data: Self.sample)
        XCTAssertEqual(list.filtered(kind: nil, search: "").map(\.id), ["b", "c", "a"], "newest first")
        XCTAssertEqual(list.filtered(kind: .vpn, search: "").map(\.id), ["b"])
        XCTAssertEqual(list.filtered(kind: .block, search: "").map(\.id), ["c"])
        XCTAssertEqual(list.filtered(kind: nil, search: " SAFARI ").map(\.id), ["a"])
        XCTAssertEqual(list.filtered(kind: nil, search: "сервер").map(\.id), ["b"])
        XCTAssertEqual(list.bytesByKind, [.direct: 1000, .vpn: 50, .block: 0])
    }
}

final class AddressCheckTests: XCTestCase {
    private let report = try! RoutingReport(data: RoutingReportTests.sample)
    private func context(geosite: [String: [String]] = [:], geoip: [String: String] = [:]) -> AddressCheck.Context {
        AddressCheck.Context(providers: report.providers,
                             geosite: { category, host in geosite[category].map { $0.contains { host == $0 || host.hasSuffix("." + $0) } } },
                             geoip: { ip, country in geoip[ip].map { $0 == country } })
    }
    private func check(_ text: String, _ rules: [String], _ ctx: AddressCheck.Context? = nil) -> AddressCheck.Result {
        AddressCheck.check(AddressCheck.Target(text)!, rules: rules, context: ctx ?? context())
    }

    func testTargets() {
        XCTAssertEqual(AddressCheck.Target("https://User@Mail.YA.ru:8443/path?q#x")?.host, "mail.ya.ru")
        XCTAssertEqual(AddressCheck.Target(" 77.88.8.8:53 ")?.ip, "77.88.8.8")
        XCTAssertEqual(AddressCheck.Target("[2a02:6b8::feed:0ff]:443")?.ip, "2a02:6b8::feed:0ff")
        XCTAssertEqual(AddressCheck.Target("example.com.")?.host, "example.com")
        XCTAssertNil(AddressCheck.Target(""))
        XCTAssertNil(AddressCheck.Target("not a host"))
        XCTAssertNil(AddressCheck.Target("nodots"))
    }

    func testDomainRules() {
        let rules = ["DOMAIN,exact.example,REJECT", "DOMAIN-SUFFIX,ru,DIRECT", "DOMAIN-KEYWORD,google,Сервер", "MATCH,Сервер"]
        XCTAssertEqual(check("exact.example", rules).route, .block)
        XCTAssertEqual(check("sub.exact.example", rules).position, 3)
        XCTAssertEqual(check("mail.ya.ru", rules).position, 1)
        XCTAssertEqual(check("yaru.com", rules).position, 3, "a suffix is a whole label")
        XCTAssertEqual(check("www.google.com", rules).route, .vpn("Сервер"))
        XCTAssertTrue(check("mail.ya.ru", rules).isExact)
    }

    func testNoMatchGoesDirect() {
        let result = check("a.example", ["DOMAIN,b.example,Сервер"])
        XCTAssertNil(result.position)
        XCTAssertEqual(result.route, .direct)
    }

    func testAddressesAndCountries() {
        let rules = ["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "GEOIP,RU,DIRECT", "MATCH,Сервер"]
        XCTAssertEqual(check("10.1.2.3", rules).position, 0)
        let ctx = context(geoip: ["77.88.8.8": "RU", "8.8.8.8": "US"])
        XCTAssertEqual(check("77.88.8.8", rules, ctx).position, 1)
        XCTAssertEqual(check("8.8.8.8", rules, ctx).position, 2)
        XCTAssertEqual(check("192.168.1.1", ["GEOIP,LAN,DIRECT", "MATCH,Сервер"]).position, 0)
    }

    func testANameMeetingAnAddressRuleIsACaveat() {
        // the core resolves the name for GEOIP without no-resolve: honest «may be»
        let result = check("example.com", ["GEOIP,RU,DIRECT", "IP-CIDR,1.0.0.0/8,DIRECT,no-resolve", "MATCH,Сервер"])
        XCTAssertEqual(result.position, 2)
        XCTAssertEqual(result.caveats.map(\.position), [0])
        XCTAssertFalse(result.isExact)
    }

    func testGeosite() {
        let ctx = context(geosite: ["category-ru": ["yandex.ru"]])
        let rules = ["GEOSITE,category-ru,DIRECT", "MATCH,Сервер"]
        XCTAssertEqual(check("music.yandex.ru", rules, ctx).position, 0)
        XCTAssertEqual(check("example.com", rules, ctx).position, 1)
        XCTAssertFalse(check("example.com", ["GEOSITE,other,DIRECT", "MATCH,Сервер"], ctx).isExact, "no data: a caveat")
    }

    func testRuleSets() {
        let rules = ["RULE-SET,ru-inline,DIRECT", "RULE-SET,ru-http,DIRECT", "MATCH,Сервер"]
        XCTAssertEqual(check("vk.com", rules).position, 0)
        let other = check("example.com", rules)
        XCTAssertEqual(other.position, 2)
        XCTAssertEqual(other.caveats.map(\.position), [1], "a downloaded set is not visible here")
    }

    func testLogicAndPrograms() {
        XCTAssertEqual(check("a.example", ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT", "MATCH,Сервер"]).position, 1,
                       "an ordinary visit is TCP")
        XCTAssertEqual(check("a.example", ["AND,((NETWORK,TCP),(DST-PORT,443)),REJECT", "MATCH,Сервер"]).position, 0)
        XCTAssertEqual(check("a.example", ["NOT,((DOMAIN,b.example)),DIRECT"]).position, 0)
        XCTAssertEqual(check("b.example", ["OR,((DOMAIN,a.example),(DOMAIN-SUFFIX,b.example)),Сервер"]).position, 0)
        let app = check("a.example", ["PROCESS-NAME,Telegram,DIRECT", "MATCH,Сервер"])
        XCTAssertEqual(app.position, 1)
        XCTAssertEqual(app.caveats.first?.reason, "зависит от программы")
    }

    func testDomainSetEntries() {
        XCTAssertTrue(AddressCheck.domainSet("+.ya.ru", "ya.ru"))
        XCTAssertTrue(AddressCheck.domainSet("+.ya.ru", "mail.ya.ru"))
        XCTAssertFalse(AddressCheck.domainSet(".ya.ru", "ya.ru"))
        XCTAssertTrue(AddressCheck.domainSet("*.ya.ru", "mail.ya.ru"))
        XCTAssertTrue(AddressCheck.ports("80/8080-8880", contain: 8443))
        XCTAssertFalse(AddressCheck.ports("80/8080-8880", contain: 9000))
        XCTAssertTrue(AddressCheck.ports("443,8443", contain: 443))
    }
}

/// The geodata the app ships, when it is in the checkout (Helper/fetch-geodata.sh).
final class GeoDataTests: XCTestCase {
    private var geo: GeoData {
        get throws {
            let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helper")
            let site = helper.appendingPathComponent("geosite.dat"), ip = helper.appendingPathComponent("geoip.metadb")
            guard FileManager.default.fileExists(atPath: site.path), FileManager.default.fileExists(atPath: ip.path) else {
                throw XCTSkip("no geodata: Helper/fetch-geodata.sh")
            }
            return GeoData(site: site, ip: ip)
        }
    }

    func testGeosite() throws {
        let geo = try geo
        XCTAssertEqual(geo.site("category-ru", contains: "music.yandex.ru"), true)
        XCTAssertEqual(geo.site("category-ru", contains: "example.com"), false)
        XCTAssertEqual(geo.site("google", contains: "www.google.com"), true)
        XCTAssertNil(geo.site("google@cn", contains: "www.google.com"))
    }

    func testGeoip() throws {
        let geo = try geo
        XCTAssertEqual(geo.ip("77.88.8.8", inCountry: "RU"), true)
        XCTAssertEqual(geo.ip("77.88.8.8", inCountry: "us"), false)
        XCTAssertEqual(geo.ip("8.8.8.8", inCountry: "RU"), false)
        XCTAssertNil(geo.ip("not-an-ip", inCountry: "RU"))
    }

    func testMissingFiles() {
        let geo = GeoData(site: nil, ip: nil)
        XCTAssertNil(geo.site("category-ru", contains: "ya.ru"))
        XCTAssertNil(geo.ip("77.88.8.8", inCountry: "RU"))
    }
}
