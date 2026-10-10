import XCTest

/// Every text the app shows goes through the string catalog (App/Localizable.xcstrings): App/Core
/// builds them with `String(localized:)`, and the catalog has each of those keys.
final class StringCatalogTests: XCTestCase {
    private let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")

    /// Not texts for people: words matched in server names and the helper's output, mihomo group
    /// names, placeholders of the diagnostics, the admin script.
    private let notTexts: Set<String> = ["ServerName.swift", "ProfileMerger.swift", "Diagnostics.swift", "AdminScript.swift"]
    private let matchedOutput = ["\"Ядро не установлено\""]

    private func sources(_ folder: String) throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: app.appending(path: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testCoreTextsAreLocalized() throws {
        let literal = try Regex(#""[^"\n]*[А-Яа-яЁё][^"\n]*""#)
        for (name, text) in try sources("Core") where !notTexts.contains(name) {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !line.contains("String(localized:"),
                      !matchedOutput.contains(where: { line.contains($0) }) else { continue }
                XCTAssertNil(line.firstMatch(of: literal), "\(name):\(number + 1) shows a text outside the catalog")
            }
        }
    }

    func testCatalogHasEveryLocalizedKey() throws {
        let data = try Data(contentsOf: app.appending(path: "Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set((catalog["strings"] as? [String: Any] ?? [:]).keys)
        // plain keys only: an interpolated one becomes a format key (%@, %lld)
        let localized = try Regex(#"String\(localized: "((?:[^"\\\n]|\\[^(])*)"\)"#)
        var checked = 0
        for folder in ["", "Core"] {
            for (name, text) in try sources(folder) {
                for match in text.matches(of: localized) {
                    let key = String(match.output[1].substring ?? "").replacingOccurrences(of: "\\\"", with: "\"")
                    checked += 1
                    XCTAssertTrue(keys.contains(key), "\(name): «\(key)» is not in Localizable.xcstrings")
                }
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }
}
