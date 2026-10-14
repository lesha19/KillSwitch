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
    private(set) var blocks: [Block] = []
    /// An automatic update found a new profile, but applying it needs the admin password
    /// (the installed helper does not allow `core refresh` without one).
    private(set) var needsPassword = false
    /// An automatic update brought new server addresses: the helper refused `core refresh`, and
    /// only a click (`confirmNewServers`) may import it with the admin password.
    private(set) var needsConfirmation = false
    /// KS-12: what waits for the admin is a change of what goes past the VPN (DIRECT, DNS), not servers.
    private(set) var routingChanged = false
    /// Which part of that change is the routing profile's, as the helper says (re-review F4), and
    /// the profile in use then (nil: «Как в подписке»).
    private(set) var routingSource: RoutingChangeSource = .subscription
    private(set) var routingProfileName: String?
    /// Settings › «Маршрутизация» (ADR 0034): the profiles added, the one in use (nil: «Как в подписке»).
    private(set) var routingProfiles = RoutingProfiles.load(links: .keychain)
    private(set) var activeRoutingProfile = UserDefaults.standard.string(forKey: RoutingProfiles.activeKey).flatMap(UUID.init(uuidString:))
    /// Settings › «Дополнительно»: fingerprint and multiplexing per server (Transport, ADR 0007).
    private(set) var transportOverrides = Transport.decode(UserDefaults.standard.data(forKey: Transport.storeKey))
    /// Servers of the cached profile whose transport can be changed, with the subscription's values.
    private(set) var transportServers: [Transport.Server] = []
    /// Server name → identity (ServerIdentity) in the profile the helper runs: what per-server
    /// settings are kept under, so they survive a rename.
    var serverKeys: [String: String] { activeBlock?.keys ?? [:] }
    /// «Начало работы»: the way of connecting the checked subscription was fetched for (ADR 0020).
    private var setupCore: CoreChoice?
    /// The raw reason the last Xray fetch failed, for the setup's fallback.
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

    /// The hosts of the subscription links (lower-cased): «Свои адреса сайтов» (ADR 0033) may not
    /// redirect them. Never shown or logged.
    func subscriptionHosts() -> Set<String> {
        Set(subscriptions.compactMap { Subscriptions.link(of: $0.id, Self.store).flatMap { URLComponents(string: $0)?.host?.lowercased() } })
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

    // MARK: routing profiles (ADR 0034)

    /// A link (https, fetched without the device's headers) or the profile itself (JSON, base64, a
    /// happ:// or incy:// routing link). The error to show, nil when added. Adding uses nothing yet.
    func addRoutingProfile(_ text: String) async -> String? {
        var profile: RoutingProfile
        do {
            if let url = RoutingProfile.sourceURL(text) {
                profile = try RoutingProfile.parse(try await Self.fetchRoutingProfile(url))
                profile.url = url.absoluteString
                profile.fetched = Date()
            } else {
                profile = try RoutingProfile.parse(text)
            }
        } catch let problem as RoutingProfile.Problem {
            return problem.message
        } catch {
            return String(localized: "Не удалось скачать профиль: \(Self.describe(error))")
        }
        routingProfiles.append(profile)
        RoutingProfiles.save(routingProfiles, links: .keychain)
        return nil
    }

    /// Puts a profile to use (nil: «Как в подписке») and hands the config over without a password;
    /// one that changes what goes past the VPN waits for «Подтвердить» with the admin's password,
    /// as a subscription's DIRECT change does (needsConfirmation, routingChanged).
    func useRoutingProfile(_ id: UUID?) async {
        guard !updating else { return }   // the picker waits for it too
        activeRoutingProfile = id
        UserDefaults.standard.set(id?.uuidString, forKey: RoutingProfiles.activeKey)
        await applyRouting()
    }

    func removeRoutingProfile(_ id: UUID) async {
        guard !updating else { return }   // a fetch puts its result back by id; the button waits too
        routingProfiles.removeAll { $0.id == id }
        RoutingProfiles.save(routingProfiles, links: .keychain)
        if activeRoutingProfile == id { await useRoutingProfile(nil) }
    }

    /// The profiles with a link, once a day (or all now, `force`); the one in use is handed over
    /// again when it changed. One run at a time, as `updating` (the picker and «Удалить профиль»
    /// wait for it); each result goes back by id, since the list may change during a fetch.
    func updateRoutingProfiles(force: Bool = false) async {
        guard !updating else { return }
        updating = true
        var changedActive = false
        let due = routingProfiles.filter { $0.url != nil && (force || $0.due(now: Date())) }
        for profile in due {
            guard let url = profile.url.flatMap(RoutingProfile.sourceURL) else { continue }
            let fetched: Result<RoutingProfile, Error>
            do { fetched = .success(try RoutingProfile.parse(try await Self.fetchRoutingProfile(url))) } catch { fetched = .failure(error) }
            routingProfiles = RoutingProfiles.changing(profile.id, in: routingProfiles) { current in
                switch fetched {
                case .success(let body):
                    let new = current.updated(with: body, at: Date())
                    if new.hint as NSDictionary != current.hint as NSDictionary, current.id == activeRoutingProfile { changedActive = true }
                    current = new
                case .failure(let problem as RoutingProfile.Problem):
                    current.error = problem.message
                    current.fetched = Date()
                case .failure(let error):
                    current.error = String(localized: "Не удалось скачать профиль: \(Self.describe(error))")
                    current.fetched = Date()
                }
            }
        }
        RoutingProfiles.save(routingProfiles, links: .keychain)
        updating = false
        if changedActive { await applyRouting() }
    }

    private func applyRouting() async {
        guard control.coreConfigured, !updating else { return }
        updating = true
        defer { updating = false }
        await applyCurrent(interactive: false)
    }

    /// A routing profile's link: a plain GET, no device headers (the link is not the provider's),
    /// no cookies or cache, the redirect and size limits of a subscription fetch.
    private static func fetchRoutingProfile(_ url: URL) async throws -> String {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let session = URLSession(configuration: RoutingProfile.fetchConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: SubscriptionFetch.RedirectGuard(original: url))
        let data = try await SubscriptionFetch.collect(bytes)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.status((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: updating

    func updateIfDue() {
        guard !updating else { return }
        let profilesDue = routingProfiles.contains { $0.due(now: Date()) }
        let subscriptionDue = hasURL && schedule.isDue(interval: effectiveInterval, now: Date())
        guard profilesDue || subscriptionDue else { return }
        // one after the other: both take `updating`, so side by side one would be skipped
        Task {
            if profilesDue { await updateRoutingProfiles() }
            if subscriptionDue { await update(interactive: false) }
        }
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

    /// Downloads and caches one subscription in the format of the way the helper runs, without
    /// handing it to the helper. The cache is what «Разрешить…» (confirmNewServers) and a switch
    /// build on, so it is the last fetched profile, applied or not. A failed fetch, or one without
    /// servers, leaves the cache alone. #11: tried in SubscriptionSource.order; the first error is shown.
    @discardableResult
    private func fetch(_ id: String) async -> Bool {
        usesXray ? await fetchXray(id) != nil : await fetchProfile(id) != nil
    }

    private func fetchProfile(_ id: String) async -> Profile? {
        guard let url = Subscriptions.link(of: id, Self.store).flatMap(URL.init(string:)) else { return nil }
        var firstError: String?
        for source in SubscriptionSource.order(vpnRunning: control.coreRunning) {
            do {
                let (body, headers) = try await Self.fetch(url, viaVPN: source.viaVPN)
                let read = try await ProfileConverter.readInBackground(subscription: body)   // off the main actor (#50)
                if id == activeID { UserDefaults.standard.set(read.leftOut, forKey: RoutingReport.leftOutKey) }
                guard subscriptions.contains(where: { $0.id == id }) else { return nil }   // deleted meanwhile
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

    /// The helper runs Xray: the subscription is the panel's Xray config (XrayProfile).
    private var usesXray: Bool { control.coreChoice == .xray }

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
        let data = RoutingProfiles.addingXray(RoutingProfiles.active(), to: config)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-xray-\(UUID().uuidString).json")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return await handOver(file: file, hash: Self.hash(data), interactive: interactive) { [self] hash in
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
    /// when it can, or when the helper runs the other way.
    func mainWayCannotUse(_ server: ManualServer) -> String? {
        guard usesXray, let proxy = try? ProxyLink.parse(server.link) else { return nil }
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

    /// The profile of the server's subscription (Subscriptions.profile), in the format of the way
    /// the helper runs.
    private func apply(to server: ServerID, interactive: Bool) async -> Bool {
        usesXray ? await applyXray(server, interactive: interactive) : await apply(server, interactive: interactive)
    }

    /// «Выбор сервера» (ADR 0036): a server of the subscription the helper runs is chosen at once;
    /// one of another subscription (or of «Свои серверы») first has that subscription's profile
    /// imported, with the admin's password (a switch without it: #64), then is chosen in it.
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

    /// Settings › «Способ подключения»: the helper switches (one password) and the subscriptions are
    /// fetched again in that way's format and imported; a VPN that was on comes back.
    func switchCore(to choice: CoreChoice) {
        guard choice != control.coreChoice, !updating else { return }
        let wasOn = control.coreRunning
        control.setCore(choice) { [self] in
            reloadProfileProxies()
            await update(interactive: true)
            if wasOn, control.coreConfigured { control.coreOn() }
        }
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
            setupCore = nil
            lastXrayFailure = nil
            let status = { [self] in subscriptions.first { $0.id == id }?.status ?? Status() }
            if usesXray {
                if let xray = await fetchXray(id) {
                    setupCore = .xray
                    return Onboarding.Found(title: status().title, servers: xray.servers.count, expire: status().usage?.expire)
                }
                // ADR 0020: a service without the main way's format still works the other way;
                // only while setting up, before anything was imported
                guard !control.coreConfigured, let failure = lastXrayFailure,
                      failure == XrayProfile.Failure.notXray.errorDescription || failure.hasPrefix("HTTP 404") else { return failed() }
                lastError = nil
            }
            guard let profile = await fetchProfile(id) else { return failed() }
            setupCore = usesXray ? .mihomo : nil
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
        // ADR 0027: own servers the main way cannot use at all are set up with the other way
        setupCore = usesXray && !hasURL && !control.coreConfigured && manual.allSatisfy({ mainWayCannotUse($0) != nil }) ? .mihomo : nil
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
        if (setupCore ?? control.coreChoice) == .xray {
            guard let config = Subscriptions.xray(for: server, configs: Self.cachedXray(subscriptions), own: manualProxies) else { return nil }
            let data = RoutingProfiles.addingXray(RoutingProfiles.active(), to: config)
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
        return Prepared(file: written.file, hash: written.hash, core: setupCore, profile: profile, subscription: server.subscription)
    }

    func didImport(_ prepared: Prepared) {
        if let profile = prepared.profile {
            imported(profile, hash: prepared.hash, subscription: prepared.subscription)
        } else {
            importedXray(hash: prepared.hash, subscription: prepared.subscription)
        }
        setupCore = nil
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
        return await handOver(file: file, hash: hash, interactive: interactive) { [self] hash in
            imported(profile, hash: hash, subscription: server.subscription)
        }
    }

    /// The written profile to the helper, unless the core already has exactly this: a click
    /// imports (admin prompt if needed), a timer only refreshes. `done` records what was imported.
    private func handOver(file: URL, hash: String, interactive: Bool, done: (String) -> Void) async -> Bool {
        if control.coreConfigured, UserDefaults.standard.string(forKey: Self.importedKey) == hash {
            done(hash)   // the subscription it is, too
            return true
        }
        guard interactive else {
            let outcome = await control.coreRefresh(file: file.path)
            switch outcome {
            case .applied:
                done(hash)
                return true
            case .newServers, .routingChanged:
                lastError = nil
                var source = RoutingChangeSource.subscription
                if case .routingChanged(let part) = outcome { source = part }
                let routing = outcome != .newServers
                if !needsConfirmation || routing != routingChanged || source != routingSource {
                    // the provider's part is told as the provider's
                    Notifier.shared.post(!routing ? .newServers : source == .profile ? .profileRouting : .routingChanged)
                }
                needsConfirmation = true
                routingChanged = routing
                routingSource = source
                routingProfileName = RoutingProfiles.active()?.name
            case .needsPassword: needsPassword = true
            case .failed(let message): lastError = UserError.from(raw: message, context: .subscription)
            }
            return false
        }
        switch await control.coreImport(file: file.path, allowPassword: true) {
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

    /// What goes to the helper: the server's subscription alone, or the own servers alone
    /// (Subscriptions.profile), plus the transport overrides (Transport).
    private func forCore(_ server: ServerID) -> Profile? {
        Subscriptions.profile(for: server, profiles: Self.cachedProfiles(subscriptions), own: manual.compactMap(Self.proxy))
            .map { RoutingProfiles.adding(RoutingProfiles.active(), to: Transport.adding(transportOverrides, to: $0)) }
    }

    /// The blocks of the servers list from the caches, in the format of the way the helper runs.
    private func reloadProfileProxies() {
        var result: [Block] = []
        let own = String(localized: "Свои серверы")
        if usesXray {
            let configs = Self.cachedXray(subscriptions)
            for subscription in subscriptions {
                guard let servers = configs[subscription.id].flatMap({ XrayManual.merge(subscription: $0, manual: [])?.servers }) else { continue }
                result.append(Block(id: subscription.id, title: subscription.title, proxies: CoreProxies(xrayServers: servers), keys: [:]))
            }
            if let servers = XrayManual.merge(subscription: nil, manual: manualProxies)?.servers {
                result.append(Block(id: ServerID.own, title: own, proxies: CoreProxies(xrayServers: servers), keys: [:]))
            }
            transportServers = []
        } else {
            var profiles = Self.cachedProfiles(subscriptions)
            profiles[ServerID.own] = ProfileMerger.merge(subscription: nil, manual: manual.compactMap(Self.proxy))
            for (id, title) in subscriptions.map({ ($0.id, $0.title) }) + [(ServerID.own, own)] {
                guard let profile = profiles[id] else { continue }
                result.append(Block(id: id, title: title, proxies: CoreProxies(profile: profile), keys: ServerIdentity.keys(profile)))
            }
            transportServers = profiles[activeID].map(Transport.servers) ?? []
        }
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
