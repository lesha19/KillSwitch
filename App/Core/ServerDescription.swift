import Foundation

/// A server's description from the subscription, shown under its name in the list: the
/// `serverDescription` of a share link (INCY's convention, base64; plain text is taken too). It
/// stays in the app's profile under `key`; the helper passes the core only the keys of the
/// protocol (Helper/ks proxy_keys), so it never reaches mihomo.
enum ServerDescription {
    static let key = "ks-description"
    static let linkParameter = "serverDescription"
    static let maxLength = 30

    /// One line of at most 30 characters, or nil when nothing is left.
    static func clean(_ raw: String) -> String? {
        let decoded = Base64.decode(raw).flatMap { text in
            text.unicodeScalars.contains { $0.properties.generalCategory == .control && !"\n\r\t".unicodeScalars.contains($0) }
                ? nil : text
        }
        let visible = String(String.UnicodeScalarView((decoded ?? raw).unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        let line = visible.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let text = String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
