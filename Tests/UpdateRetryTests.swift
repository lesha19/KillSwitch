import XCTest

/// #11: an update check that could not reach the appcast is tried again once our VPN connects
/// (then it goes through the tunnel); «no update» or a bad signature are not network failures.
final class UpdateRetryTests: XCTestCase {
    func testNetworkFailures() {
        XCTAssertTrue(UpdateRetry.isNetworkFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        let wrapped = NSError(domain: "SUSparkleErrorDomain", code: 2001,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)])
        XCTAssertTrue(UpdateRetry.isNetworkFailure(wrapped), "Sparkle's download error around a URL error")
    }

    func testOtherOutcomes() {
        XCTAssertFalse(UpdateRetry.isNetworkFailure(nil), "the check went through")
        XCTAssertFalse(UpdateRetry.isNetworkFailure(NSError(domain: "SUSparkleErrorDomain", code: 1001)), "no update")
        XCTAssertFalse(UpdateRetry.isNetworkFailure(NSError(domain: "SUSparkleErrorDomain", code: 3001)), "signature")
        XCTAssertFalse(UpdateRetry.isNetworkFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), "cancelled")
    }
}
