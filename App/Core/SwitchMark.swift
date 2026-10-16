import Foundation

/// "x-ks-switch": the app's own mark on a switching password import (#74, Subscriptions.markedSwitching).
/// A provider's Xray config may carry the key too; only the app's mark may reach the helper.
enum SwitchMark {
    static let key = "x-ks-switch"

    /// Xray: every config without it; with none there the panel's bytes stay as they are.
    static func strippingXray(_ data: Data) -> Data {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              array.contains(where: { ($0 as? [String: Any])?[key] != nil }) else { return data }
        let stripped = array.map { config -> Any in
            guard var c = config as? [String: Any] else { return config }
            c[key] = nil
            return c
        }
        return (try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys, .withoutEscapingSlashes])) ?? data
    }
}
