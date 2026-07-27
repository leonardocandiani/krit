import XCTest
@testable import KritKit

@MainActor
final class UpdateWindowTests: XCTestCase {
    func testContentUsesBundleVersionAndBuildWhenPresent() {
        let content = UpdateWindowContent.from(
            info: [
                "CFBundleDisplayName": "KRIT",
                "CFBundleShortVersionString": "0.29.0",
                "CFBundleVersion": "120",
            ],
            automaticChecks: true,
            hasWhatsNew: true
        )

        XCTAssertEqual(content.appName, "KRIT")
        XCTAssertEqual(content.versionLine, "Version 0.29.0 (120)")
        XCTAssertEqual(content.automaticChecksLine, "KRIT checks for verified releases in the background.")
        XCTAssertTrue(content.hasWhatsNew)
    }

    func testContentFallsBackForRawDevBinary() {
        let content = UpdateWindowContent.from(info: [:], automaticChecks: false, hasWhatsNew: false)

        XCTAssertEqual(content.appName, "KRIT")
        XCTAssertEqual(content.versionLine, "Version dev (local)")
        XCTAssertEqual(content.automaticChecksLine, "Background checks are off. You can still check manually.")
        XCTAssertFalse(content.hasWhatsNew)
    }

    func testOpeningUpdateWindowDoesNotStartManualCheck() {
        var checkCount = 0
        var preferenceChanges: [Bool] = []
        var whatsNewCount = 0

        let controller = UpdateWindowController(
            content: .from(info: [:], automaticChecks: true),
            actions: UpdateWindowActions(
                checkNow: { checkCount += 1 },
                setAutomaticChecks: { preferenceChanges.append($0) },
                showWhatsNew: { whatsNewCount += 1 }
            )
        )

        XCTAssertNotNil(controller.window)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(controller.window?.contentView?.bounds.height ?? 0, 456)
        XCTAssertEqual(checkCount, 0)
        XCTAssertEqual(preferenceChanges, [])
        XCTAssertEqual(whatsNewCount, 0)
    }
}
