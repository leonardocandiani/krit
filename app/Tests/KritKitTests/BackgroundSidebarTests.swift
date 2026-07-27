import XCTest
@testable import KritKit

@MainActor
final class BackgroundSidebarTests: XCTestCase {
    func testEditedPresetStateCannotRemoveOrSetDefaultByBaseFallback() {
        let presetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var base = ScreenshotBackgroundOptions.editorDefault
        base.isEnabled = true
        base.padding = 40
        let preset = EditTemplate(id: presetID, name: "Base preset", background: base)

        var edited = base
        edited.padding = 96

        let state = BackgroundSidebar.presetManagementState(
            options: edited,
            active: nil,
            editingBase: preset,
            isDefault: { _ in true }
        )

        XCTAssertEqual(state.title, "Base preset (edited)")
        XCTAssertEqual(state.titleBackground, edited)
        XCTAssertEqual(state.saveChangesPresetID, presetID)
        XCTAssertNil(state.defaultPresetID)
        XCTAssertNil(state.removePresetID)
        XCTAssertFalse(state.isDefault)
    }

    func testActivePresetStateTargetsSelectedPresetID() {
        let selectedID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var background = ScreenshotBackgroundOptions.editorDefault
        background.isEnabled = true
        let selected = EditTemplate(id: selectedID, name: "Selected preset", background: background)

        let state = BackgroundSidebar.presetManagementState(
            options: background,
            active: selected,
            editingBase: nil,
            isDefault: { $0 == selectedID }
        )

        XCTAssertEqual(state.title, "Selected preset")
        XCTAssertEqual(state.defaultPresetID, selectedID)
        XCTAssertEqual(state.removePresetID, selectedID)
        XCTAssertNil(state.saveChangesPresetID)
        XCTAssertTrue(state.isDefault)
    }

    func testDefaultPresetTitleUsesTextWithoutEmoji() {
        let title = BackgroundSidebar.presetMenuTitle(name: "Selected preset", isDefault: true)

        XCTAssertEqual(title, "Selected preset (default)")
        XCTAssertFalse(title.contains("\u{1F4CC}"))
    }

    func testRatioPopupWidthFitsFillEquallyPairColumn() {
        let width = BackgroundSidebar.pairedControlWidth(innerWidth: 232, spacing: 12)

        XCTAssertEqual(width, 110)
        XCTAssertLessThan(width, 232)
    }
}
