import AppKit
import XCTest
@testable import KritKit

final class ScreenImageCaptureBackendTests: XCTestCase {
    func testWindowCaptureResolverSelectsTheRealWindowInsideAShadowHost() {
        let host = descriptor(
            id: 236,
            owner: 1_296,
            frame: CGRect(x: -79, y: -40, width: 1_958, height: 1_288),
            title: nil
        )
        let content = descriptor(
            id: 235,
            owner: 1_296,
            frame: CGRect(x: 0, y: 39, width: 1_800, height: 1_130),
            title: "Untitled"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, content]),
            content.id
        )
    }

    func testWindowCapturePlanUsesResolvedAsideWindowAndItsNativeDimensions() throws {
        let host = descriptor(
            id: 236,
            owner: 1_296,
            frame: CGRect(x: -79, y: -40, width: 1_958, height: 1_288),
            title: nil
        )
        let content = descriptor(
            id: 235,
            owner: 1_296,
            frame: CGRect(x: 0, y: 39, width: 1_800, height: 1_130),
            title: "Untitled"
        )

        let plan = try XCTUnwrap(
            WindowCaptureTargetResolver.capturePlan(
                selectedID: host.id,
                candidates: [host, content]
            )
        )

        XCTAssertEqual(plan.targetID, content.id)
        XCTAssertEqual(plan.logicalSize, CGSize(width: 1_800, height: 1_130))
        XCTAssertEqual(
            plan.pixelSize(scale: 2, maxEdge: 16_384),
            IsolatedWindowCapturePlan.PixelSize(width: 3_600, height: 2_260)
        )
    }

    func testWindowCaptureResolverKeepsAnAlreadyTitledWindow() {
        let selected = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: "Dashboard"
        )
        let nested = descriptor(
            id: 11,
            owner: 20,
            frame: CGRect(x: 50, y: 50, width: 900, height: 600),
            title: "Dialog"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: selected, candidates: [selected, nested]),
            selected.id
        )
    }

    func testWindowCaptureResolverRejectsAnAsymmetricContainedWindow() {
        let host = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let sheet = descriptor(
            id: 11,
            owner: 20,
            frame: CGRect(x: 80, y: 30, width: 840, height: 560),
            title: "Save"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, sheet]),
            host.id
        )
    }

    func testWindowCaptureResolverRejectsAWindowFromAnotherProcess() {
        let host = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let foreignWindow = descriptor(
            id: 11,
            owner: 30,
            frame: CGRect(x: 50, y: 50, width: 900, height: 600),
            title: "Another app"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, foreignWindow]),
            host.id
        )
    }

    func testWindowCaptureResolverRejectsAnUnknownHostApplication() {
        let host = descriptor(
            id: 10,
            owner: 20,
            bundleIdentifier: "com.example.TransparentCanvas",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let content = descriptor(
            id: 11,
            owner: 20,
            bundleIdentifier: "com.example.TransparentCanvas",
            frame: CGRect(x: 50, y: 50, width: 900, height: 600),
            title: "Canvas"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, content]),
            host.id
        )
    }

    func testWindowCaptureResolverRejectsAWindowOnAnotherLayer() {
        let host = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let overlay = descriptor(
            id: 11,
            owner: 20,
            layer: 1,
            frame: CGRect(x: 50, y: 50, width: 900, height: 600),
            title: "Overlay"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, overlay]),
            host.id
        )
    }

    func testWindowCaptureResolverRejectsAnUnreasonableHostInset() {
        let host = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let smallPanel = descriptor(
            id: 11,
            owner: 20,
            frame: CGRect(x: 200, y: 200, width: 600, height: 300),
            title: "Panel"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, smallPanel]),
            host.id
        )
    }

    func testWindowCaptureResolverPreservesAnAmbiguousUntitledHost() {
        let host = descriptor(
            id: 10,
            owner: 20,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            title: nil
        )
        let first = descriptor(
            id: 11,
            owner: 20,
            frame: CGRect(x: 50, y: 50, width: 900, height: 600),
            title: "First"
        )
        let second = descriptor(
            id: 12,
            owner: 20,
            frame: CGRect(x: 48, y: 48, width: 904, height: 604),
            title: "Second"
        )

        XCTAssertEqual(
            WindowCaptureTargetResolver.targetID(selected: host, candidates: [host, first, second]),
            host.id
        )
    }

    func testVenturaUsesAOneFrameStreamWhenDesktopIconsAreExcluded() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: true,
                screenshotManagerAvailable: false,
                streamAvailable: true
            ),
            .oneFrameStream
        )
    }

    func testLegacyPathKeepsCoreGraphicsWhenNoFilteredCaptureIsRequested() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: false,
                screenshotManagerAvailable: false,
                streamAvailable: true
            ),
            .coreGraphics
        )
    }

    func testModernSystemsKeepScreenshotManagerAsThePreferredPath() {
        XCTAssertEqual(
            ScreenImageCaptureBackend.resolve(
                excludeDesktopIcons: true,
                screenshotManagerAvailable: true,
                streamAvailable: true
            ),
            .screenshotManager
        )
    }

    private func descriptor(
        id: CGWindowID,
        owner: pid_t?,
        bundleIdentifier: String? = "at.studio.AsideBrowser",
        layer: Int = 0,
        frame: CGRect,
        title: String?
    ) -> WindowCaptureDescriptor {
        WindowCaptureDescriptor(
            id: id,
            ownerProcessID: owner,
            ownerBundleIdentifier: bundleIdentifier,
            layer: layer,
            frame: frame,
            title: title
        )
    }
}
