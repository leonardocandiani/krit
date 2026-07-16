import XCTest
@testable import KritKit

@MainActor
final class AllInOneAccessibilityTests: XCTestCase {
    func testEachActionHasStableAccessibleIdentity() {
        XCTAssertEqual(
            AllInOneAction.allCases.map(\.accessibilityIdentifier),
            [
                "all-in-one.capture",
                "all-in-one.record",
                "all-in-one.window",
                "all-in-one.fullscreen",
                "all-in-one.scrolling",
                "all-in-one.ocr",
            ]
        )
        XCTAssertEqual(
            AllInOneAction.allCases.map(\.accessibilityLabel),
            ["Capture", "Record", "Window", "Fullscreen", "Scrolling", "OCR"]
        )
    }

    func testPanelUsesFocusableButtonsThatVoiceOverCanPress() {
        var selectedIdentifiers: [String] = []
        let panel = AllInOnePanelWindow { action in
            selectedIdentifiers.append(action.accessibilityIdentifier)
        }
        defer { panel.close() }

        let buttons = panel.optionButtons
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() }, AllInOneAction.allCases.map(\.accessibilityIdentifier))
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, AllInOneAction.allCases.map(\.accessibilityLabel))
        XCTAssertTrue(buttons.allSatisfy(\.acceptsFirstResponder))
        XCTAssertTrue(panel.initialFirstResponder === buttons.first)

        for button in buttons {
            XCTAssertTrue(button.accessibilityPerformPress())
        }
        XCTAssertEqual(selectedIdentifiers, AllInOneAction.allCases.map(\.accessibilityIdentifier))
    }

    func testTabOrderCyclesThroughEachAction() throws {
        let panel = AllInOnePanelWindow { _ in }
        defer { panel.close() }
        let buttons = panel.optionButtons
        let tab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            )
        )

        for index in buttons.indices {
            XCTAssertTrue(panel.makeFirstResponder(buttons[index]))
            buttons[index].keyDown(with: tab)
            XCTAssertTrue(panel.firstResponder === buttons[(index + 1) % buttons.count])
        }
    }

    func testModifiedTabDoesNotHijackSystemShortcuts() throws {
        let panel = AllInOnePanelWindow { _ in }
        defer { panel.close() }
        let first = try XCTUnwrap(panel.optionButtons.first)
        let commandTab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            )
        )

        XCTAssertTrue(panel.makeFirstResponder(first))
        first.keyDown(with: commandTab)

        XCTAssertTrue(panel.firstResponder === first)
    }

    func testFocusedButtonActivatesWithSpaceAndReturn() throws {
        var selectedIdentifiers: [String] = []
        let panel = AllInOnePanelWindow { action in
            selectedIdentifiers.append(action.accessibilityIdentifier)
        }
        defer { panel.close() }

        let space = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
        )
        let `return` = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        XCTAssertTrue(panel.makeFirstResponder(panel.optionButtons[0]))
        panel.optionButtons[0].keyDown(with: space)
        XCTAssertTrue(panel.makeFirstResponder(panel.optionButtons[1]))
        panel.optionButtons[1].keyDown(with: `return`)

        XCTAssertEqual(selectedIdentifiers, ["all-in-one.capture", "all-in-one.record"])
    }

    func testOptionsKeepTheirTouchFramesAfterDockLayout() {
        let panel = AllInOnePanelWindow { _ in }
        defer { panel.close() }

        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            panel.optionButtons.map(\.frame),
            [
                CGRect(x: 10, y: 10, width: 76, height: 60),
                CGRect(x: 88, y: 10, width: 76, height: 60),
                CGRect(x: 182, y: 10, width: 76, height: 60),
                CGRect(x: 260, y: 10, width: 76, height: 60),
                CGRect(x: 354, y: 10, width: 76, height: 60),
                CGRect(x: 432, y: 10, width: 76, height: 60),
            ]
        )
    }

    func testDockKeepsOnePrimaryActionAndThreeVisualGroups() {
        XCTAssertEqual(
            AllInOneAction.allCases.filter(\.isPrimary).map(\.accessibilityIdentifier),
            ["all-in-one.capture"]
        )
        XCTAssertEqual(
            AllInOneAction.allCases.filter(\.endsDockGroup).map(\.accessibilityIdentifier),
            ["all-in-one.record", "all-in-one.fullscreen"]
        )
    }

    func testPanelDoesNotShareWithScreenCapture() {
        let panel = AllInOnePanelWindow { _ in }
        defer { panel.close() }

        XCTAssertEqual(panel.sharingType, .none)
    }
}
