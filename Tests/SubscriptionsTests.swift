import Foundation
import XCTest

/// Several subscriptions (ADR 0036): what the helper is handed, a server's identity, the move
/// from the single-subscription shape.
final class SubscriptionsTests: XCTestCase {
    private let stork: Profile = [
        "proxies": [["name": "🇱🇹 Литва", "type": "vless", "server": "lt.stork.example", "port": 443, "uuid": "a"]],
        "proxy-groups": [["name": "Stork", "type": "select", "proxies": ["🇱🇹 Литва"]]],
        "rules": ["DOMAIN-SUFFIX,ru,DIRECT", "MATCH,Stork"],
        "dns": ["nameserver": ["https://dns.stork.example/dns-query"]],
    ]
    private let ivpn: Profile = [
        "proxies": [["name": "🇱🇹 Литва", "type": "trojan", "server": "lt.ivpn.example", "port": 443, "password": "b"]],
        "proxy-groups": [["name": "iVPN", "type": "select", "proxies": ["🇱🇹 Литва"]]],
        "rules": ["MATCH,iVPN"],
        "dns": ["nameserver": ["1.1.1.1"]],
    ]
    private let own: [[String: Any]] = [["name": "Дом", "type": "trojan", "server": "1.2.3.4", "port": 443, "password": "x"]]

    private func json(_ profile: Profile?) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(profile), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Only the selected subscription's rules, DNS and groups; nothing of the other, no own servers.
    func testTheHelperGetsTheSelectedSubscriptionAlone() throws {
        let profiles = ["s1": stork, "s2": ivpn]
        let first = try json(Subscriptions.profile(for: ServerID(subscription: "s1", name: "🇱🇹 Литва"), profiles: profiles, own: own))
        XCTAssertEqual(first, try json(stork))
        let second = try json(Subscriptions.profile(for: ServerID(subscription: "s2", name: "🇱🇹 Литва"), profiles: profiles, own: own))
        XCTAssertEqual(second, try json(ivpn))
        XCTAssertFalse(second.contains("stork"))
        XCTAssertFalse(second.contains("Дом"))
    }

    /// «Свои серверы»: today's profile without a subscription, nothing of any subscription.
    /// #64: one password approves every subscription; the one that runs goes first (ks runs the first).
    func testAnImportHandsAllSubscriptionsRunningFirst() {
        XCTAssertEqual(Subscriptions.approvalOrder(running: "2", all: ["1", "2", "3", ServerID.own]), ["2", "1", "3", ServerID.own])
        XCTAssertEqual(Subscriptions.approvalOrder(running: ServerID.own, all: ["1", ServerID.own]), [ServerID.own, "1"])
        XCTAssertEqual(Subscriptions.approvalOrder(running: "1", all: ["1"]), ["1"])
        // what ks takes: the running one and 64 others, the rest left unapproved (not a failed import)
        let many = (1...70).map(String.init)
        XCTAssertEqual(Subscriptions.approvalOrder(running: "70", all: many), ["70"] + (1...64).map(String.init))
    }

    /// #64 review B2: the confirmation names what one password approves, when it is more than one.
    func testTheConfirmationNamesTheSubscriptionsItApproves() {
        XCTAssertNil(Subscriptions.approvalNote(titles: []))
        XCTAssertNil(Subscriptions.approvalNote(titles: ["Stork"]))
        XCTAssertEqual(Subscriptions.approvalNote(titles: ["Stork", "iVPN", "Свои серверы"]),
                       "Пароль подтвердит серверы подписок: Stork, iVPN, Свои серверы")
    }

    /// #64: a timer only refreshes the running subscription; a click on another one tries it
    /// without the password and asks once for all only when the helper refuses (exit 3) or the
    /// installed sudoers has no `core use` yet.
    func testSwitchingSubscriptionsTriesWithoutThePasswordFirst() {
        XCTAssertEqual(Subscriptions.handOver(interactive: false, switching: false), .refresh)
        XCTAssertEqual(Subscriptions.handOver(interactive: false, switching: true), .refresh)
        XCTAssertEqual(Subscriptions.handOver(interactive: true, switching: true), .use)
        XCTAssertEqual(Subscriptions.handOver(interactive: true, switching: false), .importAll)
        XCTAssertTrue(Subscriptions.needsImport(after: .newServers))
        XCTAssertTrue(Subscriptions.needsImport(after: .routingChanged))
        XCTAssertTrue(Subscriptions.needsImport(after: .needsPassword))
        XCTAssertFalse(Subscriptions.needsImport(after: .applied))
        XCTAssertFalse(Subscriptions.needsImport(after: .failed("x")))
    }

    /// #65: the core follows the subscription: Xray when it offers Xray configs and Xray is
    /// installed, else mihomo; nil when no installed core can run what it offers.
    func testTheCoreFollowsWhatTheSubscriptionOffers() {
        let both: Set<CoreChoice> = [.xray, .mihomo]
        XCTAssertEqual(Subscriptions.core(offers: both, installed: both), .xray)
        XCTAssertEqual(Subscriptions.core(offers: [.xray], installed: both), .xray)
        XCTAssertEqual(Subscriptions.core(offers: [.mihomo], installed: both), .mihomo)
        XCTAssertEqual(Subscriptions.core(offers: both, installed: [.mihomo]), .mihomo)
        XCTAssertEqual(Subscriptions.core(offers: both, installed: [.xray]), .xray)
        XCTAssertNil(Subscriptions.core(offers: [.xray], installed: [.mihomo]))
        XCTAssertNil(Subscriptions.core(offers: [.mihomo], installed: [.xray]))
        XCTAssertNil(Subscriptions.core(offers: [], installed: both))
    }

    /// Review of #65: only an answer that says «no Xray here» (not an Xray config, 404) moves a
    /// subscription to mihomo for good; an outage, a 503 or nothing at all does not.
    func testOnlyANoXrayAnswerCountsAsNoXray() {
        XCTAssertTrue(Subscriptions.saysNoXray(XrayProfile.Failure.notXray.errorDescription))
        XCTAssertTrue(Subscriptions.saysNoXray("HTTP 404"))
        XCTAssertFalse(Subscriptions.saysNoXray("HTTP 503"))
        XCTAssertFalse(Subscriptions.saysNoXray("offline"))
        XCTAssertFalse(Subscriptions.saysNoXray(nil))
    }

    /// Review of #65: a subscription no installed core runs says so instead of reaching the helper.
    func testASubscriptionNoCoreRunsHasItsOwnError() {
        XCTAssertEqual(Subscriptions.noCore.title, "Подписку не запустить")
        XCTAssertEqual(Subscriptions.noCore.message, "Для её серверов в KillSwitch нет нужного VPN. Переустанови KillSwitch.")
    }

    func testOwnServersGetTheProfileWithoutASubscription() throws {
        let profile = try XCTUnwrap(Subscriptions.profile(for: ServerID(subscription: ServerID.own, name: "Дом"),
                                                          profiles: ["s1": stork], own: own))
        XCTAssertEqual(try json(profile), try json(ProfileMerger.merge(subscription: nil, manual: own)))
        XCTAssertEqual(profile["rules"] as? [String], ["MATCH,\(ProfileMerger.defaultGroup)"])
        XCTAssertNil(Subscriptions.profile(for: ServerID(subscription: ServerID.own, name: "Дом"), profiles: ["s1": stork], own: []))
        XCTAssertNil(Subscriptions.profile(for: ServerID(subscription: "gone", name: "Литва"), profiles: ["s1": stork], own: own))
    }

    /// The same with Xray: the selected subscription's panel config as it came; own servers as hosts
    /// of their own (XrayManual) only for «Свои серверы».
    func testXrayGetsTheSelectedSubscriptionAlone() throws {
        let storkXray = Data(#"[{"remarks":"🇱🇹 Литва","outbounds":[{"tag":"proxy","protocol":"vless"}]}]"#.utf8)
        let ivpnXray = Data(#"[{"remarks":"🇱🇹 Литва","outbounds":[{"tag":"proxy","protocol":"trojan"}]}]"#.utf8)
        let manual = [(name: "Дом", proxy: own[0])]
        let configs = ["s1": storkXray, "s2": ivpnXray]
        XCTAssertEqual(Subscriptions.xray(for: ServerID(subscription: "s2", name: "🇱🇹 Литва"), configs: configs, own: manual), ivpnXray)
        XCTAssertEqual(Subscriptions.xray(for: ServerID(subscription: "s1", name: "🇱🇹 Литва"), configs: configs, own: manual), storkXray)
        let ownConfig = try XCTUnwrap(Subscriptions.xray(for: ServerID(subscription: ServerID.own, name: "Дом (свой)"),
                                                         configs: configs, own: manual))
        XCTAssertEqual(ownConfig, XrayManual.merge(subscription: nil, manual: manual)?.data)
        XCTAssertFalse(String(decoding: ownConfig, as: UTF8.self).contains("vless"))
    }

    // MARK: storage

    /// UserDefaults of its own, the keychain as a dictionary, a temporary folder for the caches.
    private final class Box { var secrets: [String: Data] = [:] }
    private var box = Box()
    private var store: Subscriptions.Store!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "SubscriptionsTests-\(UUID().uuidString)"
        let box = Box()
        self.box = box
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = Subscriptions.Store(defaults: UserDefaults(suiteName: suite)!,
                                    read: { box.secrets[$0] },
                                    write: { account, data in box.secrets[account] = data; return true },
                                    directory: directory)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: store.directory)
        super.tearDown()
    }

    /// 0.19/0.20's one subscription becomes the first of the list with its status, link and caches;
    /// favourites, recents and the chosen server are kept by (subscription, server); own servers
    /// («Дом», Xray's «… (свой)») go to «Свои серверы». Runs once.
    func testTheSingleSubscriptionBecomesTheFirstOfTheList() throws {
        let defaults = store.defaults
        box.secrets["subscription-url"] = Data("https://stork.example/sub/token".utf8)
        var status = SubscriptionStatus()
        status.title = "Stork"
        defaults.set(try JSONEncoder().encode(status), forKey: "subscriptionStatus")
        try Data("mihomo".utf8).write(to: store.directory.appendingPathComponent("subscription.json"))
        try Data("xray".utf8).write(to: store.directory.appendingPathComponent("subscription-xray.json"))
        let homeKey = try XCTUnwrap(ServerIdentity.key(own[0]))
        defaults.set(["id:vless|lt.stork.example|443|aa", homeKey, "🇩🇪 Германия"].joined(separator: "\n"), forKey: "favouriteServers")
        defaults.set(["Дом (свой)", "🇱🇹 Литва"].joined(separator: "\n"), forKey: "recentServers")
        defaults.set("🇱🇹 Литва", forKey: "chosenServer")
        defaults.set("🇱🇹 Литва", forKey: "lastServer")
        let pending = ServerPicker.Entry(name: "🇱🇹 Литва", title: "🇱🇹 Литва", path: [.init(group: "Stork", proxy: "🇱🇹 Литва")])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
        old["subscription"] = nil
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "pendingServer")

        XCTAssertTrue(Subscriptions.migrate(store, own: own))

        let list = Subscriptions.load(store)
        XCTAssertEqual(list.count, 1)
        let first = try XCTUnwrap(list.first)
        XCTAssertEqual(first.status.title, "Stork")
        XCTAssertEqual(first.title, "Stork")
        XCTAssertEqual(Subscriptions.link(of: first.id, store), "https://stork.example/sub/token")
        XCTAssertNil(box.secrets["subscription-url"])
        XCTAssertNil(defaults.object(forKey: "subscriptionStatus"))
        XCTAssertEqual(try Data(contentsOf: Subscriptions.cache(of: first.id, xray: false, store)), Data("mihomo".utf8))
        XCTAssertEqual(try Data(contentsOf: Subscriptions.cache(of: first.id, xray: true, store)), Data("xray".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("subscription.json").path))
        XCTAssertEqual(defaults.string(forKey: Subscriptions.activeKey), first.id)

        let favourites = ServerRecents.list(defaults.string(forKey: "favouriteServers") ?? "").compactMap(ServerID.init(stored:))
        XCTAssertEqual(favourites, [ServerID(subscription: first.id, name: "id:vless|lt.stork.example|443|aa"),
                                    ServerID(subscription: ServerID.own, name: homeKey),
                                    ServerID(subscription: first.id, name: "🇩🇪 Германия")])
        let recents = ServerRecents.list(defaults.string(forKey: "recentServers") ?? "").compactMap(ServerID.init(stored:))
        XCTAssertEqual(recents, [ServerID(subscription: ServerID.own, name: "Дом (свой)"), ServerID(subscription: first.id, name: "🇱🇹 Литва")])
        XCTAssertEqual(defaults.string(forKey: "chosenServer").flatMap(ServerID.init(stored:)), ServerID(subscription: first.id, name: "🇱🇹 Литва"))
        XCTAssertEqual(defaults.string(forKey: "lastServer").flatMap(ServerID.init(stored:)), ServerID(subscription: first.id, name: "🇱🇹 Литва"))
        let entry = try JSONDecoder().decode(ServerPicker.Entry.self, from: XCTUnwrap(defaults.data(forKey: "pendingServer")))
        XCTAssertEqual(entry.server, ServerID(subscription: first.id, name: "🇱🇹 Литва"))

        // once: a second run changes nothing
        let favouritesAfter = defaults.string(forKey: "favouriteServers")
        XCTAssertFalse(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(defaults.string(forKey: "favouriteServers"), favouritesAfter)
        XCTAssertEqual(Subscriptions.load(store), list)
    }

    /// A password import that switches subscription marks the profile (#74): ks turns double VPN off
    /// in that run. mihomo's at the top, Xray's in its first config; not a profile: nil.
    func testASwitchingImportIsMarked() throws {
        let mihomo = try XCTUnwrap(Subscriptions.markedSwitching(Data(#"{"proxies":[]}"#.utf8)))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: mihomo) as? [String: Any])?["x-ks-switch"] as? Bool, true)
        let xray = try XCTUnwrap(Subscriptions.markedSwitching(Data(#"[{"outbounds":[]},{"outbounds":[]}]"#.utf8)))
        let configs = try XCTUnwrap(JSONSerialization.jsonObject(with: xray) as? [[String: Any]])
        XCTAssertEqual(configs.map { $0["x-ks-switch"] as? Bool }, [true, nil])
        XCTAssertNil(Subscriptions.markedSwitching(Data("[]".utf8)))
        XCTAssertNil(Subscriptions.markedSwitching(Data("not json".utf8)))
    }

    /// 0.19's Wi‑Fi rules and «Способ подключения» belong to its one subscription (or own servers):
    /// once moved, a same-name server of a subscription added later takes neither.
    func testRulesAndTransportOverridesGoToTheFirstSubscription() throws {
        let defaults = store.defaults
        box.secrets["subscription-url"] = Data("https://stork.example/sub/token".utf8)
        let homeKey = try XCTUnwrap(ServerIdentity.key(own[0]))
        let rules = [WiFiRules.Rule(ssid: "home", server: "🇱🇹 Литва"), WiFiRules.Rule(ssid: "dacha", server: "Дом"),
                     WiFiRules.Rule(ssid: "cafe"), WiFiRules.Rule(ssid: "office", server: "🇱🇹 Литва", subscription: "1")]
        defaults.set(WiFiRules.encode(rules), forKey: WiFiRules.key)
        let fp = Transport.Override(fingerprint: "chrome"), mux = Transport.Override(mux: "h2mux")
        let ltKey = "id:vless|lt.stork.example|443|aa"
        defaults.set(Transport.encode(["🇱🇹 Литва": fp, ltKey: mux, homeKey: fp]), forKey: Transport.storeKey)

        XCTAssertTrue(Subscriptions.migrate(store, own: own))

        let first = try XCTUnwrap(Subscriptions.load(store).first).id
        let moved = WiFiRules.decode(defaults.data(forKey: WiFiRules.key))
        XCTAssertEqual(moved.map(\.subscription), [first, ServerID.own, nil, "1"])
        XCTAssertEqual(moved.map(\.server), ["🇱🇹 Литва", "Дом", nil, "🇱🇹 Литва"])
        let overrides = Transport.decode(defaults.data(forKey: Transport.storeKey))
        XCTAssertEqual(overrides, [ServerID(subscription: first, name: "🇱🇹 Литва").stored: fp,
                                   ServerID(subscription: first, name: ltKey).stored: mux,
                                   ServerID(subscription: ServerID.own, name: homeKey).stored: fp])

        // a second subscription's «🇱🇹 Литва» (even of the same identity) takes neither the rule nor the override
        let lt = ServerPicker.Entry(name: "🇱🇹 Литва", title: "🇱🇹 Литва", path: [.init(group: "B", proxy: "🇱🇹 Литва")], subscription: "2")
        XCTAssertEqual(WiFiRules.server(for: moved[0], entries: [lt], current: nil, active: "2"), .keep)
        XCTAssertNil(Transport.override(in: overrides, for: "🇱🇹 Литва", key: ltKey, subscription: "2"))
        XCTAssertEqual(Transport.override(in: overrides, for: "🇱🇹 Литва", key: ltKey, subscription: first), mux)

        // once
        XCTAssertFalse(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(WiFiRules.decode(defaults.data(forKey: WiFiRules.key)), moved)
        XCTAssertEqual(Transport.decode(defaults.data(forKey: Transport.storeKey)), overrides)
    }

    /// No subscription before: an empty list, own servers' entries to «Свои серверы», which is the
    /// one in use.
    func testWithoutASubscriptionOwnServersAreInUse() {
        let defaults = store.defaults
        defaults.set("Дом", forKey: "chosenServer")
        defaults.set("Дом", forKey: "recentServers")
        XCTAssertTrue(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(Subscriptions.load(store), [])
        XCTAssertEqual(defaults.string(forKey: Subscriptions.activeKey), ServerID.own)
        XCTAssertEqual(defaults.string(forKey: "chosenServer").flatMap(ServerID.init(stored:)), ServerID(subscription: ServerID.own, name: "Дом"))
        XCTAssertEqual(defaults.string(forKey: "recentServers").flatMap(ServerID.init(stored:)), ServerID(subscription: ServerID.own, name: "Дом"))
    }

    /// Adding never replaces: a second link is a second subscription with a link of its own; the
    /// same link again (another case of the host, a trailing slash) is refused.
    func testAddingAppendsAndRefusesTheSameLink() throws {
        let first = try Subscriptions.add("https://stork.example/sub/token", store).get()
        let second = try Subscriptions.add(" https://ivpn.example/s/abc\n", store).get()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Subscriptions.load(store).map(\.id), [first.id, second.id])
        XCTAssertEqual(Subscriptions.load(store).map(\.title), ["stork.example", "ivpn.example"])
        XCTAssertEqual(Subscriptions.link(of: first.id, store), "https://stork.example/sub/token")
        XCTAssertEqual(Subscriptions.link(of: second.id, store), "https://ivpn.example/s/abc")
        XCTAssertEqual(Subscriptions.add("https://STORK.example/sub/token/", store), .failure(.duplicate))
        XCTAssertEqual(Subscriptions.add("http://stork.example/other", store), .failure(.notALink))
        XCTAssertEqual(Subscriptions.load(store).count, 2)
    }

    /// #75 review: a keychain that does not answer is no «no link»; the same link could slip past
    /// the duplicate check, so nothing is added.
    func testAKeychainThatDoesNotAnswerAddsNothing() throws {
        _ = try Subscriptions.add("https://stork.example/sub/token", store).get()
        struct Locked: Error {}
        var locked = store!
        locked.read = { _ in throw Locked() }
        XCTAssertEqual(Subscriptions.add("https://stork.example/sub/token", locked), .failure(.notKept))
        XCTAssertEqual(Subscriptions.load(store).count, 1)
        XCTAssertEqual(box.secrets.count, 1)
    }

    /// Deleting takes its link and caches; the others stay.
    func testRemovingTakesItsLinkAndCaches() throws {
        let first = try Subscriptions.add("https://stork.example/sub/token", store).get()
        let second = try Subscriptions.add("https://ivpn.example/s/abc", store).get()
        try Data("x".utf8).write(to: Subscriptions.cache(of: first.id, xray: true, store))
        Subscriptions.remove(first.id, store)
        XCTAssertEqual(Subscriptions.load(store).map(\.id), [second.id])
        XCTAssertNil(Subscriptions.link(of: first.id, store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Subscriptions.cache(of: first.id, xray: true, store).path))
        XCTAssertNotNil(Subscriptions.link(of: second.id, store))
    }

    /// Nothing of a deleted subscription is left: its favourites and recents go, and a chosen,
    /// last or waiting server of it is forgotten; the others' stay.
    func testRemovingForgetsItsServers() throws {
        let first = try Subscriptions.add("https://stork.example/sub/token", store).get()
        let second = try Subscriptions.add("https://ivpn.example/s/abc", store).get()
        let gone = ServerID(subscription: first.id, name: "🇱🇹 Литва"), kept = ServerID(subscription: second.id, name: "🇱🇹 Литва")
        let home = ServerID(subscription: ServerID.own, name: "Дом")
        let defaults = store.defaults
        defaults.set(ServerRecents.text([gone.stored, kept.stored, home.stored]), forKey: Subscriptions.favouritesKey)
        defaults.set(ServerRecents.text([kept.stored, gone.stored]), forKey: Subscriptions.recentsKey)
        defaults.set(gone.stored, forKey: Subscriptions.chosenKey)
        defaults.set(gone.stored, forKey: Subscriptions.lastKey)
        let pending = ServerPicker.Entry(name: gone.name, title: gone.name, path: [], subscription: first.id)
        defaults.set(try JSONEncoder().encode(pending), forKey: Subscriptions.pendingKey)

        Subscriptions.remove(first.id, store)

        XCTAssertEqual(defaults.string(forKey: Subscriptions.favouritesKey), ServerRecents.text([kept.stored, home.stored]))
        XCTAssertEqual(defaults.string(forKey: Subscriptions.recentsKey), kept.stored)
        XCTAssertNil(defaults.object(forKey: Subscriptions.chosenKey))
        XCTAssertNil(defaults.object(forKey: Subscriptions.lastKey))
        XCTAssertNil(defaults.object(forKey: Subscriptions.pendingKey))

        // another subscription's chosen server stays
        defaults.set(kept.stored, forKey: Subscriptions.chosenKey)
        let third = try Subscriptions.add("https://third.example/s", store).get()
        Subscriptions.remove(third.id, store)
        XCTAssertEqual(defaults.string(forKey: Subscriptions.chosenKey), kept.stored)
    }

    /// The keychain did not take the link: nothing moves, and the next launch tries again.
    func testAMoveTheKeychainRefusedIsTriedAgain() throws {
        box.secrets["subscription-url"] = Data("https://stork.example/sub/token".utf8)
        let box = self.box
        var refusing = store!
        refusing.write = { _, _ in false }
        XCTAssertFalse(Subscriptions.migrate(refusing, own: own))
        XCTAssertNil(store.defaults.object(forKey: Subscriptions.listKey))
        XCTAssertNotNil(box.secrets["subscription-url"])
        XCTAssertTrue(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(Subscriptions.load(store).count, 1)
        XCTAssertNil(box.secrets["subscription-url"])
    }

    /// A keychain that does not answer (locked, refused) is no «no link»: nothing is written, and
    /// the next launch moves the subscription. The same when the own servers could not be read.
    func testAKeychainThatDoesNotAnswerMovesNothing() throws {
        box.secrets["subscription-url"] = Data("https://stork.example/sub/token".utf8)
        store.defaults.set("Дом", forKey: "chosenServer")
        struct Locked: Error {}
        var locked = store!
        locked.read = { _ in throw Locked() }
        XCTAssertFalse(Subscriptions.migrate(locked, own: own))
        XCTAssertFalse(Subscriptions.migrate(store, own: nil))
        XCTAssertNil(store.defaults.object(forKey: Subscriptions.listKey))
        XCTAssertNil(store.defaults.object(forKey: Subscriptions.activeKey))
        XCTAssertEqual(store.defaults.string(forKey: "chosenServer"), "Дом")
        XCTAssertTrue(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(Subscriptions.load(store).count, 1)
        XCTAssertEqual(store.defaults.string(forKey: "chosenServer").flatMap(ServerID.init(stored:)), ServerID(subscription: ServerID.own, name: "Дом"))
    }

    /// Connected through an own server before the update: «Свои серверы» stays in use.
    func testAnOwnChosenServerKeepsOwnServersInUse() {
        box.secrets["subscription-url"] = Data("https://stork.example/sub/token".utf8)
        store.defaults.set("Дом", forKey: "chosenServer")
        XCTAssertTrue(Subscriptions.migrate(store, own: own))
        XCTAssertEqual(store.defaults.string(forKey: Subscriptions.activeKey), ServerID.own)
    }
}
