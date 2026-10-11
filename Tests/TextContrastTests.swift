import XCTest

/// Spec §9.4: text stays `.primary` / `.secondary`; orange, red, yellow and green go only on an
/// icon or a background. In the light theme system orange text is 1.9–2.2:1 and red 3.0–3.6:1
/// against the window and the form rows, under WCAG AA's 4.5:1 (docs/ux/audit.md, re-check 0.18.1).
final class TextContrastTests: XCTestCase {
    private let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")

    /// A system colour given to the foreground of whatever the line builds; allowed only when that
    /// is an image (`Image(` on the line or the line above, where the modifier chain starts).
    func testColouredForegroundIsOnlyOnIcons() throws {
        let coloured = try Regex(#"foregroundStyle\([^)]*(\.|Color\.)(orange|red|yellow|green)\b"#)
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where line.firstMatch(of: coloured) != nil {
                let previous = number > 0 ? lines[number - 1] : ""
                XCTAssertTrue(line.contains("Image(") || previous.contains("Image("),
                              "\(file.lastPathComponent):\(number + 1) colours text: keep it primary, colour the icon")
            }
        }
    }
}
