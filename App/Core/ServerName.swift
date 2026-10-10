import Foundation

/// A server name split into a country flag and the rest. Subscriptions usually start names with
/// a flag emoji; otherwise a country name or code in the name is recognised.
struct ServerName {
    let flag: String?
    let title: String

    init(_ name: String) {
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2, Self.isRegional(scalars[0]), Self.isRegional(scalars[1]) {
            flag = String(String.UnicodeScalarView(scalars[0...1]))
            title = String(String.UnicodeScalarView(scalars[2...])).trimmingCharacters(in: .whitespaces)
            return
        }
        title = name
        flag = Self.code(in: name).flatMap(Self.flag(code:))
    }

    private static func isRegional(_ scalar: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(scalar.value) }

    /// The country in Russian, from the flag: «Литва».
    var country: String? {
        guard let flag else { return nil }
        let code = String(String.UnicodeScalarView(flag.unicodeScalars.map { Unicode.Scalar($0.value - 0x1F1E6 + 65)! }))
        return Locale(identifier: "ru_RU").localizedString(forRegionCode: code)
    }

    /// For VoiceOver: the name without emoji (🚀, ⚡, flags); a bare flag becomes its country.
    static func spoken(_ name: String) -> String {
        let text = String(String.UnicodeScalarView(name.unicodeScalars.filter { !isEmojiScalar($0) }))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? ServerName(name).country ?? name : text
    }

    /// The name brings its own symbol (⚡ Авто): no 🌐 in front of it.
    static func startsWithEmoji(_ name: String) -> Bool {
        name.unicodeScalars.first.map(isEmojiScalar) ?? false
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        isRegional(scalar) || scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F || scalar.value == 0x200D
            || (scalar.properties.isEmoji && scalar.value > 0x2000)
    }

    static func flag(code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let scalars = upper.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static let countries: [(String, String)] = [
        ("герман", "DE"), ("german", "DE"), ("нидерланд", "NL"), ("netherland", "NL"), ("голланд", "NL"),
        ("финлянд", "FI"), ("finland", "FI"), ("швеци", "SE"), ("sweden", "SE"), ("литв", "LT"), ("lithuania", "LT"),
        ("латви", "LV"), ("latvia", "LV"), ("эстони", "EE"), ("estonia", "EE"), ("польш", "PL"), ("poland", "PL"),
        ("франц", "FR"), ("france", "FR"), ("великобритан", "GB"), ("англи", "GB"), ("united kingdom", "GB"),
        ("сша", "US"), ("америк", "US"), ("united states", "US"), ("usa", "US"), ("канад", "CA"), ("canada", "CA"),
        ("швейцар", "CH"), ("switzerland", "CH"), ("австри", "AT"), ("austria", "AT"), ("турци", "TR"), ("turkey", "TR"),
        ("казахстан", "KZ"), ("kazakhstan", "KZ"), ("росси", "RU"), ("russia", "RU"), ("япони", "JP"), ("japan", "JP"),
        ("сингапур", "SG"), ("singapore", "SG"), ("гонконг", "HK"), ("hong kong", "HK"), ("испани", "ES"), ("spain", "ES"),
        ("итали", "IT"), ("italy", "IT"), ("норвеги", "NO"), ("norway", "NO"), ("дани", "DK"), ("denmark", "DK"),
        ("чехи", "CZ"), ("czech", "CZ"), ("румыни", "RO"), ("romania", "RO"), ("болгари", "BG"), ("bulgaria", "BG"),
        ("сербия", "RS"), ("serbia", "RS"), ("молдов", "MD"), ("moldova", "MD"), ("грузи", "GE"), ("georgia", "GE"),
        ("армени", "AM"), ("armenia", "AM"), ("оаэ", "AE"), ("эмират", "AE"), ("israel", "IL"), ("израил", "IL"),
    ]

    private static let codes: Set<String> = Set(countries.map(\.1)).union(["UK"])

    private static func code(in name: String) -> String? {
        let lower = name.lowercased()
        if let match = countries.first(where: { lower.contains($0.0) }) { return match.1 }
        // a standalone two-letter code: "NL-Amsterdam", "de 2", "[FI]"
        for word in name.split(whereSeparator: { !$0.isLetter }) where word.count == 2 {
            let upper = word.uppercased()
            if codes.contains(upper) { return upper == "UK" ? "GB" : upper }
        }
        return nil
    }
}
