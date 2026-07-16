import AppKit
import Vision

struct QRCodeResult: Hashable, Sendable {
    let payload: String
}

enum QRCodeEngine {

    static func detect(in image: NSImage) async -> [QRCodeResult] {
        guard let cgImage = image.bestCGImage else { return [] }
        return await detect(in: cgImage)
    }

    static func detect(in cgImage: CGImage) async -> [QRCodeResult] {
        await VisionRequestExecutor.perform {
            var detectedCodes: [QRCodeResult] = []
            let request = VNDetectBarcodesRequest { request, error in
                guard error == nil else { return }

                let observations = request.results as? [VNBarcodeObservation] ?? []
                let results = observations
                    .filter { $0.symbology == .qr }
                    .compactMap { observation -> QRCodeResult? in
                        guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
                            return nil
                        }
                        return QRCodeResult(payload: payload)
                    }

                var seen = Set<String>()
                detectedCodes = results.filter { seen.insert($0.payload).inserted }
            }
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return detectedCodes
        }
    }
}
