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
}
