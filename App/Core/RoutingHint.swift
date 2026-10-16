import Foundation

/// "x-ks-routing": the routing profile key the helper still reads (ADR 0034). The app no longer
/// has routing profiles (#73, ADR 0036 point 4), and a subscription's own never reaches the helper.
enum RoutingHint {
    static let key = "x-ks-routing"
    private static let switchKey = "x-ks-switch"

    /// mihomo: the profile without it.
    static func stripping(_ profile: Profile) -> Profile {
        var profile = profile
        profile[key] = nil
        return profile
    }

    /// Xray: every config without it, and without a provider's own "x-ks-switch" (only the app's mark
    /// may reach the helper); with neither there the panel's bytes stay as they are.
    static func strippingXray(_ data: Data) -> Data {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              array.contains(where: { ($0 as? [String: Any]).map { $0[key] != nil || $0[switchKey] != nil } ?? false }) else { return data }
        let stripped = array.map { config -> Any in
            guard var c = config as? [String: Any] else { return config }
            c[key] = nil
            c[switchKey] = nil
            return c
        }
        return (try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys, .withoutEscapingSlashes])) ?? data
    }
}
