import AppKit
import XCTest
@testable import KritKit

@MainActor
final class AnnotationChromeInteractionTests: XCTestCase {
    func testEditorToolAndToggleButtonsInstallTheSamePointerTrackingContract() {
        let tool = FlatToolButton(tool: .arrow, target: nil, action: nil)
        let toggle = ChromeToggleButton(symbol: "eye.slash", target: nil, action: nil)

        tool.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        toggle.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        tool.updateTrackingAreas()
        toggle.updateTrackingAreas()

        assertPointerFeedback(on: tool)
        assertPointerFeedback(on: toggle)
    }

    func testEditorModeSegmentUsesKritAccentInsteadOfSystemBlue() throws {
        let bar = EditorBottomBar(frame: NSRect(x: 0, y: 0, width: 720, height: 56))
        // Searched by descendant rather than direct subview: the bar's controls
        // now live inside the glass capsule that backs the pill.
        let mode = try XCTUnwrap(descendants(of: NSSegmentedControl.self, in: bar).first)
        let actual = try XCTUnwrap(mode.selectedSegmentBezelColor?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(KritColors.accent.usingColorSpace(.sRGB))

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        XCTAssertFalse(FlatToolButton(tool: .arrow, target: nil, action: nil).mouseDownCanMoveWindow)
    }

    func testEditorToolbarUsesOneBandAndGroupsSecondaryToolsByIntent() {
        let toolbar = AnnotationToolbar(frame: NSRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: AnnotationToolbar.totalHeight
        ))

        // The pill is padding, one control, padding: nothing else may creep into
        // its height, or the capsule stops being a capsule.
        XCTAssertEqual(
            AnnotationToolbar.totalHeight,
            AnnotationToolbar.controlSize + AnnotationToolbar.pillPadding * 2
        )
        XCTAssertEqual(descendants(of: ToolFamilyButton.self, in: toolbar).count, 3)
        XCTAssertEqual(descendants(of: FlatToolButton.self, in: toolbar).count, 6)
        toolbar.layoutSubtreeIfNeeded()

        // The toolbar floats over the stage, so its width is its content's. The
        // guard that matters is that it stays a pill: wide enough for the tools,
        // and nowhere near the full width of an editor window (which is what it
        // used to span as a band).
        XCTAssertGreaterThanOrEqual(toolbar.fittingWidth, AnnotationToolbar.requiredWidth)
        XCTAssertLessThan(toolbar.fittingWidth, 900)
    }

    func testBottomBarDragPillAcceptsFirstMouseAndUsesProfessionalHitArea() throws {
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 116, height: 22))
        let event = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 58, y: 11))

        XCTAssertTrue(pill.acceptsFirstMouse(for: event))
        XCTAssertTrue(pill.mouseDownCanMoveWindow == false)
        XCTAssertTrue(pill.hitTest(NSPoint(x: 58, y: -6)) === pill)
    }

    func testEditorOpensWithVisibleFullDragOutAffordance() throws {
        let image = NSImage(size: NSSize(width: 900, height: 580))
        let editor = AnnotationWindowController(image: image, historyItem: nil, historyManager: nil)
        defer { editor.window?.close() }

        let content = try XCTUnwrap(editor.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(descendants(of: BottomBarDragPill.self, in: content).first)

        XCTAssertFalse(pill.isHidden, "The editor must expose drag-out when it first opens")
        guard case .full = pill.mode else {
            return XCTFail("The editor has enough room for the labeled drag-out control")
        }
        XCTAssertEqual(pill.frame.width, BottomBarDragPill.fullWidth, accuracy: 0.5)
    }

    func testBottomBarDragPillUsesAnExplicitPlatformDragIcon() {
        XCTAssertNotNil(BottomBarDragPill.dragSymbolName)
        XCTAssertEqual(BottomBarDragPill.dragTitle, "Drag out")
    }

    func testBottomBarDragPillDoesNotRequestImageBeforeDragThreshold() throws {
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 116, height: 22))
        var providerCalls = 0
        pill.imageProvider = {
            providerCalls += 1
            return NSImage(size: NSSize(width: 80, height: 40))
        }

        pill.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 10, y: 10)))
        pill.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 12, y: 11)))

        XCTAssertEqual(providerCalls, 0)
    }

    func testBottomBarDragPillPreviewFrameUsesPreviewAspectAndSize() {
        let wide = BottomBarDragPill.previewSize(for: NSSize(width: 400, height: 200))
        XCTAssertEqual(wide.width, 120, accuracy: 0.001)
        XCTAssertEqual(wide.height, 60, accuracy: 0.001)

        let tall = BottomBarDragPill.previewSize(for: NSSize(width: 100, height: 400))
        XCTAssertEqual(tall.width, 30, accuracy: 0.001)
        XCTAssertEqual(tall.height, 120, accuracy: 0.001)

        let frame = BottomBarDragPill.draggingFrame(centeredAt: NSPoint(x: 20, y: 30), previewSize: tall)
        XCTAssertEqual(frame.size, tall)
        XCTAssertEqual(frame.midX, 20, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 30, accuracy: 0.001)
    }

    private func assertPointerFeedback(on view: NSView) {
        XCTAssertTrue(view.trackingAreas.contains { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.activeAlways)
        })
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { view -> [T] in
            let current = (view as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }

    private func mouseEvent(type: NSEvent.EventType, location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
