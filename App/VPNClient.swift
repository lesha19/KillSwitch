import CryptoKit
import Foundation
import Observation

/// The VPN client side: the subscriptions (links in the keychain, ADR 0036), servers added from
/// share links («Свои серверы»), and handing the profile of the selected server's subscription to
/// the helper (`ks core import`).
@MainActor
@Observable
final class VPNClient {
    struct ManualServer: Codable, Identifiable, Equatable {
        var id = UUID()
        var link: String
        var name: String
    }

    typealias Status = SubscriptionStatus

    /// In the order of adding (Subscriptions).
    private(set) var subscriptions: [Subscription] = []
    private(set) var manual: [ManualServer] = []
    private(set) var updating = false
    private(set) var lastError: UserError?
    /// The servers of each subscription with a cached profile, then «Свои серверы» (ADR 0036).
    private(set) var blocks: [Block] = [] {
        // the CLI tells same-name servers of several subscriptions apart by it (#66)
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(serverBlocks(live: nil)), forKey: CLI.serversKey) }
    }
    /// An automatic update found a new profile, but applying it needs the admin password
    /// (the installed helper does not allow `core refresh` without one).
    private(set) var needsPassword = false
    /// An automatic update brought new server addresses: the helper refused `core refresh`, and
    /// only a click (`confirmNewServers`) may import it with the admin password.
    private(set) var needsConfirmation = false
    /// KS-12: what waits for the admin is a change of what goes past the VPN (DIRECT, DNS), not servers.
    private(set) var routingChanged = false
    /// Settings › «Дополнительно»: fingerprint and multiplexing per server (Transport, ADR 0007).
    private(set) var transportOverrides = Transport.decode(UserDefaults.standard.data(forKey: Transport.storeKey))
    /// Servers of the cached profile whose transport can be changed, with the subscription's values.
    private(set) var transportServers: [Transport.Server] = []
    /// Server name → identity (ServerIdentity) in the profile the helper runs: what per-server
    /// settings are kept under, so they survive a rename.
    var serverKeys: [String: String] { activeBlock?.keys ?? [:] }
    /// The raw reason the last Xray fetch failed: a subscription without Xray configs runs in mihomo.
    private var lastXrayFailure: String?

    /// «Избранные» of the server list, by (subscription, identity) (ServerRecents).
    static let favouritesKey = Subscriptions.favouritesKey

    /// One subscription's servers (or «Свои серверы»): its cached profile's groups, and its server
    /// name → identity (mihomo only).
    struct Block {
        let id: String
        let title: String
        let proxies: CoreProxies
        let keys: [String: String]
    }

    var hasURL: Bool { !subscriptions.isEmpty }
    /// The subscription the helper runs, else the first: what the single-subscription views show
    /// (per-subscription blocks with their own status come with #67).
    var current: Subscription? { subscriptions.first { $0.id == activeID } ?? subscriptions.first }
    var status: Status { current?.status ?? Status() }
    var maskedURL: String? { current.flatMap { Subscriptions.link(of: $0.id, Self.store) }.map(SubscriptionHeaders.masked) }

    /// Whose profile the helper runs (or is to run): the one last handed over (even one deleted
    /// since: the helper still runs it, #67); before any import, the first subscription, else
    /// «Свои серверы».
    var activeID: String {
        let stored = control.activeSubscription
        if control.coreConfigured || subscriptions.contains(where: { $0.id == stored }) || (stored == ServerID.own && !manual.isEmpty) {
            return stored
        }
        return subscriptions.first?.id ?? ServerID.own
    }

    var activeBlock: Block? { blocks.first { $0.id == activeID } }
    /// Groups of the profile the helper runs, from its cache, for choosing a server before connecting.
    var profileProxies: CoreProxies? { activeBlock?.proxies }

    /// The servers of every subscription as «Серверы» lists them: the running one's from the core
    /// (`live`) when it runs, the others from their caches.
    func serverBlocks(live: CoreProxies?) -> [ServerPicker.Block] {
        blocks.map { block in
            let proxies = block.id == activeID ? live ?? block.proxies : block.proxies
            return ServerPicker.Block(id: block.id, title: block.title, entries: ServerPicker.entries(proxies, subscription: block.id))
        }
    }

    /// «Stork», «Свои серверы»: the title of a subscription's block.
    func title(of subscription: String) -> String? { blocks.first { $0.id == subscription }?.title }

    /// Hours between automatic updates; 0 = what the subscription asks for.
    var intervalHours = UserDefaults.standard.integer(forKey: "subscriptionIntervalHours") {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "subscriptionIntervalHours") }
    }

    var effectiveInterval: TimeInterval { intervalHours > 0 ? TimeInterval(intervalHours) * 3600 : status.serverInterval }
    var nextUpdate: Date? { status.lastUpdate.map { $0.addingTimeInterval(effectiveInterval) } }

    private let control: KillSwitchControl
    private var timer: Timer?
    /// After a failed or refused update: try again in an hour, not after the full interval.
    private var retryAt: Date?

    /// The timer's: by the subscription the helper runs (one schedule per subscription is #67).
    private var schedule: UpdateSchedule {
        get { UpdateSchedule(lastUpdate: status.lastUpdate, retryAt: retryAt) }
        set {
            retryAt = newValue.retryAt
            if let id = current?.id, newValue.lastUpdate != status.lastUpdate { changeStatus(id) { $0.lastUpdate = newValue.lastUpdate } }
        }
    }

    private static let backupAccount = "subscription-url-backup"   // only to delete it
    private static let linksAccount = "manual-links"
    private static let importedKey = "importedProfileHash"

    /// The list, its links in the keychain, its caches in Application Support/KillSwitch.
    static let store = Subscriptions.Store(
        defaults: .standard,
        read: { try Keychain.readChecked($0) },
        write: { account, data in
            guard let data else { Keychain.delete(account); return true }
            return Keychain.write(account, data)
        },
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KillSwitch"))

    /// Once, before anything reads the server stores (KillSwitchControl): the single subscription
    /// of 0.19 becomes the first of the list (Subscriptions.migrate).
    static func migrate() {
        // the keychain not answering is no «no own servers»: the move waits for the next launch
        let data: Data?
        do { data = try Keychain.readChecked(linksAccount) } catch { return }
        let manual = data.flatMap { try? JSONDecoder().decode([ManualServer].self, from: $0) } ?? []
        Subscriptions.migrate(store, own: manual.compactMap(proxy))
    }

    init(control: KillSwitchControl) {
        self.control = control
        subscriptions = Subscriptions.load(Self.store)
        Keychain.delete(Self.backupAccount)   // the backup link of 0.16–0.19 (#11), dropped by ADR 0036
        // #11: a fetch that failed while the VPN was off goes again as soon as it connects
        NotificationCenter.default.addObserver(forName: UpdateRetry.vpnConnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasURL, self.retryAt != nil, !self.updating else { return }
                Task { await self.update(interactive: false) }
            }
        }
        if let data = Keychain.read(Self.linksAccount), let saved = try? JSONDecoder().decode([ManualServer].self, from: data) {
            manual = saved
        }
        reloadProfileProxies()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIfDue() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))   // let the first state refresh finish
            updateIfDue()
        }
    }

    // MARK: subscriptions (ADR 0036)

    /// Shown only on request in Settings, never when the provider sent `hide-url` (#26); never logged.
    func revealURL(of id: String) -> String? { urlHidden(id) ? nil : Subscriptions.link(of: id, Self.store) }

    func urlHidden(_ id: String) -> Bool { subscriptions.first { $0.id == id }?.status.provider?.hidesURL == true }

    func maskedURL(of id: String) -> String? { Subscriptions.link(of: id, Self.store).map(SubscriptionHeaders.masked) }

    /// Settings, a QR code and `killswitch://add`: adds a subscription, never replaces one; the same
    /// link again is refused. It is kept only once it answered (as a link given in 0.19 was): one
    /// that fails is taken out again and lastError says why. The first one is handed to the helper
    /// too (the admin's password), a further one waits until one of its servers is picked. True
    /// when it was added.
    @discardableResult
    func add(_ text: String) async -> Bool {
        lastError = nil
        let added: Subscription
        switch Subscriptions.add(text, Self.store) {
        case .success(let subscription): added = subscription
        case .failure(.notALink):
            lastError = Self.notALink
            return false
        case .failure(.duplicate):
            lastError = UserError(title: String(localized: "Эта подписка уже добавлена"),
                                  message: String(localized: "Такая ссылка уже есть в списке подписок."))
            return false
        case .failure(.notKept):
            lastError = UserError(title: String(localized: "Ссылка не сохранилась"), message: String(localized: "Не получилось сохранить ссылку в связке ключей."))
            return false
        }
        subscriptions = Subscriptions.load(Self.store)
        while updating { try? await Task.sleep(for: .milliseconds(500)) }   // then fetched at once, not by the timer
        updating = true
        defer { updating = false }
        guard await fetch(added.id) else {
            forget(added.id)
            return false
        }
        guard activeID == added.id else { return true }
        if await applyCurrent(interactive: true) { schedule.record(.applied, now: Date()) }
        return true
    }

    /// A subscription out of the list with all that was kept of it (Subscriptions.remove).
    private func forget(_ id: String) {
        Subscriptions.remove(id, Self.store)
        subscriptions = Subscriptions.load(Self.store)
        control.forget(subscription: id)
        reloadProfileProxies()
    }

    private static let notALink = UserError(title: String(localized: "Это не ссылка на подписку"), message: String(localized: "Нужна ссылка вида https://…"))

    /// Its link, caches, status and what was kept of its servers go (Subscriptions.remove). The
    /// helper keeps running what it was handed, even the deleted subscription's servers, until
    /// another server is picked (what deleting the one in use does is #67). Without subscriptions
    /// the own servers alone go to the helper, as before.
    func remove(_ id: String) async {
        forget(id)
        lastError = nil
        if subscriptions.isEmpty, !manual.isEmpty { await applyCurrent(interactive: true) }
    }

    private func changeStatus(_ id: String, _ change: (inout Status) -> Void) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        change(&subscriptions[index].status)
        Subscriptions.save(subscriptions, Self.store)
    }

    // MARK: manual servers

    /// Share links, one per line, or the text of a wg-quick `.conf` (`name`: the file's name).
    func addLink(_ text: String, name: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = ProxyLink.isWireGuardConf(trimmed)
            ? [trimmed]
            : trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !links.isEmpty, let added = parse(links, name: name) else { return }
        manual += added
        saveManual()
        await ownChanged()
    }

    /// Own servers are a profile of their own (ADR 0036): handed over again only while it runs.
    private func ownChanged() async {
        if activeID == ServerID.own { await applyCurrent(interactive: true) } else { reloadProfileProxies() }
    }

    private func parse(_ links: [String], name: String?) -> [ManualServer]? {
        var added: [ManualServer] = []
        for link in links {
            do {
                let proxy = try ProxyLink.parse(link)
                added.append(ManualServer(link: link, name: name ?? proxy["name"] as? String ?? "Сервер"))
            } catch {
                lastError = UserError(title: String(localized: "Не получилось добавить сервер"), message: error.localizedDescription,
                                      details: error.localizedDescription)
                return nil
            }
        }
        return added
    }

    /// A wg-quick `.conf` picked in the file dialog; the file name becomes the server name.
    func importWireGuard(file url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) < 64 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = UserError(title: String(localized: "Не получилось добавить сервер"), message: String(localized: "Не получилось прочитать файл WireGuard."))
            return
        }
        guard ProxyLink.isWireGuardConf(text) else {
            lastError = UserError(title: String(localized: "Не получилось добавить сервер"), message: String(localized: "Это не файл WireGuard: в нём нет раздела [Interface]."))
            return
        }
        await addLink(text, name: url.deletingPathExtension().lastPathComponent)
    }

    func removeManual(_ server: ManualServer) async {
        let wasActive = activeID == ServerID.own
        manual.removeAll { $0.id == server.id }
        saveManual()
        if wasActive { await applyCurrent(interactive: true) } else { reloadProfileProxies() }
    }

    /// Saves the choice and hands the profile to the core by a passwordless refresh: the servers
    /// stay the same. Not connected yet: the next import takes it.
    func setTransport(_ override: Transport.Override, for server: String) async {
        let key = serverKeys[server] ?? server
        transportOverrides[server] = nil
        transportOverrides[key] = override.isEmpty ? nil : override
        UserDefaults.standard.set(Transport.encode(transportOverrides), forKey: Transport.storeKey)
        guard control.coreConfigured, !updating else { return }
        updating = true
        defer { updating = false }
        await applyCurrent(interactive: false)
    }

    // MARK: updating

    func updateIfDue() {
        guard !updating else { return }
        guard hasURL, schedule.isDue(interval: effectiveInterval, now: Date()) else { return }
        Task { await update(interactive: false) }
    }

    /// Fetches every subscription and hands the profile the helper runs over again. On any failure
    /// the core keeps its old config. «Обновлено» moves only when the profile reached the core;
    /// otherwise again in an hour. (A schedule and an error per subscription: #67.)
    func update(interactive: Bool) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let active = activeID
        var activeError: UserError?
        var fetchedActive = false
        for subscription in subscriptions {
            let fetched = await fetch(subscription.id)
            if subscription.id == active {
                fetchedActive = fetched
                activeError = lastError
            } else if fetched {
                changeStatus(subscription.id) { $0.lastUpdate = Date() }
            }
        }
        lastError = activeError
        if active == ServerID.own {
            if !manual.isEmpty { await applyCurrent(interactive: interactive) }
            return
        }
        guard fetchedActive else { return }
        let applied = await applyCurrent(interactive: interactive)
        schedule.record(applied ? .applied : .notApplied, now: Date())
    }

    /// Downloads and caches one subscription in the format of its core (core(of:)), without
    /// handing it to the helper. The cache is what «Разрешить…» (confirmNewServers) and a switch
    /// build on, so it is the last fetched profile, applied or not. A failed fetch, or one without
    /// servers, leaves the cache alone. #11: tried in SubscriptionSource.order; the first error is shown.
    @discardableResult
    private func fetch(_ id: String) async -> Bool {
        await fetchEither(id) != nil
    }

    private enum Fetched { case xray(XrayProfile), mihomo(Profile) }

    /// The core follows the subscription (ADR 0036, #65): its Xray configs at `<link>/json` when
    /// Xray is installed, else (none there, or none fetched yet) its mihomo profile. One that says
    /// it has no Xray configs (Subscriptions.saysNoXray) loses its old ones once its mihomo profile
    /// came, so it runs in mihomo from then on; a failed fetch keeps them. One no installed core runs
    /// is kept with Subscriptions.noCore as its error.
    private func fetchEither(_ id: String) async -> Fetched? {
        lastXrayFailure = nil
        let fetched: Fetched?
        if installedCores.contains(.xray), let xray = await fetchXray(id) {
            fetched = .xray(xray)
        } else {
            let xrayCache = Subscriptions.cache(of: id, xray: true, Self.store)
            let none = Subscriptions.saysNoXray(lastXrayFailure)
            guard lastXrayFailure == nil || none || !FileManager.default.fileExists(atPath: xrayCache.path) else { return nil }
            if lastXrayFailure != nil { lastError = nil }
            guard let profile = await fetchProfile(id) else { return nil }
            if none { try? FileManager.default.removeItem(at: xrayCache) }
            fetched = .mihomo(profile)
        }
        if unusable(id) { lastError = Subscriptions.noCore }
        return fetched
    }

    /// The cores the helper has (or the app carries for its install, ADR 0020).
    private var installedCores: Set<CoreChoice> {
        Set(CoreChoice.allCases.filter {
            FileManager.default.fileExists(atPath: $0.binary) || Bundle.main.path(forResource: $0.rawValue, ofType: nil, inDirectory: "Helper") != nil
        })
    }

    /// The core a subscription runs in (Subscriptions.core): what its last fetch cached. «Свои
    /// серверы» run in Xray unless it can use none of them (ADR 0027).
    private func core(of id: String) -> CoreChoice? {
        Subscriptions.core(offers: offers(of: id), installed: installedCores)
    }

    private func offers(of id: String) -> Set<CoreChoice> {
        if id == ServerID.own {
            if manual.isEmpty { return [] }
            return manual.allSatisfy({ (try? ProxyLink.parse($0.link)).flatMap(XrayManual.unsupported) != nil }) ? [.mihomo] : [.xray, .mihomo]
        }
        return Set(CoreChoice.allCases.filter { FileManager.default.fileExists(atPath: Subscriptions.cache(of: id, xray: $0 == .xray, Self.store).path) })
    }

    /// It has servers, but in no format an installed core runs: never handed to the helper.
    private func unusable(_ id: String) -> Bool { core(of: id) == nil && !offers(of: id).isEmpty }

    private func fetchProfile(_ id: String) async -> Profile? {
        guard let url = Subscriptions.link(of: id, Self.store).flatMap(URL.init(string:)) else { return nil }
        var firstError: String?
        for source in SubscriptionSource.order(vpnRunning: control.coreRunning) {
            do {
                let (body, headers) = try await Self.fetch(url, viaVPN: source.viaVPN)
                let read = try await ProfileConverter.readInBackground(subscription: body)   // off the main actor (#50)
                guard subscriptions.contains(where: { $0.id == id }) else { return nil }   // deleted meanwhile
                if id == activeID { UserDefaults.standard.set(read.leftOut, forKey: RoutingReport.leftOutKey) }
                if let json = read.json { Self.cache(json, to: Subscriptions.cache(of: id, xray: false, Self.store)) }
                took(headers, source: source, for: id)
                return read.profile
            } catch {
                firstError = firstError ?? Self.describe(error)
            }
        }
        failed(id, raw: firstError ?? "empty")
        return nil
    }

    private func failed(_ id: String, raw: String) {
        if id == current?.id { schedule.record(.fetchFailed(offline: raw.hasPrefix("offline")), now: Date()) }
        lastError = UserError.from(raw: raw, context: .subscription)
    }

    // MARK: the main way of connecting (ADR 0020)

    /// The same sources and order as fetchProfile; the link plus XrayProfile.pathComponent.
    private func fetchXray(_ id: String) async -> XrayProfile? {
        guard let url = Subscriptions.link(of: id, Self.store).flatMap(URL.init(string:)) else { return nil }
        var firstError: String?
        for source in SubscriptionSource.order(vpnRunning: control.coreRunning) {
            do {
                let (body, headers) = try await Self.fetch(XrayProfile.url(for: url), viaVPN: source.viaVPN)
                let profile = try XrayProfile(body: body)
                guard subscriptions.contains(where: { $0.id == id }) else { return nil }   // deleted meanwhile
                if id == activeID { UserDefaults.standard.set([String](), forKey: RoutingReport.leftOutKey) }
                Self.cache(profile.data, to: Subscriptions.cache(of: id, xray: true, Self.store))
                took(headers, source: source, for: id)
                return profile
            } catch {
                firstError = firstError ?? Self.describe(error)
            }
        }
        let raw = firstError ?? "empty"
        lastXrayFailure = raw
        failed(id, raw: raw)
        return nil
    }

    /// The selected subscription's panel config to the helper (refresh, or import with the password
    /// on a click); for «Свои серверы» the own servers the main way can use, as hosts of their own
    /// (XrayManual, ADR 0027).
    @discardableResult
    private func applyXray(_ server: ServerID, interactive: Bool) async -> Bool {
        guard let config = Subscriptions.xray(for: server, configs: Self.cachedXray(subscriptions), own: manualProxies) else {
            lastError = nil
            return true
        }
        let data = RoutingHint.strippingXray(config)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-xray-\(UUID().uuidString).json")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return await handOver(file: file, hash: Self.hash(data), subscription: server.subscription, interactive: interactive) { [self] hash in
            importedXray(hash: hash, subscription: server.subscription)
        }
    }

    private func importedXray(hash: String, subscription: String) {
        control.setActiveSubscription(subscription)
        reloadProfileProxies()
        UserDefaults.standard.set(hash, forKey: Self.importedKey)
        UserDefaults.standard.set([CoreProxies.xrayGroup], forKey: KillSwitchControl.groupOrderKey)
        lastError = nil
        needsPassword = false
        needsConfirmation = false; routingChanged = false
    }

    /// Own servers by name with their entries, as ProxyLink reads them.
    private var manualProxies: [(name: String, proxy: [String: Any])] {
        manual.compactMap { server in (try? ProxyLink.parse(server.link)).map { (server.name, $0) } }
    }

    /// Why the main way cannot use this own server (it then works only with the other way); nil
    /// when it can, or when the own servers run the other way.
    func mainWayCannotUse(_ server: ManualServer) -> String? {
        guard core(of: ServerID.own) == .xray, let proxy = try? ProxyLink.parse(server.link) else { return nil }
        return XrayManual.unsupported(proxy)
    }

    /// The server the helper's profile is built for: the chosen one's subscription is `activeID`.
    private var selected: ServerID {
        ServerID(subscription: activeID, name: control.chosenServer.flatMap { $0.subscription == activeID ? $0.name : nil } ?? "")
    }

    /// The cached profile of the subscription the helper runs, to the helper again.
    @discardableResult
    private func applyCurrent(interactive: Bool) async -> Bool {
        await apply(to: selected, interactive: interactive)
    }

    /// The profile of the server's subscription (Subscriptions.profile), in the format of its core:
    /// the helper switches to that core by the profile (#65).
    private func apply(to server: ServerID, interactive: Bool) async -> Bool {
        if unusable(server.subscription) {
            lastError = Subscriptions.noCore
            return false
        }
        return core(of: server.subscription) == .xray ? await applyXray(server, interactive: interactive) : await apply(server, interactive: interactive)
    }

    /// «Выбор сервера» (ADR 0036): a server of the subscription the helper runs is chosen at once;
    /// one of another subscription (or of «Свои серверы») first has that subscription's profile
    /// handed to the helper, without the password when the last import approved it (#64), then is
    /// chosen in it.
    /// Blocking holds through the import as through any (ADR 0035).
    /// Only a server actually chosen goes to «Недавние»: not one whose import was cancelled or
    /// failed, nor a click while an update runs (it does nothing).
    func choose(_ entry: ServerPicker.Entry) async {
        if entry.subscription == activeID {
            control.choose(entry)
        } else {
            guard !updating, blocks.contains(where: { $0.id == entry.subscription }) else { return }
            updating = true
            defer { updating = false }
            guard await apply(to: entry.server, interactive: true), control.activeSubscription == entry.subscription else { return }
            await control.chooseImported(entry)
        }
        guard !entry.isFastest else { return }
        let keys = blocks.first { $0.id == entry.subscription }?.keys ?? [:]
        let recents = ServerRecents.list(UserDefaults.standard.string(forKey: ServerRecents.key) ?? "")
        UserDefaults.standard.set(ServerRecents.text(ServerRecents.adding(entry.server, keys: keys, to: recents)), forKey: ServerRecents.key)
    }

    private func took(_ headers: [String: String], source: SubscriptionSource, for id: String) {
        guard let host = subscriptions.first(where: { $0.id == id })?.host else { return }
        changeStatus(id) { status in
            status.title = SubscriptionHeaders.title(headers["profile-title"]) ?? status.title ?? host
            status.source = source
            status.usage = SubscriptionUsage(header: headers["subscription-userinfo"])
            status.serverInterval = SubscriptionHeaders.updateInterval(headers["profile-update-interval"])
            status.provider = ProviderInfo(headers: headers)
            status.accountURL = [headers["profile-web-page-url"], headers["support-url"]].lazy
                .compactMap { $0.flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
        }
        reloadProfileProxies()
        if id == current?.id { noticeLimits() }
    }

    /// «Подписка кончается» at 3 days and at 1 day, «Трафик почти закончился» past 90 %: once per
    /// threshold and period, not on every update.
    private func noticeLimits() {
        guard let usage = status.usage else { return }
        let defaults = UserDefaults.standard
        if let expire = usage.expire, let days = UserNotice.endingThreshold(secondsLeft: expire.timeIntervalSinceNow) {
            let mark = "\(Int(expire.timeIntervalSince1970))-\(days)"
            if defaults.string(forKey: "noticedEnding") != mark {
                defaults.set(mark, forKey: "noticedEnding")
                Notifier.shared.post(.subscriptionEnding(days: days, title: status.title, expire: expire))
            }
        }
        if let total = usage.total, total > 0, Double(usage.used) >= 0.9 * Double(total) {
            let mark = "\(total)-\(Int(usage.expire?.timeIntervalSince1970 ?? 0))"
            if defaults.string(forKey: "noticedTraffic") != mark {
                defaults.set(mark, forKey: "noticedTraffic")
                Notifier.shared.post(.trafficLow(used: usage.used, total: total))
            }
        }
    }

    // MARK: first run (Onboarding)

    /// Step «Ссылка на подписку»: adds and checks a subscription link (one already in the list is
    /// checked again), or takes share links or the text of a WireGuard file as own servers.
    /// Nothing reaches the helper yet, so no password.
    func check(_ text: String) async -> Onboarding.Found? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !updating else { return nil }
        lastError = nil
        if trimmed.lowercased().hasPrefix("http") {
            let key = Subscriptions.normalised(trimmed)
            let id: String
            var new = false
            if let kept = subscriptions.first(where: { key != nil && Subscriptions.link(of: $0.id, Self.store).flatMap(Subscriptions.normalised) == key }) {
                id = kept.id
            } else {
                switch Subscriptions.add(trimmed, Self.store) {
                case .success(let added):
                    id = added.id
                    new = true
                case .failure(.notKept):
                    lastError = UserError(title: String(localized: "Ссылка не сохранилась"), message: String(localized: "Не получилось сохранить ссылку в связке ключей."))
                    return nil
                case .failure:
                    lastError = Self.notALink
                    return nil
                }
                subscriptions = Subscriptions.load(Self.store)
            }
            setupSubscription = id
            // as `add`: a new link is kept only once it answered
            let failed = { [self] () -> Onboarding.Found? in
                if new { forget(id); setupSubscription = nil }
                return nil
            }
            updating = true
            defer { updating = false }
            let status = { [self] in subscriptions.first { $0.id == id }?.status ?? Status() }
            let profile: Profile
            switch await fetchEither(id) {
            case .xray(let xray): return Onboarding.Found(title: status().title, servers: xray.servers.count, expire: status().usage?.expire)
            case .mihomo(let fetched): profile = fetched
            case nil: return failed()
            }
            let found = Onboarding.Found(title: status().title, servers: (profile["proxies"] as? [Any])?.count ?? 0,
                                         expire: status().usage?.expire)
            if !found.ready { lastError = UserError.from(raw: "empty", context: .subscription) }
            return found
        }
        let links = ProxyLink.isWireGuardConf(trimmed)
            ? [trimmed]
            : trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let added = parse(links, name: nil) else { return nil }
        manual += added
        saveManual()
        setupSubscription = hasURL ? nil : ServerID.own
        reloadProfileProxies()
        return Onboarding.Found(title: nil, servers: manual.count, expire: nil, ownServers: true)
    }

    /// The subscription the wizard checked (or ServerID.own): the one it imports.
    private var setupSubscription: String?

    /// What is already there when the wizard is reopened.
    var found: Onboarding.Found? {
        guard let servers = profileProxies?.servers.count, servers > 0 else { return nil }
        return Onboarding.Found(title: status.title, servers: servers, expire: status.usage?.expire, ownServers: !hasURL)
    }

    /// The profile in a private temporary file, for `ks core import` inside the wizard's one admin
    /// command; `didImport` or `discard` removes the file.
    struct Prepared {
        let file: URL
        let hash: String
        /// The way of connecting it is for, set before the import (nil: the one the helper runs).
        let core: CoreChoice?
        fileprivate let profile: Profile?
        fileprivate let subscription: String
    }

    func prepareImport() -> Prepared? {
        let server = ServerID(subscription: setupSubscription ?? activeID, name: "")
        if unusable(server.subscription) {
            lastError = Subscriptions.noCore
            return nil
        }
        let core = core(of: server.subscription)
        if core == .xray {
            guard let config = Subscriptions.xray(for: server, configs: Self.cachedXray(subscriptions), own: manualProxies) else { return nil }
            let data = RoutingHint.strippingXray(config)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-xray-\(UUID().uuidString).json")
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
                return nil
            }
            return Prepared(file: file, hash: Self.hash(data), core: .xray, profile: nil, subscription: server.subscription)
        }
        guard let profile = forCore(server), let written = write(profile) else { return nil }
        return Prepared(file: written.file, hash: written.hash, core: core, profile: profile, subscription: server.subscription)
    }

    func didImport(_ prepared: Prepared) {
        if let profile = prepared.profile {
            imported(profile, hash: prepared.hash, subscription: prepared.subscription)
        } else {
            importedXray(hash: prepared.hash, subscription: prepared.subscription)
        }
        setupSubscription = nil
        // the wizard fetched the subscription a moment ago (check)
        if hasURL { schedule.record(.applied, now: Date()) }
        discard(prepared)
    }

    func discard(_ prepared: Prepared) { try? FileManager.default.removeItem(at: prepared.file) }

    private func write(_ profile: Profile) -> (file: URL, hash: String)? {
        let data: Data
        do { data = try ProfileConverter.json(profile) } catch {
            lastError = UserError.from(raw: "profile: \(error.localizedDescription)", context: .subscription)
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-profile-\(UUID().uuidString).json")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
            return nil
        }
        return (file, Self.hash(data))
    }

    /// Imports the last fetched subscription with the admin password. Only from a click.
    func confirmNewServers() async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        if await applyCurrent(interactive: true) { schedule.record(.applied, now: Date()) }
    }

    /// Hands the server's subscription profile to the helper, unless the core already has exactly
    /// this. A click imports (admin prompt if needed); a timer only refreshes, which the helper
    /// refuses when new server addresses would have to be let out.
    /// True when the core has this profile now (imported, or it had it already).
    @discardableResult
    private func apply(_ server: ServerID, interactive: Bool) async -> Bool {
        guard let profile = forCore(server) else {
            lastError = nil
            return true
        }
        guard let (file, hash) = write(profile) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        return await handOver(file: file, hash: hash, subscription: server.subscription, interactive: interactive) { [self] hash in
            imported(profile, hash: hash, subscription: server.subscription)
        }
    }

    /// The written profile to the helper, unless the core already has exactly this: a click
    /// imports (admin prompt if needed), a timer only refreshes. `done` records what was imported.
    /// A click on another subscription's server first switches without the password (#64); the
    /// password import hands every subscription's profile, so one password approves them all.
    private func handOver(file: URL, hash: String, subscription: String, interactive: Bool, done: (String) -> Void) async -> Bool {
        if control.coreConfigured, UserDefaults.standard.string(forKey: Self.importedKey) == hash {
            done(hash)   // the subscription it is, too
            return true
        }
        let step = Subscriptions.handOver(interactive: interactive, switching: subscription != control.activeSubscription)
        if step == .use {
            let outcome = await control.coreUse(file: file.path)
            if outcome == .applied {
                done(hash)
                return true
            }
            guard Subscriptions.needsImport(after: outcome) else {
                if case .failed(let message) = outcome { lastError = UserError.from(raw: message, context: .subscription) }
                return false
            }
        }
        guard step != .refresh else {
            let outcome = await control.coreRefresh(file: file.path)
            switch outcome {
            case .applied:
                done(hash)
                return true
            case .newServers, .routingChanged:
                lastError = nil
                let routing = outcome != .newServers
                if !needsConfirmation || routing != routingChanged {
                    Notifier.shared.post(routing ? .routingChanged : .newServers)
                }
                needsConfirmation = true
                routingChanged = routing
            case .needsPassword: needsPassword = true
            case .failed(let message): lastError = UserError.from(raw: message, context: .subscription)
            }
            return false
        }
        let others = approvalFiles(besides: subscription)
        defer { others.forEach { try? FileManager.default.removeItem(at: $0) } }
        switch await control.coreImport(file: file.path, others: others.map(\.path), allowPassword: true) {
        case .ok:
            done(hash)
            return true
        case .cancelled:
            break
        case .needsPassword:
            needsPassword = true
        case .failed(let message):
            lastError = UserError.from(raw: message, context: .subscription)
        }
        return false
    }

    /// Whose servers «Подтвердить…» approves: every subscription the import hands the helper (#64).
    var approvalNote: String? {
        let titles = Dictionary(subscriptions.map { ($0.id, $0.title) } + [(ServerID.own, String(localized: "Свои серверы"))]) { first, _ in first }
        let all = subscriptions.map(\.id) + (manual.isEmpty ? [] : [ServerID.own])
        return Subscriptions.approvalNote(titles: Subscriptions.approvalOrder(running: activeID, all: all).compactMap { titles[$0] })
    }

    /// The other subscriptions' profiles (and the own servers'), each in the format of its core
    /// (#65), for it to approve with the one it runs (Subscriptions.approvalOrder). One that cannot be
    /// written is left out: it stays unapproved, and a switch to it asks again.
    private func approvalFiles(besides subscription: String) -> [URL] {
        let all = subscriptions.map(\.id) + (manual.isEmpty ? [] : [ServerID.own])
        let order = Subscriptions.approvalOrder(running: subscription, all: all)
        if order.count < all.count {
            HelperClient.log.notice("import: \(all.count - order.count) subscriptions over the limit left unapproved")
        }
        return order.dropFirst().compactMap { id in
            let server = ServerID(subscription: id, name: "")
            let data: Data? = switch core(of: id) {
            case .xray: Subscriptions.xray(for: server, configs: Self.cachedXray(subscriptions), own: manualProxies).map(RoutingHint.strippingXray)
            case .mihomo: forCore(server).flatMap { try? ProfileConverter.json($0) }
            case nil: nil   // no installed core runs it: left unapproved
            }
            guard let data else { return nil }
            // the servers' passwords: the user's only from the first byte
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-approve-\(UUID().uuidString).json")
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return file
        }
    }

    /// What goes to the helper: the server's subscription alone, or the own servers alone
    /// (Subscriptions.profile), plus the transport overrides (Transport).
    private func forCore(_ server: ServerID) -> Profile? {
        Subscriptions.profile(for: server, profiles: Self.cachedProfiles(subscriptions), own: manual.compactMap(Self.proxy))
            .map { RoutingHint.stripping(Transport.adding(transportOverrides, to: $0)) }
    }

    /// The blocks of the servers list from the caches, each in the format of its core (#65).
    private func reloadProfileProxies() {
        var result: [Block] = []
        let configs = Self.cachedXray(subscriptions)
        var profiles = Self.cachedProfiles(subscriptions)
        profiles[ServerID.own] = ProfileMerger.merge(subscription: nil, manual: manual.compactMap(Self.proxy))
        for (id, title) in subscriptions.map({ ($0.id, $0.title) }) + [(ServerID.own, String(localized: "Свои серверы"))] {
            if core(of: id) == .xray {
                let config = id == ServerID.own ? XrayManual.merge(subscription: nil, manual: manualProxies) : configs[id].flatMap { XrayManual.merge(subscription: $0, manual: []) }
                guard let servers = config?.servers else { continue }
                result.append(Block(id: id, title: title, proxies: CoreProxies(xrayServers: servers), keys: [:]))
            } else if core(of: id) == .mihomo, let profile = profiles[id] {
                result.append(Block(id: id, title: title, proxies: CoreProxies(profile: profile), keys: ServerIdentity.keys(profile)))
            }
        }
        transportServers = core(of: activeID) == .xray ? [] : profiles[activeID].map(Transport.servers) ?? []
        blocks = result
        migrateToServerKeys()
        // «Сменить страну на …» in Spotlight and Siri knows the new list
        KillSwitchShortcuts.updateAppShortcutParameters()
    }

    /// The override for a server of the list, by its identity (or, not migrated yet, its name).
    func transportOverride(for server: String) -> Transport.Override? {
        serverKeys[server].flatMap { transportOverrides[$0] } ?? transportOverrides[server]
    }

    /// Settings kept by server name before 0.13 move to the server's identity once it is known.
    private func migrateToServerKeys() {
        guard !serverKeys.isEmpty else { return }
        let overrides = ServerIdentity.migrate(transportOverrides, keys: serverKeys)
        if overrides != transportOverrides {
            transportOverrides = overrides
            UserDefaults.standard.set(Transport.encode(overrides), forKey: Transport.storeKey)
        }
    }

    private func imported(_ profile: Profile, hash: String, subscription: String) {
        control.setActiveSubscription(subscription)
        reloadProfileProxies()
        UserDefaults.standard.set(hash, forKey: Self.importedKey)
        let groups = (profile["proxy-groups"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        UserDefaults.standard.set(groups, forKey: KillSwitchControl.groupOrderKey)
        lastError = nil
        needsPassword = false
        needsConfirmation = false; routingChanged = false
    }

    /// The stored name wins: a `.conf` carries none, and it is what the list shows.
    private static func proxy(_ server: ManualServer) -> [String: Any]? {
        guard var proxy = try? ProxyLink.parse(server.link) else { return nil }
        proxy["name"] = server.name
        return proxy
    }

    // MARK: network

    /// `viaVPN`: through the core's loopback listener (SubscriptionSource.proxy), not the TUN's rules.
    private static func fetch(_ url: URL, viaVPN: Bool) async throws -> (String, [String: String]) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        for (name, value) in SubscriptionHeaders.request(appVersion: DeviceInfo.appVersion, hwid: DeviceInfo.hwid, osVersion: DeviceInfo.osVersion, model: DeviceInfo.model) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // ephemeral: the URL and the profile must not land in a disk cache or cookie store
        let configuration = URLSessionConfiguration.ephemeral
        if viaVPN { configuration.connectionProxyDictionary = SubscriptionSource.proxy }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: SubscriptionFetch.RedirectGuard(original: url))
        let data = try await SubscriptionFetch.collect(bytes)
        guard let http = response as? HTTPURLResponse else { throw FetchError.status(0, nil) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        let body = String(decoding: data, as: UTF8.self)
        if let problem = SubscriptionHeaders.hwidProblem(headers: headers) { throw FetchError.device(problem) }
        guard (200..<300).contains(http.statusCode) else {
            let hint = body.hasPrefix("<") ? nil : String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            throw FetchError.status(http.statusCode, hint)
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchError.empty }
        return (body, headers)
    }

    private enum FetchError: Error { case status(Int, String?), device(String), empty }

    /// Raw text for UserError (context .subscription), without the URL (URLError descriptions may
    /// carry it).
    private static func describe(_ error: Error) -> String {
        switch error {
        case FetchError.status(let code, let hint):
            return "HTTP \(code)" + (hint.map { $0.isEmpty ? "" : ": \($0)" } ?? "")
        case FetchError.device(let header):
            return header
        case FetchError.empty:
            return "empty"
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut:
                return "offline (URLError \(error.code.rawValue))"
            case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "certificate (URLError \(error.code.rawValue))"
            default:
                return "URLError \(error.code.rawValue)"
            }
        case let error as LocalizedError:
            return error.errorDescription ?? "\(error)"
        default:
            return "\(error)"
        }
    }

    // MARK: storage

    private func saveManual() {
        if manual.isEmpty {
            Keychain.delete(Self.linksAccount)
        } else if let data = try? JSONEncoder().encode(manual) {
            Keychain.write(Self.linksAccount, data)
        }
    }

    /// A subscription's last good profile (Subscriptions.cache), so a switch and own servers work
    /// offline. It holds server credentials, hence user-only permissions.
    private static func cache(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The Xray configs by subscription.
    private static func cachedXray(_ subscriptions: [Subscription]) -> [String: Data] {
        var result: [String: Data] = [:]
        for subscription in subscriptions {
            result[subscription.id] = try? Data(contentsOf: Subscriptions.cache(of: subscription.id, xray: true, store))
        }
        return result
    }

    /// The mihomo profiles by subscription.
    private static func cachedProfiles(_ subscriptions: [Subscription]) -> [String: Profile] {
        var result: [String: Profile] = [:]
        for subscription in subscriptions {
            guard let data = try? Data(contentsOf: Subscriptions.cache(of: subscription.id, xray: false, store)) else { continue }
            result[subscription.id] = try? JSONSerialization.jsonObject(with: data) as? Profile
        }
        return result
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
