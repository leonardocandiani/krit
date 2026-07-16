import XCTest
@testable import KritKit

@MainActor
final class VisionRequestExecutorTests: XCTestCase {
    func testRunsVisionWorkAwayFromTheMainThread() async {
        let ranOffMainThread = await VisionRequestExecutor.perform {
            !Thread.isMainThread
        }

        XCTAssertTrue(ranOffMainThread)
    }
}
