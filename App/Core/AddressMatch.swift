import Foundation

/// Address decisions of the content filter (Filter/FilterDataProvider), kept here so the unit
/// tests reach them; the filter target compiles this file too (project.yml).
enum AddressMatch {
    /// Always allowed while no tunnel is up: loopback, link-local, multicast, broadcast.
    static let always = ["127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "::1/128", "fe80::/10", "ff00::/8"]
    /// The local network, with the «lan» setting.
    static let privateIPv4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

    static func isLocal(_ host: String, lan: Bool) -> Bool {
        (always + (lan ? privateIPv4 : [])).contains { matches(host, $0) }
    }

    /// host is an IP address; network is an address or address/prefix. A name never matches.
    static func matches(_ host: String, _ network: String) -> Bool {
        let parts = network.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let hostBytes = bytes(host), let netBytes = bytes(first),
              hostBytes.count == netBytes.count else { return false }
        let prefix = parts.count == 2 ? Int(parts[1]) ?? -1 : hostBytes.count * 8
        guard prefix >= 0, prefix <= hostBytes.count * 8 else { return false }
        for bit in 0..<prefix where (hostBytes[bit / 8] ^ netBytes[bit / 8]) & UInt8(0x80 >> (bit % 8)) != 0 {
            return false
        }
        return true
    }

    static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
