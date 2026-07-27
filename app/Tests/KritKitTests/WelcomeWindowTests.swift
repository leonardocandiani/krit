import AppKit
import XCTest
@testable import KritKit

@MainActor
final class WelcomeWindowTests: XCTestCase {
    func testWelcomePageUsesTaskWorkflowList() {
        let controller = makeController()
        let texts = controller.uiTestTextContent(onPage: 0)
        let identifiers = controller.uiTestViewIdentifiers(onPage: 0)

        XCTAssertTrue(texts.contains("Capture, polish, and deliver screen work"))
        XCTAssertTrue(texts.contains("Capture"))
        XCTAssertTrue(texts.contains("Polish"))
        XCTAssertTrue(texts.contains("Deliver"))
        XCTAssertTrue(texts.contains(where: { $0.contains("Area, window, full screen, scrolling, OCR, and QR") }))
        XCTAssertTrue(texts.contains(where: { $0.contains("Annotate, crop, blur sensitive text") }))
        XCTAssertTrue(texts.contains(where: { $0.contains("Copy, save, paste into the next app") }))
        XCTAssertTrue(identifiers.contains("onboarding-workflow-list"))
        XCTAssertTrue(controller.uiTestWorkflowTextDoesNotOverlap)

        XCTAssertFalse(texts.contains("Beautiful screenshots, built for you and your AI agent."))
        XCTAssertFalse(texts.contains("Area, window & full-screen capture"))
        XCTAssertFalse(texts.contains("Screen recording, GIF & webcam"))
    }

    func testAgentPageKeepsCommandBlockWithoutSparklesHero() {
        let controller = makeController()
        let texts = controller.uiTestTextContent(onPage: 3)
        let identifiers = controller.uiTestViewIdentifiers(onPage: 3)

        XCTAssertTrue(texts.contains("Automate capture when the job calls for it"))
        XCTAssertTrue(texts.contains("krit capture --area --ocr"))
        XCTAssertTrue(texts.contains(where: { $0.contains("same local capture engine") }))

        XCTAssertFalse(texts.contains(where: { $0.contains("Claude Code, Cursor") }))
        XCTAssertFalse(identifiers.contains("onboarding-hero-symbol-sparkles"))
    }

    func testWelcomeWindowStillBuildsPagesLazily() {
        let controller = makeController()

        XCTAssertEqual(controller.uiTestPageCount, 4)
        XCTAssertEqual(controller.uiTestBuiltPageCount, 1)

        _ = controller.uiTestTextContent(onPage: 3)
        XCTAssertEqual(controller.uiTestBuiltPageCount, 2)
    }

    func testCompletingWelcomeMarksLaunchWithoutMarkingFeatureTourSeen() {
        let controller = makeController()
        Settings.hasLaunchedBefore = false
        Settings.hasSeenFeatureTour = false

        controller.uiTestContinue()
        controller.uiTestContinue()
        controller.uiTestContinue()
        controller.uiTestContinue()

        XCTAssertTrue(Settings.hasLaunchedBefore)
        XCTAssertFalse(Settings.hasSeenFeatureTour)
    }

    func testSkippingWelcomeDoesNotMarkFeatureTourSeen() {
        let controller = makeController()
        Settings.hasLaunchedBefore = false
        Settings.hasSeenFeatureTour = false

        controller.uiTestSkip()

        XCTAssertTrue(Settings.hasLaunchedBefore)
        XCTAssertFalse(Settings.hasSeenFeatureTour)
    }

    func testFeatureTourRemainsAvailableFromMenu() {
        let appDelegate = AppDelegate()
        let menu = appDelegate.buildMenu()
        let item = menu.items.first { $0.title == "Feature Tour" }

        XCTAssertNotNil(item)
        XCTAssertTrue(item?.target === appDelegate)
        XCTAssertEqual(item?.action, #selector(AppDelegate.showFeatureTour))
    }

    func testWelcomePageAccessibilitySummarizesCurrentPage() {
        let controller = makeController()

        XCTAssertEqual(
            controller.uiTestCurrentPageAccessibilityLabel,
            "Capture, polish, and deliver screen work, page 1 of 4"
        )
        XCTAssertEqual(
            controller.uiTestPageIndicatorAccessibilityLabel,
            "Capture, polish, and deliver screen work, page 1 of 4"
        )

        controller.uiTestContinue()

        XCTAssertEqual(
            controller.uiTestCurrentPageAccessibilityLabel,
            "Allow Screen Recording, page 2 of 4"
        )
        XCTAssertEqual(
            controller.uiTestPageIndicatorAccessibilityLabel,
            "Allow Screen Recording, page 2 of 4"
        )
    }

    func testWelcomeMotionPolicyUsesMotionDurationAndReduceMotion() {
        XCTAssertEqual(
            WelcomeWindowController.uiTestPageTransitionDuration(reduceMotion: false),
            Motion.Duration.standard
        )
        XCTAssertEqual(
            WelcomeWindowController.uiTestPageTransitionDuration(reduceMotion: true),
            0
        )
    }

    func testWelcomePagesProduceVisibleFallbackSnapshots() async throws {
        let controller = makeController()
        let directory = "/tmp/krit-welcome-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let paths = await controller.uiTestRenderAllPages(toDirectory: directory)

        XCTAssertEqual(paths.count, 4)
        var renderedData: [Data] = []
        for path in paths {
            let image = try XCTUnwrap(NSImage(contentsOfFile: path))
            XCTAssertGreaterThan(image.size.width, 400)
            XCTAssertGreaterThan(image.size.height, 250)
            renderedData.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        XCTAssertEqual(Set(renderedData).count, 4)
    }

    private func makeController() -> WelcomeWindowController {
        _ = NSApplication.shared
        let launched = Settings.hasLaunchedBefore
        let sawTour = Settings.hasSeenFeatureTour
        let controller = WelcomeWindowController()
        controller.uiTestForceShow()
        addTeardownBlock { @MainActor in
            controller.uiTestClose(restoringHasLaunchedBefore: launched)
            Settings.hasSeenFeatureTour = sawTour
        }
        return controller
    }
}
