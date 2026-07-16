import XCTest
@testable import KritKit

@MainActor
final class SystemWallpaperSourceTests: XCTestCase {
    func testBundledWallpaperNamesMatchPrecisionMonolithDisplayOrder() {
        XCTAssertEqual(
            SystemWallpaperSource.bundledWallpaperNames,
            [
                "Obsidian Cut",
                "Cobalt Plane",
                "Titanium Fold",
                "Ember Channel",
                "Porcelain Edge",
                "Glacier Plane",
                "Carbon Violet",
                "Jade Alloy",
            ]
        )
    }

    func testBundledWallpaperCatalogResolvesAndDecodesEveryManifestEntry() async {
        let wallpapers = SystemWallpaperSource.resolvedBundledWallpapers

        XCTAssertEqual(wallpapers.map(\.name), SystemWallpaperSource.bundledWallpaperNames)
        XCTAssertEqual(wallpapers.count, 8)
        for wallpaper in wallpapers {
            let image = await thumbnail(for: wallpaper, maxPixel: 128)
            XCTAssertNotNil(image, "Expected bundled wallpaper \(wallpaper.name) to decode.")
        }
    }

    func testDefaultBlurWallpaperIsObsidianCut() {
        XCTAssertEqual(SystemWallpaperSource.defaultBlurWallpaperName, "Obsidian Cut")
    }

    func testDefaultBlurBackgroundDataDecodesObsidianCut() async throws {
        var deliveredOnMainThread = false
        let data = await withCheckedContinuation { continuation in
            SystemWallpaperSource.defaultBlurBackgroundData(maxPixel: 320) { data in
                deliveredOnMainThread = Thread.isMainThread
                continuation.resume(returning: data)
            }
        }

        XCTAssertTrue(deliveredOnMainThread)
        let encoded = try XCTUnwrap(data)
        XCTAssertNotNil(NSImage(data: encoded))
    }

    func testUntouchedEditorDefaultSeedsDefaultBlurWallpaper() {
        XCTAssertTrue(
            BackgroundSidebar.shouldSeedDefaultBlurWallpaper(
                for: ScreenshotBackgroundOptions.editorDefault
            )
        )
    }

    func testExplicitBackgroundChoicesKeepTheirOwnBlurPreviewSource() {
        var gradient = ScreenshotBackgroundOptions.editorDefault
        gradient.isEnabled = true

        var solid = ScreenshotBackgroundOptions.editorDefault
        solid.isEnabled = true
        solid.style = .solid
        solid.colorHex = "#112233"

        var fixedImage = ScreenshotBackgroundOptions.editorDefault
        fixedImage.isEnabled = true
        fixedImage.style = .image
        fixedImage.presetName = "Imported"
        fixedImage.customImageName = "Imported"
        fixedImage.customImageData = Data([0x01])

        var currentDesktop = ScreenshotBackgroundOptions.editorDefault
        currentDesktop.isEnabled = true
        currentDesktop.style = .image
        currentDesktop.presetName = "Current"
        currentDesktop.tracksDesktopWallpaper = true

        var blurred = fixedImage
        blurred.style = .blurredImage

        let explicitChoices = [
            ("gradient", gradient),
            ("solid", solid),
            ("fixed image", fixedImage),
            ("current desktop", currentDesktop),
            ("blurred", blurred),
        ]

        for (name, options) in explicitChoices {
            XCTAssertFalse(
                BackgroundSidebar.shouldSeedDefaultBlurWallpaper(for: options),
                "Expected the explicit \(name) choice to keep its own preview source."
            )
        }
    }

    func testDefaultSeedAndExplicitSamePaletteUseDistinctBlurPreviewIdentities() {
        let untouched = ScreenshotBackgroundOptions.editorDefault
        var explicit = untouched
        explicit.isEnabled = true

        let seededIdentity = BackgroundSidebar.blurPreviewIdentity(for: untouched)
        let explicitIdentity = BackgroundSidebar.blurPreviewIdentity(for: explicit)

        XCTAssertTrue(seededIdentity.hasPrefix("seed-default|"))
        XCTAssertTrue(explicitIdentity.hasPrefix("selected|"))
        XCTAssertNotEqual(seededIdentity, explicitIdentity)
    }

    func testBlurPreviewIdentityIncludesCustomImageContent() {
        var first = ScreenshotBackgroundOptions.editorDefault
        first.isEnabled = true
        first.style = .image
        first.customImageName = "Imported"
        first.customImageData = Data([0x01, 0x02])

        var second = first
        second.customImageData = Data([0x03, 0x04])

        XCTAssertNotEqual(
            BackgroundSidebar.blurPreviewIdentity(for: first),
            BackgroundSidebar.blurPreviewIdentity(for: second)
        )
    }

    func testBlurPreviewIdentityIncludesGradientAccentColors() {
        var coral = ScreenshotBackgroundOptions.editorDefault
        coral.isEnabled = true
        coral.accentHexes = ["#ff6f8f", "#ffab6b"]

        var cobalt = coral
        cobalt.accentHexes = ["#3f7cff", "#8f5cff"]

        XCTAssertNotEqual(
            BackgroundSidebar.blurPreviewIdentity(for: coral),
            BackgroundSidebar.blurPreviewIdentity(for: cobalt)
        )
    }

    func testBlurPreviewIdentityIncludesDesktopTrackingState() {
        var fixed = ScreenshotBackgroundOptions.editorDefault
        fixed.isEnabled = true
        fixed.style = .image
        fixed.customImageName = "Current wallpaper"
        fixed.customImageData = Data([0x01])
        fixed.tracksDesktopWallpaper = false

        var tracking = fixed
        tracking.tracksDesktopWallpaper = true

        XCTAssertNotEqual(
            BackgroundSidebar.blurPreviewIdentity(for: fixed),
            BackgroundSidebar.blurPreviewIdentity(for: tracking)
        )
    }

    func testBlurSelectionKeepsExplicitBackgroundSource() {
        var explicit = ScreenshotBackgroundOptions.editorDefault
        explicit.isEnabled = true
        explicit.style = .image
        explicit.presetName = "Imported"
        explicit.customImageName = "Imported"
        explicit.customImageData = Data([0x01, 0x02])
        explicit.tracksDesktopWallpaper = false

        let selected = BackgroundSidebar.blurSelectionOptions(
            from: explicit,
            level: 40,
            defaultWallpaperData: Data([0x09])
        )

        XCTAssertTrue(selected.isEnabled)
        XCTAssertEqual(selected.style, .blurredImage)
        XCTAssertEqual(selected.blurIntensity, 40)
        XCTAssertEqual(selected.presetName, explicit.presetName)
        XCTAssertEqual(selected.customImageName, explicit.customImageName)
        XCTAssertEqual(selected.customImageData, explicit.customImageData)
        XCTAssertEqual(selected.tracksDesktopWallpaper, explicit.tracksDesktopWallpaper)
    }

    func testBlurSelectionSeedsObsidianForUntouchedEditorDefault() async throws {
        let data = await withCheckedContinuation { continuation in
            SystemWallpaperSource.defaultBlurBackgroundData(maxPixel: 320) { data in
                continuation.resume(returning: data)
            }
        }
        let decodedData = try XCTUnwrap(data)
        XCTAssertNotNil(NSImage(data: decodedData))

        let selected = BackgroundSidebar.blurSelectionOptions(
            from: .editorDefault,
            level: 22,
            defaultWallpaperData: decodedData
        )

        XCTAssertTrue(selected.isEnabled)
        XCTAssertEqual(selected.style, .blurredImage)
        XCTAssertEqual(selected.blurIntensity, 22)
        XCTAssertEqual(selected.presetName, "Obsidian Cut")
        XCTAssertEqual(selected.customImageName, "Obsidian Cut")
        XCTAssertEqual(selected.customImageData, decodedData)
        XCTAssertNil(selected.tracksDesktopWallpaper)
    }

    func testBlurSelectionTokenIsInvalidatedAcrossExternalABAAssignments() {
        var gate = BackgroundSidebar.BlurSelectionRequestGate()
        let initialToken = gate.begin()

        gate.externalOptionsAssigned() // B: explicit gradient
        gate.externalOptionsAssigned() // A: back to the initial options

        XCTAssertFalse(gate.accepts(initialToken))
    }

    func testNoOpCommitIntentInvalidatesBlurSelectionToken() {
        var gate = BackgroundSidebar.BlurSelectionRequestGate()
        let initialToken = gate.begin()

        gate.commitIntent()

        XCTAssertFalse(gate.accepts(initialToken))
    }

    func testCachedThumbnailCallbackIsDeferred() async throws {
        let wallpaper = try XCTUnwrap(
            SystemWallpaperSource.resolvedBundledWallpapers.first { $0.name == "Obsidian Cut" }
        )

        let warmup = await thumbnail(for: wallpaper)
        _ = try XCTUnwrap(warmup)

        var calledBeforeReturn = false
        let delivered = expectation(description: "cached thumbnail")
        SystemWallpaperSource.thumbnail(for: wallpaper, maxPixel: 320) { _ in
            calledBeforeReturn = true
            delivered.fulfill()
        }

        XCTAssertFalse(calledBeforeReturn)
        await fulfillment(of: [delivered], timeout: 1)
    }

    func testThumbnailCacheSeparatesRequestedSizes() async throws {
        let wallpaper = try XCTUnwrap(
            SystemWallpaperSource.resolvedBundledWallpapers.first { $0.name == "Obsidian Cut" }
        )

        guard let small = await thumbnail(for: wallpaper, maxPixel: 64),
              let large = await thumbnail(for: wallpaper, maxPixel: 320) else {
            XCTFail("Expected both thumbnail requests to decode an image.")
            return
        }

        let smallEdge = max(small.size.width, small.size.height)
        let largeEdge = max(large.size.width, large.size.height)
        XCTAssertGreaterThan(largeEdge, smallEdge)
    }

    private func thumbnail(for wallpaper: SystemWallpaperSource.Wallpaper, maxPixel: CGFloat = 320) async -> NSImage? {
        await withCheckedContinuation { continuation in
            SystemWallpaperSource.thumbnail(for: wallpaper, maxPixel: maxPixel) { image in
                continuation.resume(returning: image)
            }
        }
    }
}
