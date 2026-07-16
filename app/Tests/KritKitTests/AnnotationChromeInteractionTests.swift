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
        let mode = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        let actual = try XCTUnwrap(mode.selectedSegmentBezelColor?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(KritColors.accent.usingColorSpace(.sRGB))

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        XCTAssertFalse(FlatToolButton(tool: .arrow, target: nil, action: nil).mouseDownCanMoveWindow)
    }

    private func assertPointerFeedback(on view: NSView) {
        XCTAssertTrue(view.trackingAreas.contains { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.activeAlways)
        })
    }
}
