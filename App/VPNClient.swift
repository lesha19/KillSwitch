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

    /// Saved state of the last successful fetch; no secrets in it.
    struct Status: Codable, Equatable {
        var title: String?
        var usage: SubscriptionUsage?
        var serverInterval: TimeInterval = SubscriptionHeaders.defaultInterval
        var lastUpdate: Date?
        /// The service's page (`profile-web-page-url` or `support-url`), for «Открыть кабинет».
        var accountURL: URL?
    }

    private(set) var hasURL = false
    private(set) var maskedURL: String?
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
    /// Settings › «Дополнительно»: fingerprint and multiplexing per server (Transport, ADR 0007).
    private(set) var transportOverrides = Transport.decode(UserDefaults.standard.data(forKey: Transport.storeKey))
    /// Servers of the cached profile whose transport can be changed, with the subscription's values.
    private(set) var transportServers: [Transport.Server] = []
    /// Server name → identity (ServerIdentity) in the cached profile: what per-server settings
    /// are kept under, so they survive a rename.
    private(set) var serverKeys: [String: String] = [:]

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
    private static let linksAccount = "manual-links"
    private static let statusKey = "subscriptionStatus"
    private static let importedKey = "importedProfileHash"

    init(control: KillSwitchControl) {
        self.control = control
        if let url = Self.storedURL() {
            hasURL = true
            maskedURL = SubscriptionHeaders.masked(url)
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

    /// Shown only on request in Settings; never logged.
    func revealURL() -> String? { Self.storedURL() }

    func setURL(_ text: String) async {
        guard store(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        await update(interactive: true)
    }

    /// Keeps a subscription link in the keychain; the status starts over.
    private func store(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else {
            lastError = UserError(title: String(localized: "Это не ссылка на подписку"), message: String(localized: "Нужна ссылка вида https://…"))
            return false
        }
        guard Keychain.write(Self.urlAccount, Data(url.utf8)) else {
            lastError = UserError(title: String(localized: "Ссылка не сохранилась"), message: String(localized: "Не получилось сохранить ссылку в связке ключей."))
            return false
        }
        hasURL = true
        maskedURL = SubscriptionHeaders.masked(url)
        status = Status()
        saveStatus()
        return true
    }

    func removeURL() async {
        Keychain.delete(Self.urlAccount)
        try? FileManager.default.removeItem(at: Self.cacheFile)
        reloadProfileProxies()
        hasURL = false
        maskedURL = nil
        status = Status()
        saveStatus()
        lastError = nil
        if !manual.isEmpty { await apply(subscription: nil, interactive: true) }
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
        await apply(subscription: Self.cachedSubscription(), interactive: true)
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
        await apply(subscription: Self.cachedSubscription(), interactive: true)
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
        await apply(subscription: Self.cachedSubscription(), interactive: false)
    }

    // MARK: updating

    func updateIfDue() {
        guard hasURL, !updating, schedule.isDue(interval: effectiveInterval, now: Date()) else { return }
        Task { await update(interactive: false) }
    }

    /// Fetches the subscription and applies it. On any failure the core keeps its old config.
    /// «Обновлено» moves only when the profile reached the core; otherwise again in an hour.
    func update(interactive: Bool) async {
        guard let url = Self.storedURL().flatMap(URL.init(string:)) else {
            if !manual.isEmpty { await apply(subscription: nil, interactive: interactive) }
            return
        }
        guard !updating else { return }
        updating = true
        defer { updating = false }
        guard let profile = await fetchProfile(url) else { return }
        let applied = await apply(subscription: profile, interactive: interactive)
        schedule.record(applied ? .applied : .notApplied, now: Date())
    }

    /// Downloads and caches the subscription, without handing it to the helper. The cache is what
    /// «Разрешить…» (confirmNewServers) and manual servers build on, so it is the last fetched
    /// profile, applied or not.
    private func fetchProfile(_ url: URL) async -> Profile? {
        do {
            let (body, headers) = try await Self.fetch(url)
            let profile = try ProfileConverter.profile(fromSubscription: body)
            status.title = SubscriptionHeaders.title(headers["profile-title"]) ?? status.title ?? url.host
            status.usage = SubscriptionUsage(header: headers["subscription-userinfo"])
            status.serverInterval = SubscriptionHeaders.updateInterval(headers["profile-update-interval"])
            status.accountURL = [headers["profile-web-page-url"], headers["support-url"]].lazy
                .compactMap { $0.flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
            saveStatus()
            Self.cache(profile)
            reloadProfileProxies()
            noticeLimits()
            return profile
        } catch {
            let raw = Self.describe(error)
            schedule.record(.fetchFailed(offline: raw.hasPrefix("offline")), now: Date())
            lastError = UserError.from(raw: raw, context: .subscription)
            return nil
        }
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
            guard store(trimmed), let url = URL(string: trimmed) else { return nil }
            updating = true
            defer { updating = false }
            guard let profile = await fetchProfile(url) else { return nil }
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
        fileprivate let profile: Profile
    }

    func prepareImport() -> Prepared? {
        guard let profile = forCore(Self.cachedSubscription()),
              let written = write(profile) else { return nil }
        return Prepared(file: written.file, hash: written.hash, profile: profile)
    }

    func didImport(_ prepared: Prepared) {
        imported(prepared.profile, hash: prepared.hash)
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
        if await apply(subscription: Self.cachedSubscription(), interactive: true) { schedule.record(.applied, now: Date()) }
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
        if control.coreConfigured, UserDefaults.standard.string(forKey: Self.importedKey) == hash {
            lastError = nil
            needsPassword = false
            needsConfirmation = false
            return true
        }
        guard interactive else {
            switch await control.coreRefresh(file: file.path) {
            case .applied:
                imported(profile, hash: hash)
                return true
            case .newServers:
                lastError = nil
                if !needsConfirmation { Notifier.shared.post(.newServers) }
                needsConfirmation = true
            case .needsPassword: needsPassword = true
            case .failed(let message): lastError = UserError.from(raw: message, context: .subscription)
            }
            return false
        }
        switch await control.coreImport(file: file.path, allowPassword: true) {
        case .ok:
            imported(profile, hash: hash)
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
        needsConfirmation = false
    }

    /// The stored name wins: a `.conf` carries none, and it is what the list shows.
    private static func proxy(_ server: ManualServer) -> [String: Any]? {
        guard var proxy = try? ProxyLink.parse(server.link) else { return nil }
        proxy["name"] = server.name
        return proxy
    }

    // MARK: network

    private static func fetch(_ url: URL) async throws -> (String, [String: String]) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        for (name, value) in SubscriptionHeaders.request(appVersion: DeviceInfo.appVersion, hwid: DeviceInfo.hwid, osVersion: DeviceInfo.osVersion, model: DeviceInfo.model) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // ephemeral: the URL and the profile must not land in a disk cache or cookie store
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
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

    private static func cachedSubscription() -> Profile? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? Profile
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
