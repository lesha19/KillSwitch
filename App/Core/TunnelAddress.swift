import Foundation

/// Tells VPN tunnels apart by their utun's IPv4 address. Every VPN TUN we know sits in
/// 198.18.0.0/16 (dropweb and Happ use 198.18.0.1); ours takes 198.18.128.1, the start of the
/// core's fake-ip-range (Helper/ks, CORE_TUN_ADDR).
enum TunnelAddress {
    enum Kind: Equatable { case own, other }

    static let own = "198.18.128.1"

    /// nil: not a VPN tunnel address (Tailscale, iCloud Private Relay…).
    static func kind(_ address: String) -> Kind? {
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return nil }
        guard UInt32(bigEndian: v4.s_addr) & 0xFFFF0000 == 0xC6120000 else { return nil }
        return address == own ? .own : .other
    }
}
