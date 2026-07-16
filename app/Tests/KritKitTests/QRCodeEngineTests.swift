import CoreImage
import XCTest
@testable import KritKit

final class QRCodeEngineTests: XCTestCase {
    func testDetectsGeneratedQRCode() async throws {
        let payload = "krit://capture?mode=area"
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel")

        guard let output = filter?.outputImage else {
            throw XCTSkip("The system QR image generator is unavailable.")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else {
            throw XCTSkip("The system QR image generator is unavailable.")
        }

        let results = await QRCodeEngine.detect(in: image)

        XCTAssertEqual(results.map { $0.payload }, [payload])
    }
}
