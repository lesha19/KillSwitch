import Foundation
import NetworkExtension
import Security

/// Second layer under the pf rules: a socket-flow content filter.
///
/// It cannot see which interface a flow will leave through, so it does not try to repeat pf.
/// It only covers the case pf exists for in the first place, from a different part of the
/// system: while no VPN tunnel is up, a new flow is let through only to the local network,
/// to listed addresses (VPN servers, Tailscale relays, exceptions) or from trusted programs
/// (our own core, the system tailscaled, dropweb's core with "direct"). Everything else is
/// dropped. With a tunnel up, flows are allowed and pf does the fine-grained filtering.
///
/// The app passes the lists in `vendorConfiguration` (see FilterConfig in the app).
final class FilterDataProvider: NEFilterDataProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        nonisolated(unsafe) let done = completionHandler   // called once, by NetworkExtension
        apply(settings) { error in done(error) }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let config = filterConfiguration.vendorConfiguration ?? [:]
        if Self.vpnTunnelUp() { return .allow() }
        if let token = flow.sourceAppAuditToken, Self.isTrusted(token, config: config) { return .allow() }
        guard let socket = flow as? NEFilterSocketFlow,
              let host = Self.remoteHost(socket) else { return .drop() }
        if Self.isLocal(host, lan: config["lan"] as? Bool ?? true) { return .allow() }
        let allowed = config["addresses"] as? [String] ?? []
        if allowed.contains(where: { Self.matches(host, $0) }) { return .allow() }
        return .drop()
    }

    // MARK: - Decisions

    private static func remoteHost(_ flow: NEFilterSocketFlow) -> String? {
        guard let endpoint = flow.remoteFlowEndpoint,
              case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)".split(separator: "%").first.map(String.init)
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Paths of programs whose flows are always allowed. Paths come from the code signature
    /// of the running process, so a copy elsewhere does not count.
    private static func isTrusted(_ token: Data, config: [String: Any]) -> Bool {
        guard let path = processPath(token) else { return false }
        if path.hasPrefix("/Library/KillSwitch/core/") { return true }
        if path.hasPrefix("/opt/homebrew/Cellar/tailscale/") && (config["tailscale"] as? Bool ?? true) { return true }
        if path.hasSuffix("/app.dropweb/cores/DropwebCore") && (config["direct"] as? Bool ?? false) { return true }
        return false
    }

    private static func processPath(_ token: Data) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    private static func isLocal(_ host: String, lan: Bool) -> Bool {
        let always = ["127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "::1/128", "fe80::/10", "ff00::/8"]
        let private4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        return (always + (lan ? private4 : [])).contains { matches(host, $0) }
    }

    /// host is an IP address; network is an address or address/prefix.
    static func matches(_ host: String, _ network: String) -> Bool {
        let parts = network.split(separator: "/", maxSplits: 1).map(String.init)
        guard let hostBytes = bytes(host), let netBytes = bytes(parts[0]), hostBytes.count == netBytes.count else { return false }
        let prefix = parts.count == 2 ? Int(parts[1]) ?? -1 : hostBytes.count * 8
        guard prefix >= 0, prefix <= hostBytes.count * 8 else { return false }
        for bit in 0..<prefix where (hostBytes[bit / 8] ^ netBytes[bit / 8]) & UInt8(0x80 >> (bit % 8)) != 0 {
            return false
        }
        return true
    }

    private static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// VPN TUN interfaces (dropweb, Happ, our core) carry an address in 198.18.0.0/16.
    private static func vpnTunnelUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name).hasPrefix("utun"), ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            if UInt32(bigEndian: sin.sin_addr.s_addr) & 0xFFFF0000 == 0xC6120000 { return true }
        }
        return false
    }
}
