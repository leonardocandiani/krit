import XCTest
@testable import KritKit

@MainActor
final class CaptureTriggerTests: XCTestCase {
    func testLegacyDistributedNotificationsStayDisabledInTheNormalTestBuild() {
        XCTAssertFalse(CaptureTrigger.isEnabled(in: [:]))
        XCTAssertFalse(CaptureTrigger.isEnabled(in: ["KRIT_UI_TEST": "0"]))
        XCTAssertFalse(CaptureTrigger.isEnabled(in: ["KRIT_UI_TEST": "1"]))
    }

    func testRuntimeFlagAlsoNeedsAnExplicitHarnessBuild() {
        XCTAssertFalse(KritTestHarness.runtimeGate(
            buildSupportsHarness: false, runtimeFlagPresent: true
        ))
        XCTAssertTrue(KritTestHarness.runtimeGate(
            buildSupportsHarness: true, runtimeFlagPresent: true
        ))
    }

    func testBundleRuntimeProbeRequiresItsExactCommandLineArgument() {
        XCTAssertFalse(KritBundleRuntimeProbe.isRequested(in: ["KRIT"]))
        XCTAssertFalse(KritBundleRuntimeProbe.isRequested(in: ["KRIT", "--verify-resources"]))
        XCTAssertTrue(KritBundleRuntimeProbe.isRequested(in: [
            "KRIT", KritBundleRuntimeProbe.argument
        ]))
    }

    func testLegacyTriggerOutputStaysInsideTemporaryDirectory() {
        XCTAssertNotNil(CaptureTrigger.temporaryOutputURL(for: "/tmp/krit-capture-test.png"))
        XCTAssertNil(CaptureTrigger.temporaryOutputURL(for: "/Users/shared/krit-capture-test.png"))
        XCTAssertNil(CaptureTrigger.temporaryOutputURL(for: "/tmp/../Users/shared/krit-capture-test.png"))
    }
}
