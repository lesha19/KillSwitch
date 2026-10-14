import Foundation

/// One subscription of the list (ADR 0036). Its link is in the keychain (`Subscriptions.account`),
/// its last fetched profiles in files of its own; this, without secrets, in UserDefaults.
struct Subscription: Codable, Equatable, Identifiable {
    /// Generated when it is added; never changes.
    let id: String
    /// The link's host: the block's title until the provider names it (`profile-title`).
    var host: String
    var status = SubscriptionStatus()

    var title: String { status.title ?? host }
}

/// The list of subscriptions (ADR 0036): each brings its own servers and configuration; the helper
/// runs one of them at a time, the one whose server is selected.
enum Subscriptions {
    /// The list in the order of adding.
    static let listKey = "subscriptions"
    /// The subscription (or ServerID.own) whose profile the helper was last handed.
    static let activeKey = "activeSubscription"

    /// Where the list, the links and the caches live: the app's (VPNClient), or a test's.
    struct Store {
        var defaults: UserDefaults
        /// The keychain item of an account; nil when there is none, throws when the keychain did
        /// not answer (locked, refused).
        var read: (String) throws -> Data?
        /// nil deletes it. False: not kept.
        var write: (String, Data?) -> Bool
        /// Application Support/KillSwitch.
        var directory: URL
    }

    static func account(_ id: String) -> String { "subscription-url.\(id)" }

    static func load(_ store: Store) -> [Subscription] {
        store.defaults.data(forKey: listKey).flatMap { try? JSONDecoder().decode([Subscription].self, from: $0) } ?? []
    }

    static func save(_ list: [Subscription], _ store: Store) {
        store.defaults.set(try? JSONEncoder().encode(list), forKey: listKey)
    }

    static func link(of id: String, _ store: Store) -> String? {
        (try? store.read(account(id))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The last fetched profile, mihomo's or Xray's; it holds server credentials (0600).
    static func cache(of id: String, xray: Bool, _ store: Store) -> URL {
        store.directory.appendingPathComponent(xray ? "subscription-\(id)-xray.json" : "subscription-\(id).json")
    }

    enum AddError: Error, Equatable {
        /// Not an https link with a host.
        case notALink
        /// This link is in the list already.
        case duplicate
        /// The keychain did not take it, or did not answer.
        case notKept
    }

    /// Appends a subscription for the link (ADR 0036, decision 1): never replaces one.
    static func add(_ text: String, _ store: Store) -> Result<Subscription, AddError> {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = normalised(url) else { return .failure(.notALink) }
        var list = load(store)
        // a keychain that does not answer is no «no link»: the same link could be added twice
        guard let links = try? list.map({ try store.read(account($0.id)) }) else { return .failure(.notKept) }
        guard !links.contains(where: { $0.flatMap { String(data: $0, encoding: .utf8) }.flatMap(normalised) == key }) else {
            return .failure(.duplicate)
        }
        let subscription = Subscription(id: UUID().uuidString, host: URLComponents(string: url)?.host ?? url)
        guard store.write(account(subscription.id), Data(url.utf8)) else { return .failure(.notKept) }
        list.append(subscription)
        save(list, store)
        return .success(subscription)
    }

    /// The link, its caches, its place in the list, and what was kept of its servers: favourites,
    /// recents, the chosen, last and waiting server (ADR 0036, decision 1).
    static func remove(_ id: String, _ store: Store) {
        _ = store.write(account(id), nil)
        for xray in [false, true] { try? FileManager.default.removeItem(at: cache(of: id, xray: xray, store)) }
        save(load(store).filter { $0.id != id }, store)
        let defaults = store.defaults
        func its(_ line: String) -> Bool { ServerID(stored: line)?.subscription == id }
        for key in [favouritesKey, recentsKey] {
            guard let text = defaults.string(forKey: key) else { continue }
            defaults.set(ServerRecents.text(ServerRecents.list(text).filter { !its($0) }), forKey: key)
        }
        for key in [chosenKey, lastKey] where defaults.string(forKey: key).map(its) == true { defaults.removeObject(forKey: key) }
        if let data = defaults.data(forKey: pendingKey), (try? JSONDecoder().decode(ServerPicker.Entry.self, from: data))?.subscription == id {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    /// What makes two links the same: scheme and host in any case, a path with or without a final
    /// slash. Nil for what is not an https link with a host.
    static func normalised(_ url: String) -> String? {
        guard var components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    // MARK: from one subscription (0.19, 0.20 before ADR 0036)

    private static let oldAccount = "subscription-url"
    private static let oldStatusKey = "subscriptionStatus"
    static let favouritesKey = "favouriteServers"
    static let recentsKey = "recentServers"
    static let chosenKey = "chosenServer"
    static let lastKey = "lastServer"
    static let pendingKey = "pendingServer"

    /// Once, before the list is first read: the one subscription becomes the first of the list
    /// (link, status, caches), and what was kept by server name is kept by (subscription, server);
    /// own servers (`own`: their proxies, by name) go to «Свои серверы». False when it ran before,
    /// or when the keychain did not answer (`own` nil: the own servers could not be read): then
    /// nothing is written and the next launch tries again.
    @discardableResult
    static func migrate(_ store: Store, own: [[String: Any]]?) -> Bool {
        let defaults = store.defaults
        guard defaults.object(forKey: listKey) == nil, let own else { return false }
        let old: Data?
        do { old = try store.read(oldAccount) } catch { return false }
        var list: [Subscription] = []
        if let link = old.flatMap({ String(data: $0, encoding: .utf8) }) {
            // not moved: tried again at the next launch rather than losing the link
            guard store.write(account(firstID), Data(link.utf8)) else { return false }
            var first = Subscription(id: firstID, host: URLComponents(string: link)?.host ?? link)
            if let data = defaults.data(forKey: oldStatusKey), let status = try? JSONDecoder().decode(SubscriptionStatus.self, from: data) {
                first.status = status
            }
            for xray in [false, true] {
                let old = store.directory.appendingPathComponent(xray ? "subscription-xray.json" : "subscription.json")
                try? FileManager.default.moveItem(at: old, to: cache(of: firstID, xray: xray, store))
            }
            list.append(first)
        }
        let ownNames = Set(own.compactMap { $0["name"] as? String }), ownKeys = Set(own.compactMap(ServerIdentity.key))
        let subscription = list.first?.id ?? ServerID.own
        func moved(_ entry: String) -> String {
            if ServerID(stored: entry) != nil { return entry }
            let isOwn = ownNames.contains(entry) || ownKeys.contains(entry) || entry.hasSuffix(XrayManual.mark)
            return ServerID(subscription: isOwn ? ServerID.own : subscription, name: entry).stored
        }
        for key in [favouritesKey, recentsKey] {
            guard let text = defaults.string(forKey: key) else { continue }
            defaults.set(ServerRecents.text(ServerRecents.list(text).map(moved)), forKey: key)
        }
        for key in [chosenKey, lastKey] {
            if let name = defaults.string(forKey: key) { defaults.set(moved(name), forKey: key) }
        }
        if let data = defaults.data(forKey: pendingKey), var entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           entry["subscription"] == nil, let name = entry["name"] as? String {
            entry["subscription"] = ServerID(stored: moved(name))?.subscription
            defaults.set(try? JSONSerialization.data(withJSONObject: entry), forKey: pendingKey)
        }
        let chosen = defaults.string(forKey: chosenKey).flatMap(ServerID.init(stored:))
        defaults.set(chosen?.isOwn == true ? ServerID.own : subscription, forKey: activeKey)
        save(list, store)
        // only once the list is kept: an interrupted move starts over from the old shape
        if !list.isEmpty {
            _ = store.write(oldAccount, nil)
            defaults.removeObject(forKey: oldStatusKey)
        }
        return true
    }

    /// The old subscription's id in the list: a constant, so an interrupted move ends the same.
    private static let firstID = "1"
    /// What the helper is handed for a server (mihomo format): its subscription's profile as it
    /// came, nothing of the others; for «Свои серверы» the own servers alone, all traffic to the
    /// chosen one (the profile without a subscription). Nil when there is nothing to run.
    static func profile(for server: ServerID, profiles: [String: Profile], own: [[String: Any]]) -> Profile? {
        server.isOwn ? ProfileMerger.merge(subscription: nil, manual: own) : profiles[server.subscription]
    }

    /// The subscriptions whose profiles an import with the password hands the helper (#64): the one
    /// that runs first (ks runs the first), then every other one, so one password approves them all.
    /// At most what the helper takes (HelperCommand.maxOtherProfiles): the rest stay unapproved.
    static func approvalOrder(running: String, all: [String]) -> [String] {
        [running] + all.filter { $0 != running }.prefix(HelperCommand.maxOtherProfiles)
    }

    /// Under «Подтвердить…»: whose servers the password approves (the import hands them all), when
    /// more than one; nil for one.
    static func approvalNote(titles: [String]) -> String? {
        titles.count > 1 ? String(localized: "Пароль подтвердит серверы подписок: \(titles.joined(separator: ", "))") : nil
    }

    /// How a profile reaches the helper (#64).
    enum HandOver: Equatable {
        /// A timer: a newer copy of the running subscription, never a prompt.
        case refresh
        /// A click on a server of another subscription: without the password if the last import approved it.
        case use
        /// The password, approving every subscription at once.
        case importAll
    }

    static func handOver(interactive: Bool, switching: Bool) -> HandOver {
        interactive ? (switching ? .use : .importAll) : .refresh
    }

    /// After `use`: the helper refused (exit 3) or the installed sudoers has no `core use` yet. Then
    /// the password, once for all subscriptions with new servers.
    static func needsImport(after outcome: RefreshOutcome) -> Bool {
        switch outcome {
        case .newServers, .routingChanged, .needsPassword: true
        case .applied, .failed: false
        }
    }

    /// The core a subscription runs in (ADR 0036, #65): Xray when it offers Xray configs and Xray is
    /// installed, else mihomo; nil when no installed core takes what it offers.
    static func core(offers: Set<CoreChoice>, installed: Set<CoreChoice>) -> CoreChoice? {
        [CoreChoice.xray, .mihomo].first { offers.contains($0) && installed.contains($0) }
    }

    /// A subscription whose formats no installed core runs (core(offers:installed:) nil): kept,
    /// never handed to the helper.
    static let noCore = UserError(title: String(localized: "Подписку не запустить"),
                                  message: String(localized: "Для её серверов в KillSwitch нет нужного VPN. Переустанови KillSwitch."))

    /// The answer at `<link>/json` says the subscription has no Xray configs (not an Xray config, or
    /// 404), unlike an outage or a server error.
    static func saysNoXray(_ failure: String?) -> Bool {
        guard let failure else { return false }
        return failure == XrayProfile.Failure.notXray.errorDescription || failure.hasPrefix("HTTP 404")
    }

    /// The same with Xray: the subscription's panel config as it came, or the own servers as hosts
    /// of their own (XrayManual).
    static func xray(for server: ServerID, configs: [String: Data], own: [(name: String, proxy: [String: Any])]) -> Data? {
        server.isOwn ? XrayManual.merge(subscription: nil, manual: own)?.data : configs[server.subscription]
    }
}
