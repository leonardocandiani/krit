import XCTest
@testable import KritKit

final class InteractiveCaptureRoutingTests: XCTestCase {
    func testAllInOneDoesNotRememberKritAsTheSourceApp() {
        XCTAssertNil(
            InteractiveCaptureRoute.allInOneSourceProcessIdentifier(
                frontmostProcessIdentifier: 42,
                kritProcessIdentifier: 42
            )
        )
    }

    func testAllInOneRemembersTheAppThatOpenedIt() {
        XCTAssertEqual(
            InteractiveCaptureRoute.allInOneSourceProcessIdentifier(
                frontmostProcessIdentifier: 41,
                kritProcessIdentifier: 42
            ),
            41
        )
    }

    func testSnapAndPastePrefersTheAppThatOpenedAllInOne() {
        XCTAssertEqual(
            InteractiveCaptureRoute.snapAndPasteTargetProcessIdentifier(
                allInOneSourceProcessIdentifier: 41,
                frontmostProcessIdentifier: 42
            ),
            41
        )
    }

    func testSnapAndPasteFallsBackToTheCurrentFrontmostApp() {
        XCTAssertEqual(
            InteractiveCaptureRoute.snapAndPasteTargetProcessIdentifier(
                allInOneSourceProcessIdentifier: nil,
                frontmostProcessIdentifier: 99
            ),
            99
        )
    }

    func testInteractiveCaptureDispatchGateRejectsAnOlderQueuedRequest() {
        var gate = InteractiveCaptureDispatchGate()
        let olderRequest = gate.beginRequest()
        let latestRequest = gate.beginRequest()

        XCTAssertFalse(gate.isLatest(olderRequest))
        XCTAssertTrue(gate.isLatest(latestRequest))
    }

    @MainActor
    func testInteractiveCaptureDispatchRunsOnlyTheLatestQueuedOperation() async {
        let engine = CaptureEngine()
        var executed: [String] = []

        engine.enqueueInteractiveRequest {
            executed.append("older")
        }
        engine.enqueueInteractiveRequest {
            executed.append("latest")
        }

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(executed, ["latest"])
    }
}
