import XCTest
@testable import KillSwitch

final class ProtectionLogTests: XCTestCase {
    private func text(_ line: String) -> String? { ProtectionLog.entry(line)?.text }

    func testDateIsParsed() {
        let entry = ProtectionLog.entry("2026-10-10 14:03:22 core on")
        XCTAssertEqual(entry?.text, "VPN подключён")
        XCTAssertEqual(entry?.time, "10.10 14:03")
    }

    func testRepairsInPlainWords() {
        XCTAssertEqual(text("2026-10-10 14:03:22 pf was disabled: reloading"), "Защиту кто-то выключил — включена снова")
        XCTAssertEqual(text("2026-10-10 14:03:22 rules were changed or flushed: reloading"), "Защиту кто-то изменил — восстановлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 anchor missing from main ruleset: reloading"), "Защиту кто-то изменил — восстановлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 tunnels changed (utun5 198.18.0.1): reloading"), "VPN подключился или отключился — защита обновлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 initial load: reloading"), "Защита включилась")
        XCTAssertEqual(text("2026-10-10 14:03:22 reload failed"), "Не получилось обновить защиту")
        XCTAssertEqual(text("2026-10-10 14:03:22 rules found loaded while off: flushed"), "Защита осталась включённой после выключения — снята")
    }

    func testVPNEvents() {
        XCTAssertEqual(text("2026-10-10 14:03:22 core: 🚀 Выбор сервера -> 🇱🇹 Литва"), "Выбран сервер «🇱🇹 Литва»")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN: off"), "Двойной VPN выключен")
        XCTAssertEqual(text("2026-10-10 14:03:22 apps outside the VPN: none"), "Программы без VPN: нет")
        XCTAssertEqual(text("2026-10-10 14:03:22 another VPN tunnel next to the core: utun6"), "Рядом работает другой VPN")
        XCTAssertEqual(text("2026-10-10 14:03:22 shutdown: network off (en0)"), "Mac выключается — сеть отключена")
    }

    func testUnknownLineStaysAsIs() {
        XCTAssertEqual(text("2026-10-10 14:03:22 something new"), "something new")
        XCTAssertNil(ProtectionLog.entry(""))
    }
}
