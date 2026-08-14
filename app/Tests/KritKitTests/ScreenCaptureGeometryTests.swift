import AVFoundation
import XCTest
@testable import KritKit

final class ScreenCaptureGeometryTests: XCTestCase {
    func testCameraBubbleStaysInsideItsRecordedScreenWhenDraggedTowardAnotherDisplay() {
        let recordedScreen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let origin = CameraBubbleGeometry.clampedOrigin(
            mouseLocation: CGPoint(x: 1_260, y: 420),
            dragOffset: CGPoint(x: 40, y: 60),
            bubbleSize: CGSize(width: 150, height: 150),
            visibleFrame: recordedScreen
        )

        XCTAssertEqual(origin.x, 850)
        XCTAssertEqual(origin.y, 360)
        XCTAssertTrue(recordedScreen.contains(CGRect(origin: origin, size: CGSize(width: 150, height: 150))))
    }

    func testOneXSecondaryDisplayUsesLocalTopLeftCoordinatesAndEvenRecordingPixels() throws {
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: 42,
            appKitFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            coreGraphicsFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            backingScale: 1
        )

        let region = try geometry.sourceRegion(
            for: CGRect(x: -1_819.75, y: 100.25, width: 641, height: 479),
            evenPixelDimensions: true,
            maxEdge: 16_384
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 100, y: 501, width: 641, height: 479))
        XCTAssertEqual(region.pixelWidth, 642)
        XCTAssertEqual(region.pixelHeight, 480)
    }

    func testRetinaRegionSnapsEveryEdgeToTheNativePixelGrid() throws {
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: 7,
            appKitFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            coreGraphicsFrame: CGRect(x: 0, y: 0, width: 3_024, height: 1_964),
            backingScale: 2
        )

        let region = try geometry.sourceRegion(
            for: CGRect(x: 10.25, y: 20.25, width: 100.1, height: 50.1),
            evenPixelDimensions: false,
            maxEdge: 16_384
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 10, y: 911.5, width: 100.5, height: 50.5))
        XCTAssertEqual(region.pixelWidth, 201)
        XCTAssertEqual(region.pixelHeight, 101)
    }

    func testTextureLimitPreservesAspectRatioAndKeepsClampedPixelsEven() throws {
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: 8,
            appKitFrame: CGRect(x: 0, y: 0, width: 12_000, height: 10_000),
            coreGraphicsFrame: CGRect(x: 0, y: 0, width: 24_000, height: 20_000),
            backingScale: 2
        )

        XCTAssertEqual(ScreenCaptureDisplayGeometry.maxCaptureEdge, 16_384)

        let region = try geometry.sourceRegion(
            for: CGRect(x: 0, y: 0, width: 9_000, height: 8_191.5),
            evenPixelDimensions: true,
            maxEdge: ScreenCaptureDisplayGeometry.maxCaptureEdge
        )

        XCTAssertEqual(region.pixelWidth, 16_384)
        XCTAssertEqual(region.pixelHeight, 14_912)
        XCTAssertTrue(region.pixelWidth.isMultiple(of: 2))
        XCTAssertTrue(region.pixelHeight.isMultiple(of: 2))
    }

    func testRecordingCapsLargeRetinaDisplayAtHardwareH264Edge() throws {
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: 10,
            appKitFrame: CGRect(x: 0, y: 0, width: 3_008, height: 1_692),
            coreGraphicsFrame: CGRect(x: 0, y: 0, width: 6_016, height: 3_384),
            backingScale: 2
        )

        XCTAssertEqual(RecordingEngine.maxCaptureEdge, 4_096)

        let region = try geometry.sourceRegion(
            for: geometry.appKitFrame,
            evenPixelDimensions: true,
            maxEdge: RecordingEngine.maxCaptureEdge
        )

        XCTAssertEqual(region.pixelWidth, 4_096)
        XCTAssertEqual(region.pixelHeight, 2_304)
    }

    @MainActor
    func testH264SettingsDoNotContainStillImageQualityKey() throws {
        let settings = RecordingEngine.videoSettings(
            width: 4_096,
            height: 2_304,
            fps: 30,
            quality: .high
        )
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )

        XCTAssertNil(compression[AVVideoQualityKey])
        XCTAssertNotNil(compression[AVVideoAverageBitRateKey])
    }

    func testWindowFrameRoundTripsAcrossMixedGlobalCoordinateSpaces() {
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: 9,
            appKitFrame: CGRect(x: 0, y: 982, width: 1_280, height: 720),
            coreGraphicsFrame: CGRect(x: 0, y: -720, width: 1_280, height: 720),
            backingScale: 1
        )
        let windowFrame = CGRect(x: 100, y: -650, width: 640, height: 480)

        let appKit = geometry.appKitRect(fromCoreGraphics: windowFrame)

        XCTAssertEqual(appKit, CGRect(x: 100, y: 1_152, width: 640, height: 480))
        XCTAssertEqual(geometry.coreGraphicsRect(fromAppKit: appKit), windowFrame)
    }
}

@MainActor
final class ScreenCaptureSnapshotStoreTests: XCTestCase {
    func testStableSnapshotCachesUntilTopologyInvalidation() async throws {
        let store = ScreenCaptureSnapshotStore<String, Int>()
        var loads = 0

        let first = try await store.value(for: "displays", cacheCompleted: true) {
            loads += 1
            return loads
        }
        let second = try await store.value(for: "displays", cacheCompleted: true) {
            loads += 1
            return loads
        }
        store.invalidate(keepCompleted: false)
        let third = try await store.value(for: "displays", cacheCompleted: true) {
            loads += 1
            return loads
        }

        XCTAssertEqual([first, second, third], [1, 1, 2])
        XCTAssertEqual(loads, 2)
    }

    func testSequentialWindowSnapshotsStayFresh() async throws {
        let store = ScreenCaptureSnapshotStore<String, Int>()
        var loads = 0

        let first = try await store.value(for: "on-screen", cacheCompleted: false) {
            loads += 1
            return loads
        }
        let second = try await store.value(for: "on-screen", cacheCompleted: false) {
            loads += 1
            return loads
        }

        XCTAssertEqual([first, second], [1, 2])
    }

    func testConcurrentWindowSnapshotsShareOnlyTheInFlightEnumeration() async throws {
        let store = ScreenCaptureSnapshotStore<String, Int>()
        var loads = 0

        async let first = store.value(for: "all", cacheCompleted: false) {
            loads += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return loads
        }
        async let second = store.value(for: "all", cacheCompleted: false) {
            loads += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return loads
        }
        let values = try await [first, second]

        XCTAssertEqual(values, [1, 1])
        XCTAssertEqual(loads, 1)
    }
}
