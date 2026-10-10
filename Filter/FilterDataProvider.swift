import Foundation
import NetworkExtension
import os

/// Second layer under the pf rules: a socket-flow content filter.
///
/// It cannot see which interface a flow will leave through, so it does not try to repeat pf.
/// It only covers the case pf exists for in the first place, from a different part of the
/// system: while no VPN tunnel is up, a new flow is let through only to the local network,
/// to listed addresses (VPN servers, Tailscale relays, exceptions) or from trusted programs
/// (our own core, Tailscale), identified by code signature. Everything else is dropped.
/// With a tunnel up, flows are allowed and pf does the fine-grained filtering.
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
        if AddressMatch.isLocal(host, lan: config["lan"] as? Bool ?? true) { return .allow() }
        let allowed = config["addresses"] as? [String] ?? []
        if allowed.contains(where: { AddressMatch.matches(host, $0) }) { return .allow() }
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

    /// Programs whose flows are always allowed, recognised by code signature (TrustedCode), not
    /// by path. dropweb's core is ad-hoc signed, so the filter cannot tell it from a copy and
    /// does not trust it, "direct" or not; pf's direct rule still applies to it.
    private static func isTrusted(_ token: Data, config: [String: Any]) -> Bool {
        switch trustedProgram(token) {
        case .core: return true
        case .tailscale: return config["tailscale"] as? Bool ?? true
        case nil: return false
        }
    }

    // MARK: - Caches: a burst of flows asks the same questions

    /// Signature checks per process: the audit token holds the pid and its version, so a new
    /// process with a reused pid is a new key. Ten seconds, then SecCodeCheckValidity again (it
    /// also catches code changed in a running process). Nil (not trusted) is cached too.
    private static let trustCache = OSAllocatedUnfairLock(
        initialState: ExpiringCache<Data, TrustedCode.Program?>(lifetime: 10, capacity: 512))
    /// Whether a VPN tunnel is up, for a second: pf does the exact filtering meanwhile.
    private static let tunnelCache = OSAllocatedUnfairLock(initialState: ExpiringCache<Int, Bool>(lifetime: 1, capacity: 1))

    private static func trustedProgram(_ token: Data) -> TrustedCode.Program? {
        let now = Date()
        if let cached = trustCache.withLock({ $0.value(for: token, now: now) }) { return cached }
        let program = TrustedCode.program(auditToken: token)
        trustCache.withLock { $0.set(program, for: token, now: now) }
        return program
    }

    private static func vpnTunnelUp() -> Bool {
        let now = Date()
        if let cached = tunnelCache.withLock({ $0.value(for: 0, now: now) }) { return cached }
        let up = vpnTunnelUpNow()
        tunnelCache.withLock { $0.set(up, for: 0, now: now) }
        return up
    }

    /// VPN TUN interfaces carry an address in 198.18.0.0/16: our core's 198.18.128.1, dropweb's and
    /// Happ's 198.18.0.1. Any of them counts: pf decides what may enter which tunnel.
    private static func vpnTunnelUpNow() -> Bool {
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
