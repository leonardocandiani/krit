import XCTest
@testable import KritKit

final class PreferencesTabTests: XCTestCase {
    func testEveryTabHasCompleteUniqueNavigationMetadata() {
        let tabs = PreferencesTab.allCases

        XCTAssertEqual(tabs.count, 9)
        XCTAssertEqual(Set(tabs.map(\.title)).count, tabs.count)
        XCTAssertEqual(Set(tabs.map(\.symbol)).count, tabs.count)
        XCTAssertTrue(tabs.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(tabs.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(tabs.allSatisfy { !$0.subtitle.isEmpty })
        XCTAssertEqual(
            PreferencesTab.capture.subtitle,
            "File format, timer, window background, and save location."
        )
    }
}
