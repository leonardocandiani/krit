import XCTest
@testable import KritKit

final class AutomationGateTests: XCTestCase {
    func testAutomationRequiresThePersistedUserOptIn() {
        XCTAssertFalse(AutomationGate.decide(prefEnabled: false))
        XCTAssertTrue(AutomationGate.decide(prefEnabled: true))
    }
}
