import AppKit
import CoreMedia
import XCTest
@testable import KritKit

@MainActor
final class RecordingContinuumTests: XCTestCase {
    func testPreflightLayoutUsesOneDisjointFourPointGridRow() {
        let layout = RecordingPreflightLayout()

        XCTAssertEqual(layout.shell.size, CGSize(width: 744, height: 72))
        assertContainedAndDisjoint(layout.semanticFrames, inside: layout.shell)
        assertFourPointGrid(layout.semanticFrames + [layout.shell])
        XCTAssertEqual(layout.record.width, 136)
        XCTAssertEqual(layout.toggles.count, 4)
    }

    func testHUDLayoutKeepsEveryControlDisjointWithAndWithoutMicrophoneMeter() {
        for showsMeter in [false, true] {
            let layout = RecordingHUDLayout(showsMeter: showsMeter)

            assertContainedAndDisjoint(layout.semanticFrames, inside: layout.shell)
            assertFourPointGrid(layout.semanticFrames + [layout.shell])
            XCTAssertEqual(layout.microphoneMeter != nil, showsMeter)
            XCTAssertEqual(layout.shell.width, showsMeter ? 556 : 436)
            XCTAssertEqual(layout.pause.width, 100)
            XCTAssertEqual(layout.stop.width, 112)
            XCTAssertEqual(layout.overflow.width, 48)
        }
    }

    func testRecordingChromeAllocatesSpaceToLiveStateBeforeSecondaryChrome() {
        let preflight = RecordingPreflightLayout()
        XCTAssertEqual(preflight.shell.size, CGSize(width: 744, height: 72))
        XCTAssertEqual(preflight.source, CGRect(x: 8, y: 8, width: 176, height: 56))
        XCTAssertEqual(
            preflight.toggles,
            [
                CGRect(x: 192, y: 8, width: 52, height: 56),
                CGRect(x: 244, y: 8, width: 52, height: 56),
                CGRect(x: 296, y: 8, width: 52, height: 56),
                CGRect(x: 348, y: 8, width: 52, height: 56),
            ]
        )
        XCTAssertEqual(preflight.options, CGRect(x: 408, y: 8, width: 136, height: 56))
        XCTAssertEqual(preflight.record, CGRect(x: 552, y: 8, width: 136, height: 56))
        XCTAssertEqual(preflight.cancel, CGRect(x: 696, y: 8, width: 40, height: 56))
        assertContainedAndDisjoint(preflight.semanticFrames, inside: preflight.shell)

        let activeHUD = RecordingHUDLayout(showsMeter: true)
        XCTAssertEqual(activeHUD.shell.size, CGSize(width: 556, height: 72))
        XCTAssertEqual(activeHUD.liveCluster, CGRect(x: 8, y: 8, width: 136, height: 56))
        XCTAssertEqual(activeHUD.microphoneMeter, CGRect(x: 152, y: 8, width: 112, height: 56))
        XCTAssertEqual(activeHUD.pause, CGRect(x: 272, y: 8, width: 100, height: 56))
        XCTAssertEqual(activeHUD.stop, CGRect(x: 380, y: 8, width: 112, height: 56))
        XCTAssertEqual(activeHUD.overflow, CGRect(x: 500, y: 8, width: 48, height: 56))
        assertContainedAndDisjoint(activeHUD.semanticFrames, inside: activeHUD.shell)

        let compactHUD = RecordingHUDLayout(showsMeter: false)
        XCTAssertEqual(compactHUD.shell.size, CGSize(width: 436, height: 72))
        XCTAssertEqual(compactHUD.liveCluster, CGRect(x: 8, y: 8, width: 136, height: 56))
        XCTAssertEqual(compactHUD.pause, CGRect(x: 152, y: 8, width: 100, height: 56))
        XCTAssertEqual(compactHUD.stop, CGRect(x: 260, y: 8, width: 112, height: 56))
        XCTAssertEqual(compactHUD.overflow, CGRect(x: 380, y: 8, width: 48, height: 56))
        assertContainedAndDisjoint(compactHUD.semanticFrames, inside: compactHUD.shell)

        let result = RecordingResultLayout()
        XCTAssertEqual(result.shell.size, CGSize(width: 696, height: 112))
        XCTAssertEqual(result.thumbnail, CGRect(x: 12, y: 12, width: 144, height: 88))
        XCTAssertEqual(result.metadata, CGRect(x: 168, y: 12, width: 216, height: 88))
        XCTAssertEqual(result.editRecording, CGRect(x: 392, y: 28, width: 136, height: 56))
        XCTAssertEqual(result.reveal, CGRect(x: 536, y: 28, width: 96, height: 56))
        XCTAssertEqual(result.overflow, CGRect(x: 640, y: 28, width: 44, height: 56))
        assertContainedAndDisjoint(result.semanticFrames, inside: result.shell)
    }

    func testResultLayoutCannotRecreateEditRevealOverlap() {
        let layout = RecordingResultLayout()

        XCTAssertEqual(layout.shell.size, CGSize(width: 696, height: 112))
        assertContainedAndDisjoint(layout.semanticFrames, inside: layout.shell)
        assertFourPointGrid(layout.semanticFrames + [layout.shell])
        XCTAssertFalse(layout.editRecording.intersects(layout.reveal))
        XCTAssertEqual(layout.primaryAction, layout.editRecording)
        XCTAssertEqual(layout.overflow.width, 44)
        XCTAssertEqual(layout.metadata, CGRect(x: 168, y: 12, width: 216, height: 88))
        XCTAssertEqual(layout.editRecording, CGRect(x: 392, y: 28, width: 136, height: 56))
        XCTAssertEqual(layout.reveal, CGRect(x: 536, y: 28, width: 96, height: 56))
        XCTAssertEqual(layout.overflow, CGRect(x: 640, y: 28, width: 44, height: 56))
    }

    func testMotionPolicyMatchesSurfaceFrequencyAndReduceMotion() {
        XCTAssertEqual(
            RecordingMotionPolicy.entrance(
                for: .preflight,
                trigger: .keyboard,
                reduceMotion: false
            ),
            .instant
        )
        XCTAssertEqual(
            RecordingMotionPolicy.entrance(
                for: .hud,
                trigger: .stateTransition,
                reduceMotion: false
            ),
            .fadeAndScale(duration: 0.16, initialScale: 0.98)
        )
        XCTAssertEqual(
            RecordingMotionPolicy.exit(for: .hud, reduceMotion: false),
            .fade(duration: 0.12)
        )
        XCTAssertEqual(
            RecordingMotionPolicy.entrance(
                for: .result,
                trigger: .stateTransition,
                reduceMotion: true
            ),
            .instant
        )
    }

    func testPausedHUDKeepsStopFullyAvailable() {
        let paused = RecordingHUDStateAppearance(paused: true)

        XCTAssertEqual(paused.stopAlpha, 1)
        XCTAssertEqual(paused.stateLabel, "Paused")
        XCTAssertEqual(paused.liveRole, .paused)
        XCTAssertEqual(paused.pauseAccessibilityLabel, "Resume recording")
    }

    func testSharedButtonBlocksWindowDraggingAndHasStableAccessibility() {
        let button = RecordingChromeButton(
            symbol: "record.circle",
            title: "Record",
            role: .primary,
            presentation: .horizontal
        )

        XCTAssertFalse(button.mouseDownCanMoveWindow)
        XCTAssertEqual(button.accessibilityLabel(), "Record")
        XCTAssertEqual(button.semanticRole, .primary)
    }

    func testNeutralRecordingButtonsRestDirectlyOnTheSharedShell() {
        let button = RecordingChromeButton(
            symbol: "slider.horizontal.3",
            title: "Recording options",
            role: .neutral,
            presentation: .horizontal
        )

        XCTAssertEqual(backgroundAlpha(of: button), 0, accuracy: 0.001)

        button.setSemanticRole(.selected)
        XCTAssertEqual(backgroundAlpha(of: button), 0, accuracy: 0.001)

        button.setSemanticRole(.primary)
        XCTAssertGreaterThan(backgroundAlpha(of: button), 0.8)
    }

    func testSharedMeterUsesNativeLevelIndicatorAccessibility() {
        let meter = RecordingLevelMeter(frame: NSRect(x: 0, y: 0, width: 32, height: 24))

        XCTAssertEqual(meter.accessibilityRole(), .levelIndicator)
        XCTAssertEqual(meter.accessibilityLabel(), "Microphone input level")
        XCTAssertNil(meter.hitTest(NSPoint(x: 4, y: 4)))
    }

    func testWideRecordingMeterUsesItsAvailableWidth() {
        let meter = RecordingLevelMeter(frame: NSRect(x: 0, y: 0, width: 48, height: 20))

        meter.setLevel(1)

        let rightmostBar = meter.subviews.map { $0.frame.maxX }.max() ?? 0
        XCTAssertGreaterThan(rightmostBar, 44)
    }

    func testRecordingSurfacesUseOneSharedStyleGrammar() {
        XCTAssertEqual(RecordingChrome.preflightShellRadius, ChromeFactory.Radius.dock)
        XCTAssertEqual(RecordingChrome.hudShellRadius, RecordingChrome.preflightShellRadius)
        XCTAssertEqual(RecordingChrome.resultShellRadius, ChromeFactory.Radius.panel)
        XCTAssertEqual(RecordingChrome.controlRadius, ChromeFactory.Radius.control)
        // Wide and soft, the shadow a menu casts. The point of pinning it is
        // that both recording surfaces share one shadow, and that it stays in
        // the range that reads as "floating" rather than as a dark rectangle
        // painted underneath, which is what 0.56 looked like over pale content.
        XCTAssertEqual(RecordingChrome.overlayShadow.opacity, 0.22)
        XCTAssertLessThanOrEqual(RecordingChrome.overlayShadow.opacity, 0.30)
        XCTAssertEqual(RecordingChrome.overlayShadow.radius, 28)
        XCTAssertLessThan(RecordingChrome.contrastFloorAlpha, 0.68)
    }

    func testRecordingContrastFloorRespondsToAccessibilityPreferences() {
        XCTAssertEqual(
            RecordingChrome.contrastFloorOpacity(
                reduceTransparency: false,
                increaseContrast: false
            ),
            RecordingChrome.contrastFloorAlpha
        )
        XCTAssertGreaterThan(
            RecordingChrome.contrastFloorOpacity(
                reduceTransparency: true,
                increaseContrast: false
            ),
            RecordingChrome.contrastFloorAlpha
        )
        XCTAssertGreaterThan(
            RecordingChrome.contrastFloorOpacity(
                reduceTransparency: false,
                increaseContrast: true
            ),
            RecordingChrome.contrastFloorAlpha
        )
    }

    func testClearGlassFallbackCompositesWithinItsContainingWindow() {
        XCTAssertEqual(
            ChromeFactory.fallbackBlendingMode(for: .clear),
            .withinWindow
        )
        XCTAssertEqual(
            ChromeFactory.fallbackBlendingMode(for: .regular),
            .behindWindow
        )
    }

    func testPreflightRealViewMatchesTheContinuumHierarchy() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let originalMicrophone = Settings.recordingMicrophone
        let originalCamera = Settings.recordingWebcam
        Settings.recordingMicrophone = false
        Settings.recordingWebcam = false

        let engine = CaptureEngine()
        defer {
            engine.uiTestCloseRecordingPreflight()
            Settings.recordingMicrophone = originalMicrophone
            Settings.recordingWebcam = originalCamera
        }

        let window = try XCTUnwrap(
            engine.uiTestShowRecordingPreflight(
                rect: CGRect(x: 40, y: 40, width: 640, height: 360),
                on: screen
            )
        )
        let views = allSubviews(of: try XCTUnwrap(window.contentView))
        let expectedIdentifiers: Set<String> = [
            "recording.preflight.source",
            "recording.preflight.system-audio",
            "recording.preflight.microphone",
            "recording.preflight.cursor",
            "recording.preflight.camera",
            "recording.preflight.options",
            "recording.preflight.record",
            "recording.preflight.cancel",
        ]
        let viewsByIdentifier = Dictionary(
            uniqueKeysWithValues: views.compactMap { view -> (String, NSView)? in
                guard let rawValue = view.identifier?.rawValue else { return nil }
                return (rawValue, view)
            }
        )

        XCTAssertEqual(window.frame.size, CGSize(width: 760, height: 88))
        XCTAssertTrue(expectedIdentifiers.isSubset(of: Set(viewsByIdentifier.keys)))
        let compactTitles = [
            "recording.preflight.system-audio": "Audio",
            "recording.preflight.microphone": "Mic",
            "recording.preflight.cursor": "Cursor",
            "recording.preflight.camera": "Camera",
        ]
        for (identifier, title) in compactTitles {
            XCTAssertEqual((viewsByIdentifier[identifier] as? NSButton)?.title, title)
        }
        for identifier in expectedIdentifiers where identifier != "recording.preflight.source" {
            let button = try XCTUnwrap(viewsByIdentifier[identifier] as? NSButton)
            XCTAssertFalse(button.mouseDownCanMoveWindow, identifier)
            XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty, identifier)
            XCTAssertEqual(button.accessibilityIdentifier(), identifier)
        }

        let dividerIdentifiers: Set<String> = [
            "recording.preflight.section-divider.source",
            "recording.preflight.section-divider.toggles",
            "recording.preflight.section-divider.options",
        ]
        XCTAssertTrue(dividerIdentifiers.isSubset(of: Set(viewsByIdentifier.keys)))
        XCTAssertEqual(backgroundAlpha(of: try XCTUnwrap(viewsByIdentifier["recording.preflight.source"])), 0, accuracy: 0.001)
        XCTAssertEqual(backgroundAlpha(of: try XCTUnwrap(viewsByIdentifier["recording.preflight.toggle-rail"])), 0, accuracy: 0.001)
    }

    func testPreflightGroupsMediaTogglesIntoOneSegmentedRail() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let originalMicrophone = Settings.recordingMicrophone
        let originalCamera = Settings.recordingWebcam
        Settings.recordingMicrophone = false
        Settings.recordingWebcam = false
        let engine = CaptureEngine()
        defer {
            engine.uiTestCloseRecordingPreflight()
            Settings.recordingMicrophone = originalMicrophone
            Settings.recordingWebcam = originalCamera
        }

        let window = try XCTUnwrap(
            engine.uiTestShowRecordingPreflight(
                rect: CGRect(x: 40, y: 40, width: 640, height: 360),
                on: screen
            )
        )
        let views = allSubviews(of: try XCTUnwrap(window.contentView))
        let rail = try XCTUnwrap(
            views.first { $0.identifier?.rawValue == "recording.preflight.toggle-rail" }
        )

        XCTAssertEqual(rail.frame, CGRect(x: 192, y: 8, width: 208, height: 56))
        let dividers = allSubviews(of: rail).filter {
            $0.identifier?.rawValue.hasPrefix("recording.preflight.toggle-divider.") == true
        }
        XCTAssertEqual(dividers.count, 3)
        XCTAssertTrue(dividers.allSatisfy { $0.frame.height == 24 })
    }

    func testHUDRealViewMatchesTheContinuumHierarchyAndPausedPriority() throws {
        let hud = RecordingHUDWindow()
        hud.restartHandler = {}
        hud.discardHandler = {}
        hud.configure(systemAudio: true, microphone: true, fps: 60, quality: "High")

        let views = allSubviews(of: try XCTUnwrap(hud.contentView))
        let expectedIdentifiers: Set<String> = [
            "recording.hud.live",
            "recording.hud.microphone-meter",
            "recording.hud.pause",
            "recording.hud.stop",
            "recording.hud.overflow",
        ]
        let viewsByIdentifier = Dictionary(
            uniqueKeysWithValues: views.compactMap { view -> (String, NSView)? in
                guard let rawValue = view.identifier?.rawValue else { return nil }
                return (rawValue, view)
            }
        )

        XCTAssertEqual(hud.frame.size, CGSize(width: 556, height: 72))
        XCTAssertTrue(expectedIdentifiers.isSubset(of: Set(viewsByIdentifier.keys)))
        XCTAssertNil(viewsByIdentifier["recording.hud.restart"])

        hud.setPaused(true)

        let stop = try XCTUnwrap(viewsByIdentifier["recording.hud.stop"] as? NSButton)
        let pause = try XCTUnwrap(viewsByIdentifier["recording.hud.pause"] as? NSButton)
        XCTAssertEqual(stop.alphaValue, 1)
        XCTAssertEqual(stop.accessibilityLabel(), "Stop recording")
        XCTAssertEqual(pause.accessibilityLabel(), "Resume recording")
        XCTAssertEqual(pause.title, "Resume")
        XCTAssertEqual((stop as? RecordingChromeButton)?.presentation, .horizontal)
        XCTAssertEqual((pause as? RecordingChromeButton)?.presentation, .horizontal)
        XCTAssertEqual(stop.frame, RecordingHUDLayout(showsMeter: true).stop)
        XCTAssertEqual(pause.frame, RecordingHUDLayout(showsMeter: true).pause)
        for identifier in expectedIdentifiers {
            let view = try XCTUnwrap(viewsByIdentifier[identifier], identifier)
            XCTAssertFalse(view.isHidden, identifier)
            XCTAssertGreaterThan(view.alphaValue, 0.99, identifier)
            guard let button = viewsByIdentifier[identifier] as? NSButton else { continue }
            XCTAssertFalse(button.mouseDownCanMoveWindow, identifier)
            XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty, identifier)
        }

        let dividerIdentifiers = Set((0..<4).map { "recording.hud.section-divider.\($0)" })
        XCTAssertTrue(dividerIdentifiers.isSubset(of: Set(viewsByIdentifier.keys)))
        XCTAssertEqual(backgroundAlpha(of: try XCTUnwrap(viewsByIdentifier["recording.hud.live"])), 0, accuracy: 0.001)
        XCTAssertEqual(backgroundAlpha(of: try XCTUnwrap(viewsByIdentifier["recording.hud.microphone-meter"])), 0, accuracy: 0.001)
    }

    func testRecordingChromeUsesTextualPauseAndRevealActionsWhenSpaceAllows() throws {
        let hud = RecordingHUDWindow()
        hud.configure(systemAudio: true, microphone: true, fps: 60, quality: "High")
        let hudViews = allSubviews(of: try XCTUnwrap(hud.contentView))
        let pause = try XCTUnwrap(
            hudViews.first { $0.identifier?.rawValue == "recording.hud.pause" } as? RecordingChromeButton
        )
        XCTAssertEqual(pause.presentation, .horizontal)
        XCTAssertEqual(pause.title, "Pause")

        let result = RecordingResultWindow.uiTestMake(
            url: URL(fileURLWithPath: "/tmp/KRIT-recording-hierarchy.mp4"),
            duration: 12,
            actions: StubRecordingResultActions()
        )
        let resultViews = allSubviews(of: try XCTUnwrap(result.contentView))
        let reveal = try XCTUnwrap(
            resultViews.first { $0.identifier?.rawValue == "recording.result.reveal" } as? RecordingChromeButton
        )
        XCTAssertEqual(reveal.presentation, .horizontal)
    }

    func testHUDKeepsRestartAndDiscardInsideMoreMenu() {
        let hud = RecordingHUDWindow()
        hud.restartHandler = {}
        hud.discardHandler = {}

        let actions = hud.makeOverflowMenu().items.filter { !$0.isSeparatorItem }

        XCTAssertEqual(actions.map(\.title), ["Restart Recording", "Discard Recording"])
        XCTAssertEqual(actions.map(\.isEnabled), [true, true])
    }

    func testResultRealViewMatchesTheContinuumHierarchyWithoutOverlap() throws {
        let actions = StubRecordingResultActions()
        let window = RecordingResultWindow.uiTestMake(
            url: URL(fileURLWithPath: "/tmp/KRIT 2026-07-10 at 13.38.42.mp4"),
            duration: 12,
            actions: actions
        )
        let views = allSubviews(of: try XCTUnwrap(window.contentView))
        let expectedIdentifiers: Set<String> = [
            "recording.result.thumbnail",
            "recording.result.metadata",
            "recording.result.edit",
            "recording.result.reveal",
            "recording.result.overflow",
        ]
        let viewsByIdentifier = Dictionary(
            uniqueKeysWithValues: views.compactMap { view -> (String, NSView)? in
                guard let rawValue = view.identifier?.rawValue else { return nil }
                return (rawValue, view)
            }
        )

        XCTAssertEqual(window.frame.size, CGSize(width: 696, height: 112))
        XCTAssertTrue(expectedIdentifiers.isSubset(of: Set(viewsByIdentifier.keys)))

        let edit = try XCTUnwrap(viewsByIdentifier["recording.result.edit"] as? RecordingChromeButton)
        let reveal = try XCTUnwrap(viewsByIdentifier["recording.result.reveal"] as? RecordingChromeButton)
        let overflow = try XCTUnwrap(viewsByIdentifier["recording.result.overflow"] as? RecordingChromeButton)
        XCTAssertEqual(edit.semanticRole, .primary)
        XCTAssertEqual(reveal.semanticRole, .neutral)
        XCTAssertEqual(overflow.semanticRole, .neutral)
        XCTAssertFalse(edit.frame.intersects(reveal.frame))
        XCTAssertFalse(reveal.frame.intersects(overflow.frame))
        XCTAssertEqual(overflow.frame.size, CGSize(width: 44, height: 56))
    }

    func testBorderlessRecordingResultParticipatesInActivationLifetime() {
        let window = RecordingResultWindow.uiTestMake(
            url: URL(fileURLWithPath: "/tmp/KRIT-activation-result.mp4"),
            duration: 1,
            actions: StubRecordingResultActions()
        )

        XCTAssertEqual(window.styleMask, [.borderless])
        XCTAssertTrue(NSApp.isActivationPersistentWindow(window))

        window.close()

        XCTAssertFalse(NSApp.isActivationPersistentWindow(window))
    }

    func testBorderlessRecordingPreflightKeepsAccessoryPolicyWhenPreferencesCloses() throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let originalMicrophone = Settings.recordingMicrophone
        let originalCamera = Settings.recordingWebcam
        Settings.recordingMicrophone = false
        Settings.recordingWebcam = false
        let engine = CaptureEngine()
        let preferences = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 240, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            preferences.orderOut(nil)
            engine.uiTestCloseRecordingPreflight()
            Settings.recordingMicrophone = originalMicrophone
            Settings.recordingWebcam = originalCamera
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("Requires an active macOS display.")
        }
        let preflight = try XCTUnwrap(
            engine.uiTestShowRecordingPreflight(
                rect: CGRect(x: 40, y: 40, width: 640, height: 360),
                on: screen
            )
        )

        XCTAssertEqual(preflight.styleMask, [.borderless])
        XCTAssertTrue(NSApp.isActivationPersistentWindow(preflight))

        _ = NSApp.setActivationPolicy(.accessory)
        preferences.orderFrontRegardless()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: preferences)

        XCTAssertEqual(NSApp.activationPolicy(), .accessory)

        preflight.close()

        XCTAssertFalse(NSApp.isActivationPersistentWindow(preflight))
    }

    func testRecordingThumbnailProviderReturnsFallbackForUnreadableAsset() async {
        let image = await RecordingThumbnailProvider.thumbnail(
            for: URL(fileURLWithPath: "/tmp/krit-does-not-exist-\(UUID().uuidString).mp4")
        )

        XCTAssertFalse(image.isValid == false && image.size == .zero)
    }

    func testMicrophoneLevelDeliveryGateCapsUpdatesAtThirtyHertz() {
        var gate = MicrophoneLevelDeliveryGate(maximumUpdatesPerSecond: 30)

        XCTAssertTrue(gate.shouldDeliver(at: 0))
        XCTAssertFalse(gate.shouldDeliver(at: 0.02))
        XCTAssertTrue(gate.shouldDeliver(at: 1.0 / 30.0))
        XCTAssertFalse(gate.shouldDeliver(at: 0.05))
        XCTAssertTrue(gate.shouldDeliver(at: 2.0 / 30.0))
    }

    func testMicrophoneMonitorEpochRejectsStoppedAndSupersededCallbacks() {
        var epoch = MicrophoneMonitorEpoch()
        let first = epoch.begin()

        XCTAssertTrue(epoch.accepts(first))

        epoch.invalidate()
        XCTAssertFalse(epoch.accepts(first))

        let second = epoch.begin()
        XCTAssertTrue(epoch.accepts(second))
        XCTAssertFalse(epoch.accepts(first))
    }

    func testCameraSessionEpochRejectsAStartInvalidatedBeforeTheSessionQueueRuns() {
        let epoch = CameraSessionEpoch()
        let first = epoch.begin()

        XCTAssertTrue(epoch.accepts(first))

        epoch.invalidate()
        XCTAssertFalse(epoch.accepts(first))

        let second = epoch.begin()
        XCTAssertTrue(epoch.accepts(second))
        XCTAssertNotEqual(first, second)
    }

    private func assertContainedAndDisjoint(
        _ frames: [CGRect],
        inside shell: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for frame in frames {
            XCTAssertTrue(shell.contains(frame), "Frame \(frame) escapes shell \(shell)", file: file, line: line)
        }
        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    frames[firstIndex].intersects(frames[secondIndex]),
                    "Frames overlap: \(frames[firstIndex]) and \(frames[secondIndex])",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertFourPointGrid(
        _ frames: [CGRect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for frame in frames {
            for value in [frame.minX, frame.minY, frame.width, frame.height] {
                XCTAssertEqual(
                    value.truncatingRemainder(dividingBy: 4),
                    0,
                    accuracy: 0.001,
                    "\(frame) is off the 4 point grid",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allSubviews(of:))
    }

    private func backgroundAlpha(of view: NSView) -> CGFloat {
        view.layer?.backgroundColor?.alpha ?? 0
    }
}

@MainActor
private final class StubRecordingResultActions: RecordingResultActions {
    func exportGIF(from url: URL) {}
    func trim(url: URL, range: CMTimeRange, convert: VideoTrimPanel.ConvertOptions?) {}
    func exportAutoZoom(from url: URL) {}
    func openVideoEditor(url: URL, duration: Double) {}
}
