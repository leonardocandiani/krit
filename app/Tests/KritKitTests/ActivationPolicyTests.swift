import AppKit
import XCTest
@testable import KritKit

@MainActor
final class ActivationPolicyTests: XCTestCase {
    func testLiveAnnotationDrawingKeepsAccessoryPolicyWhenPreferencesCloses() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let controller = LiveAnnotationController()
        let preferences = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 240, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        defer {
            preferences.orderOut(nil)
            controller.deactivate(clearing: true)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        controller.toggleDrawMode()
        guard case .drawing = controller.mode else {
            return XCTFail("Live Annotation did not enter drawing mode")
        }

        _ = NSApp.setActivationPolicy(.accessory)
        preferences.orderFrontRegardless()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: preferences)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    func testLiveAnnotationPassiveDoesNotKeepAccessoryPolicy() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let controller = LiveAnnotationController()

        defer {
            controller.deactivate(clearing: true)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        controller.toggleDrawMode()
        controller.seedTestInk()
        controller.exitDrawModeKeepingAnnotations()

        guard case .passive = controller.mode else {
            return XCTFail("Live Annotation did not enter passive mode")
        }

        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testLiveAnnotationRearmedFromPassiveKeepsAccessoryPolicy() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let controller = LiveAnnotationController()
        let preferences = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 240, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        defer {
            preferences.orderOut(nil)
            controller.deactivate(clearing: true)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        controller.toggleDrawMode()
        controller.seedTestInk()
        controller.exitDrawModeKeepingAnnotations()
        controller.toggleDrawMode()

        guard case .drawing = controller.mode else {
            return XCTFail("Live Annotation did not re-enter drawing mode")
        }

        _ = NSApp.setActivationPolicy(.accessory)
        preferences.orderFrontRegardless()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: preferences)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }

    func testLiveAnnotationDeactivationDoesNotKeepAccessoryPolicy() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let controller = LiveAnnotationController()

        defer {
            controller.deactivate(clearing: true)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        controller.toggleDrawMode()
        guard case .drawing = controller.mode else {
            return XCTFail("Live Annotation did not enter drawing mode")
        }

        controller.deactivate(clearing: true)

        guard case .off = controller.mode else {
            return XCTFail("Live Annotation did not deactivate")
        }
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testStatusLevelWindowDoesNotBlockBackgroundOnlyRestoration() {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let statusLevelWindow = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 120, height: 48),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        statusLevelWindow.level = .statusBar

        defer {
            statusLevelWindow.orderOut(nil)
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        _ = NSApp.setActivationPolicy(.accessory)
        statusLevelWindow.orderFrontRegardless()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()

        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testPinnedWindowPromotesAndRestoresActivationPolicy() throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        PinnedWindow.closeAll()
        defer {
            PinnedWindow.closeAll()
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        _ = NSApp.setActivationPolicy(.prohibited)
        PinnedWindow.pin(image: makeImage())

        XCTAssertFalse(PinnedWindow.uiTestPinnedWindows.isEmpty)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)

        PinnedWindow.closeAll()
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
    }

    func testClosingAllPinnedWindowsRemovesSnapReleaseMonitor() throws {
        _ = NSApplication.shared
        PinnedWindow.closeAll()
        defer { PinnedWindow.closeAll() }

        PinnedWindow.pin(image: makeImage())
        let pin = try XCTUnwrap(PinnedWindow.uiTestPinnedWindows.last)
        pin.uiTestArmSnapMouseUpMonitor()
        XCTAssertTrue(pin.uiTestSnapMouseUpMonitorArmed)

        PinnedWindow.closeAll()

        XCTAssertFalse(pin.uiTestSnapMouseUpMonitorArmed)
    }

    func testClosingPinnedWindowRemovesSnapReleaseMonitor() throws {
        _ = NSApplication.shared
        PinnedWindow.closeAll()
        defer { PinnedWindow.closeAll() }

        PinnedWindow.pin(image: makeImage())
        let pin = try XCTUnwrap(PinnedWindow.uiTestPinnedWindows.last)
        pin.uiTestArmSnapMouseUpMonitor()
        XCTAssertTrue(pin.uiTestSnapMouseUpMonitorArmed)

        pin.uiTestClose()

        XCTAssertFalse(pin.uiTestSnapMouseUpMonitorArmed)
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }
}
