import AppKit
import XCTest
@testable import KritKit

@MainActor
final class PreferencesWindowChromeTests: XCTestCase {
    func testWindowUsesCompleteNativeChrome() throws {
        try withPreferencesWindow { _, window in
            let expectedMask: NSWindow.StyleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ]

            XCTAssertEqual(window.styleMask.intersection(expectedMask), expectedMask)
            XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(.closeButton)).isEnabled)
            XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(.miniaturizeButton)).isEnabled)
            XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(.zoomButton)).isEnabled)
        }
    }

    func testWindowKeepsSemanticTitleHiddenBehindNativeChrome() throws {
        try withPreferencesWindow { _, window in
            XCTAssertEqual(window.title, "KRIT Settings")
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertTrue(window.titlebarAppearsTransparent)
        }
    }

    func testSidebarHasNoStaticBrandLabelAndKeepsSourceListAccessible() {
        let sidebar = NativePreferencesSidebar(width: 220, height: 680) { _ in }
        let labels = descendants(of: sidebar.view, as: NSTextField.self)
        let sourceLists = descendants(of: sidebar.view, as: NSTableView.self)

        XCTAssertFalse(labels.contains { $0.stringValue == "KRIT" })
        XCTAssertEqual(sourceLists.count, 1)
        XCTAssertEqual(sourceLists.first?.style, .sourceList)
        XCTAssertEqual(sourceLists.first?.accessibilityLabel(), "Preferences sections")
    }

    func testShowRestoresAMiniaturizedWindow() throws {
        try withPreferencesWindow { controller, window in
            controller.show()
            window.miniaturize(nil)
            XCTAssertTrue(waitUntil { window.isMiniaturized })

            controller.show()

            XCTAssertTrue(waitUntil { !window.isMiniaturized })
            XCTAssertTrue(window.isVisible)
        }
    }

    func testShowReopensAClosedWindow() throws {
        try withPreferencesWindow { controller, window in
            controller.show()
            XCTAssertTrue(window.isVisible)

            window.close()
            XCTAssertFalse(window.isVisible)

            controller.show()

            XCTAssertTrue(window.isVisible)
        }
    }

    func testClosingLastPersistentWindowRestoresProhibitedPolicy() throws {
        try withPreferencesWindow { controller, window in
            _ = NSApp.setActivationPolicy(.prohibited)
            controller.show()
            XCTAssertEqual(NSApp.activationPolicy(), .accessory)

            window.close()

            XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        }
    }

    private func withPreferencesWindow(
        _ body: (PreferencesWindowController, NSWindow) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let controller = PreferencesWindowController.shared
        let window = try XCTUnwrap(controller.uiTestWindow)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderOut(nil)

        defer {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderOut(nil)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        try body(controller, window)
    }

    private func descendants<View: NSView>(of root: NSView, as type: View.Type) -> [View] {
        var matches = root is View ? [root as! View] : []
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: subview, as: type))
        }
        return matches
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
