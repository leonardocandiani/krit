import AppKit
import XCTest
@testable import KritKit

/// Spacing is the thing that regresses silently. A colour change is obvious in
/// any screenshot; a panel that drifts from 250pt to 232pt, or a pill that
/// centres on the window instead of on the stage, looks "fine" until someone
/// puts the two side by side. These assert the ruler in `KritMetrics` instead.
@MainActor
final class EditorSpacingRulerTests: XCTestCase {

    private func makeEditor() -> AnnotationWindowController {
        let image = NSImage(size: NSSize(width: 900, height: 580))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 580).fill()
        image.unlockFocus()
        let editor = AnnotationWindowController(image: image, historyItem: nil, historyManager: nil)
        // A realistic window. Headless, AppKit hands back a frame far narrower
        // than any real editor, and the chrome then reports the metrics of a
        // window nobody will ever see.
        editor.window?.setFrame(NSRect(x: 0, y: 0, width: 1_280, height: 820), display: false)
        return editor
    }

    func testFloatingPanelKeepsItsMarginOnEveryEdge() throws {
        let editor = makeEditor()
        defer { editor.window?.close() }
        editor.uiTestToggleSidebar()

        let metrics = try XCTUnwrap(editor.uiTestChromeMetrics)
        let margin = Double(KritMetrics.Panel.margin)

        XCTAssertEqual(try XCTUnwrap(metrics["panelWidth"]), Double(KritMetrics.Panel.width), accuracy: 0.5)
        // A floating panel that touches any edge stops reading as floating, and
        // its 20.5pt corners get clipped into a square by the window. The panel
        // lives on the LEADING edge, the side the reference puts it on.
        XCTAssertEqual(try XCTUnwrap(metrics["panelMarginLeading"]), margin, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(metrics["panelMarginBottom"]), margin, accuracy: 0.5)
        // The top is the ONE edge where the panel keeps more than the margin: it
        // stops below the band the system draws the traffic lights in. Those
        // buttons cannot be moved, so the panel is what gives way.
        XCTAssertEqual(try XCTUnwrap(metrics["panelMarginTop"]),
                       margin + Double(AnnotationWindowController.uiTestTrafficLightBand),
                       accuracy: 0.5)
    }

    func testToolPillCentresOnTheStageRatherThanTheWindow() throws {
        let editor = makeEditor()
        defer { editor.window?.close() }
        editor.uiTestToggleSidebar()

        let metrics = try XCTUnwrap(editor.uiTestChromeMetrics)
        // With the panel open the stage is narrower than the window. Centring on
        // the window would push the pill under the panel by half its width.
        XCTAssertEqual(try XCTUnwrap(metrics["toolPillCenterOffset"]), 0, accuracy: 1)
    }

    func testBothPillsShareOneHeightAndOneRuler() throws {
        let editor = makeEditor()
        defer { editor.window?.close() }

        let metrics = try XCTUnwrap(editor.uiTestChromeMetrics)
        let expected = Double(AnnotationToolbar.controlSize + AnnotationToolbar.pillPadding * 2)

        XCTAssertEqual(try XCTUnwrap(metrics["toolPillHeight"]), expected, accuracy: 0.5)
        // Two floating capsules that disagree on their metrics read as two apps.
        XCTAssertEqual(try XCTUnwrap(metrics["actionPillHeight"]), expected, accuracy: 0.5)
        // Both pills centre on the same vertical line: one at the top of the
        // stage, one at the bottom.
        XCTAssertEqual(try XCTUnwrap(metrics["actionPillCenterOffset"]), 0, accuracy: 1)
        XCTAssertEqual(EditorBottomBar.pillHeight, AnnotationToolbar.totalHeight)
    }

    func testSpacingRulerMatchesTheReferenceTokens() {
        // These are the reference app's literal design tokens. If one of them
        // changes, it should be because the reference changed, not because a
        // call site wanted a slightly different number.
        XCTAssertEqual(KritMetrics.unit, 8)
        XCTAssertEqual(KritMetrics.Radius.panel, 20.5)
        XCTAssertEqual(KritMetrics.Radius.card, 10)
        XCTAssertEqual(KritMetrics.Radius.cell, 7)
        XCTAssertEqual(KritMetrics.cardPadY, 12)
        XCTAssertEqual(KritMetrics.cardPadX, 14)
        XCTAssertEqual(KritMetrics.cardGap, 10)
        XCTAssertEqual(KritMetrics.headerGap, 6)
        XCTAssertEqual(KritMetrics.Grid.swatchColumns, 10)
        XCTAssertEqual(KritMetrics.Grid.swatchGap, 5)
        XCTAssertEqual(KritMetrics.Grid.cellColumns, 4)
        XCTAssertEqual(KritMetrics.Grid.cellGap, 4)
    }
}
