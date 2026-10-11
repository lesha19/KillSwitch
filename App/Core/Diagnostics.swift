import Foundation

/// Text for «Скопировать диагностику»: states and error messages only, with anything that could
/// identify the subscription or a server masked (links, host names, addresses, UUIDs, keys).
enum Diagnostics {
    static func report(_ fields: [(String, String)]) -> String {
        fields.map { "\($0.0): \(scrub($0.1))" }.joined(separator: "\n")
    }

    /// ICU patterns (they need lookbehind); order matters: links before hosts, keys before IPs.
    private static let rules: [(pattern: String, replacement: String, needsDigit: Bool)] = [
        (#"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#, "<ссылка>", false),
        (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<uuid>", false),
        // keys, tokens, hashes: long base64/hex runs that contain a digit
        (#"[A-Za-z0-9+/_\-]{20,}={0,2}"#, "<ключ>", true),
        (#"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"#, "<ip>", false),
        (#"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#, "<ip>", false),
        // with its port and path: a link without its scheme still carries the subscription token (#26)
        (#"(?<![\w.\-])(?:[A-Za-z0-9\-]+\.)+[A-Za-z]{2,}(?![\w\-])(?::\d{1,5})?(?:/\S*)?"#, "<хост>", false),
    ]

    static func scrub(_ text: String) -> String {
        var text = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let found = ns.substring(with: match.range)
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                result += rule.needsDigit && !found.contains(where: \.isNumber) ? found : rule.replacement
                last = match.range.location + match.range.length
            }
            text = result + ns.substring(from: last)
        }
        return text
    }
}
