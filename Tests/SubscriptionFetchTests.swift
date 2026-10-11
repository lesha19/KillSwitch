import Foundation
import XCTest

/// KS-21: the subscription fetch reads at most what ks takes, never follows a redirect off https,
/// and sends the device headers (HWID, model) only to the host of the user's link.
final class SubscriptionFetchTests: XCTestCase {
    private let original = URL(string: "https://sub.example.com/abc")!

    private func request(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in SubscriptionHeaders.request(appVersion: "1", hwid: "0123456789abcdef", osVersion: "15", model: "Mac") {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func testRedirectOffHTTPSRefused() {
        XCTAssertNil(SubscriptionFetch.redirect(request("http://sub.example.com/abc"), from: original))
        XCTAssertNil(SubscriptionFetch.redirect(request("ftp://sub.example.com/abc"), from: original))
    }

    func testRedirectOnTheSameHostKeepsTheHeaders() throws {
        let next = try XCTUnwrap(SubscriptionFetch.redirect(request("https://SUB.example.com/v2/abc"), from: original))
        XCTAssertEqual(next.value(forHTTPHeaderField: "x-hwid"), "0123456789abcdef")
    }

    func testRedirectToAnotherHostWithoutTheDeviceHeaders() throws {
        let next = try XCTUnwrap(SubscriptionFetch.redirect(request("https://cdn.example.net/abc"), from: original))
        for name in ["x-hwid", "x-device-os", "x-ver-os", "x-device-model"] {
            XCTAssertNil(next.value(forHTTPHeaderField: name), name)
        }
        XCTAssertNotNil(next.value(forHTTPHeaderField: "User-Agent"))
    }

    private struct Bytes: AsyncSequence {
        typealias Element = UInt8
        let count: Int
        struct AsyncIterator: AsyncIteratorProtocol {
            var left: Int
            mutating func next() async -> UInt8? {
                guard left > 0 else { return nil }
                left -= 1
                return 0x61
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(left: count) }
    }

    func testBodyUpToTheCap() async throws {
        let data = try await SubscriptionFetch.collect(Bytes(count: 100), limit: 100)
        XCTAssertEqual(data.count, 100)
    }

    func testBodyOverTheCapRefused() async {
        do {
            _ = try await SubscriptionFetch.collect(Bytes(count: 101), limit: 100)
            XCTFail("read past the cap")
        } catch {
            XCTAssertEqual(error as? SubscriptionFetch.Failure, .tooLarge)
        }
    }

    func testCapIsWhatKsTakes() {
        XCTAssertEqual(SubscriptionFetch.maxBodyBytes, 20_000_000)
    }
}
