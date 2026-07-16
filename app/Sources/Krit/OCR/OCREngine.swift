import Vision
import AppKit

enum OCREngine {

    /// Recognize text in a CGImage and return the full recognized string.
    static func recognizeText(in image: NSImage) async -> String {
        guard let cgImage = image.bestCGImage else { return "" }
        return await recognizeText(in: cgImage)
    }

    static func recognizeText(in cgImage: CGImage) async -> String {
        await VisionRequestExecutor.perform {
            var recognizedText = ""
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else { return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            return recognizedText
        }
    }
}
