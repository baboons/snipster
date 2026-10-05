import Foundation
import Vision

/// On-device OCR and QR/barcode reading through the Vision framework.
enum TextRecognizer {
    /// Returns the text found in the image, one recognised line per line,
    /// followed by the payloads of any codes that aren't already in the text.
    static func recognize(_ image: PixelImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSync(image))
            }
        }
    }

    private static func recognizeSync(_ image: PixelImage) -> String {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        try? handler.perform([text, codes])

        var lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
        for payload in (codes.results ?? []).compactMap(\.payloadStringValue) where !joined.contains(payload) {
            lines.append(payload)
        }
        return lines.joined(separator: "\n")
    }
}
