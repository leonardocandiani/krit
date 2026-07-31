import AppKit
import XCTest
@testable import KritKit

/// The card borrows the keyboard on plain hover, which is what makes Space and
/// ⌘C work without a click. The cost is that a keystroke aimed at whatever app
/// was frontmost can land here instead: the owner kept hitting a card that
/// "opens the whole editor out of nowhere" just by passing the cursor over it.
/// These assert the settling window that separates spillover from intent.
final class QuickAccessKeyFocusTests: XCTestCase {

    func testKeysAreIgnoredWhileFocusIsStillSettling() {
        let landed: CFAbsoluteTime = 1_000
        // The same instant focus landed: this is the in-flight keystroke.
        XCTAssertFalse(KeyFocusSettling.hasSettled(takenAt: landed, now: landed))
        // Still inside the window, still not ours.
        XCTAssertFalse(KeyFocusSettling.hasSettled(takenAt: landed,
                                                   now: landed + KeyFocusSettling.delay - 0.01))
    }

    func testKeysCountOnceFocusHasSettled() {
        let landed: CFAbsoluteTime = 1_000
        XCTAssertTrue(KeyFocusSettling.hasSettled(takenAt: landed,
                                                  now: landed + KeyFocusSettling.delay))
        // A card the cursor has been resting on stays fully keyboard-operable.
        XCTAssertTrue(KeyFocusSettling.hasSettled(takenAt: landed, now: landed + 5))
    }

    func testSettleDelayStaysBelowHumanReactionTime() {
        // Longer than a keystroke already in flight, shorter than the ~300ms a
        // hand needs to move the mouse and then press a key. Grow this and the
        // card starts eating keys the user meant for it.
        XCTAssertGreaterThanOrEqual(KeyFocusSettling.delay, 0.15)
        XCTAssertLessThanOrEqual(KeyFocusSettling.delay, 0.30)
    }
}
