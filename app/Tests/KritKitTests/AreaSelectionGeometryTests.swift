import XCTest
@testable import KritKit

final class AreaSelectionGeometryTests: XCTestCase {
    func testClampsAForwardDragToTheOriginatingScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let rect = AreaSelectionGeometry.rect(
            from: CGPoint(x: 1_200, y: 600),
            to: CGPoint(x: 1_800, y: 1_100),
            constrainedTo: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 1_200, y: 600, width: 240, height: 300))
        XCTAssertTrue(bounds.contains(rect))
    }

    func testClampsAReverseDragToTheOriginatingScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let rect = AreaSelectionGeometry.rect(
            from: CGPoint(x: 300, y: 200),
            to: CGPoint(x: -120, y: -80),
            constrainedTo: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertTrue(bounds.contains(rect))
    }

    func testLeavesAnInBoundsDragUnchanged() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertEqual(
            AreaSelectionGeometry.rect(
                from: CGPoint(x: 240, y: 180),
                to: CGPoint(x: 960, y: 620),
                constrainedTo: bounds
            ),
            CGRect(x: 240, y: 180, width: 720, height: 440)
        )
    }
}
