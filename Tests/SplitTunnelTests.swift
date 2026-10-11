import Foundation
import XCTest

final class SplitAppsTests: XCTestCase {
    func testProcessName() {
        XCTAssertEqual(SplitApps.processName(infoPlist: ["CFBundleExecutable": "Telegram", "CFBundleName": "Telegram Desktop"]), "Telegram")
        XCTAssertEqual(SplitApps.processName(infoPlist: ["CFBundleExecutable": "Google Chrome"]), "Google Chrome")
        XCTAssertNil(SplitApps.processName(infoPlist: [:]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": ""]))
        // would break the comma list or the helper's argument
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": "a,b"]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": "a\nb"]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": "../x"]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": String(repeating: "x", count: 300)]))
    }

    /// A picked app goes by its bundle's path: every process inside it, and no other program can
    /// take it by naming itself the same.
    func testEntryIsTheBundlePath() {
        let info: [String: Any] = ["CFBundleExecutable": "Telegram"]
        XCTAssertEqual(SplitApps.entry(bundle: URL(fileURLWithPath: "/Applications/Telegram.app"), infoPlist: info),
                       "/Applications/Telegram.app")
        // a path the helper would refuse falls back to the process name
        let long = "/Applications/" + String(repeating: "x", count: 250) + ".app"
        XCTAssertEqual(SplitApps.entry(bundle: URL(fileURLWithPath: long), infoPlist: info), "Telegram")
        XCTAssertEqual(SplitApps.entry(bundle: URL(fileURLWithPath: "/Applications/A,B.app"), infoPlist: info), "Telegram")
        XCTAssertNil(SplitApps.entry(bundle: URL(fileURLWithPath: "/Applications/A,B.app"), infoPlist: [:]))
    }

    func testPathsAndNamesAreBothValid() {
        XCTAssertTrue(SplitApps.isValid("/Applications/Google Chrome.app"))
        XCTAssertTrue(SplitApps.isValid("Telegram"), "lists from before 0.9.1")
        XCTAssertFalse(SplitApps.isValid("/Applications/Telegram"))
        XCTAssertFalse(SplitApps.isValid("/Applications/../tmp/x.app"))
        XCTAssertFalse(SplitApps.isValid("Applications/Telegram.app"))
        XCTAssertFalse(SplitApps.isValid("/" + String(repeating: "x", count: 252) + ".app"))
        XCTAssertEqual(SplitApps.parse(setting: "/Applications/Telegram.app,Steam"), ["/Applications/Telegram.app", "Steam"])
    }

    func testSettingRoundTrip() {
        XCTAssertEqual(SplitApps.parse(setting: "Telegram,Google Chrome"), ["Telegram", "Google Chrome"])
        XCTAssertEqual(SplitApps.parse(setting: nil), [])
        XCTAssertEqual(SplitApps.parse(setting: ""), [])
        XCTAssertEqual(SplitApps.parse(setting: " a , ,b,a"), ["a", "b"])
        XCTAssertEqual(SplitApps.argument(["Telegram", "Google Chrome"]), "Telegram,Google Chrome")
    }

    func testAdding() {
        XCTAssertEqual(SplitApps.adding(["Telegram", "Steam"], to: ["Steam"]), ["Steam", "Telegram"])
    }

    func testHelperLimits() {
        // ks set splitapps refuses a name over 64 bytes and more than 50 names
        XCTAssertNotNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": String(repeating: "x", count: 64)]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": String(repeating: "x", count: 65)]))
        XCTAssertNil(SplitApps.processName(infoPlist: ["CFBundleExecutable": String(repeating: "я", count: 33)]))
        let many = (1...60).map { "app\($0)" }
        XCTAssertEqual(SplitApps.adding(many, to: []).count, 50)
        XCTAssertEqual(SplitApps.parse(setting: many.joined(separator: ",")).count, 50)
    }
}

final class MultihopTests: XCTestCase {
    func testParseSetting() {
        XCTAssertEqual(Multihop.entry(setting: "🇩🇪 Германия"), "🇩🇪 Германия")
        XCTAssertNil(Multihop.entry(setting: "off"))
        XCTAssertNil(Multihop.entry(setting: ""))
        XCTAssertNil(Multihop.entry(setting: nil))
    }

    func testChain() {
        XCTAssertEqual(Multihop.chain(entry: "🇩🇪 Германия", exit: "🇱🇹 Литва"), "Вход: 🇩🇪 Германия → Выход: 🇱🇹 Литва")
        XCTAssertEqual(Multihop.chain(entry: "Germany 1", exit: nil), "Вход: 🇩🇪 Germany 1 → Выход: ?")
    }

    func testEntryCandidates() {
        // the exit itself cannot be the entry; names the helper would refuse are left out
        XCTAssertEqual(Multihop.candidates(["🇩🇪 DE", "🇱🇹 LT", "off", "a\u{7}b"], exit: "🇱🇹 LT"), ["🇩🇪 DE"])
    }

    func testTurningOnPrefersAnEntryThatAnswers() {
        // ADR 0027: a dead entry would drop the VPN at once
        let alive: [String: Bool] = ["🇩🇪 DE": false, "🇳🇱 NL": true]
        XCTAssertEqual(Multihop.preferred(["🇩🇪 DE", "🇳🇱 NL"], alive: { alive[$0] }), "🇳🇱 NL")
        XCTAssertEqual(Multihop.preferred(["🇩🇪 DE", "🇵🇱 PL"], alive: { alive[$0] }), "🇵🇱 PL", "not checked yet is not dead")
        XCTAssertNil(Multihop.preferred(["🇩🇪 DE"], alive: { alive[$0] }), "only dead ones: none")
    }

    func testTheEntryIsNoExit() {
        XCTAssertEqual(Multihop.exits(["🇩🇪 DE", "🇱🇹 LT"], entry: "🇩🇪 DE"), ["🇱🇹 LT"], "one hop while showing two")
        XCTAssertEqual(Multihop.exits(["🇩🇪 DE", "🇱🇹 LT"], entry: nil), ["🇩🇪 DE", "🇱🇹 LT"])
    }
}
