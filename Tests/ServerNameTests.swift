import XCTest

final class ServerNameSpeechTests: XCTestCase {
    func testSpokenNameHasNoEmoji() {
        XCTAssertEqual(ServerName.spoken("⚡ Авто"), "Авто")
        XCTAssertEqual(ServerName.spoken("🚀 Выбор сервера"), "Выбор сервера")
        XCTAssertEqual(ServerName.spoken("🇱🇹 Литва"), "Литва")
        XCTAssertEqual(ServerName.spoken("Дом WireGuard"), "Дом WireGuard")
    }

    func testSpokenNameOfABareFlagIsTheCountry() {
        XCTAssertEqual(ServerName.spoken("🇩🇪"), "Германия")
    }

    func testCountryInRussian() {
        XCTAssertEqual(ServerName("🇱🇹 Vilnius 1").country, "Литва")
        XCTAssertEqual(ServerName("NL-Amsterdam").country, "Нидерланды")
        XCTAssertNil(ServerName("Дом").country)
    }

    func testDisplayName() {
        XCTAssertEqual(ServerName.display("🇱🇹 Литва"), "🇱🇹 Литва")
        XCTAssertEqual(ServerName.display("LT-Vilnius"), "🇱🇹 LT-Vilnius")
        XCTAssertEqual(ServerName.display("⚡ Авто"), "⚡ Авто")
        XCTAssertEqual(ServerName.display("🇩🇪"), "🇩🇪 Германия")
    }

    func testOwnEmojiIsNotDoubledWithAGlobe() {
        // H4-5: «Авто» showed 🌐⚡
        XCTAssertNil(ServerName("⚡ Авто").flag)
        XCTAssertTrue(ServerName.startsWithEmoji("⚡ Авто"))
        XCTAssertFalse(ServerName.startsWithEmoji("Авто"))
    }
}
