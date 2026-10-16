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

    /// Kept by (subscription, server identity) like the favourites (never a secret): a rename keeps
    /// the place, and «Литва» of two subscriptions are two entries.
    func testServersNowInTheirOrder() {
        let keys = ["s1": ["🇱🇹 Литва 1": "id:vless|lt|443|aa", "🇩🇪 Германия": "id:vless|de|443|bb"],
                    "s2": ["🇱🇹 Литва 1": "id:trojan|lt2|443|cc"]]
        let stored = ["s1\tid:vless|de|443|bb", "own\tДом", "s2\tid:trojan|lt2|443|cc", "s1\tid:vless|lt|443|aa", "s1\tid:gone|x|1|cc", "Литва"]
        XCTAssertEqual(ServerRecents.servers(stored, keys: keys),
                       [ServerID(subscription: "s1", name: "🇩🇪 Германия"), ServerID(subscription: ServerID.own, name: "Дом"),
                        ServerID(subscription: "s2", name: "🇱🇹 Литва 1"), ServerID(subscription: "s1", name: "🇱🇹 Литва 1")])
    }

    func testTheIdentityOfAServerIsStoredNotItsName() {
        let keys = ["🇱🇹 Литва": "id:vless|lt|443|aa"]
        let lithuania = ServerID(subscription: "s1", name: "🇱🇹 Литва")
        XCTAssertEqual(ServerRecents.adding(lithuania, keys: keys, to: ["own\tДом"]), ["s1\tid:vless|lt|443|aa", "own\tДом"])
        // without a key (Xray) the name; a key replaces it later
        XCTAssertEqual(ServerRecents.adding(ServerID(subscription: ServerID.own, name: "Дом"), keys: keys, to: []), ["own\tДом"])
        XCTAssertEqual(ServerRecents.adding(lithuania, keys: keys, to: ["s1\t🇱🇹 Литва"]), ["s1\tid:vless|lt|443|aa"])
        // the same name of another subscription is another server
        XCTAssertEqual(ServerRecents.adding(ServerID(subscription: "s2", name: "🇱🇹 Литва"), keys: [:], to: ["s1\tid:vless|lt|443|aa"]),
                       ["s2\t🇱🇹 Литва", "s1\tid:vless|lt|443|aa"])
    }

    /// «Избранное»: a star toggles the server of its subscription only.
    func testAFavouriteIsOfItsSubscription() {
        let keys = ["🇱🇹 Литва": "id:vless|lt|443|aa"]
        let stork = ServerID(subscription: "s1", name: "🇱🇹 Литва"), other = ServerID(subscription: "s2", name: "🇱🇹 Литва")
        var stored = ServerRecents.toggled(stork, keys: keys, in: [])
        XCTAssertEqual(stored, ["s1\tid:vless|lt|443|aa"])
        stored = ServerRecents.toggled(other, keys: [:], in: stored)
        XCTAssertEqual(Set(ServerRecents.servers(stored, keys: ["s1": keys])), [stork, other])
        XCTAssertEqual(ServerRecents.toggled(stork, keys: keys, in: stored), ["s2\t🇱🇹 Литва"])
        // one kept by name before its identity was known goes too
        XCTAssertEqual(ServerRecents.toggled(stork, keys: keys, in: ["s1\t🇱🇹 Литва"]), [])
    }
}
