import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Reading and drawing QR codes (#24), in memory only: no picture is written to disk or logged.
enum QRCode {
    /// The texts of the QR codes in a picture (a screenshot, a photo), each once.
    static func payloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        var found: [String] = []
        for case let text? in (request.results ?? []).map(\.payloadStringValue) where !found.contains(text) {
            found.append(text)
        }
        return found
    }

    /// A black-on-white code at least `side` pixels wide, with whole pixels per module so a phone
    /// camera reads it off the screen.
    static func image(for text: String, side: Int = 320) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = (CGFloat(side) / code.extent.width).rounded(.up)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(scaled, from: scaled.extent)
    }
}
