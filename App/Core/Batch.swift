import Foundation

/// Settings changed together in a sheet («Изменить… → Применить…») become one admin command,
/// so one password for the whole batch (spec §5.4, H7-1).
enum Batch {
    /// Commands that turn `old` into `new`: removals first, then additions in the order given.
    static func list(helper: String, add: String, remove: String, old: [String], new: [String]) -> [[String]] {
        let removed = old.filter { !new.contains($0) }.map { [helper, remove, $0] }
        let added = new.filter { !old.contains($0) }.map { [helper, add, $0] }
        return removed + added
    }

    /// `ks set <key> 0|1` for the switches that changed, by key.
    static func settings(helper: String, old: [String: Bool], new: [String: Bool]) -> [[String]] {
        new.keys.sorted().compactMap { key in
            guard let value = new[key], old[key] != value else { return nil }
            return [helper, "set", key, value ? "1" : "0"]
        }
    }

    /// An IPv4 or IPv6 address or network as the helper takes it (install.sh checks the same),
    /// or nil: host names and anything else never reach a root command.
    static func address(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$"#, options: .regularExpression) != nil,
              trimmed.contains(where: \.isNumber) else { return nil }
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        let ip = String(parts[0])
        let isV6 = ip.contains(":")
        if parts.count == 2, let bits = Int(parts[1]), bits > (isV6 ? 128 : 32) { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        let valid = isV6 ? inet_pton(AF_INET6, ip, &v6) == 1 : inet_pton(AF_INET, ip, &v4) == 1
        return valid ? trimmed : nil
    }
}
