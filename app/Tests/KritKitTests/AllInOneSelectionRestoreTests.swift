import XCTest
@testable import KritKit

final class AllInOneSelectionRestoreTests: XCTestCase {
    func testUsesTheMostRecentValidAreaBeforeThePersistedFallback() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let sessionArea = CGRect(x: 1760, y: 180, width: 720, height: 420)
        let persistedArea = CGRect(x: 140, y: 120, width: 640, height: 360)

        let restored = AllInOneSelectionRestore.resolve(
            candidates: [sessionArea, persistedArea],
            screenFrames: [primary, external]
        )

        XCTAssertEqual(restored?.rect, sessionArea)
        XCTAssertEqual(restored?.screenIndex, 1)
    }

    func testSkipsAnAreaThatNoLongerFitsOneCurrentDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let staleArea = CGRect(x: 1320, y: 220, width: 300, height: 360)
        let persistedArea = CGRect(x: 1840, y: 160, width: 560, height: 320)

        let restored = AllInOneSelectionRestore.resolve(
            candidates: [staleArea, persistedArea],
            screenFrames: [primary, external]
        )

        XCTAssertEqual(restored?.rect, persistedArea)
        XCTAssertEqual(restored?.screenIndex, 1)
    }

    func testUsesThePersistedAreaWhenTheSessionHasNoPreviousSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let persistedArea = CGRect(x: 240, y: 180, width: 720, height: 420)

        let restored = AllInOneSelectionRestore.resolve(
            candidates: [nil, persistedArea],
            screenFrames: [screen]
        )

        XCTAssertEqual(restored?.rect, persistedArea)
        XCTAssertEqual(restored?.screenIndex, 0)
    }

    func testReturnsNoSelectionWhenEveryCandidateIsInvalid() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let restored = AllInOneSelectionRestore.resolve(
            candidates: [CGRect(x: 60, y: 60, width: 0, height: 300), CGRect(x: -20, y: 80, width: 320, height: 240)],
            screenFrames: [screen]
        )

        XCTAssertNil(restored)
    }

    func testDefaultSelectionKeepsTheExistingCenteredSixtyPercentGeometry() {
        let screen = CGRect(x: 400, y: -100, width: 1600, height: 1000)

        XCTAssertEqual(
            AllInOneSelectionRestore.defaultRect(in: screen),
            CGRect(x: 720, y: 100, width: 960, height: 600)
        )
    }
}
