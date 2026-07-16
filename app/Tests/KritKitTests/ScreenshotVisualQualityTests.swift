import AppKit
import XCTest
@testable import KritKit

final class ScreenshotVisualQualityTests: XCTestCase {
    func testRejectsAnOpaqueBlackFrame() throws {
        let image = try makeImage { context, bounds in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
        }

        XCTAssertFalse(ScreenshotVisualQuality.hasVisibleContent(image))
    }

    func testAcceptsDarkInterfaceWithLegibleForeground() throws {
        let image = try makeImage { context, bounds in
            context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
            context.fill(bounds)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 12, y: 12, width: 40, height: 8))
            context.setFillColor(NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: 12, y: 30, width: 24, height: 18))
        }

        XCTAssertTrue(ScreenshotVisualQuality.hasVisibleContent(image))
    }

    private func makeImage(
        draw: (CGContext, CGRect) -> Void
    ) throws -> CGImage {
        let width = 64
        let height = 64
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("CGContext unavailable")
        }
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
