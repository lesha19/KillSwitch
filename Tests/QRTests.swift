import CoreGraphics
import Foundation
import XCTest

/// #24: what a scanned QR code holds decides which existing way of adding it is used
/// (`VPNClient.setURL` or `VPNClient.addLink`); those still validate it.
final class QRPayloadTests: XCTestCase {
    private let vless = "vless://11111111-2222-3333-4444-555555555555@de.example.com:443?type=tcp&security=reality&pbk=KEY&sid=ab&sni=www.google.com#DE"

    func testHTTPSLinkIsASubscription() {
        XCTAssertEqual(QRPayload.classify(" https://sub.example.com/api/sub/abcdef \n"), .subscription("https://sub.example.com/api/sub/abcdef"))
    }

    func testPlainHTTPGoesToTheSubscriptionCheckToBeRefusedThere() {
        XCTAssertEqual(QRPayload.classify("http://sub.example.com/abc"), .subscription("http://sub.example.com/abc"))
    }

    func testShareLinksAreServers() {
        XCTAssertEqual(QRPayload.classify(vless), .servers(vless))
        let two = "trojan://pass@a.example.com:443#A\nss://YWVzLTI1Ni1nY206cGFzcw@b.example.com:8388#B"
        XCTAssertEqual(QRPayload.classify(two), .servers(two))
        XCTAssertEqual(QRPayload.classify("HY2://pass@h.example.com:443"), .servers("HY2://pass@h.example.com:443"))
    }

    func testWireGuardConfigIsAServer() {
        let conf = "[Interface]\nPrivateKey = AAA=\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = BBB=\nEndpoint = wg.example.com:51820\nAllowedIPs = 0.0.0.0/0"
        XCTAssertEqual(QRPayload.classify(conf), .servers(conf))
    }

    /// Provider bots wrap the subscription into another client's import link.
    func testSubscriptionInsideAnImportLink() {
        XCTAssertEqual(QRPayload.classify("clash://install-config?url=https%3A%2F%2Fsub.example.com%2Fs%2Fabc&name=X"),
                       .subscription("https://sub.example.com/s/abc"))
        XCTAssertEqual(QRPayload.classify("sing-box://import-remote-profile?url=https://sub.example.com/s/abc#Name"),
                       .subscription("https://sub.example.com/s/abc"))
        XCTAssertEqual(QRPayload.classify("happ://add/https://sub.example.com/s/abc"), .subscription("https://sub.example.com/s/abc"))
    }

    func testAnythingElseIsNotRecognised() {
        for text in ["", "   ", "привет", "WIFI:S:Home;T:WPA;P:secret;;", "tel:+79990000000", "happ://crypt3/AbCdEf", "ftp://files.example.com/x"] {
            XCTAssertEqual(QRPayload.classify(text), .unrecognized, text)
        }
    }

    func testFirstRecognisedCodeOfSeveralWins() {
        XCTAssertEqual(QRPayload.first(of: ["WIFI:S:Home;;", vless, "https://sub.example.com/x"]), .servers(vless))
        XCTAssertEqual(QRPayload.first(of: ["hello"]), .unrecognized)
        XCTAssertEqual(QRPayload.first(of: []), .unrecognized)
    }

    func testSubscriptionShowsOnlyMasked() {
        XCTAssertEqual(QRPayload.subscription("https://sub.example.com/api/sub/abcdef1234").summary, "https://sub.example.com/•••••1234")
    }
}

final class QRCodeTests: XCTestCase {
    func testGeneratedCodeReadsBack() throws {
        let link = "https://sub.example.com/api/sub/0123456789abcdef?format=raw"
        let image = try XCTUnwrap(QRCode.image(for: link))
        XCTAssertGreaterThanOrEqual(image.width, 200, "big enough for a phone camera")
        XCTAssertEqual(QRCode.payloads(in: image), [link])
    }

    func testCodeInsideALargerPictureIsFound() throws {
        let link = "vless://id@de.example.com:443?security=tls#DE"
        let code = try XCTUnwrap(QRCode.image(for: link))
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        context.draw(code, in: CGRect(x: 1100, y: 300, width: code.width, height: code.height))
        XCTAssertEqual(QRCode.payloads(in: try XCTUnwrap(context.makeImage())), [link])
    }

    func testPictureWithoutCode() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(QRCode.payloads(in: try XCTUnwrap(context.makeImage())), [])
    }
}
