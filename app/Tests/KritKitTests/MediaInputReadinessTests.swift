import XCTest
@testable import KritKit

final class MediaInputReadinessTests: XCTestCase {
    func testReturnsImmediatelyWhenInputIsReady() {
        var pauseCount = 0

        let ready = MediaInputReadiness.waitUntilReady(
            deadline: 5,
            isReady: { true },
            now: { 0 },
            pause: { _ in pauseCount += 1 }
        )

        XCTAssertTrue(ready)
        XCTAssertEqual(pauseCount, 0)
    }

    func testStopsAtSharedDeadlineWhenInputNeverBecomesReady() {
        var now = 0.0

        let ready = MediaInputReadiness.waitUntilReady(
            deadline: 0.006,
            pollInterval: 0.002,
            isReady: { false },
            now: { now },
            pause: { duration in now += duration }
        )

        XCTAssertFalse(ready)
        XCTAssertEqual(now, 0.006, accuracy: 0.000_001)
    }

    func testSyntheticWriterDeadlineAllowsAVFoundationToFinishInitialSetup() {
        XCTAssertGreaterThanOrEqual(MediaInputReadiness.syntheticWriterTimeout, 15)
    }

    @MainActor
    func testFinishDeadlineResumesWhenWriterNeverCompletes() async {
        let finished = await MediaInputReadiness.waitForFinish(timeout: 0.01) { _ in }

        XCTAssertFalse(finished)
    }
}
