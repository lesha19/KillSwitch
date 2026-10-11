import XCTest

/// The panel's Xray config for the main way of connecting (ADR 0020).
final class XrayProfileTests: XCTestCase {
    func testJSONLinkIsTheSubscriptionPlusJson() {
        let cases = [
            ("https://sub.example.com/api/sub/AbC123", "https://sub.example.com/api/sub/AbC123/json"),
            ("https://sub.example.com/api/sub/AbC123/", "https://sub.example.com/api/sub/AbC123/json"),
            ("https://sub.example.com/AbC123?x=1", "https://sub.example.com/AbC123/json?x=1"),
            ("https://sub.example.com/api/sub/AbC123/json", "https://sub.example.com/api/sub/AbC123/json"),
        ]
        for (link, json) in cases {
            XCTAssertEqual(XrayProfile.url(for: URL(string: link)!).absoluteString, json, link)
        }
    }

    func testReadsTheHostsOfTheArray() throws {
        let body = """
        [{"remarks":"🇱🇹Литва","outbounds":[{"tag":"LT_1","protocol":"vless"}]},
         {"outbounds":[{"tag":"x","protocol":"trojan"}]}]
        """
        let profile = try XrayProfile(body: body)
        XCTAssertEqual(profile.servers, ["🇱🇹Литва", "#2"], "a host without remarks is named by its place, as Helper/ks does")
        XCTAssertEqual(profile.data, Data(body.utf8), "handed to the helper as it came")
    }

    func testRefusesWhatIsNotTheXrayJSON() {
        XCTAssertThrowsError(try XrayProfile(body: "<html><body>hi</body></html>")) { XCTAssertEqual($0 as? XrayProfile.Failure, .html) }
        XCTAssertThrowsError(try XrayProfile(body: "proxies:\n  - name: a\n")) { XCTAssertEqual($0 as? XrayProfile.Failure, .notXray) }
        XCTAssertThrowsError(try XrayProfile(body: "dmxlc3M6Ly8=")) { XCTAssertEqual($0 as? XrayProfile.Failure, .notXray) }
        XCTAssertThrowsError(try XrayProfile(body: #"{"outbounds":[]}"#)) { XCTAssertEqual($0 as? XrayProfile.Failure, .notXray) }
        XCTAssertThrowsError(try XrayProfile(body: "[]")) { XCTAssertEqual($0 as? XrayProfile.Failure, .noServers) }
        XCTAssertThrowsError(try XrayProfile(body: #"[{"remarks":"a"}]"#)) { XCTAssertEqual($0 as? XrayProfile.Failure, .notXray) }
    }

    func testFailureTextsArePlainWords() {
        for failure in [XrayProfile.Failure.html, .notXray, .noServers] {
            let text = failure.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertNil(text.range(of: "xray", options: .caseInsensitive), text)
            XCTAssertNil(text.range(of: "json", options: .caseInsensitive), text)
        }
    }

    func testCoreChoiceFromTheSettingsFile() {
        XCTAssertEqual(CoreChoice.read(settings: nil), .mihomo, "no file: what every install before had")
        XCTAssertEqual(CoreChoice.read(settings: "lan=1\n"), .mihomo)
        XCTAssertEqual(CoreChoice.read(settings: "core=xray\nlan=0\n"), .xray)
        XCTAssertEqual(CoreChoice.read(settings: "core=xray\ncore=mihomo\n"), .mihomo, "the last line counts, as in ks")
        XCTAssertEqual(CoreChoice.read(settings: "core=sing-box\n"), .mihomo)
        XCTAssertEqual(CoreChoice.xray.binary, "/Library/KillSwitch/core/xray")
        XCTAssertEqual(CoreChoice.xray.config, "/Library/KillSwitch/core/xray.json")
        XCTAssertEqual(CoreChoice.mihomo.config, "/Library/KillSwitch/core/config.yaml")
        XCTAssertFalse(CoreChoice.xray.hasConnections)
        XCTAssertTrue(CoreChoice.mihomo.hasConnections)
    }

    func testDoubleVPNOnlyWithMihomoButAlwaysOff() {
        XCTAssertTrue(CoreChoice.mihomo.canTurnOnMultihop)
        XCTAssertFalse(CoreChoice.xray.canTurnOnMultihop, "ks set multihop refuses an entry with Xray")
    }

    func testServersBeforeTheCoreRuns() {
        let proxies = CoreProxies(xrayServers: ["🇱🇹Литва", "DE"])
        XCTAssertEqual(proxies.mainGroup?.name, CoreProxies.xrayGroup)
        XCTAssertEqual(proxies.mainGroup?.all, ["🇱🇹Литва", "DE"])
        XCTAssertEqual(proxies.mainGroup?.selectable, true)
        XCTAssertEqual(proxies.servers, ["🇱🇹Литва", "DE"])
    }

    /// `ks core proxies` with Xray: one selector of the subscription's hosts (Helper/ks core_proxies).
    func testHelpersXrayAnswer() throws {
        let json = #"{"proxies":{"DE":{"type":"Xray"},"Сервер":{"all":["🇱🇹Литва","DE"],"now":"DE","type":"Selector"},"🇱🇹Литва":{"type":"Xray"}}}"#
        let proxies = try CoreProxies(data: Data(json.utf8))
        XCTAssertEqual(proxies.mainGroup?.name, CoreProxies.xrayGroup)
        XCTAssertEqual(proxies.leaf(of: CoreProxies.xrayGroup), "DE")
    }
}
