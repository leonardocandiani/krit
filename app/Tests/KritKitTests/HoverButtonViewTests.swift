import XCTest
@testable import KritKit

@MainActor
final class NativePreferencesSidebarTests: XCTestCase {
    func testUsesACompleteAccessibleSourceListWithStableSelection() {
        var callbacks: [PreferencesTab] = []
        let sidebar = NativePreferencesSidebar(width: 220, height: 680) {
            callbacks.append($0)
        }

        XCTAssertEqual(
            sidebar.numberOfRows(in: sidebar.uiTestTableView),
            PreferencesTab.allCases.count
        )
        XCTAssertEqual(sidebar.uiTestTableView.style, .sourceList)
        XCTAssertEqual(sidebar.uiTestTableView.accessibilityLabel(), "Preferences sections")
        XCTAssertFalse(sidebar.uiTestTableView.allowsEmptySelection)
        XCTAssertTrue(sidebar.uiTestTableView.allowsTypeSelect)

        sidebar.setSelected(.capture)

        XCTAssertEqual(sidebar.uiTestSelectedTab, .capture)
        XCTAssertTrue(callbacks.isEmpty, "Controller-driven selection must not recurse through its callback")
    }
}
