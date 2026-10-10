import Foundation

/// The panel's Xray config for the main way of connecting (ADR 0020): Remnawave answers the
/// subscription link plus `/json` with an array of full Xray configs, one per host. The helper
/// builds the core's config from it (Helper/ks core_generate_xray); the app needs only the hosts'
/// names and the body to hand over.
struct XrayProfile: Equatable {
    /// Where the panel serves it, the one place to change: a path component after the link.
    /// Measured 2026-10-10: `<link>/json` with the usual User-Agent (SubscriptionHeaders) gives
    /// 200 application/json; other User-Agents are refused by StorkVPN's Caddy.
    static let pathComponent = "json"

    static func url(for link: URL) -> URL {
        guard var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/" + pathComponent) { path += "/" + pathComponent }
        parts.path = path
        return parts.url ?? link
    }

    enum Failure: LocalizedError, Equatable {
        case html, notXray, noServers

        var errorDescription: String? {
            switch self {
            case .html: ProfileError.html.errorDescription
            case .notXray:
                String(localized: "Сервис подписки не отдал настройки для основного способа подключения. Выбери запасной в настройках VPN.")
            case .noServers: ProfileError.noProxies.errorDescription
            }
        }
    }

    /// The body as it came.
    let data: Data
    /// The hosts by name (`remarks`, else «#n» as Helper/ks names them), in the panel's order.
    let servers: [String]

    init(body: String) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { throw Failure.html }
        guard trimmed.hasPrefix("["), let array = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] else {
            throw Failure.notXray
        }
        guard !array.isEmpty else { throw Failure.noServers }
        var servers: [String] = []
        for (index, item) in array.enumerated() {
            guard let config = item as? [String: Any], config["outbounds"] is [Any] else { throw Failure.notXray }
            let remarks = config["remarks"] as? String ?? ""
            servers.append(remarks.isEmpty ? "#\(index + 1)" : remarks)
        }
        data = Data(body.utf8)
        self.servers = servers
    }
}
