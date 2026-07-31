import XCTest
@testable import KritKit

@MainActor
final class NativePreferencesSidebarTests: XCTestCase {
    func testUsesACompleteAccessibleSourceListWithStableSelection() {
        var callbacks: [PreferencesTab] = []
        let sidebar = NativePreferencesSidebar(width: 196, height: 620) {
            callbacks.append($0)
        }

        // The list interleaves group headers with tabs, so its row count is no
        // longer the tab count. What must hold is that every tab is still
        // reachable: a tab that lost its row would silently become unopenable.
        XCTAssertGreaterThanOrEqual(
            sidebar.numberOfRows(in: sidebar.uiTestTableView),
            PreferencesTab.allCases.count
        )
        for tab in PreferencesTab.allCases {
            sidebar.setSelected(tab)
            XCTAssertEqual(sidebar.uiTestSelectedTab, tab, "\(tab) has no row in the source list")
        }
        XCTAssertEqual(sidebar.uiTestTableView.style, .sourceList)
        XCTAssertEqual(sidebar.uiTestTableView.accessibilityLabel(), "Preferences sections")
        XCTAssertFalse(sidebar.uiTestTableView.allowsEmptySelection)
        XCTAssertTrue(sidebar.uiTestTableView.allowsTypeSelect)

        sidebar.setSelected(.capture)

        XCTAssertEqual(sidebar.uiTestSelectedTab, .capture)
        XCTAssertTrue(callbacks.isEmpty, "Controller-driven selection must not recurse through its callback")
    }
}
