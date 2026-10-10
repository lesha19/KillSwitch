import Darwin
import XCTest

/// The daemon's scratch directories: made where they belong, and nothing else is ever removed
/// (0.15.1 removed "/" as root when mkdtemp's path came back empty).
final class PrivateDirectoryTests: XCTestCase {
    func testMakesAPrivateDirectoryInTheTemporaryDirectory() throws {
        let url = try XCTUnwrap(PrivateDirectory.make())
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotEqual(url.path, "/")
        XCTAssertTrue(url.path.hasPrefix("/"), url.path)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("killswitch."), url.path)
        XCTAssertEqual(url.lastPathComponent.count, "killswitch.XXXXXX".count, url.path)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.path)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testEachCallMakesANewOne() throws {
        let a = try XCTUnwrap(PrivateDirectory.make()), b = try XCTUnwrap(PrivateDirectory.make())
        defer { PrivateDirectory.remove(a); PrivateDirectory.remove(b) }
        XCTAssertNotEqual(a, b)
    }

    func testRemovesWhatItMade() throws {
        let url = try XCTUnwrap(PrivateDirectory.make())
        try Data("x".utf8).write(to: url.appendingPathComponent("profile.json"))
        XCTAssertTrue(PrivateDirectory.remove(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesAnythingElse() throws {
        let temporary = NSTemporaryDirectory()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(UUID().uuidString)")
        let nested = outside.appendingPathComponent("killswitch.abcdef")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("other.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let made = try XCTUnwrap(PrivateDirectory.make())
        defer { try? FileManager.default.removeItem(at: made) }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("killswitch.link\(UUID().uuidString.prefix(6))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: made)
        defer { try? FileManager.default.removeItem(at: link) }

        for path in ["/", "", "killswitch.abcdef", "./killswitch.abcdef", "/killswitch.abcdef", "/Applications",
                     "/KillSwitch.app", nested.path, plain.path, link.path,
                     (temporary as NSString).appendingPathComponent("killswitch."),
                     made.path + "/..", made.appendingPathComponent("../..").path, temporary] {
            XCTAssertFalse(PrivateDirectory.isRemovable(path), path)
            XCTAssertFalse(PrivateDirectory.remove(URL(fileURLWithPath: path)), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        // an empty temporary directory (the 0.15.1 failure the other way round) is no parent
        XCTAssertFalse(PrivateDirectory.isRemovable(made.path, temporary: ""))
        XCTAssertFalse(PrivateDirectory.isRemovable(made.path, temporary: "/"))
        XCTAssertTrue(PrivateDirectory.isRemovable(made.path))
    }
}
