import XCTest

/// #27: install.sh leaves `core/geodata` ("<file>=ok|mismatch|unpinned"); the app names each file
/// that was not replaced, in plain words.
final class GeoDataInstallTests: XCTestCase {
    func testOnlyProblemsAreShown() {
        XCTAssertEqual(GeoDataInstall.problems(nil), [])
        XCTAssertEqual(GeoDataInstall.problems("geosite.dat=ok\ngeoip.metadb=ok\n"), [])
        XCTAssertTrue(GeoDataInstall.problems("geoip.dat=mismatch\n").first?.hasPrefix("База стран не обновилась") == true,
                      "Xray's country base (ADR 0020) is the same thing to the person")
        XCTAssertEqual(GeoDataInstall.path, "/Library/KillSwitch/core/geodata")
    }

    func testEachFileByItsOwnName() {
        let problems = GeoDataInstall.problems("geosite.dat=mismatch\ngeoip.metadb=unpinned\n")
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].hasPrefix("База категорий сайтов не обновилась"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("База стран не обновилась"), problems[1])
        XCTAssertTrue(problems.allSatisfy { $0.contains("работает прежняя") })
        XCTAssertFalse(problems.joined().contains("geosite"), "no file names on screen")
    }

    func testUnknownLinesAreIgnored() {
        XCTAssertEqual(GeoDataInstall.problems("other=mismatch\ngarbage\ngeosite.dat=\n"), [])
    }
}
