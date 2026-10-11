import Foundation
import XCTest

final class ServerRecentsTests: XCTestCase {
    func testTheLastUsedComesFirstOnceAndAtMostFive() {
        var stored: [String] = []
        for server in ["a", "b", "c", "b", "d", "e", "f", "g"] {
            stored = ServerRecents.adding(server, to: stored)
        }
        XCTAssertEqual(stored, ["g", "f", "e", "d", "b"])
        XCTAssertEqual(ServerRecents.adding("e", to: stored), ["e", "g", "f", "d", "b"])
    }

    func testStoredAsTextLines() {
        XCTAssertEqual(ServerRecents.list(ServerRecents.text(["id:vless|a|443|00", "Дом"])), ["id:vless|a|443|00", "Дом"])
        XCTAssertEqual(ServerRecents.list(""), [])
    }

    /// Kept by server identity like the favourites (never a secret): a rename keeps the place.
    func testNamesNowInTheirOrder() {
        let keys = ["🇱🇹 Литва 1": "id:vless|lt|443|aa", "🇩🇪 Германия": "id:vless|de|443|bb"]
        XCTAssertEqual(ServerRecents.names(["id:vless|de|443|bb", "Дом", "id:vless|lt|443|aa", "id:gone|x|1|cc"], keys: keys),
                       ["🇩🇪 Германия", "Дом", "🇱🇹 Литва 1"])
    }

    func testTheIdentityOfAServerIsStoredNotItsName() {
        let keys = ["🇱🇹 Литва": "id:vless|lt|443|aa"]
        XCTAssertEqual(ServerRecents.adding(name: "🇱🇹 Литва", keys: keys, to: ["Дом"]), ["id:vless|lt|443|aa", "Дом"])
        // without a key (Xray, before the profile is read) the name; a key replaces it later
        XCTAssertEqual(ServerRecents.adding(name: "Дом", keys: keys, to: []), ["Дом"])
        XCTAssertEqual(ServerRecents.adding(name: "🇱🇹 Литва", keys: keys, to: ["🇱🇹 Литва"]), ["id:vless|lt|443|aa"])
    }
}
