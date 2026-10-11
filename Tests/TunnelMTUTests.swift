import XCTest
@testable import KillSwitch

/// «Размер пакетов VPN» (ADR 0032): the line ks keeps and the choices Settings offers.
final class TunnelMTUTests: XCTestCase {
    func testSettingLine() {
        XCTAssertEqual(TunnelMTU.value(setting: "1380"), 1380)
        XCTAssertEqual(TunnelMTU.value(setting: "1280"), 1280)
        XCTAssertEqual(TunnelMTU.value(setting: "1500"), 1500)
        // no line, or one ks would refuse (it blocks everything then, ADR 0015): «Авто» on screen
        for line in [nil, "", "auto", "1000", "1501", "01380", "1380 ", "abc"] as [String?] {
            XCTAssertNil(TunnelMTU.value(setting: line), String(describing: line))
        }
    }

    func testChoices() {
        XCTAssertEqual(TunnelMTU.choices(current: nil).first, .some(nil), "«Авто» first")
        XCTAssertTrue(TunnelMTU.choices(current: nil).contains(1280))
        XCTAssertTrue(TunnelMTU.choices(current: nil).contains(1500))
        XCTAssertTrue(TunnelMTU.choices(current: nil).allSatisfy { $0.map { HelperCommand.setMTU($0).isValid } ?? true })
        // a value set elsewhere (the command line, a settings file) stays selectable
        XCTAssertTrue(TunnelMTU.choices(current: 1350).contains(1350))
        XCTAssertEqual(TunnelMTU.title(nil), "Авто")
        XCTAssertEqual(TunnelMTU.title(1380), "1380")
    }
}
