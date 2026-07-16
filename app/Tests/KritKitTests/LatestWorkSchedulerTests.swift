import XCTest
@testable import KritKit

@MainActor
final class LatestWorkSchedulerTests: XCTestCase {
    func testRunsTheFirstRequestAndKeepsOnlyTheLatestPendingRequest() {
        var scheduler = LatestWorkScheduler<Int>()

        XCTAssertEqual(scheduler.submit(1), .start)
        XCTAssertEqual(scheduler.submit(2), .queued)
        XCTAssertEqual(scheduler.submit(3), .queued)
        XCTAssertEqual(scheduler.active, 1)
        XCTAssertEqual(scheduler.pending, 3)

        XCTAssertEqual(scheduler.complete(1), 3)
        XCTAssertEqual(scheduler.active, 3)
        XCTAssertNil(scheduler.pending)
        XCTAssertNil(scheduler.complete(3))
        XCTAssertNil(scheduler.active)
    }

    func testReturningToTheActiveRequestDropsAStaleQueuedRequest() {
        var scheduler = LatestWorkScheduler<String>()

        XCTAssertEqual(scheduler.submit("first"), .start)
        XCTAssertEqual(scheduler.submit("middle"), .queued)
        XCTAssertEqual(scheduler.submit("first"), .alreadyActive)
        XCTAssertNil(scheduler.pending)
        XCTAssertNil(scheduler.complete("first"))
        XCTAssertNil(scheduler.active)
    }
}
