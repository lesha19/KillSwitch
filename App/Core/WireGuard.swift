import Foundation

/// WireGuard: a wg-quick `.conf` or a `wireguard://` link → a mihomo `type: wireguard` proxy.
/// DNS, ListenPort, Table and Pre/PostUp/Down of the file are ignored: names are resolved by the
/// core and nothing from the file is ever run. Error texts never contain key material.
enum WireGuard {
    static func parse(conf text: String, name: String?) throws -> [String: Any] {
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peers.append([:]) }
                continue
            }
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            switch section {
            case "[interface]": interface[key] = kv[1]
            case "[peer]": peers[peers.count - 1][key] = kv[1]
            default: continue
            }
        }
        let amnezia: Set<String> = ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"]
        if !amnezia.isDisjoint(with: interface.keys) { throw ProxyLinkError.malformed("AmneziaWG пока не поддерживается") }
        guard !peers.isEmpty else { throw ProxyLinkError.malformed("нет раздела [Peer]") }
        guard peers.count == 1 else { throw ProxyLinkError.malformed("несколько [Peer] не поддерживаются") }
        let peer = peers[0]
        guard let endpoint = peer["endpoint"], let (host, port) = splitEndpoint(endpoint) else {
            throw ProxyLinkError.malformed("нет адреса сервера (Endpoint)")
        }
        return try build(
            name: name, host: host, port: port,
            privateKey: interface["privatekey"], publicKey: peer["publickey"], presharedKey: peer["presharedkey"],
            address: interface["address"], allowedIPs: peer["allowedips"],
            mtu: interface["mtu"], reserved: peer["reserved"] ?? interface["reserved"],
            keepalive: peer["persistentkeepalive"]
        )
    }

    /// `wireguard://<private key>@host:port?publickey=…&address=…&mtu=…&reserved=…#name`
    /// (v2rayN/sing-box style; `wg://` and the usual spellings of the keys are accepted).
    static func parse(link: String) throws -> [String: Any] {
        guard let schemeEnd = link.range(of: "://") else { throw ProxyLinkError.malformed("нет схемы") }
        let body = link[schemeEnd.upperBound...]
        // the key is base64 and may come unencoded with "/" in it: split it off by hand
        guard let at = body.firstIndex(of: "@") else { throw ProxyLinkError.malformed("нет сервера") }
        let userinfo = String(body[..<at])
        guard let components = URLComponents(string: "wg://x@" + body[body.index(after: at)...]) else {
            throw ProxyLinkError.malformed("не разбирается как адрес")
        }
        guard var host = components.host, !host.isEmpty else { throw ProxyLinkError.malformed("нет сервера") }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard let port = components.port, (1...65535).contains(port) else { throw ProxyLinkError.malformed("нет порта") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")] = item.value ?? ""
        }
        let privateKey = userinfo.isEmpty ? query["privatekey"] : (userinfo.removingPercentEncoding ?? userinfo)
        return try build(
            name: components.fragment.flatMap { $0.isEmpty ? nil : $0 }, host: host, port: port,
            privateKey: privateKey,
            publicKey: query["publickey"] ?? query["peerpublickey"],
            presharedKey: query["presharedkey"] ?? query["psk"],
            address: query["address"] ?? query["ip"], allowedIPs: query["allowedips"],
            mtu: query["mtu"], reserved: query["reserved"], keepalive: query["keepalive"] ?? query["persistentkeepalive"]
        )
    }

    // MARK: -

    private static func build(name: String?, host: String, port: Int, privateKey: String?, publicKey: String?,
                              presharedKey: String?, address: String?, allowedIPs: String?, mtu: String?,
                              reserved: String?, keepalive: String?) throws -> [String: Any] {
        guard let privateKey, isKey(privateKey) else { throw ProxyLinkError.malformed("нет закрытого ключа или он неверный") }
        guard let publicKey, isKey(publicKey) else { throw ProxyLinkError.malformed("нет открытого ключа сервера или он неверный") }
        var proxy: [String: Any] = [
            "name": name ?? "WireGuard \(host)", "type": "wireguard", "server": host, "port": port,
            "private-key": privateKey, "public-key": publicKey, "udp": true,
        ]
        if let presharedKey, !presharedKey.isEmpty {
            guard isKey(presharedKey) else { throw ProxyLinkError.malformed("неверный общий ключ (PresharedKey)") }
            proxy["pre-shared-key"] = presharedKey
        }
        // mihomo takes bare addresses; the prefix of a wg-quick Address is the tunnel's own
        for item in list(address ?? "") {
            let ip = String(item.split(separator: "/").first ?? "")
            if ip.contains(":") { if proxy["ipv6"] == nil { proxy["ipv6"] = ip } } else if proxy["ip"] == nil { proxy["ip"] = ip }
        }
        guard proxy["ip"] != nil || proxy["ipv6"] != nil else { throw ProxyLinkError.malformed("нет адреса в туннеле (Address)") }
        let allowed = list(allowedIPs ?? "")
        proxy["allowed-ips"] = allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed
        if let mtu = mtu.flatMap(Int.init), mtu > 0 { proxy["mtu"] = mtu }
        if let keepalive = keepalive.flatMap(Int.init), keepalive > 0 { proxy["persistent-keepalive"] = keepalive }
        if let reserved, !reserved.isEmpty {
            let bytes = list(reserved).compactMap(Int.init)
            // "1,2,3" → [1, 2, 3]; anything else is mihomo's base64 form ("U4An")
            proxy["reserved"] = bytes.count == 3 && bytes.allSatisfy({ (0...255).contains($0) }) ? bytes as Any : reserved as Any
        }
        return proxy
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Curve25519 keys are 32 bytes in base64.
    private static func isKey(_ text: String) -> Bool {
        Data(base64Encoded: text)?.count == 32
    }

    /// "host:port" or "[v6]:port".
    private static func splitEndpoint(_ text: String) -> (String, Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }
}
