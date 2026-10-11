import CryptoKit
import Foundation
import Observation

/// The VPN client side: subscription (URL in the keychain), servers added from share links,
/// and handing the merged profile to the helper (`ks core import`).
@MainActor
@Observable
final class VPNClient {
    struct ManualServer: Codable, Identifiable, Equatable {
        var id = UUID()
        var link: String
        var name: String
    }

    typealias Status = SubscriptionStatus

    private(set) var hasURL = false
    private(set) var maskedURL: String?
    /// #11: the person's backup link, asked when the main one fails; keychain, never logged.
    private(set) var maskedBackupURL: String?
    private(set) var status = Status()
    private(set) var manual: [ManualServer] = []
    private(set) var updating = false
    private(set) var lastError: UserError?
    /// Groups of the cached profile, for choosing a server before connecting.
    private(set) var profileProxies: CoreProxies?
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
    /// Server name → identity (ServerIdentity) in the cached profile: what per-server settings
    /// are kept under, so they survive a rename.
    private(set) var serverKeys: [String: String] = [:]
    /// «Начало работы»: the way of connecting the checked subscription was fetched for (ADR 0020).
    private var setupCore: CoreChoice?
    /// The raw reason the last Xray fetch failed, for the setup's fallback.
    private var lastXrayFailure: String?

    /// «Избранные» of the server list, by identity (names for servers not seen yet).
    static let favouritesKey = "favouriteServers"

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

    private var schedule: UpdateSchedule {
        get { UpdateSchedule(lastUpdate: status.lastUpdate, retryAt: retryAt) }
        set {
            retryAt = newValue.retryAt
            if newValue.lastUpdate != status.lastUpdate {
                status.lastUpdate = newValue.lastUpdate
                saveStatus()
            }
        }
    }

    private static let urlAccount = "subscription-url"
    private static let backupAccount = "subscription-url-backup"
    private static let linksAccount = "manual-links"
    private static let statusKey = "subscriptionStatus"
    private static let importedKey = "importedProfileHash"

    init(control: KillSwitchControl) {
        self.control = control
        if let url = Self.storedURL() {
            hasURL = true
            maskedURL = SubscriptionHeaders.masked(url)
        }
        maskedBackupURL = Self.storedBackupURL().map(SubscriptionHeaders.masked)
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
        if let data = UserDefaults.standard.data(forKey: Self.statusKey), let saved = try? JSONDecoder().decode(Status.self, from: data) {
            status = saved
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

    // MARK: subscription URL

    /// Shown only on request in Settings, never when the provider sent `hide-url` (#26); never logged.
    func revealURL() -> String? { urlHidden ? nil : Self.storedURL() }

    var urlHidden: Bool { status.provider?.hidesURL == true }

    /// Settings, a QR code and `killswitch://add`: a first link is kept at once; another one only
    /// once it answered, so a link that fails leaves the working one, its status and its servers
    /// (SubscriptionChange).
    /// `stillWanted`: asked right before a replacing link is kept (a link's sheet still open).
    @discardableResult
    func setURL(_ text: String, stillWanted: @escaping @MainActor () -> Bool = { true }) async -> SubscriptionChange.Outcome {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        guard Self.isSubscriptionLink(url) else {
            lastError = Self.notALink
            return .notKept
        }
        let change = SubscriptionChange.of(url, current: Self.storedURL())
        if change.storesBeforeFetch { guard store(url) else { return .notKept } }
        return await update(interactive: true, link: url, change: change, stillWanted: stillWanted)
    }

    /// The hosts of the subscription links (lower-cased): «Свои адреса сайтов» (ADR 0033) may not
    /// redirect them. Never shown or logged.
    func subscriptionHosts() -> Set<String> {
        Set([Self.storedURL(), Self.storedBackupURL()].compactMap { $0.flatMap { URLComponents(string: $0)?.host?.lowercased() } })
    }

    /// Shown only on request in Settings; never logged.
    func revealBackupURL() -> String? { Self.storedBackupURL() }

    /// «Резервная ссылка» (#11): kept like the main one, asked only when the main one fails.
    func setBackupURL(_ text: String) {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSubscriptionLink(url) else { lastError = Self.notALink; return }
        guard Keychain.write(Self.backupAccount, Data(url.utf8)) else {
            lastError = UserError(title: String(localized: "Ссылка не сохранилась"), message: String(localized: "Не получилось сохранить ссылку в связке ключей."))
            return
        }
        maskedBackupURL = SubscriptionHeaders.masked(url)
    }

    func removeBackupURL() {
        Keychain.delete(Self.backupAccount)
        maskedBackupURL = nil
    }

    private static func isSubscriptionLink(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        return components.scheme?.lowercased() == "https" && components.host?.isEmpty == false
    }

    private static let notALink = UserError(title: String(localized: "Это не ссылка на подписку"), message: String(localized: "Нужна ссылка вида https://…"))

    /// Keeps a subscription link in the keychain; the status starts over.
    private func store(_ url: String) -> Bool {
        guard Self.isSubscriptionLink(url) else {
            lastError = Self.notALink
            return false
        }
        guard Keychain.write(Self.urlAccount, Data(url.utf8)) else {
            lastError = UserError(title: String(localized: "Ссылка не сохранилась"), message: String(localized: "Не получилось сохранить ссылку в связке ключей."))
            return false
        }
        urlGeneration += 1
        hasURL = true
        maskedURL = SubscriptionHeaders.masked(url)
        status = Status()
        saveStatus()
        return true
    }

    func removeURL() async {
        urlGeneration += 1   // a replace in flight is not kept after this
        Keychain.delete(Self.urlAccount)
        try? FileManager.default.removeItem(at: Self.cacheFile)
        try? FileManager.default.removeItem(at: Self.xrayCacheFile)
        reloadProfileProxies()
        hasURL = false
        maskedURL = nil
        status = Status()
        saveStatus()
        lastError = nil
        if !manual.isEmpty { await applyManualOnly(interactive: true) }
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
        await applyCurrent(interactive: true)
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
        manual.removeAll { $0.id == server.id }
        saveManual()
        await applyCurrent(interactive: true)
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
        guard hasURL, !updating, schedule.isDue(interval: effectiveInterval, now: Date()) else { return }
        Task { await update(interactive: false) }
    }

    /// Fetches the subscription and applies it. On any failure the core keeps its old config.
    /// «Обновлено» moves only when the profile reached the core; otherwise again in an hour.
    /// `link` and `change`: a link given by the person (setURL); otherwise the kept one is updated.
    @discardableResult
    func update(interactive: Bool, link: String? = nil, change: SubscriptionChange = .same,
                stillWanted: @escaping @MainActor () -> Bool = { true }) async -> SubscriptionChange.Outcome {
        guard let url = (link ?? Self.storedURL()).flatMap(URL.init(string:)) else {
            if !manual.isEmpty { await applyManualOnly(interactive: interactive) }
            return .notKept
        }
        guard !updating else {
            // the kept link is being fetched: a new one would be dropped without a word
            if change == .replace {
                lastError = UserError(title: String(localized: "Подписка сейчас обновляется"),
                                      message: String(localized: "Попробуй ещё раз через минуту."))
            }
            return .notKept
        }
        updating = true
        defer { updating = false }
        let commit = change == .replace ? link.map { Commit(url: $0, allowed: unchanged(and: stillWanted)) } : nil
        let applied: Bool
        if usesXray {
            guard let xray = await fetchXray(url, change: change, commit: commit) else { return .notKept }
            applied = await applyXray(xray.data, interactive: interactive)
        } else {
            guard let profile = await fetchProfile(url, change: change, commit: commit) else { return .notKept }
            applied = await apply(subscription: profile, interactive: interactive)
        }
        schedule.record(applied ? .applied : .notApplied, now: Date())
        if applied { return .applied }
        // a new link is kept but the core still runs the old servers: say so, also after a
        // cancelled password prompt (which sets no error); «Обновить» applies it
        if change != .same, lastError == nil { needsPassword = true }
        return .keptNotApplied
    }

    /// A replacing link, kept only if `allowed` still holds once it answered.
    private struct Commit {
        let url: String
        let allowed: @MainActor () -> Bool
    }

    /// A new link answered but could not be kept in the keychain (`store` said why).
    private struct NotKept: Error {}
    /// A new link answered, but the link was removed or another one given meanwhile, or its sheet
    /// went away: nothing is kept, nothing is said.
    private struct Abandoned: Error {}

    /// Bumped by every change of the kept link (store, removeURL): a replace that started before
    /// one is not kept.
    private var urlGeneration = 0

    private func unchanged(and stillWanted: @escaping @MainActor () -> Bool = { true }) -> @MainActor () -> Bool {
        let generation = urlGeneration
        return { [weak self] in self?.urlGeneration == generation && stillWanted() }
    }

    /// Keeps a replacing link that answered; its old backup link belonged to the old subscription.
    private func keep(_ commit: Commit?) throws {
        guard let commit else { return }
        guard commit.allowed() else { throw Abandoned() }
        guard store(commit.url) else { throw NotKept() }
        if maskedBackupURL != nil { removeBackupURL() }
    }

    /// Downloads and caches the subscription, without handing it to the helper. The cache is what
    /// «Разрешить…» (confirmNewServers) and manual servers build on, so it is the last fetched
    /// profile, applied or not. A failed fetch, or one without servers, leaves the cache and the
    /// core's config alone. #11: tried in SubscriptionSource.order; the first error is shown.
    /// `commit`: a replacing link, kept (and the status started over) only once it answered.
    private func fetchProfile(_ url: URL, change: SubscriptionChange = .same, commit: Commit? = nil) async -> Profile? {
        let backup = Self.storedBackupURL().flatMap(URL.init(string:))
        var firstError: String?
        for source in change.sources(hasBackup: backup != nil, vpnRunning: control.coreRunning) {
            guard let link = source.usesBackup ? backup : url else { continue }
            do {
                return try await fetchProfile(link, source: source, title: url.host, commit: commit)
            } catch is NotKept, is Abandoned {
                return nil
            } catch {
                firstError = firstError ?? Self.describe(error)
            }
        }
        let raw = firstError ?? "empty"
        if change.recordsFailure { schedule.record(.fetchFailed(offline: raw.hasPrefix("offline")), now: Date()) }
        lastError = UserError.from(raw: raw, context: .subscription)
        return nil
    }

    private func fetchProfile(_ url: URL, source: SubscriptionSource, title: String?, commit: Commit?) async throws -> Profile {
        let (body, headers) = try await Self.fetch(url, viaVPN: source.viaVPN)
        let (profile, leftOut) = try ProfileConverter.read(subscription: body)
        try keep(commit)
        UserDefaults.standard.set(leftOut, forKey: RoutingReport.leftOutKey)
        Self.cache(profile)
        took(headers, source: source, title: title)
        return profile
    }

    // MARK: the main way of connecting (ADR 0020)

    /// The helper runs Xray: the subscription is the panel's Xray config (XrayProfile).
    private var usesXray: Bool { control.coreChoice == .xray }

    /// The same sources and order as fetchProfile; the link plus XrayProfile.pathComponent.
    private func fetchXray(_ url: URL, change: SubscriptionChange = .same, commit: Commit? = nil) async -> XrayProfile? {
        let backup = Self.storedBackupURL().flatMap(URL.init(string:))
        var firstError: String?
        for source in change.sources(hasBackup: backup != nil, vpnRunning: control.coreRunning) {
            guard let link = source.usesBackup ? backup : url else { continue }
            do {
                return try await fetchXray(link, source: source, title: url.host, commit: commit)
            } catch is NotKept, is Abandoned {
                return nil
            } catch {
                firstError = firstError ?? Self.describe(error)
            }
        }
        let raw = firstError ?? "empty"
        lastXrayFailure = raw
        if change.recordsFailure { schedule.record(.fetchFailed(offline: raw.hasPrefix("offline")), now: Date()) }
        lastError = change.xrayFailure(raw: raw) ?? UserError.from(raw: raw, context: .subscription)
        return nil
    }

    private func fetchXray(_ url: URL, source: SubscriptionSource, title: String?, commit: Commit?) async throws -> XrayProfile {
        let (body, headers) = try await Self.fetch(XrayProfile.url(for: url), viaVPN: source.viaVPN)
        let profile = try XrayProfile(body: body)
        try keep(commit)
        UserDefaults.standard.set([String](), forKey: RoutingReport.leftOutKey)
        Self.cacheXray(profile.data)
        took(headers, source: source, title: title)
        return profile
    }

    /// The panel's config to the helper (refresh, or import with the password on a click), with the
    /// own servers the main way can use as hosts of their own (XrayManual, ADR 0027).
    @discardableResult
    private func applyXray(_ subscription: Data?, interactive: Bool) async -> Bool {
        guard let data = XrayManual.merge(subscription: subscription, manual: manualProxies)?.data else {
            lastError = nil
            return true
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-xray-\(UUID().uuidString).json")
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return await handOver(file: file, hash: Self.hash(data), interactive: interactive) { [self] hash in importedXray(hash: hash) }
    }

    private func importedXray(hash: String) {
        reloadProfileProxies()
        UserDefaults.standard.set(hash, forKey: Self.importedKey)
        UserDefaults.standard.set([CoreProxies.xrayGroup], forKey: KillSwitchControl.groupOrderKey)
        lastError = nil
        needsPassword = false
        needsConfirmation = false; routingChanged = false
    }

    /// No subscription: the own servers alone, in the format of the way the helper runs.
    private func applyManualOnly(interactive: Bool) async {
        if usesXray { await applyXray(nil, interactive: interactive) } else { await apply(subscription: nil, interactive: interactive) }
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

    /// The cached subscription of the way the helper runs, to the helper again.
    @discardableResult
    private func applyCurrent(interactive: Bool) async -> Bool {
        if usesXray { return await applyXray(Self.cachedXray(), interactive: interactive) }
        return await apply(subscription: Self.cachedSubscription(), interactive: interactive)
    }

    /// Settings › «Способ подключения»: the helper switches (one password) and the subscription is
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

    private func took(_ headers: [String: String], source: SubscriptionSource, title: String?) {
        status.title = SubscriptionHeaders.title(headers["profile-title"]) ?? status.title ?? title
        status.source = source
        status.usage = SubscriptionUsage(header: headers["subscription-userinfo"])
        status.serverInterval = SubscriptionHeaders.updateInterval(headers["profile-update-interval"])
        status.provider = ProviderInfo(headers: headers)
        status.accountURL = [headers["profile-web-page-url"], headers["support-url"]].lazy
            .compactMap { $0.flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
        saveStatus()
        reloadProfileProxies()
        noticeLimits()
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

    /// Step «Ссылка на подписку»: keeps and checks a subscription link, or takes share links or the
    /// text of a WireGuard file as own servers. Nothing reaches the helper yet, so no password.
    func check(_ text: String) async -> Onboarding.Found? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !updating else { return nil }
        lastError = nil
        if trimmed.lowercased().hasPrefix("http") {
            // as setURL: another link replaces the kept one only once it answered (SubscriptionChange)
            guard Self.isSubscriptionLink(trimmed), let url = URL(string: trimmed) else {
                lastError = Self.notALink
                return nil
            }
            let change = SubscriptionChange.of(trimmed, current: Self.storedURL())
            if change.storesBeforeFetch { guard store(trimmed) else { return nil } }
            let commit = change == .replace ? Commit(url: trimmed, allowed: unchanged()) : nil
            updating = true
            defer { updating = false }
            setupCore = nil
            lastXrayFailure = nil
            if usesXray {
                if let xray = await fetchXray(url, change: change, commit: commit) {
                    setupCore = .xray
                    return Onboarding.Found(title: status.title, servers: xray.servers.count, expire: status.usage?.expire)
                }
                // ADR 0020: a service without the main way's format still works the other way;
                // only while setting up, before anything was imported
                guard !control.coreConfigured, let failure = lastXrayFailure,
                      failure == XrayProfile.Failure.notXray.errorDescription || failure.hasPrefix("HTTP 404") else { return nil }
                lastError = nil
            }
            guard let profile = await fetchProfile(url, change: change, commit: commit) else { return nil }
            setupCore = usesXray ? .mihomo : nil
            let found = Onboarding.Found(title: status.title, servers: (profile["proxies"] as? [Any])?.count ?? 0,
                                         expire: status.usage?.expire)
            if !found.ready { lastError = UserError.from(raw: "empty", context: .subscription) }
            return found
        }
        let links = ProxyLink.isWireGuardConf(trimmed)
            ? [trimmed]
            : trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let added = parse(links, name: nil) else { return nil }
        manual += added
        saveManual()
        // ADR 0027: own servers the main way cannot use at all are set up with the other way
        setupCore = usesXray && !hasURL && !control.coreConfigured && manual.allSatisfy({ mainWayCannotUse($0) != nil }) ? .mihomo : nil
        reloadProfileProxies()
        return Onboarding.Found(title: nil, servers: manual.count, expire: nil, ownServers: true)
    }

    /// What is already there when the wizard is reopened.
    var found: Onboarding.Found? {
        guard let servers = profileProxies?.servers.count, servers > 0 else { return nil }
        return Onboarding.Found(title: status.title, servers: servers, expire: status.usage?.expire, ownServers: !hasURL)
    }

    /// The merged profile in a private temporary file, for `ks core import` inside the wizard's one
    /// admin command; `didImport` or `discard` removes the file.
    struct Prepared {
        let file: URL
        let hash: String
        /// The way of connecting it is for, set before the import (nil: the one the helper runs).
        let core: CoreChoice?
        fileprivate let profile: Profile?
    }

    func prepareImport() -> Prepared? {
        if (setupCore ?? control.coreChoice) == .xray {
            guard let data = XrayManual.merge(subscription: Self.cachedXray(), manual: manualProxies)?.data else { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-xray-\(UUID().uuidString).json")
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                lastError = UserError.from(raw: "profile file: \(error.localizedDescription)", context: .subscription)
                return nil
            }
            return Prepared(file: file, hash: Self.hash(data), core: .xray, profile: nil)
        }
        guard let profile = forCore(Self.cachedSubscription()),
              let written = write(profile) else { return nil }
        return Prepared(file: written.file, hash: written.hash, core: setupCore, profile: profile)
    }

    func didImport(_ prepared: Prepared) {
        if let profile = prepared.profile { imported(profile, hash: prepared.hash) } else { importedXray(hash: prepared.hash) }
        setupCore = nil
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

    /// Merges with the manual servers and hands the result to the helper, unless the core already
    /// has exactly this. A click imports (admin prompt if needed); a timer only refreshes, which
    /// the helper refuses when new server addresses would have to be let out.
    /// True when the core has this profile now (imported, or it had it already).
    @discardableResult
    private func apply(subscription: Profile?, interactive: Bool) async -> Bool {
        guard let profile = forCore(subscription) else {
            lastError = nil
            return true
        }
        guard let (file, hash) = write(profile) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        return await handOver(file: file, hash: hash, interactive: interactive) { [self] hash in imported(profile, hash: hash) }
    }

    /// The written profile to the helper, unless the core already has exactly this: a click
    /// imports (admin prompt if needed), a timer only refreshes. `done` records what was imported.
    private func handOver(file: URL, hash: String, interactive: Bool, done: (String) -> Void) async -> Bool {
        if control.coreConfigured, UserDefaults.standard.string(forKey: Self.importedKey) == hash {
            lastError = nil
            needsPassword = false
            needsConfirmation = false; routingChanged = false
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
                let routing = outcome == .routingChanged
                if !needsConfirmation || routing != routingChanged { Notifier.shared.post(routing ? .routingChanged : .newServers) }
                needsConfirmation = true
                routingChanged = routing
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

    /// What goes to the helper: the subscription with the own servers, plus the same-country sets
    /// the helper turns into failover groups (Failover) and the transport overrides (Transport).
    private func forCore(_ subscription: Profile?) -> Profile? {
        ProfileMerger.merge(subscription: subscription, manual: manual.compactMap(Self.proxy))
            .map { Transport.adding(transportOverrides, to: Failover.adding(to: $0)) }
    }

    private func reloadProfileProxies() {
        if usesXray {
            profileProxies = XrayManual.merge(subscription: Self.cachedXray(), manual: manualProxies)
                .map { CoreProxies(xrayServers: $0.servers) }
            transportServers = []
            serverKeys = [:]
            KillSwitchShortcuts.updateAppShortcutParameters()
            return
        }
        let profile = ProfileMerger.merge(subscription: Self.cachedSubscription(), manual: manual.compactMap(Self.proxy))
        profileProxies = profile.map(CoreProxies.init(profile:))
        transportServers = profile.map(Transport.servers) ?? []
        serverKeys = profile.map(ServerIdentity.keys) ?? [:]
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
        let stored = (UserDefaults.standard.string(forKey: Self.favouritesKey) ?? "").split(separator: "\n").map(String.init)
        let favourites = ServerIdentity.migrate(stored, keys: serverKeys)
        if favourites != stored { UserDefaults.standard.set(favourites.joined(separator: "\n"), forKey: Self.favouritesKey) }
    }

    private func imported(_ profile: Profile, hash: String) {
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

    private static func storedURL() -> String? {
        Keychain.read(urlAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func storedBackupURL() -> String? {
        Keychain.read(backupAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func saveManual() {
        if manual.isEmpty {
            Keychain.delete(Self.linksAccount)
        } else if let data = try? JSONEncoder().encode(manual) {
            Keychain.write(Self.linksAccount, data)
        }
    }

    private func saveStatus() {
        UserDefaults.standard.set(try? JSONEncoder().encode(status), forKey: Self.statusKey)
    }

    /// Last good subscription profile, so manual servers can be added offline. It holds server
    /// credentials, hence user-only permissions.
    private static var cacheFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KillSwitch")
        return dir.appendingPathComponent("subscription.json")
    }

    private static func cache(_ profile: Profile) {
        guard let data = try? ProfileConverter.json(profile) else { return }
        let dir = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: cacheFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
    }

    private static var xrayCacheFile: URL { cacheFile.deletingLastPathComponent().appendingPathComponent("subscription-xray.json") }

    private static func cacheXray(_ data: Data) {
        let dir = xrayCacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: xrayCacheFile, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xrayCacheFile.path)
    }

    private static func cachedXray() -> Data? { try? Data(contentsOf: xrayCacheFile) }

    private static func cachedSubscription() -> Profile? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? Profile
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
