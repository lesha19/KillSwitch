import XCTest
@testable import KillSwitch

final class BatchTests: XCTestCase {
    /// spec С7: three addresses added and one removed is one admin command, so one password.
    func testListChangesBecomeOneChain() {
        let commands = Batch.list(helper: "/ks", add: "allow", remove: "unallow",
                                  old: ["1.1.1.1", "2.2.2.2"], new: ["2.2.2.2", "3.3.3.3", "10.8.0.0/24", "4.4.4.4"])
        XCTAssertEqual(commands, [
            ["/ks", "unallow", "1.1.1.1"],
            ["/ks", "allow", "3.3.3.3"],
            ["/ks", "allow", "10.8.0.0/24"],
            ["/ks", "allow", "4.4.4.4"],
        ])
        let source = AdminScript.source(commands)
        XCTAssertEqual(source.components(separatedBy: "with administrator privileges").count, 2)
    }

    func testUnchangedListNeedsNothing() {
        XCTAssertEqual(Batch.list(helper: "/ks", add: "allow", remove: "unallow", old: ["1.1.1.1"], new: ["1.1.1.1"]), [])
    }

    func testOnlyChangedSwitchesAreSet() {
        let commands = Batch.settings(helper: "/ks", old: ["lan": true, "dns": false, "tailscale": true],
                                      new: ["lan": false, "dns": true, "tailscale": true])
        XCTAssertEqual(commands, [["/ks", "set", "dns", "1"], ["/ks", "set", "lan", "0"]])
    }

    func testAddressesAreCheckedBeforeTheyReachRoot() {
        XCTAssertEqual(Batch.address(" 1.2.3.46 "), "1.2.3.46")
        XCTAssertEqual(Batch.address("10.8.0.0/24"), "10.8.0.0/24")
        XCTAssertEqual(Batch.address("2001:db8::1"), "2001:db8::1")
        XCTAssertNil(Batch.address("example.com"))
        XCTAssertNil(Batch.address("1.2.3.4; rm -rf /"))
        XCTAssertNil(Batch.address(""))
        XCTAssertNil(Batch.address("10.0.0.0/240"))
    }
}
