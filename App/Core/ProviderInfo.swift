import Foundation

/// What the provider says in the subscription's response headers besides the profile:
/// an announcement for the main screen (#22), support contacts (#22), and `hide-url` (#26).
/// Header names as Remnawave (`ISubscriptionHeaders`) and Happ/INCY document them; text values
/// are plain or `base64:<UTF-8>`. Body `#announce:` lines are not read (KillSwitch gets YAML/JSON).
/// Everything here is untrusted text: it is shown with `Text(String)` (no Markdown, no HTML) and
/// only https, Telegram chat (tg://resolve) and mailto links are kept (KS-20).
struct ProviderInfo: Codable, Equatable {
    var announcement: String?
    var announcementURL: URL?
    var supportURL: URL?
    var supportEmail: String?
    /// `hide-url`: the subscription link is never shown or copied in full.
    var hidesURL = false

    static let maxAnnouncementLength = 300
    static let maxAnnouncementLines = 5
    static let linkSchemes: Set<String> = ["https", "tg", "mailto"]

    init(headers: [String: String]) {
        announcement = Self.text(headers["announce"])
        announcementURL = Self.link(headers["announce-url"])
        supportURL = Self.link(headers["support-url"])
        supportEmail = Self.email(headers["support-email"])
        hidesURL = ["1", "true", "yes"].contains(headers["hide-url"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
    }

    var supportMail: URL? { supportEmail.flatMap { URL(string: "mailto:" + $0) } }

    /// The announcement until ✕ hides it; a new text shows again.
    func announcementToShow(dismissed: String?) -> String? {
        guard let announcement, announcement != dismissed else { return nil }
        return announcement
    }

    /// Decoded, without control and invisible format characters (bidi overrides), at most
    /// `maxLines` non-empty lines and `maxLength` characters (also `profile-title`, KS-20).
    static func text(_ header: String?, maxLines: Int = maxAnnouncementLines, maxLength: Int = maxAnnouncementLength) -> String? {
        guard var text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("base64:"), let decoded = Base64.decode(String(text.dropFirst(7))) { text = decoded }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(whereSeparator: \.isNewline).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                if scalar == "\t" { return " " }
                // the zero-width joiner holds emoji sequences together (👨‍👩‍👧); it cannot reorder text
                if scalar == "\u{200D}" { return scalar }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return nil
                default: return scalar
                }
            })).trimmingCharacters(in: .whitespaces)
        }
        text = lines.filter { !$0.isEmpty }.prefix(maxLines).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    private static func link(_ header: String?) -> URL? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              linkSchemes.contains(scheme) else { return nil }
        switch scheme {
        case "https": guard components.host?.isEmpty == false else { return nil }
        case "mailto": guard email(components.path) != nil else { return nil }
        // KS-20: a chat only; tg://login, proxy, socks and the like ask once and then act
        case "tg": guard text.wholeMatch(of: /tg:\/\/resolve\?domain=[A-Za-z0-9_]{4,32}/.ignoresCase()) != nil else { return nil }
        default: return nil
        }
        return URL(string: text)
    }

    private static func email(_ header: String?) -> String? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), text.count <= 254,
              text.wholeMatch(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) != nil else { return nil }
        return text
    }
}
