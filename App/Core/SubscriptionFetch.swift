import Foundation

/// KS-21: the subscription fetch reads the body only up to what ks takes (`head -c 20000001`
/// there), never follows a redirect off https, and sends the device headers (HWID, model) only to
/// the host of the user's link.
enum SubscriptionFetch {
    static let maxBodyBytes = 20_000_000
    static let deviceHeaders = ["x-hwid", "x-device-os", "x-ver-os", "x-device-model"]

    enum Failure: LocalizedError, Equatable {
        case tooLarge

        var errorDescription: String? {
            String(localized: "Подписка больше 20 МБ.")
        }
    }

    /// The request to follow a redirect with, or nil to stop at the redirect (shown as its status).
    static func redirect(_ request: URLRequest, from original: URL) -> URLRequest? {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host == original.host?.lowercased() { return request }
        var request = request
        for name in deviceHeaders { request.setValue(nil, forHTTPHeaderField: name) }
        return request
    }

    static func collect<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int = maxBodyBytes) async throws -> Data where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.tooLarge }
            data.append(byte)
        }
        return data
    }

    /// Per task: URLSession asks it before following a redirect.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let original: URL

        init(original: URL) { self.original = original }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            SubscriptionFetch.redirect(request, from: original)
        }
    }
}
