import Foundation

enum ProxyLinkError: LocalizedError, Equatable {
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let scheme): String(localized: "Ссылки \(scheme):// не поддерживаются. Подходят vless, trojan, ss, hysteria2, tuic, wireguard.")
        case .malformed(let what): String(localized: "Ссылка неполная: \(what).")
        }
    }
}

/// Share links (vless://, trojan://, ss://, hysteria2://, tuic://, wireguard://) and wg-quick
/// `.conf` text → mihomo proxy entries.
enum ProxyLink {
    static func parse(_ raw: String) throws -> [String: Any] {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWireGuardConf(link) { return try WireGuard.parse(conf: link, name: nil) }
        guard let schemeEnd = link.range(of: "://") else { throw ProxyLinkError.malformed(String(localized: "нет схемы")) }
        let scheme = link[..<schemeEnd.lowerBound].lowercased()
        switch scheme {
        case "vless": return try vless(link)
        case "trojan": return try trojan(link)
        case "ss": return try shadowsocks(link)
        case "hysteria2", "hy2": return try hysteria2(link)
        case "tuic": return try tuic(link)
        case "wireguard", "wg": return try WireGuard.parse(link: link)
        default: throw ProxyLinkError.unsupported(scheme)
        }
    }

    /// A wg-quick file is one entry, not a list of links.
    static func isWireGuardConf(_ text: String) -> Bool {
        text.range(of: "[Interface]", options: .caseInsensitive) != nil
    }

    // MARK: protocols

    private static func vless(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        guard let uuid = parts.user, !uuid.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет UUID")) }
        var proxy = parts.base(type: "vless")
        proxy["uuid"] = uuid
        proxy["udp"] = true
        if let flow = parts.query["flow"], !flow.isEmpty { proxy["flow"] = flow }
        if let encryption = parts.query["encryption"], !encryption.isEmpty, encryption != "none" { proxy["encryption"] = encryption }
        let security = parts.query["security"] ?? "none"
        if security == "tls" || security == "reality" {
            proxy["tls"] = true
            if let sni = parts.query["sni"] ?? parts.query["peer"] { proxy["servername"] = sni }
        }
        applyCommon(parts, security: security, to: &proxy)
        return proxy
    }

    private static func trojan(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        guard let password = parts.user, !password.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет пароля")) }
        var proxy = parts.base(type: "trojan")
        proxy["password"] = password
        proxy["udp"] = true
        if let sni = parts.query["sni"] ?? parts.query["peer"] { proxy["sni"] = sni }
        applyCommon(parts, security: parts.query["security"] ?? "tls", to: &proxy)
        return proxy
    }

    private static func shadowsocks(_ link: String) throws -> [String: Any] {
        var link = link
        // legacy: ss://base64(method:password@host:port)#name
        let body = link.dropFirst(5).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if let first = body.first, !first.contains("@"), let decoded = Base64.decode(String(first.split(separator: "?").first ?? "")) {
            link = "ss://" + decoded + (body.count > 1 ? "#" + body[1] : "")
        }
        // userinfo can contain "/" or "=" from base64 or a 2022 key; split it off by hand
        guard let at = link.range(of: "@", options: .backwards) else { throw ProxyLinkError.malformed(String(localized: "нет сервера")) }
        let userinfo = String(link[link.index(link.startIndex, offsetBy: 5)..<at.lowerBound])
        let parts = try Parts("ss://x@" + link[at.upperBound...])
        let credentials: String
        if let decoded = Base64.decode(userinfo), decoded.contains(":") {
            credentials = decoded
        } else {
            credentials = userinfo.removingPercentEncoding ?? userinfo
        }
        let pair = credentials.split(separator: ":", maxSplits: 1).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет шифра или пароля")) }
        var proxy = parts.base(type: "ss")
        proxy["cipher"] = pair[0]
        proxy["password"] = pair[1]
        proxy["udp"] = true
        if let plugin = parts.query["plugin"], !plugin.isEmpty {
            let options = plugin.split(separator: ";").map(String.init)
            guard let kind = options.first, kind == "obfs-local" || kind == "simple-obfs" else {
                throw ProxyLinkError.malformed(String(localized: "плагин \(options.first ?? "") не поддерживается"))
            }
            var opts: [String: Any] = [:]
            for option in options.dropFirst() {
                let kv = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                if kv[0] == "obfs" { opts["mode"] = kv[1] }
                if kv[0] == "obfs-host" { opts["host"] = kv[1] }
            }
            proxy["plugin"] = "obfs"
            proxy["plugin-opts"] = opts
        }
        return proxy
    }

    private static func hysteria2(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        var proxy = parts.base(type: "hysteria2")
        // auth may be "user:pass" in the userinfo
        let auth = [parts.user, parts.password].compactMap { $0 }.joined(separator: ":")
        guard !auth.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет пароля")) }
        proxy["password"] = auth
        if let sni = parts.query["sni"] { proxy["sni"] = sni }
        if let obfs = parts.query["obfs"], !obfs.isEmpty, obfs != "none" {
            proxy["obfs"] = obfs
            if let password = parts.query["obfs-password"] { proxy["obfs-password"] = password }
        }
        if let ports = parts.query["mport"], !ports.isEmpty { proxy["ports"] = ports }
        if let pin = parts.query["pinSHA256"], !pin.isEmpty { proxy["fingerprint"] = pin }
        if let alpn = parts.query["alpn"], !alpn.isEmpty { proxy["alpn"] = alpn.split(separator: ",").map(String.init) }
        if parts.flag("insecure") { proxy["skip-cert-verify"] = true }
        return proxy
    }

    private static func tuic(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        guard let uuid = parts.user, !uuid.isEmpty, let password = parts.password else { throw ProxyLinkError.malformed(String(localized: "нет UUID или пароля")) }
        var proxy = parts.base(type: "tuic")
        proxy["uuid"] = uuid
        proxy["password"] = password
        if let sni = parts.query["sni"] { proxy["sni"] = sni }
        if let cc = parts.query["congestion_control"] { proxy["congestion-controller"] = cc }
        if let mode = parts.query["udp_relay_mode"] { proxy["udp-relay-mode"] = mode }
        if let alpn = parts.query["alpn"], !alpn.isEmpty { proxy["alpn"] = alpn.split(separator: ",").map(String.init) }
        if parts.flag("allow_insecure") || parts.flag("insecure") { proxy["skip-cert-verify"] = true }
        return proxy
    }

    /// Transport and TLS options shared by vless and trojan (Xray share-link conventions).
    private static func applyCommon(_ parts: Parts, security: String, to proxy: inout [String: Any]) {
        let q = parts.query
        let network = q["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "tcp"
        proxy["network"] = network
        if let fp = q["fp"], !fp.isEmpty { proxy["client-fingerprint"] = fp }
        if let alpn = q["alpn"], !alpn.isEmpty { proxy["alpn"] = alpn.split(separator: ",").map(String.init) }
        if parts.flag("allowInsecure") || parts.flag("insecure") { proxy["skip-cert-verify"] = true }
        if security == "reality" {
            var reality: [String: Any] = [:]
            if let pbk = q["pbk"] { reality["public-key"] = pbk }
            if let sid = q["sid"] { reality["short-id"] = sid }
            proxy["reality-opts"] = reality
        }
        switch network {
        case "ws", "httpupgrade":
            var ws: [String: Any] = [:]
            if let path = q["path"] { ws["path"] = path }
            if let host = q["host"], !host.isEmpty { ws["headers"] = ["Host": host] }
            if network == "httpupgrade" { ws["v2ray-http-upgrade"] = true; proxy["network"] = "ws" }
            proxy["ws-opts"] = ws
        case "grpc":
            proxy["grpc-opts"] = ["grpc-service-name": q["serviceName"] ?? ""]
        case "h2", "http":
            var h2: [String: Any] = [:]
            if let path = q["path"] { h2["path"] = network == "http" ? [path] : path as Any }
            if let host = q["host"], !host.isEmpty { h2["host"] = [host] }
            proxy[network == "h2" ? "h2-opts" : "http-opts"] = h2
        case "xhttp", "splithttp":
            var xhttp: [String: Any] = [:]
            if let path = q["path"] { xhttp["path"] = path }
            if let host = q["host"], !host.isEmpty { xhttp["host"] = host }
            if let mode = q["mode"], !mode.isEmpty { xhttp["mode"] = mode }
            proxy["network"] = "xhttp"
            proxy["xhttp-opts"] = xhttp
        default:
            break
        }
    }

    /// The generic URL pieces of a share link.
    private struct Parts {
        let user: String?
        let password: String?
        let host: String
        let port: Int
        let query: [String: String]
        let name: String?

        init(_ link: String) throws {
            guard let components = URLComponents(string: link) else { throw ProxyLinkError.malformed(String(localized: "не разбирается как адрес")) }
            guard var host = components.host, !host.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет сервера")) }
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard let port = components.port, (1...65535).contains(port) else { throw ProxyLinkError.malformed(String(localized: "нет порта")) }
            self.host = host
            self.port = port
            user = components.user
            password = components.password
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            self.query = query
            name = components.fragment.flatMap { $0.isEmpty ? nil : $0 }
        }

        func flag(_ key: String) -> Bool { ["1", "true"].contains(query[key]?.lowercased() ?? "") }

        func base(type: String) -> [String: Any] {
            ["name": name ?? "\(host):\(port)", "type": type, "server": host, "port": port]
        }
    }
}
