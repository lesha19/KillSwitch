import Foundation
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testScrubsSecrets() {
        let text = Diagnostics.scrub("""
        fetch https://sub.example.com/api/sub/AbCdEf123456 failed for 11111111-2222-3333-4444-555555555555 \
        key eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU= at 203.0.113.7 and 2001:db8::1, vless://x@h:1
        """)
        XCTAssertFalse(text.contains("sub.example.com"))
        XCTAssertFalse(text.contains("AbCdEf123456"))
        XCTAssertFalse(text.contains("11111111-2222"))
        XCTAssertFalse(text.contains("eCtXsJZ27"))
        XCTAssertFalse(text.contains("203.0.113.7"))
        XCTAssertFalse(text.contains("2001:db8::1"))
        XCTAssertFalse(text.contains("vless://"))
        XCTAssertTrue(text.contains("failed for"))
    }

    func testKeepsPlainText() {
        XCTAssertEqual(Diagnostics.scrub("Ядро не запустилось (код 1)"), "Ядро не запустилось (код 1)")
    }

    func testReport() {
        let report = Diagnostics.report([("Версия", "0.6 (6)"), ("Ошибка", "see https://x.example/secret")])
        XCTAssertTrue(report.contains("Версия: 0.6 (6)"))
        XCTAssertFalse(report.contains("x.example"))
    }

    /// #26: a subscription link never reaches the copied diagnostics, with or without its scheme,
    /// even with a short token (Remnawave's shortUuid) the key rule would not catch.
    func testSubscriptionLinkNeverCopied() {
        for text in ["fetch https://sub.example.com/Ab12cd34 failed",
                     "could not reach sub.example.com/Ab12cd34: timed out",
                     "error at sub.example.com:8443/api/sub/Ab12cd34?x=1"] {
            let report = Diagnostics.report([("Ошибка", text)])
            XCTAssertFalse(report.contains("sub.example.com"), report)
            XCTAssertFalse(report.contains("Ab12cd34"), report)
        }
    }
}
