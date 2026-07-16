import XCTest
@testable import KritKit

final class ScreenImageCaptureBackendTests: XCTestCase {
    func testVenturaUsesAOneFrameStreamWhenDesktopIconsAreExcluded() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: true,
                screenshotManagerAvailable: false,
                streamAvailable: true
            ),
            .oneFrameStream
        )
    }

    func testLegacyPathKeepsCoreGraphicsWhenNoFilteredCaptureIsRequested() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: false,
                screenshotManagerAvailable: false,
                streamAvailable: true
            ),
            .coreGraphics
        )
    }

    func testModernSystemsKeepScreenshotManagerAsThePreferredPath() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: true,
                screenshotManagerAvailable: true,
                streamAvailable: true
            ),
            .screenshotManager
        )
    }
}
