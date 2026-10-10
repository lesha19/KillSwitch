import XCTest

final class ServerIdentityTests: XCTestCase {
    private let lithuania: [String: Any] = ["name": "🇱🇹 Литва", "type": "vless", "server": "LT.example.com", "port": 443,
                                            "uuid": "11111111-2222-3333-4444-555555555555"]

    func testTheKeyIsTypeServerPortAndAHashOfTheSecret() throws {
        let key = try XCTUnwrap(ServerIdentity.key(lithuania))
        XCTAssertTrue(key.hasPrefix("id:vless|lt.example.com|443|"))
        XCTAssertFalse(key.contains("11111111"), "the secret itself is never stored")
        XCTAssertEqual(key.count, "id:vless|lt.example.com|443|".count + 16)
    }

    func testARenameKeepsTheKey() {
        var renamed = lithuania
        renamed["name"] = "LT Vilnius 1 (premium)"
        XCTAssertEqual(ServerIdentity.key(renamed), ServerIdentity.key(lithuania))
    }

    func testAnotherServerPortOrSecretIsAnotherKey() {
        for (field, value) in [("server", "lt2.example.com"), ("port", 8443), ("uuid", "other"), ("type", "vmess")] as [(String, Any)] {
            var other = lithuania
            other[field] = value
            XCTAssertNotEqual(ServerIdentity.key(other), ServerIdentity.key(lithuania), field)
        }
    }

    func testPasswordsPortsAsTextAndWireGuardPeers() {
        let ss: [String: Any] = ["name": "a", "type": "ss", "server": "1.2.3.4", "port": "8388", "password": "p"]
        XCTAssertTrue(ServerIdentity.key(ss)?.hasPrefix("id:ss|1.2.3.4|8388|") == true)
        let wg: [String: Any] = ["name": "w", "type": "wireguard", "private-key": "k",
                                 "peers": [["server": "5.6.7.8", "port": 51820]]]
        XCTAssertTrue(ServerIdentity.key(wg)?.hasPrefix("id:wireguard|5.6.7.8|51820|") == true)
        XCTAssertNil(ServerIdentity.key(["name": "group", "type": "select"]))
    }

    func testSudokuKeyIsItsSecret() {
        let a: [String: Any] = ["name": "s", "type": "sudoku", "server": "1.2.3.4", "port": 8443, "key": "one"]
        var b = a
        b["key"] = "two"
        XCTAssertNotEqual(ServerIdentity.key(a), ServerIdentity.key(b))
    }

    private var profile: Profile {
        ["proxies": [lithuania, ["name": "NL", "type": "ss", "server": "9.9.9.9", "port": 1, "password": "x"]]]
    }

    func testKeysByName() {
        let keys = ServerIdentity.keys(profile)
        XCTAssertEqual(Set(keys.keys), ["🇱🇹 Литва", "NL"])
        XCTAssertEqual(keys["NL"], ServerIdentity.key(["type": "ss", "server": "9.9.9.9", "port": 1, "password": "x"]))
    }

    /// Settings saved by name before 0.13 move to the key; names of servers not in the profile
    /// (gone for now) stay as they were; a value already under the key wins.
    func testNameKeyedDataIsMigrated() {
        let keys = ServerIdentity.keys(profile)
        let lt = keys["🇱🇹 Литва"]!, nl = keys["NL"]!
        XCTAssertEqual(ServerIdentity.migrate(["🇱🇹 Литва": 1, "gone": 2, "NL": 3, nl: 4], keys: keys), [lt: 1, "gone": 2, nl: 4])
        XCTAssertEqual(ServerIdentity.migrate(["NL", "gone", "🇱🇹 Литва", lt], keys: keys), [nl, "gone", lt])
    }

    /// After a rename the stored key finds the server under its new name.
    func testStoredKeysGiveTheCurrentNames() {
        let keys = ServerIdentity.keys(profile)
        var renamed = profile
        renamed["proxies"] = [lithuania.merging(["name": "LT new"]) { $1 }]
        XCTAssertEqual(ServerIdentity.names([keys["🇱🇹 Литва"]!, "Самый быстрый group"], keys: ServerIdentity.keys(renamed)),
                       ["LT new", "Самый быстрый group"])
    }

    func testTransportOverridesFollowARename() throws {
        let key = ServerIdentity.key(lithuania)!
        var renamed = lithuania
        renamed["name"] = "LT new"
        let sent = try XCTUnwrap(Transport.adding([key: .init(fingerprint: "firefox", mux: nil)],
                                                  to: ["proxies": [renamed]])[Transport.hintKey] as? [String: [String: Any]])
        XCTAssertEqual(sent["LT new"]?["client-fingerprint"] as? String, "firefox")
    }
}
