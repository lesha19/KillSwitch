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
    }

    private(set) var hasURL = false
    private(set) var maskedURL: String?
    private(set) var status = Status()
    private(set) var manual: [ManualServer] = []
    private(set) var updating = false
    private(set) var lastError: String?
    /// An automatic update found a new profile, but applying it needs the admin password.
    private(set) var needsPassword = false

    /// Hours between automatic updates; 0 = what the subscription asks for.
    var intervalHours = UserDefaults.standard.integer(forKey: "subscriptionIntervalHours") {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "subscriptionIntervalHours") }
    }

    var effectiveInterval: TimeInterval { intervalHours > 0 ? TimeInterval(intervalHours) * 3600 : status.serverInterval }
    var nextUpdate: Date? { status.lastUpdate.map { $0.addingTimeInterval(effectiveInterval) } }

    private let control: KillSwitchControl
    private var timer: Timer?
    /// After a failed automatic update: try again in an hour, not after the full interval.
    private var retryAt: Date?

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
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else {
            lastError = "Нужна ссылка вида https://…"
            return
        }
        guard Keychain.write(Self.urlAccount, Data(url.utf8)) else {
            lastError = "Не получилось сохранить ссылку в связке ключей."
            return
        }
        hasURL = true
        maskedURL = SubscriptionHeaders.masked(url)
        status = Status()
        saveStatus()
        await update(interactive: true)
    }

    func removeURL() async {
        Keychain.delete(Self.urlAccount)
        try? FileManager.default.removeItem(at: Self.cacheFile)
        hasURL = false
        maskedURL = nil
        status = Status()
        saveStatus()
        lastError = nil
        if !manual.isEmpty { await apply(subscription: nil, interactive: true) }
    }

    // MARK: manual servers

    func addLink(_ text: String) async {
        let links = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { return }
        var added: [ManualServer] = []
        for link in links {
            do {
                let proxy = try ProxyLink.parse(link)
                added.append(ManualServer(link: link, name: proxy["name"] as? String ?? "Сервер"))
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        manual += added
        saveManual()
        await apply(subscription: Self.cachedSubscription(), interactive: true)
    }

    func removeManual(_ server: ManualServer) async {
        manual.removeAll { $0.id == server.id }
        saveManual()
        await apply(subscription: Self.cachedSubscription(), interactive: true)
    }

    // MARK: updating

    func updateIfDue() {
        guard hasURL, !updating else { return }
        if let next = nextUpdate, next > Date() { return }
        if let retryAt, retryAt > Date() { return }
        Task { await update(interactive: false) }
    }

    /// Fetches the subscription and applies it. On any failure the core keeps its old config.
    func update(interactive: Bool) async {
        guard let url = Self.storedURL().flatMap(URL.init(string:)) else {
            if !manual.isEmpty { await apply(subscription: nil, interactive: interactive) }
            return
        }
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let (body, headers) = try await Self.fetch(url)
            let profile = try ProfileConverter.profile(fromSubscription: body)
            status.title = SubscriptionHeaders.title(headers["profile-title"]) ?? status.title ?? url.host
            status.usage = SubscriptionUsage(header: headers["subscription-userinfo"])
            status.serverInterval = SubscriptionHeaders.updateInterval(headers["profile-update-interval"])
            status.lastUpdate = Date()
            saveStatus()
            retryAt = nil
            Self.cache(profile)
            await apply(subscription: profile, interactive: interactive)
        } catch {
            retryAt = Date().addingTimeInterval(3600)
            lastError = Self.describe(error)
        }
    }

    /// Merges with the manual servers and imports, unless the core already has exactly this.
    private func apply(subscription: Profile?, interactive: Bool) async {
        guard let profile = ProfileMerger.merge(subscription: subscription, manual: manual.compactMap { try? ProxyLink.parse($0.link) }) else {
            lastError = nil
            return
        }
        let data: Data
        do { data = try ProfileConverter.json(profile) } catch {
            lastError = "Не получилось собрать профиль: \(error.localizedDescription)"
            return
        }
        let hash = Self.hash(data)
        if control.coreConfigured, UserDefaults.standard.string(forKey: Self.importedKey) == hash {
            lastError = nil
            needsPassword = false
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ks-profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            lastError = "Не получилось записать профиль: \(error.localizedDescription)"
            return
        }
        switch await control.coreImport(file: file.path, allowPassword: interactive) {
        case .ok:
            UserDefaults.standard.set(hash, forKey: Self.importedKey)
            let groups = (profile["proxy-groups"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            UserDefaults.standard.set(groups, forKey: KillSwitchControl.groupOrderKey)
            lastError = nil
            needsPassword = false
        case .cancelled:
            break
        case .needsPassword:
            needsPassword = true
        case .failed(let message):
            lastError = message
        }
    }

    // MARK: network

    private static func fetch(_ url: URL) async throws -> (String, [String: String]) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        for (name, value) in SubscriptionHeaders.request(hwid: DeviceInfo.hwid, osVersion: DeviceInfo.osVersion, model: DeviceInfo.model) {
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
        guard (200..<300).contains(http.statusCode) else {
            let hint = body.hasPrefix("<") ? nil : String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            throw FetchError.status(http.statusCode, hint)
        }
        return (body, headers)
    }

    private enum FetchError: Error { case status(Int, String?) }

    /// Error text without the URL (URLError descriptions may carry it).
    private static func describe(_ error: Error) -> String {
        switch error {
        case FetchError.status(let code, let hint):
            let reason = code == 404 ? "подписка не найдена" : code == 403 ? "доступ запрещён" : "ошибка \(code)"
            return "Сервер подписки ответил: \(reason)." + (hint.map { $0.isEmpty ? "" : " \($0)" } ?? "")
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut:
                return "Нет связи с сервером подписки. Если защита включена, а VPN нет — сначала подключись."
            case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "Сервер подписки не прошёл проверку сертификата."
            default:
                return "Не получилось скачать подписку (код \(error.code.rawValue))."
            }
        case let error as LocalizedError:
            return error.errorDescription ?? "Не получилось обновить подписку."
        default:
            return "Не получилось обновить подписку."
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
