import Foundation
import XCTest

/// A server's description from the subscription, shown under its name: `serverDescription` of a
/// share link, base64 as INCY writes it (or plain text), one line of at most 30 characters.
final class ServerDescriptionTests: XCTestCase {
    private func description(_ query: String) throws -> String? {
        try ProxyLink.parse("vless://id@lt.example.com:443?security=none&\(query)#%F0%9F%87%B1%F0%9F%87%B9%20Литва")[ServerDescription.key] as? String
    }

    func testBase64FromTheLink() throws {
        XCTAssertEqual(try description("serverDescription=TmV0ZmxpeCwgWW91VHViZQ=="), "Netflix, YouTube")
        XCTAssertEqual(try description("serverDescription=TmV0ZmxpeCwgWW91VHViZQ"), "Netflix, YouTube")   // no padding
    }

    func testPlainTextOneLineAtMostThirtyCharacters() throws {
        XCTAssertEqual(try description("serverDescription=Fast"), "Fast")
        XCTAssertEqual(try description("serverDescription=%D0%91%D0%B5%D0%B7%20%D1%80%D0%B5%D0%BA%D0%BB%D0%B0%D0%BC%D1%8B"),
                       "Без рекламы")
        let long = "0JHQtdC3INGA0LXQutC70LDQvNGLCtC4INGC0YDQtdC60LXRgNC+0LIsINC+0YfQtdC90Ywg0LHRi9GB0YLRgNGL0Lkg0YHQtdGA0LLQtdGAINC00LvRjyDQstGB0LXQs9C+"
        XCTAssertEqual(try description("serverDescription=\(long)"), "Без рекламы и трекеров, очень")
    }

    func testNoneOrEmpty() throws {
        XCTAssertNil(try description("type=tcp"))
        XCTAssertNil(try description("serverDescription="))
        XCTAssertNil(try description("serverDescription=%20%0A"))
    }

    /// Kept in the profile next to the server (the helper passes the core only the keys of the
    /// protocol), and found by name for the list before and while connected.
    func testByServerNameFromTheProfile() {
        let proxies = CoreProxies(profile: [
            "proxies": [["name": "A", "type": "vless", ServerDescription.key: "Netflix"], ["name": "B", "type": "vless"]],
            "proxy-groups": [["name": "PROXY", "type": "select", "proxies": ["A", "B"]]],
        ])
        XCTAssertEqual(proxies.serverDescription(of: "A"), "Netflix")
        XCTAssertNil(proxies.serverDescription(of: "B"))
    }
}
