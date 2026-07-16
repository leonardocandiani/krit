import Foundation
import XCTest
@testable import KritKit

final class QuickAccessScreenResolutionTests: XCTestCase {
    func testStaleStoredScreenUsesLiveFallback() {
        let removedScreen = NSObject()
        let liveScreen = NSObject()
        let liveID = ObjectIdentifier(liveScreen)

        let resolved = QuickAccessScreenResolution.resolve(
            storedScreenID: ObjectIdentifier(removedScreen),
            liveScreenIDs: [liveID],
            fallbackScreenID: liveID
        )

        XCTAssertEqual(resolved, liveID)
    }

    func testLiveStoredScreenWinsOverFallback() {
        let storedScreen = NSObject()
        let fallbackScreen = NSObject()
        let storedID = ObjectIdentifier(storedScreen)

        let resolved = QuickAccessScreenResolution.resolve(
            storedScreenID: storedID,
            liveScreenIDs: [storedID, ObjectIdentifier(fallbackScreen)],
            fallbackScreenID: ObjectIdentifier(fallbackScreen)
        )

        XCTAssertEqual(resolved, storedID)
    }

    func testStaleStoredScreenUsesFirstLiveScreenWhenFallbackIsGone() {
        let removedScreen = NSObject()
        let removedFallback = NSObject()
        let firstLiveScreen = NSObject()
        let secondLiveScreen = NSObject()
        let firstLiveID = ObjectIdentifier(firstLiveScreen)

        let resolved = QuickAccessScreenResolution.resolve(
            storedScreenID: ObjectIdentifier(removedScreen),
            liveScreenIDs: [firstLiveID, ObjectIdentifier(secondLiveScreen)],
            fallbackScreenID: ObjectIdentifier(removedFallback)
        )

        XCTAssertEqual(resolved, firstLiveID)
    }

    func testNoLiveScreenReturnsNil() {
        let removedScreen = NSObject()

        let resolved = QuickAccessScreenResolution.resolve(
            storedScreenID: ObjectIdentifier(removedScreen),
            liveScreenIDs: [],
            fallbackScreenID: nil
        )

        XCTAssertNil(resolved)
    }
}
