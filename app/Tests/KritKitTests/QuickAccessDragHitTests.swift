import AppKit
import XCTest
@testable import KritKit

@MainActor
final class QuickAccessDragHitTests: XCTestCase {
    func testHitMapSeparatesThumbnailBackgroundFromInteractiveControls() throws {
        let originalSize = Settings.overlaySize
        Settings.overlaySize = .medium
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-hit-map-\(UUID().uuidString)", isDirectory: true)
        let manager = HistoryManager(storageDir: directory)
        let image = makeImage(size: NSSize(width: 640, height: 360))
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("capture-thumb.png").path,
            captureRect: nil
        )
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            Settings.overlaySize = originalSize
            if QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: manager,
            screen: NSScreen.main,
            entrance: .slide
        )

        let window = try XCTUnwrap(QuickAccessOverlay.uiTestWindows.last)
        let content = try XCTUnwrap(window.contentView)
        let controls = try XCTUnwrap(
            allSubviews(of: content).first {
                String(describing: type(of: $0)) == "OverlayControlsView"
            }
        )
        XCTAssertEqual(controls.alphaValue, 0)

        let cornerHit = try XCTUnwrap(content.hitTest(NSPoint(x: 22, y: 24)))
        let pillHit = try XCTUnwrap(content.hitTest(NSPoint(x: 87, y: 77)))
        let centerGapHit = try XCTUnwrap(content.hitTest(NSPoint(x: 120, y: 77)))
        let progressHit = try XCTUnwrap(content.hitTest(NSPoint(x: 120, y: 1)))

        XCTAssertEqual(String(describing: type(of: cornerHit)), "DraggableImageView")
        XCTAssertEqual(String(describing: type(of: pillHit)), "DraggableImageView")
        XCTAssertEqual(String(describing: type(of: centerGapHit)), "DraggableImageView")
        XCTAssertEqual(String(describing: type(of: progressHit)), "DraggableImageView")

        QuickAccessOverlay.uiTestMarkNewestPresentationReady()
        QuickAccessOverlay.uiTestSetNewestHovered(true)
        let visibleCornerHit = try XCTUnwrap(content.hitTest(NSPoint(x: 22, y: 24)))
        let visiblePillHit = try XCTUnwrap(content.hitTest(NSPoint(x: 87, y: 77)))
        let visibleGapHit = try XCTUnwrap(content.hitTest(NSPoint(x: 120, y: 77)))

        XCTAssertEqual(String(describing: type(of: visibleCornerHit)), "OverlayCornerButton")
        XCTAssertEqual(String(describing: type(of: visiblePillHit)), "OverlayPillButton")
        XCTAssertEqual(String(describing: type(of: visibleGapHit)), "DraggableImageView")

        let accessibilityIDs = allSubviews(of: content).compactMap { $0.accessibilityIdentifier() }
        XCTAssertEqual(accessibilityIDs.filter { $0 == "quickAccess.corner.save" }.count, 1)
        XCTAssertEqual(accessibilityIDs.filter { $0 == "quickAccess.pill.save" }.count, 1)

        QuickAccessOverlay.uiTestSetNewestHovered(false)
        let hiddenAgainHit = try XCTUnwrap(content.hitTest(NSPoint(x: 22, y: 24)))
        XCTAssertEqual(String(describing: type(of: hiddenAgainHit)), "DraggableImageView")
    }

    func testFileDragConversionResumesSiblingDismissCountdown() {
        let originalTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-file-drag-timer-\(UUID().uuidString)", isDirectory: true)
        let manager = HistoryManager(storageDir: directory)
        let image = makeImage(size: NSSize(width: 640, height: 360))
        let before = QuickAccessOverlay.uiTestWindows.count

        defer {
            Settings.overlayTimeout = originalTimeout
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        for _ in 0..<2 {
            let item = HistoryItem(
                id: UUID(),
                createdAt: Date(),
                imagePath: directory.appendingPathComponent("capture-\(UUID().uuidString).png").path,
                thumbnailPath: directory.appendingPathComponent("thumbnail-\(UUID().uuidString).png").path,
                captureRect: nil
            )
            QuickAccessOverlay.show(
                image: image,
                historyItem: item,
                historyManager: manager,
                screen: NSScreen.main,
                entrance: .slide
            )
        }

        QuickAccessOverlay.uiTestArmDismissTimers()
        XCTAssertEqual(Array(QuickAccessOverlay.uiTestDismissTimersActive().suffix(2)), [true, true])

        QuickAccessOverlay.uiTestGestureConvertToFileDrag()

        // The newest card starts the file session. Its sibling must no longer be
        // frozen just because the drag exited through the file-conversion branch.
        // A sibling directly under the real cursor remains paused by design.
        let statesAfterConversion = QuickAccessOverlay.uiTestDismissTimerStates()
        let siblingState = statesAfterConversion.suffix(2).first ?? [:]
        let siblingDismissStateIsValid = siblingState["timerActive"] == true
            || siblingState["cursorOwns"] == true
        XCTAssertTrue(
            siblingDismissStateIsValid,
            "Dismiss states after file drag conversion: \(statesAfterConversion)"
        )
    }

    func testQueuedAutoDismissCannotCloseCardAfterDragBegins() {
        let originalTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-queued-dismiss-drag-\(UUID().uuidString)", isDirectory: true)
        let manager = HistoryManager(storageDir: directory)
        let image = makeImage(size: NSSize(width: 640, height: 360))
        let before = QuickAccessOverlay.uiTestWindows.count

        defer {
            Settings.overlayTimeout = originalTimeout
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumbnail.png").path,
            captureRect: nil
        )
        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: manager,
            screen: NSScreen.main,
            entrance: .slide
        )

        QuickAccessOverlay.uiTestArmDismissTimers()
        QuickAccessOverlay.uiTestQueueNewestAutoDismiss()
        QuickAccessOverlay.uiTestGestureBegin()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(QuickAccessOverlay.uiTestWindows.count, before + 1)
        XCTAssertNotEqual(QuickAccessOverlay.uiTestGestureState(), "closing")
    }

    func testUIIntrospectionPressesTheFrontmostDuplicateIdentifier() throws {
        guard NSScreen.main ?? NSScreen.screens.first != nil else {
            throw XCTSkip("Requires an active macOS display.")
        }
        let target = DuplicateIdentifierPressTarget()
        let back = makeDuplicateIdentifierWindow(tag: 1, target: target)
        let front = makeDuplicateIdentifierWindow(tag: 2, target: target)
        defer {
            back.close()
            front.close()
        }

        back.orderFrontRegardless()
        front.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        _ = try UIIntrospection.click(id: "test.duplicate.identifier")
        XCTAssertEqual(target.pressedTag, 2)
    }

    private func makeImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allSubviews(of:))
    }

    private func makeDuplicateIdentifierWindow(
        tag: Int,
        target: DuplicateIdentifierPressTarget
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 40 + tag * 20, y: 40 + tag * 20, width: 180, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "Duplicate", target: target, action: #selector(DuplicateIdentifierPressTarget.press(_:)))
        button.tag = tag
        button.frame = NSRect(x: 20, y: 30, width: 140, height: 32)
        button.setAccessibilityIdentifier("test.duplicate.identifier")
        window.contentView?.addSubview(button)
        return window
    }
}

@MainActor
private final class DuplicateIdentifierPressTarget: NSObject {
    private(set) var pressedTag: Int?

    @objc func press(_ sender: Any?) {
        pressedTag = (sender as? NSControl)?.tag
    }
}
