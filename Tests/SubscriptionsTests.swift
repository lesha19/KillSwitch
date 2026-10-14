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
