import XCTest

/// macOS (Sequoia's App Data protection) asks «KillSwitch.app запрашивает доступ к данным других
/// приложений» when the app reads another app's container or Application Support folder. 0.14.1
/// read dropweb's profiles and Happ's group container on every launch. Neither the app nor the
/// filter may read another app's files; other VPNs are recognised by `scutil --nc list` and routes.
final class OtherAppsDataTests: XCTestCase {
    private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private let forbidden = ["Group Containers", "Library/Containers", "Application Support", "NSHomeDirectory",
                             "homeDirectoryForCurrentUser", "group.su.ffg.happ", "org.dropweb.vpn"]

    func testNoReadsOfOtherAppsData() throws {
        var checked = 0
        for folder in ["App", "App/Core", "Filter", "Widget", "Shared"] {
            let dir = root.appending(path: folder)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
                checked += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                    for word in forbidden {
                        XCTAssertFalse(line.contains(word), "\(folder)/\(file.lastPathComponent):\(number + 1) reads another app's data (\(word))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }
}
