import AppKit
import XCTest
@testable import KritKit

@MainActor
final class AnnotationEditorStateTests: XCTestCase {
    func testPreviewBlocksDeleteMutation() throws {
        let canvas = AnnotationCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let object = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 80, height: 40))
        canvas.objects = [object]
        canvas.setSelection([object])
        canvas.isPreviewMode = true

        canvas.keyDown(with: try keyEvent(characters: "", keyCode: 51))

        XCTAssertEqual(canvas.objects.count, 1)
    }

    func testCommandZoomRoutesCallbacksExactlyOnce() throws {
        let canvas = AnnotationCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = canvas

        var userZoomCount = 0
        var userFitCount = 0
        canvas.onUserZoom = { userZoomCount += 1 }
        canvas.onUserFit = { userFitCount += 1 }

        canvas.keyDown(with: try keyEvent(characters: "=", keyCode: 24, modifiers: [.command]))
        canvas.keyDown(with: try keyEvent(characters: "-", keyCode: 27, modifiers: [.command]))
        canvas.keyDown(with: try keyEvent(characters: "0", keyCode: 29, modifiers: [.command]))

        XCTAssertEqual(userZoomCount, 2)
        XCTAssertEqual(userFitCount, 1)
    }

    func testAppliedCropMarksEditorDirty() throws {
        let controller = AnnotationWindowController(
            image: makeSolidImage(size: NSSize(width: 320, height: 200)),
            historyItem: nil,
            historyManager: nil
        )
        defer { closeWithoutPrompt(controller.window) }

        XCTAssertFalse(controller.uiTestHasUnsavedChanges)
        controller.uiTestCanvas.cropRect = CGRect(x: 20, y: 20, width: 180, height: 120)
        controller.uiTestCanvas.onCropCommit?()

        XCTAssertTrue(controller.uiTestHasUnsavedChanges)
    }

    func testDragExportCommitsActiveText() throws {
        let controller = AnnotationWindowController(
            image: makeSolidImage(size: NSSize(width: 320, height: 200)),
            historyItem: nil,
            historyManager: nil
        )
        defer { closeWithoutPrompt(controller.window) }

        let canvas = controller.uiTestCanvas
        let text = TextAnnotation(origin: CGPoint(x: 30, y: 30))
        text.text = "Before"
        canvas.objects = [text]
        canvas.beginTextEdit(of: text)

        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "After"
        let bar = try XCTUnwrap(
            controller.window?.contentView?.subviews.compactMap { $0 as? EditorBottomBar }.first
        )

        _ = bar.onRequestDragImage?()

        XCTAssertEqual(text.text, "After")
        XCTAssertFalse(canvas.subviews.contains { $0 is NSTextView })
    }

    func testSavedCheckpointTracksUndoDepthInsteadOfObjectPresence() {
        let controller = AnnotationWindowController(
            image: makeSolidImage(size: NSSize(width: 320, height: 200)),
            historyItem: nil,
            historyManager: nil
        )
        defer { closeWithoutPrompt(controller.window) }

        let canvas = controller.uiTestCanvas
        let object = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 80, height: 40))
        canvas.objects = [object]
        canvas.pushUndo()
        controller.uiTestMarkCurrentDocumentClean()

        XCTAssertFalse(controller.uiTestHasUnsavedChanges)

        canvas.pushUndo()
        object.move(by: CGPoint(x: 10, y: 0))
        XCTAssertTrue(controller.uiTestHasUnsavedChanges)

        canvas.performUndo()
        XCTAssertFalse(controller.uiTestHasUnsavedChanges)
    }

    func testSelectionMetricsStayConstantInScreenPointsAcrossZoomRange() {
        for magnification in [CGFloat(0.1), 0.25, 1, 2] {
            let metrics = AnnotationSelectionMetrics(magnification: magnification)

            XCTAssertEqual(
                metrics.cornerHandleRadius * magnification,
                AnnotationSelectionMetrics.cornerHandleRadiusScreenPoints,
                accuracy: 0.001
            )
            XCTAssertEqual(
                metrics.edgeHandleRadius * magnification,
                AnnotationSelectionMetrics.edgeHandleRadiusScreenPoints,
                accuracy: 0.001
            )
            XCTAssertEqual(
                metrics.resizeHitRadius * magnification,
                AnnotationSelectionMetrics.resizeHitRadiusScreenPoints,
                accuracy: 0.001
            )
            XCTAssertEqual(
                metrics.outlineStrokeWidth * magnification,
                AnnotationSelectionMetrics.outlineStrokeScreenPoints,
                accuracy: 0.001
            )
            XCTAssertEqual(
                metrics.outlineDashLengths[0] * magnification,
                AnnotationSelectionMetrics.dashOnScreenPoints,
                accuracy: 0.001
            )
            XCTAssertEqual(
                metrics.outlineDashLengths[1] * magnification,
                AnnotationSelectionMetrics.dashOffScreenPoints,
                accuracy: 0.001
            )
        }
    }

    func testSelectionMetricsClampMagnificationToCanvasZoomLimits() {
        let tooSmall = AnnotationSelectionMetrics(magnification: 0.001)
        let tooLarge = AnnotationSelectionMetrics(magnification: 80)

        XCTAssertEqual(tooSmall.magnification, AnnotationSelectionMetrics.minimumMagnification)
        XCTAssertEqual(tooLarge.magnification, AnnotationSelectionMetrics.maximumMagnification)
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeSolidImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func closeWithoutPrompt(_ window: NSWindow?) {
        window?.delegate = nil
        window?.close()
    }
}
