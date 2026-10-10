import Foundation

enum ProxyLinkError: LocalizedError, Equatable {
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let scheme): String(localized: "Ссылки \(scheme):// не поддерживаются. Подходят vless, vmess, trojan, ss, hysteria2, tuic, anytls, socks, http, wireguard.")
        case .malformed(let what): String(localized: "Ссылка неполная: \(what).")
        }
    }
}

/// Share links (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, anytls://, socks5://,
/// http(s)://, wireguard://) and wg-quick `.conf` text → mihomo proxy entries. Only keys of the
/// protocol come out, never a file path, an interface or a dialer: the helper refuses those.
enum ProxyLink {
    static func parse(_ raw: String) throws -> [String: Any] {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWireGuardConf(link) { return try WireGuard.parse(conf: link, name: nil) }
        guard let schemeEnd = link.range(of: "://") else { throw ProxyLinkError.malformed(String(localized: "нет схемы")) }
        let scheme = link[..<schemeEnd.lowerBound].lowercased()
        switch scheme {
        case "vless": return try vless(link)
        case "vmess": return try vmess(link)
        case "trojan": return try trojan(link)
        case "ss": return try shadowsocks(link)
        case "hysteria2", "hy2": return try hysteria2(link)
        case "tuic": return try tuic(link)
        case "anytls": return try anytls(link)
        case "socks", "socks5", "socks5h": return try socks(link)
        case "http", "https": return try httpProxy(link, tls: scheme == "https")
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

    /// v2rayN's `vmess://base64(JSON)`, or the URI form `vmess://uuid@host:port?…` of Xray's share standard.
    private static func vmess(_ link: String) throws -> [String: Any] {
        let body = link.dropFirst("vmess://".count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let decoded = Base64.decode(String(body.first ?? "")),
              let json = (try? JSONSerialization.jsonObject(with: Data(decoded.utf8))) as? [String: Any] else {
            let parts = try Parts(link)
            guard let uuid = parts.user, !uuid.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет UUID")) }
            var proxy = parts.base(type: "vmess")
            proxy["uuid"] = uuid
            proxy["alterId"] = 0
            proxy["cipher"] = parts.query["encryption"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
            proxy["udp"] = true
            let security = parts.query["security"] ?? "none"
            if security == "tls" {
                proxy["tls"] = true
                if let sni = parts.query["sni"] { proxy["servername"] = sni }
            }
            applyCommon(parts, security: security, to: &proxy)
            return proxy
        }
        func field(_ key: String) -> String? {
            switch json[key] {
            case let text as String: text.isEmpty ? nil : text
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        guard let host = field("add") else { throw ProxyLinkError.malformed(String(localized: "нет сервера")) }
        guard let port = field("port").flatMap(Int.init), (1...65535).contains(port) else { throw ProxyLinkError.malformed(String(localized: "нет порта")) }
        guard let uuid = field("id") else { throw ProxyLinkError.malformed(String(localized: "нет UUID")) }
        // the JSON's fields as the query of a URI-form link, so the transports are read in one place
        var net = field("net") ?? "tcp"
        if net == "tcp" && field("type") == "http" { net = "http" }
        var query: [String: String] = ["type": net]
        for (key, name) in [("path", "path"), ("host", "host"), ("fp", "fp"), ("alpn", "alpn"), ("sni", "sni")] {
            if let value = field(key) { query[name] = value }
        }
        if net == "grpc" { query["serviceName"] = field("path") ?? "" }
        let parts = Parts(host: host, port: port, query: query, name: field("ps"))
        var proxy = parts.base(type: "vmess")
        proxy["uuid"] = uuid
        proxy["alterId"] = field("aid").flatMap(Int.init) ?? 0
        proxy["cipher"] = field("scy") ?? "auto"
        proxy["udp"] = true
        let security = field("tls") ?? "none"
        if security == "tls" {
            proxy["tls"] = true
            if let sni = field("sni") { proxy["servername"] = sni }
        }
        applyCommon(parts, security: security, to: &proxy)
        return proxy
    }

    /// `anytls://password@host:port?sni=…&fp=…&insecure=1#name`
    private static func anytls(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        guard let password = parts.user, !password.isEmpty else { throw ProxyLinkError.malformed(String(localized: "нет пароля")) }
        var proxy = parts.base(type: "anytls")
        proxy["password"] = password
        proxy["udp"] = true
        if let sni = parts.query["sni"] ?? parts.query["peer"], !sni.isEmpty { proxy["sni"] = sni }
        if let fp = parts.query["fp"], !fp.isEmpty { proxy["client-fingerprint"] = fp }
        if let alpn = parts.query["alpn"], !alpn.isEmpty { proxy["alpn"] = alpn.split(separator: ",").map(String.init) }
        if parts.flag("insecure") || parts.flag("allowInsecure") { proxy["skip-cert-verify"] = true }
        return proxy
    }

    /// `socks5://user:pass@host:port`, or v2rayN's `socks://base64(user:pass)@host:port`.
    private static func socks(_ link: String) throws -> [String: Any] {
        let parts = try Parts(link)
        var proxy = parts.base(type: "socks5")
        proxy["udp"] = true
        var user = parts.user, password = parts.password
        if password == nil, let encoded = user, let decoded = Base64.decode(encoded), decoded.contains(":") {
            let pair = decoded.split(separator: ":", maxSplits: 1).map(String.init)
            user = pair[0]
            password = pair.count > 1 ? pair[1] : ""
        }
        if let user, !user.isEmpty { proxy["username"] = user }
        if let password, !password.isEmpty { proxy["password"] = password }
        return proxy
    }

    /// `http(s)://user:pass@host:port`. A link with a path or a query is a subscription's address,
    /// not a proxy: refused rather than turned into a server.
    private static func httpProxy(_ link: String, tls: Bool) throws -> [String: Any] {
        let parts = try Parts(link)
        guard parts.path.isEmpty || parts.path == "/", parts.query.isEmpty else {
            throw ProxyLinkError.malformed(String(localized: "это ссылка подписки, а не сервера"))
        }
        var proxy = parts.base(type: "http")
        if let user = parts.user, !user.isEmpty { proxy["username"] = user }
        if let password = parts.password, !password.isEmpty { proxy["password"] = password }
        if tls {
            proxy["tls"] = true
            proxy["sni"] = parts.host
        }
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
            // SIP003: "name;key=value;flag"
            let options = plugin.split(separator: ";").map(String.init)
            var fields: [String: String] = [:]
            for option in options.dropFirst() {
                let kv = option.split(separator: "=", maxSplits: 1).map(String.init)
                fields[kv[0]] = kv.count == 2 ? kv[1] : ""
            }
            var opts: [String: Any] = [:]
            switch options.first ?? "" {
            case "obfs-local", "simple-obfs":
                if let mode = fields["obfs"] { opts["mode"] = mode }
                if let host = fields["obfs-host"] { opts["host"] = host }
                proxy["plugin"] = "obfs"
            case "v2ray-plugin":
                opts["mode"] = fields["mode"].flatMap { $0.isEmpty ? nil : $0 } ?? "websocket"
                if fields["tls"] != nil { opts["tls"] = true }
                if let host = fields["host"], !host.isEmpty { opts["host"] = host }
                if let path = fields["path"], !path.isEmpty { opts["path"] = path }
                if let mux = fields["mux"] { opts["mux"] = !["0", "false"].contains(mux.lowercased()) }
                proxy["plugin"] = "v2ray-plugin"
            case "shadow-tls":
                if let host = fields["host"], !host.isEmpty { opts["host"] = host }
                if let password = fields["password"], !password.isEmpty { opts["password"] = password }
                if let version = fields["version"].flatMap(Int.init) { opts["version"] = version }
                proxy["plugin"] = "shadow-tls"
            default:
                throw ProxyLinkError.malformed(String(localized: "плагин \(options.first ?? "") не поддерживается"))
            }
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
            if let extra = q["extra"], let json = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] {
                xhttp.merge(xhttpExtra(json)) { _, new in new }
            }
            proxy["network"] = "xhttp"
            proxy["xhttp-opts"] = xhttp
        default:
            break
        }
    }

    /// Xray's `extra` JSON of an xHTTP link → mihomo's `xhttp-opts` keys: padding, XMUX
    /// (`reuse-settings`) and a separate download server (`download-settings`, which the helper pins
    /// like the server). Unknown fields are left out.
    private static func xhttpExtra(_ extra: [String: Any]) -> [String: Any] {
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: string.isEmpty ? nil : string
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        var out: [String: Any] = [:]
        for (from, to) in [("xPaddingBytes", "x-padding-bytes"), ("scMaxEachPostBytes", "sc-max-each-post-bytes"),
                           ("scMinPostsIntervalMs", "sc-min-posts-interval-ms")] {
            if let value = text(extra[from]) { out[to] = value }
        }
        if let flag = extra["noGRPCHeader"] as? Bool { out["no-grpc-header"] = flag }
        if let xmux = extra["xmux"] as? [String: Any] {
            var reuse: [String: Any] = [:]
            for (from, to) in [("maxConcurrency", "max-concurrency"), ("maxConnections", "max-connections"),
                               ("cMaxReuseTimes", "c-max-reuse-times"), ("hMaxRequestTimes", "h-max-request-times"),
                               ("hMaxReusableSecs", "h-max-reusable-secs")] {
                if let value = text(xmux[from]) { reuse[to] = value }
            }
            if let period = text(xmux["hKeepAlivePeriod"]).flatMap(Int.init) { reuse["h-keep-alive-period"] = period }
            if !reuse.isEmpty { out["reuse-settings"] = reuse }
        }
        if let download = extra["downloadSettings"] as? [String: Any] {
            var d: [String: Any] = [:]
            if let address = text(download["address"]) { d["server"] = address }
            if let port = text(download["port"]).flatMap(Int.init), (1...65535).contains(port) { d["port"] = port }
            let settings = download["xhttpSettings"] as? [String: Any] ?? [:]
            if let path = text(settings["path"]) { d["path"] = path }
            if let host = text(settings["host"]) { d["host"] = host }
            let security = text(download["security"]) ?? "none"
            if security == "tls" || security == "reality" {
                d["tls"] = true
                let tls = download[security == "tls" ? "tlsSettings" : "realitySettings"] as? [String: Any] ?? [:]
                if let sni = text(tls["serverName"]) { d["servername"] = sni }
                if let fp = text(tls["fingerprint"]) { d["client-fingerprint"] = fp }
                if let alpn = tls["alpn"] as? [String], !alpn.isEmpty { d["alpn"] = alpn }
                if tls["allowInsecure"] as? Bool == true { d["skip-cert-verify"] = true }
                if security == "reality" {
                    var reality: [String: Any] = [:]
                    if let key = text(tls["publicKey"]) { reality["public-key"] = key }
                    if let sid = text(tls["shortId"]) { reality["short-id"] = sid }
                    d["reality-opts"] = reality
                }
            }
            if d["server"] != nil { out["download-settings"] = d }
        }
        return out
    }

    /// The generic URL pieces of a share link.
    private struct Parts {
        let user: String?
        let password: String?
        let host: String
        let port: Int
        let query: [String: String]
        let name: String?
        var path = ""

        init(host: String, port: Int, query: [String: String], name: String?) {
            self.host = host
            self.port = port
            self.query = query
            self.name = name
            user = nil
            password = nil
        }

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
            path = components.path
        }

        func flag(_ key: String) -> Bool { ["1", "true"].contains(query[key]?.lowercased() ?? "") }

        func base(type: String) -> [String: Any] {
            ["name": name ?? "\(host):\(port)", "type": type, "server": host, "port": port]
        }
    }
}
