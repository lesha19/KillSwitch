import Foundation
import Security

/// Programs whose flows the filter lets out while no VPN tunnel is up.
///
/// They are recognised by code signature, never by path: ~/, /opt/homebrew, /tmp and copies of
/// apps are writable by the user, so anything can be dropped there, but nothing dropped there
/// carries someone else's certificate. Every rule starts with `anchor apple generic` (a
/// certificate issued by Apple), which ad-hoc and unsigned code cannot satisfy.
enum TrustedCode {
    enum Program: CaseIterable {
        /// Our own VPN core: mihomo or Xray (ADR 0020), signed by our team with this identifier (scripts/sign-core.sh).
        case core
        /// Tailscale's app and network extension, Developer ID or Mac App Store build.
        case tailscale
    }

    static func requirementText(_ program: Program) -> String {
        switch program {
        case .core:
            return #"anchor apple generic and certificate leaf[subject.OU] = "YR58655PJ7" and identifier "com.lesha19.KillSwitch.core""#
        case .tailscale:
            // Developer ID: any code of Tailscale's team. App Store builds are signed by Apple and
            // carry no team in the certificate, so there the identifier pins them, as in their own
            // designated requirement.
            return #"anchor apple generic and certificate leaf[subject.OU] = "W5364U7YZB""#
                + #" or anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"#
                + #" and (identifier "io.tailscale.ipn.macos" or identifier "io.tailscale.ipn.macos.network-extension")"#
        }
    }

    nonisolated(unsafe) private static let requirements: [(Program, SecRequirement)] = Program.allCases.map { program in
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(requirementText(program) as CFString, [], &requirement)
        precondition(status == errSecSuccess && requirement != nil, "bad requirement for \(program)")
        return (program, requirement!)
    }

    /// The program whose rule `satisfies` accepts, if any.
    static func program(where satisfies: (SecRequirement) -> Bool) -> Program? {
        requirements.first { satisfies($0.1) }?.0
    }

    /// The program behind a flow's audit token. SecCodeCheckValidity also checks that the running
    /// process still matches its signature, so a binary patched on disk or in memory fails.
    static func program(auditToken: Data) -> Program? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        return program { SecCodeCheckValidity(code, [], $0) == errSecSuccess }
    }
}
