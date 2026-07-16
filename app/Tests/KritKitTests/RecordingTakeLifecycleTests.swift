import XCTest
@testable import KritKit

final class RecordingTakeLifecycleTests: XCTestCase {
    func testSecondStartIsRejectedWhileTheFirstTakeIsStarting() throws {
        var lifecycle = RecordingTakeLifecycle()

        let first = try XCTUnwrap(lifecycle.begin())

        XCTAssertNil(lifecycle.begin())
        XCTAssertTrue(lifecycle.isStarting(first))
        XCTAssertTrue(lifecycle.isActive)
    }

    func testStopDuringStartKeepsTheTakeOwnedUntilItsCleanupCompletes() throws {
        var lifecycle = RecordingTakeLifecycle()
        let first = try XCTUnwrap(lifecycle.begin())

        XCTAssertTrue(lifecycle.beginFinishing(first))
        XCTAssertTrue(lifecycle.isFinishing(first))
        XCTAssertNil(lifecycle.begin())

        XCTAssertTrue(lifecycle.complete(first))
        XCTAssertFalse(lifecycle.isActive)
        XCTAssertNotNil(lifecycle.begin())
    }

    func testStaleCompletionCannotEndANewerTake() throws {
        var lifecycle = RecordingTakeLifecycle()
        let first = try XCTUnwrap(lifecycle.begin())
        XCTAssertTrue(lifecycle.beginFinishing(first))
        XCTAssertTrue(lifecycle.complete(first))
        let second = try XCTUnwrap(lifecycle.begin())

        XCTAssertFalse(lifecycle.complete(first))
        XCTAssertTrue(lifecycle.isStarting(second))
    }
}
