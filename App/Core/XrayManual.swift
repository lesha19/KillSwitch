import Foundation

/// Own servers added by link with the main way of connecting (#33, ADR 0027). Xray runs one host of
/// the panel's array at a time, so each own server becomes a host of its own appended to it: its one
/// server as the only outbound (what no rule takes goes there; nothing can go direct) and DNS through
/// it. The helper checks and pins it like the panel's hosts, and a new address needs the admin, as
/// with the other way. Only what the helper takes from Xray configs (vless, vmess, trojan,
/// shadowsocks) over transports Xray has; the rest stays a server of the other way.
enum XrayManual {
    struct Unsupported: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The name's mark in the list, as the other way shows own servers.
    static var mark: String { String(localized: " (свой)") }
    /// Resolvers of an own server's host: reached through the server (what no rule takes).
    static let dnsServers = ["1.1.1.1", "8.8.8.8"]

    /// Why the main way cannot use this server, nil when it can.
    static func unsupported(_ proxy: [String: Any]) -> String? {
        do { _ = try outbound(proxy); return nil } catch { return error.localizedDescription }
    }

    /// The other way's proxy entry (ProxyLink) as an Xray outbound tagged `proxy`.
    static func outbound(_ proxy: [String: Any]) throws -> [String: Any] {
        let type = proxy["type"] as? String ?? ""
        guard let server = proxy["server"] as? String, !server.isEmpty, let port = proxy["port"] as? Int else {
            throw Unsupported(reason: String(localized: "в ссылке нет сервера"))
        }
        guard !server.contains(":") else {
            throw Unsupported(reason: String(localized: "адрес сервера IPv6, а защита пускает к серверам только IPv4"))
        }
        if proxy["skip-cert-verify"] as? Bool == true {
            throw Unsupported(reason: String(localized: "сервер просит не проверять его сертификат"))
        }
        let settings: [String: Any]
        let xrayProtocol: String
        var tls = proxy["tls"] as? Bool == true
        switch type {
        case "vless":
            var user: [String: Any] = ["id": proxy["uuid"] as? String ?? "", "encryption": proxy["encryption"] as? String ?? "none"]
            if let flow = proxy["flow"] as? String { user["flow"] = flow }
            settings = ["vnext": [["address": server, "port": port, "users": [user]]]]
            xrayProtocol = "vless"
        case "vmess":
            let user: [String: Any] = ["id": proxy["uuid"] as? String ?? "", "security": proxy["cipher"] as? String ?? "auto"]
            settings = ["vnext": [["address": server, "port": port, "users": [user]]]]
            xrayProtocol = "vmess"
        case "trojan":
            settings = ["servers": [["address": server, "port": port, "password": proxy["password"] as? String ?? ""]]]
            xrayProtocol = "trojan"
            tls = true
        case "ss":
            guard proxy["plugin"] == nil else { throw Unsupported(reason: String(localized: "плагин Shadowsocks есть только у запасного способа")) }
            settings = ["servers": [["address": server, "port": port, "method": proxy["cipher"] as? String ?? "",
                                     "password": proxy["password"] as? String ?? ""]]]
            xrayProtocol = "shadowsocks"
        default:
            throw Unsupported(reason: String(localized: "такой сервер работает только у запасного способа"))
        }
        var outbound: [String: Any] = ["tag": "proxy", "protocol": xrayProtocol, "settings": settings]
        if type != "ss" { outbound["streamSettings"] = try stream(proxy, tls: tls) }
        return outbound
    }

    /// One host for the array: the server, DNS through it, the name shown in the list.
    static func host(name: String, outbound: [String: Any]) -> [String: Any] {
        ["remarks": name, "outbounds": [outbound], "dns": ["servers": dnsServers, "queryStrategy": "UseIPv4"]]
    }

    /// The panel's array (nil: no subscription) with the own servers the main way can use after its
    /// hosts, named «<name> (свой)», made unique against the hosts as Helper/ks names them. `skipped`:
    /// the names left out. The body as it came when there is nothing to add; nil when there is
    /// nothing at all.
    static func merge(subscription: Data?, manual: [(name: String, proxy: [String: Any])])
        -> (data: Data, servers: [String], skipped: [String])? {
        var array = subscription.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
        var names = array.enumerated().map { index, item in
            let remarks = (item as? [String: Any])?["remarks"] as? String ?? ""
            return remarks.isEmpty ? "#\(index + 1)" : remarks
        }
        var skipped: [String] = []
        var added = 0
        for server in manual {
            guard let outbound = try? outbound(server.proxy) else { skipped.append(server.name); continue }
            let base = server.name + mark
            var name = base
            var n = 2
            while names.contains(name) { name = "\(base) (\(n))"; n += 1 }
            names.append(name)
            array.append(host(name: name, outbound: outbound))
            added += 1
        }
        if added == 0 {
            guard let subscription, !names.isEmpty else { return nil }
            return (subscription, names, skipped)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return (data, names, skipped)
    }

    // MARK: transport

    private static func stream(_ proxy: [String: Any], tls: Bool) throws -> [String: Any] {
        var stream: [String: Any] = [:]
        let network = proxy["network"] as? String ?? "tcp"
        switch network {
        case "tcp":
            stream["network"] = "tcp"
        case "ws":
            let ws = proxy["ws-opts"] as? [String: Any] ?? [:]
            var opts: [String: Any] = [:]
            if let path = ws["path"] as? String { opts["path"] = path }
            if let host = (ws["headers"] as? [String: Any])?["Host"] as? String { opts["host"] = host }
            if ws["v2ray-http-upgrade"] as? Bool == true {
                stream["network"] = "httpupgrade"
                stream["httpupgradeSettings"] = opts
            } else {
                stream["network"] = "ws"
                stream["wsSettings"] = opts
            }
        case "grpc":
            stream["network"] = "grpc"
            stream["grpcSettings"] = ["serviceName": (proxy["grpc-opts"] as? [String: Any])?["grpc-service-name"] as? String ?? ""]
        case "xhttp":
            let x = proxy["xhttp-opts"] as? [String: Any] ?? [:]
            guard x["download-settings"] == nil, x["reuse-settings"] == nil else {
                throw Unsupported(reason: String(localized: "такие настройки xHTTP есть только у запасного способа"))
            }
            var opts: [String: Any] = [:]
            for key in ["path", "host", "mode"] { if let value = x[key] as? String { opts[key] = value } }
            var extra: [String: Any] = [:]
            for (from, to) in [("x-padding-bytes", "xPaddingBytes"), ("sc-max-each-post-bytes", "scMaxEachPostBytes"),
                               ("sc-min-posts-interval-ms", "scMinPostsIntervalMs")] {
                if let value = x[from] as? String { extra[to] = value }
            }
            if let flag = x["no-grpc-header"] as? Bool { extra["noGRPCHeader"] = flag }
            if !extra.isEmpty { opts["extra"] = extra }
            stream["network"] = "xhttp"
            stream["xhttpSettings"] = opts
        default:
            throw Unsupported(reason: String(localized: "такой транспорт есть только у запасного способа"))
        }
        guard tls else { return stream }
        var security: [String: Any] = [:]
        if let name = proxy["servername"] as? String ?? proxy["sni"] as? String, !name.isEmpty { security["serverName"] = name }
        if let fingerprint = proxy["client-fingerprint"] as? String { security["fingerprint"] = fingerprint }
        if let reality = proxy["reality-opts"] as? [String: Any] {
            security["fingerprint"] = security["fingerprint"] ?? "chrome"
            if let key = reality["public-key"] as? String { security["publicKey"] = key }
            if let id = reality["short-id"] as? String { security["shortId"] = id }
            stream["security"] = "reality"
            stream["realitySettings"] = security
        } else {
            if let alpn = proxy["alpn"] as? [String], !alpn.isEmpty { security["alpn"] = alpn }
            stream["security"] = "tls"
            stream["tlsSettings"] = security
        }
        return stream
    }
}
