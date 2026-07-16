// Deprecated on 2026-07-10 with LegacyPreferencesSidebar.swift.
// The replacement contract is NativePreferencesSidebarTests in the test target.

import XCTest
@testable import KritKit

@MainActor
final class HoverButtonViewTests: XCTestCase {
    func testActsAsAnAccessibleKeyboardFocusableButton() {
        var clicks = 0
        let view = HoverButtonView(
            onClick: { clicks += 1 },
            accessibilityLabel: "Capture"
        )

        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "Capture")
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.canBecomeKeyView)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(clicks, 1)
        view.performClick(nil)
        XCTAssertEqual(clicks, 2)
    }
}
