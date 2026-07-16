import XCTest
@testable import KritKit

final class NativeShortcutManagerTests: XCTestCase {
    func testPromptPolicyOnlyOffersConflictResolutionOnce() {
        XCTAssertTrue(
            NativeShortcutManager.shouldOfferConflictResolution(
                nativeShortcutsEnabled: true,
                hasPromptedBefore: false
            )
        )
        XCTAssertFalse(
            NativeShortcutManager.shouldOfferConflictResolution(
                nativeShortcutsEnabled: true,
                hasPromptedBefore: true
            )
        )
        XCTAssertFalse(
            NativeShortcutManager.shouldOfferConflictResolution(
                nativeShortcutsEnabled: false,
                hasPromptedBefore: false
            )
        )
    }
}
