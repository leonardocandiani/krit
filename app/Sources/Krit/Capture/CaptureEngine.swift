import AppKit
import ApplicationServices
import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore
import ScreenCaptureKit
import AudioToolbox
import os
import os.log

/// Central coordinator for all capture modes.
@MainActor
final class CaptureEngine {

    static let captureLog = Logger(subsystem: "com.krit.app", category: "capture")

    /// Hard ceiling on a captured buffer's edge in pixels. ScreenCaptureKit
    /// rejects configurations past the GPU texture limit; clamp the supersampled
    /// width/height here so Maximum on a huge display degrades instead of failing.
    static let maxCaptureEdge = 16384

    /// Set when the SCK path fails because Screen Recording consent is missing,
    /// so callers can surface the permission alert instead of failing silently.
    private(set) var lastCaptureFailureWasPermission = false

    // Remembers the last selected area for "Capture Previous Area"
    private(set) var lastCaptureRect: CGRect?

    /// One-shot completion for the NEXT interactive capture to finish. Fired in
    /// finishCapture with the PRESENTED image (the composed one for window/template
    /// default shots), then cleared so it never leaks into a later capture. Cleared
    /// without firing when that capture is cancelled or fails. The `krit://` router
    /// uses this to run `then=` chains on the interactive flows it can't grab
    /// headlessly. Setting it again while one is pending replaces it.
    var onNextCaptureFinished: ((NSImage, HistoryItem?) -> Void)?

    /// Hands the pending image to the one-shot completion and clears it.
    private func fireOnNextCaptureFinished(image: NSImage, item: HistoryItem?) {
        guard let handler = onNextCaptureFinished else { return }
        onNextCaptureFinished = nil
        handler(image, item)
    }

    /// Clears a pending one-shot completion without firing it (cancel/failure).
    private func clearOnNextCaptureFinished() {
        onNextCaptureFinished = nil
    }

    /// App to refocus + paste into once the next interactive capture finishes
    /// (Snap & Paste). Captured before the selection overlay steals focus.
    private var snapAndPasteTarget: NSRunningApplication?

    private var areaSelectionWindow: AreaSelectionWindow?
    // Guards back-to-back fullscreen/previous triggers from stacking countdowns
    // (those paths have no area-selection re-entry guard).
    private var countdownActive = false
    private var scrollingCapture: ScrollingCaptureController?
    private var allInOneController: AllInOneController?
    private var recordingControlsWindow: RecordingControlsWindow?
    private var recordingScreenChooserWindow: RecordingScreenChooserWindow?
    private var recordingWindowChooserWindow: RecordingWindowChooserWindow?
    private let recordingEngine = RecordingEngine()

    var recordingActive: Bool { recordingEngine.active }
    var recordingActionsEnabled: Bool { !recordingEngine.active && !recordingSetupActive }

    private var recordingSetupActive: Bool {
        areaSelectionWindow != nil || allInOneController != nil || recordingControlsWindow != nil || recordingScreenChooserWindow != nil || recordingWindowChooserWindow != nil
    }

    private func hideDesktopIconsForCaptureIfNeeded() async -> Bool {
        guard Settings.hideDesktopIconsWhileCapturing else { return false }
        let hiddenByCapture = DesktopIconsManager.hideForCapture()
        if hiddenByCapture {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return hiddenByCapture
    }

    private func restoreDesktopIconsIfNeeded(_ hiddenByCapture: Bool) {
        DesktopIconsManager.showAfterCapture(ifHiddenByCapture: hiddenByCapture)
    }

    // Cached SCShareableContent. `SCShareableContent.excludingDesktopWindows`
    // enumerates every on-screen window and routinely costs 30-100 ms. For
    // area/fullscreen/previous capture modes we only need the display list, and
    // the display list only changes when the user plugs/unplugs a monitor or
    // changes resolution, NSApplication.didChangeScreenParametersNotification
    // is the perfect invalidator.
    @available(macOS 14.0, *)
    private static var cachedContent: SCShareableContent?
    private static var cachedContentIncludesWindows = false
    private static var observerInstalled = false

    init() {
        installScreenChangeObserverIfNeeded()
    }

    private func installScreenChangeObserverIfNeeded() {
        guard !Self.observerInstalled else { return }
        Self.observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if #available(macOS 14.0, *) {
                    Self.cachedContent = nil
                    Self.cachedContentIncludesWindows = false
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func shareableContent(includeWindows: Bool) async throws -> SCShareableContent {
        // Only reuse the cache if it covers what the caller needs. A cache
        // populated for "displays only" can't serve window-capture mode.
        if let cached = cachedContent, cachedContentIncludesWindows || !includeWindows {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: includeWindows
        )
        cachedContent = content
        cachedContentIncludesWindows = includeWindows
        return content
    }

    // MARK: - Area Capture

    func startAreaCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return } // already selecting
        // Snapshot the source app BEFORE the overlay activates KRIT and steals focus,
        // so the history thumbnail can badge where the shot came from.
        historyManager.prepareForCapture()
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.clearOnNextCaptureFinished()
                self.snapAndPasteTarget = nil
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            self.lastCaptureRect = rect
            Task {
                await self.captureRect(rect, on: screen, historyManager: historyManager)
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: - All-in-One

    /// CleanShot-style All-in-One: shows the persisted selection (or a centered
    /// default the first time) with handles and a floating options panel. Each
    /// option routes to the real capture/record/tool path. The adjusted rect is
    /// saved as the new static selection on Capture, Record, and OCR.
    func startAllInOne(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        // Reuse the area-selection re-entry guard plus our own controller guard so
        // All-in-One can't stack over an in-flight selection or another All-in-One.
        guard areaSelectionWindow == nil, allInOneController == nil else { return }

        // Target the display under the cursor (matches fullscreen capture).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let initialRect = restoredAllInOneRect(on: screen)

        let controller = AllInOneController(
            screen: screen,
            initialRect: initialRect,
            onAction: { [weak self] action, rect, screen in
                guard let self else { return }
                self.allInOneController = nil
                self.handleAllInOne(action: action, rect: rect, on: screen, historyManager: historyManager)
            },
            onCancel: { [weak self] in
                self?.allInOneController = nil
            }
        )
        allInOneController = controller
        await controller.prepareAndShow(engine: self)
    }

    /// The starting rect for All-in-One in AppKit global coordinates: the saved
    /// rect if it still fits a current screen, otherwise a centered 60% box on
    /// `screen` (the first-run default).
    private func restoredAllInOneRect(on screen: NSScreen) -> CGRect {
        if let saved = Settings.allInOneRect,
           NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
            return saved
        }
        let f = screen.frame
        let w = f.width * 0.6
        let h = f.height * 0.6
        return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
    }

    private func handleAllInOne(action: AllInOneAction, rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) {
        switch action {
        case .capture:
            Settings.allInOneRect = rect
            lastCaptureRect = rect
            Task { await captureRect(rect, on: screen, historyManager: historyManager) }
        case .record:
            Settings.allInOneRect = rect
            lastCaptureRect = rect
            guard recordingActionsEnabled else {
                ToastWindow.show(message: "Finish or stop the current recording first")
                return
            }
            // Route through the preflight controls so the user picks mic/system
            // audio/camera before recording, same as the dedicated area path.
            showRecordingControls(rect: rect, on: screen, target: .area)
        case .ocr:
            Settings.allInOneRect = rect
            Task { await runOCR(on: rect, screen: screen) }
        case .window:
            Task { await startWindowCapture(historyManager: historyManager) }
        case .fullscreen:
            Task { await captureFullscreen(historyManager: historyManager) }
        case .scrolling:
            Task { await startScrollingCapture(historyManager: historyManager) }
        }
    }

    // MARK: - Window Capture

    func startWindowCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        historyManager.prepareForCapture()
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .window) { [weak self] rect, screen, windowID in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.clearOnNextCaptureFinished()
                self.snapAndPasteTarget = nil
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                // Prefer the isolated-window grab (clean alpha corners, immune to
                // overlapping windows); fall back to the rect crop on older macOS.
                if #available(macOS 14.0, *), let windowID {
                    await self.captureWindowIsolated(windowID: windowID, rect: rect, on: screen, historyManager: historyManager)
                } else {
                    await self.captureRect(rect, on: screen, historyManager: historyManager, isWindowCapture: true)
                }
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: - Fullscreen

    func captureFullscreen(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        historyManager.prepareForCapture()
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        // Capture the display under the cursor so the global hotkey targets the
        // screen the user is looking at on a multi-monitor setup (NSScreen.main is
        // the menu-bar/key-window screen, not necessarily where the cursor is).
        let mouse = NSEvent.mouseLocation
        let screen = screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? screens[0]
        let rect = screen.frame
        await captureRect(rect, on: screen, historyManager: historyManager)
    }

    // MARK: - Screen Recording

    func startAreaRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }

        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.lastCaptureRect = rect
            self.showRecordingControls(rect: rect, on: screen, target: .area)
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    func startWindowRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let choices = await recordingWindowChoices(from: content.windows)
            guard !choices.isEmpty else {
                ToastWindow.show(message: "No recordable windows found")
                return
            }

            let chooser = RecordingWindowChooserWindow(
                choices: choices,
                selectHandler: { [weak self] choice in
                    guard let self else { return }
                    self.recordingWindowChooserWindow = nil
                    self.showRecordingControls(
                        rect: choice.previewRect,
                        on: choice.screen,
                        target: .window,
                        selectedWindow: choice.window
                    )
                },
                closeHandler: { [weak self] in
                    self?.recordingWindowChooserWindow = nil
                }
            )
            recordingWindowChooserWindow = chooser
            chooser.show()
        } catch {
            ToastWindow.show(message: "Could not list windows. Check permissions.")
            print("[KRIT] Window picker failed: \(error)")
        }
    }

    func startFullscreenRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard canBeginRecordingSetup() else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        guard screens.count > 1 else {
            let screen = screens[0]
            showRecordingControls(rect: screen.frame, on: screen, target: .fullscreen)
            return
        }

        recordingScreenChooserWindow?.closeChooser()
        let chooser = RecordingScreenChooserWindow(
            screens: screens,
            selectHandler: { [weak self] screen in
                self?.recordingScreenChooserWindow = nil
                self?.showRecordingControls(rect: screen.frame, on: screen, target: .fullscreen)
            },
            closeHandler: { [weak self] in
                self?.recordingScreenChooserWindow = nil
            }
        )
        recordingScreenChooserWindow = chooser
        chooser.show()
    }

    private func canBeginRecordingSetup() -> Bool {
        guard !recordingEngine.active else {
            ToastWindow.show(message: "Recording already in progress")
            return false
        }
        guard !recordingSetupActive else {
            ToastWindow.show(message: "Finish or cancel the current recording setup")
            return false
        }
        return true
    }

    private func recordingWindowChoices(from windows: [SCWindow]) async -> [RecordingWindowChoice] {
        let currentProcessID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let candidates: [(window: SCWindow, appName: String, title: String, frame: CGRect, screen: NSScreen, previewRect: CGRect, appIcon: NSImage?)] = windows.compactMap { window in
            guard Self.isRecordableWindowCandidate(window) else { return nil }
            if window.owningApplication?.processID == currentProcessID { return nil }

            let appName = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? "App"
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || appName != "App" else { return nil }

            let screen = screen(containing: window.frame) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return nil }
            let previewRect = CGRect(
                x: screen.frame.midX - window.frame.width / 2,
                y: min(screen.visibleFrame.maxY - window.frame.height - 24, screen.visibleFrame.midY),
                width: window.frame.width,
                height: window.frame.height
            )
            let appIcon = window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
            return (window, appName, title, window.frame, screen, previewRect, appIcon)
        }
        .sorted {
            let lhs = "\($0.appName) \($0.title)".localizedLowercase
            let rhs = "\($1.appName) \($1.title)".localizedLowercase
            return lhs < rhs
        }

        var choices: [RecordingWindowChoice] = []
        choices.reserveCapacity(candidates.count)
        for candidate in candidates {
            let previewImage = await windowPreviewImage(for: candidate.window)
            choices.append(
                RecordingWindowChoice(
                    window: candidate.window,
                    appName: candidate.appName,
                    title: candidate.title,
                    frame: candidate.frame,
                    screen: candidate.screen,
                    previewRect: candidate.previewRect,
                    previewImage: previewImage,
                    appIcon: candidate.appIcon
                )
            )
        }
        return choices
    }

    private func windowPreviewImage(for window: SCWindow) async -> NSImage? {
        if #available(macOS 14.0, *), let image = await screenCaptureKitWindowPreview(for: window) {
            return image
        }
        return fallbackWindowPreview(for: window)
    }

    @available(macOS 14.0, *)
    private func screenCaptureKitWindowPreview(for window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pixelSize = Self.previewPixelSize(for: window.frame.size)
        let config = SCStreamConfiguration()
        config.width = pixelSize.width
        config.height = pixelSize.height
        config.scalesToFit = true
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Self.nsImage(from: cgImage, logicalSize: Self.previewLogicalSize(pixelSize: pixelSize))
        } catch {
            return nil
        }
    }

    private func fallbackWindowPreview(for window: SCWindow) -> NSImage? {
        let options: CGWindowImageOption = [.bestResolution, .boundsIgnoreFraming]
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowID), options) else { return nil }
        return Self.nsImage(from: cgImage, logicalSize: window.frame.size)
    }

    nonisolated private static func previewPixelSize(for size: CGSize) -> (width: Int, height: Int) {
        let maxWidth: CGFloat = 420
        let maxHeight: CGFloat = 260
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return (
            width: max(2, evenCeil(Int(ceil(width * scale * 2)))),
            height: max(2, evenCeil(Int(ceil(height * scale * 2))))
        )
    }

    nonisolated private static func previewLogicalSize(pixelSize: (width: Int, height: Int)) -> CGSize {
        CGSize(width: CGFloat(pixelSize.width) / 2, height: CGFloat(pixelSize.height) / 2)
    }

    nonisolated private static func evenCeil(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    nonisolated private static func isRecordableWindowCandidate(_ window: SCWindow) -> Bool {
        guard window.frame.width >= 160, window.frame.height >= 120 else { return false }
        let aspectRatio = window.frame.width / max(window.frame.height, 1)
        guard aspectRatio <= 10 else { return false }

        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let searchText = "\(appName) \(title)".localizedLowercase
        let blockedFragments = ["backstop", "underbelly"]
        return !blockedFragments.contains { searchText.contains($0) }
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(rect).width * lhs.frame.intersection(rect).height < rhs.frame.intersection(rect).width * rhs.frame.intersection(rect).height
        }
    }

    private func showRecordingControls(rect: CGRect, on screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow? = nil) {
        recordingControlsWindow?.closeControls()
        let window = RecordingControlsWindow(
            rect: rect,
            screen: screen,
            target: target,
            selectedWindow: selectedWindow,
            startHandler: { [weak self] rect, screen, selectedWindow in
                Task {
                    if let selectedWindow {
                        await self?.recordingEngine.startRecording(window: selectedWindow, on: screen)
                    } else {
                        await self?.recordingEngine.startRecording(rect: rect, on: screen)
                    }
                }
            },
            closeHandler: { [weak self] in
                self?.recordingControlsWindow = nil
            }
        )
        recordingControlsWindow = window
        window.show()
    }

    /// GUI test hook: starts a rect recording through the production engine,
    /// skipping the preflight panel (the harness has no one to click Record).
    func uiTestStartRecording(rect: CGRect, on screen: NSScreen) async {
        await recordingEngine.startRecording(rect: rect, on: screen)
    }

    /// GUI test hook: live dim panel count while a recording runs.
    var uiTestDimPanelCount: Int { recordingEngine.uiTestDimPanelCount }

    /// GUI test hook: outcome of the last recording finish (saved/failed + reason).
    var uiTestRecordingOutcome: String { recordingEngine.uiTestLastFinishOutcome }

    /// GUI test hook: raw domain/code of the last SCStream stop error.
    var uiTestStreamError: String { recordingEngine.uiTestLastStreamError }

    /// GUI test hook: shows the recording preflight panel for a fake area so the
    /// harness can snapshot the glass chrome without starting a recording.
    func uiTestShowRecordingPreflight(rect: CGRect, on screen: NSScreen) -> NSWindow? {
        showRecordingControls(rect: rect, on: screen, target: .area)
        return recordingControlsWindow
    }

    /// GUI test hook: closes the preflight panel opened by the harness.
    func uiTestCloseRecordingPreflight() {
        recordingControlsWindow?.closeControls()
        recordingControlsWindow = nil
    }

    func stopRecording() {
        guard recordingEngine.active else {
            ToastWindow.show(message: "No recording in progress")
            return
        }
        recordingEngine.stopRecording()
    }

    var hasLastRecording: Bool { recordingEngine.hasLastRecording }

    func reopenLastRecording() {
        recordingEngine.reopenLastResult()
    }

    // MARK: - Previous Area

    func capturePreviousArea(historyManager: HistoryManager) async {
        guard let rect = lastCaptureRect else {
            await startAreaCapture(historyManager: historyManager)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
            await startAreaCapture(historyManager: historyManager); return
        }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        defer { restoreDesktopIconsIfNeeded(hiddenByCapture) }
        await captureRect(rect, on: screen, historyManager: historyManager)
    }

    // MARK: - Snap and Paste

    /// One-key area capture that lands straight back in the app you were in:
    /// memorizes the frontmost app, runs the normal area selection + capture (so
    /// the presented image is the composed one when a default template applies),
    /// copies it, reactivates that app, and synthesizes Cmd+V. Without
    /// Accessibility access the synthetic keystroke is silently dropped by macOS,
    /// so we copy normally and nudge the user to grant it instead of failing
    /// loudly.
    func startSnapAndPaste(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }

        // Grab the target BEFORE the overlay activates KRIT and steals focus.
        snapAndPasteTarget = NSWorkspace.shared.frontmostApplication

        onNextCaptureFinished = { [weak self] image, _ in
            self?.completeSnapAndPaste(image: image)
        }
        await startAreaCapture(historyManager: historyManager)
    }

    private func completeSnapAndPaste(image: NSImage) {
        ImageExporter.copyToClipboard(image: image)

        guard AXIsProcessTrusted() else {
            // Copy still works; tell the user how to unlock the auto-paste half.
            ToastWindow.show(message: "Grant Accessibility access to auto-paste (System Settings > Privacy & Security > Accessibility)")
            if !Settings.didPromptAccessibilityForPaste {
                Settings.didPromptAccessibilityForPaste = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            snapAndPasteTarget = nil
            return
        }

        let target = snapAndPasteTarget
        snapAndPasteTarget = nil
        target?.activate()

        // Give the reactivated app a beat to take key focus before the paste,
        // otherwise the synthetic Cmd+V can land while KRIT is still frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.synthesizePaste()
        }
    }

    /// Posts a synthetic Cmd+V (key down + up) on the HID event tap. Requires the
    /// app to be Accessibility-trusted; the caller checks AXIsProcessTrusted first.
    private static func synthesizePaste() {
        let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Snap Presets

    /// Fires a saved preset headlessly: validates its global top-left rect against
    /// the current screens, grabs it (presenting through the default template like
    /// any shot), and runs the preset's action chain. No selection overlay; the
    /// only visible feedback is the capture flash. Returns silently with a toast
    /// if the rect no longer fits a screen (monitor unplugged / resolution
    /// changed) so a stale preset never grabs the wrong area.
    func runPreset(_ preset: SnapPreset, historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard let (appKitRect, screen) = appKitRectForPreset(preset.rect) else {
            ToastWindow.show(message: "Preset region is off-screen. Edit it in Settings > Presets.")
            return
        }

        guard let image = await captureRectToImage(appKitRect, on: screen) else {
            if lastCaptureFailureWasPermission {
                PermissionsManager.showPermissionDeniedAlert()
            } else {
                ToastWindow.show(message: "Capture failed. Try again or check Screen Recording permission")
            }
            return
        }

        // Present through the default template so a preset matches what a normal
        // shot of the same region would look like (clipboard/save included).
        var presented = image
        if let options = TemplateStore.defaultBackgroundOptions(for: screen) {
            presented = ScreenshotBackgroundComposer.composeIfNeeded(image, options: options)
        }

        playCaptureSound()
        // Flash only (no overlay card): a preset is a deliberate, scripted shot;
        // the action chain is the feedback. Skipped entirely when the chain edits,
        // since the editor window is the feedback in that case.
        if !preset.actions.contains(.edit) {
            CaptureFlash.play(rect: appKitRect, on: screen, image: nil, landLeft: Settings.overlayOnLeft)
        }

        CaptureActionChain.apply(preset.actions, to: presented, format: preset.format)
    }

    /// Converts a preset's global TOP-LEFT rect to an AppKit (bottom-left) rect on
    /// the screen that contains it, or nil if no current screen fully contains it.
    private func appKitRectForPreset(_ topLeft: CGRect) -> (CGRect, NSScreen)? {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first)?.frame.height ?? topLeft.maxY
        let appKit = CGRect(
            x: topLeft.origin.x,
            y: primaryHeight - topLeft.origin.y - topLeft.height,
            width: topLeft.width,
            height: topLeft.height
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKit) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(appKit) }) else { return nil }
        return (appKit, screen)
    }

    /// Opens the interactive area selection purely to DEFINE a rect (no capture).
    /// Used by "New preset from selection" in Preferences: the completion gets the
    /// selected region as a global TOP-LEFT rect ready to persist, or nil if the
    /// user cancelled. Mirrors the AreaSelectionWindow lifecycle of startAreaCapture.
    func selectRectForPreset(completion: @escaping (CGRect?) -> Void) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert()
            completion(nil)
            return
        }
        guard areaSelectionWindow == nil else { completion(nil); return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, _, _ in
            guard let self else { completion(nil); return }
            self.areaSelectionWindow = nil
            guard let rect else { completion(nil); return }
            completion(self.topLeftRect(fromAppKit: rect))
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    /// AppKit (bottom-left, primary-anchored) rect to global TOP-LEFT points.
    private func topLeftRect(fromAppKit appKit: CGRect) -> CGRect {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first)?.frame.height ?? appKit.maxY
        return CGRect(
            x: appKit.origin.x,
            y: primaryHeight - appKit.origin.y - appKit.height,
            width: appKit.width,
            height: appKit.height
        )
    }

    // MARK: - Scrolling Capture

    func startScrollingCapture(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard scrollingCapture?.isActive != true else { return }
        scrollingCapture = ScrollingCaptureController()
        await scrollingCapture?.start(historyManager: historyManager, hiddenDesktopIconsByCapture: await hideDesktopIconsForCaptureIfNeeded())
    }

    // MARK: - OCR Capture

    func startOCRCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                await self.runOCR(on: rect, screen: screen)
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    /// Grabs `rect`, recognizes its text, and copies it to the clipboard. Shared
    /// by the area OCR path and the All-in-One OCR option, which already has a rect.
    func runOCR(on rect: CGRect, screen: NSScreen) async {
        guard let image = await captureRectToImage(rect, on: screen) else { return }
        let text = await OCREngine.recognizeText(in: image)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showOCRNotification(text: text)
    }

    // MARK: - QR Capture

    func startQRCodeCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard areaSelectionWindow == nil else { return }
        let hiddenByCapture = await hideDesktopIconsForCaptureIfNeeded()
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                return
            }
            Task {
                guard let image = await self.captureRectToImage(rect, on: screen) else {
                    self.restoreDesktopIconsIfNeeded(hiddenByCapture)
                    return
                }
                let results = await QRCodeEngine.detect(in: image)
                await MainActor.run {
                    if results.isEmpty {
                        ToastWindow.show(message: "No QR code found in this selection")
                    } else {
                        QRCodeResultWindow.show(results: results)
                    }
                }
                self.restoreDesktopIconsIfNeeded(hiddenByCapture)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self)
    }

    // MARK: - Core capture

    func captureRect(_ rect: CGRect, on screen: NSScreen, historyManager: HistoryManager, isWindowCapture: Bool = false) async {
        // D1 self-timer: count down on the captured display before grabbing.
        // Gating here covers all four screenshot modes (area/window/fullscreen/
        // previous) and leaves OCR/QR/automation untouched, they call
        // captureRectToImage directly. Esc aborts before any side effect fires.
        let countdown = Settings.captureCountdownSeconds
        if countdown > 0 {
            guard !countdownActive else { return }   // ignore a new trigger while one is live
            let proceed = await runCountdown(countdown, on: screen)
            guard proceed else { return }            // Esc cancels the whole capture
        }
        guard let image = await captureRectToImage(rect, on: screen) else {
            clearOnNextCaptureFinished()
            snapAndPasteTarget = nil
            if lastCaptureFailureWasPermission {
                PermissionsManager.showPermissionDeniedAlert()
            } else {
                ToastWindow.show(message: "Capture failed. Try again or check Screen Recording permission")
            }
            return
        }
        finishCapture(image: image, rect: rect, on: screen, historyManager: historyManager, isWindowCapture: isWindowCapture)
    }

    /// Shared post-capture finishing: sound, haptic, history, auto-actions, and
    /// the flash/overlay handoff. Both the rect crop (captureRect) and the
    /// isolated-window grab (captureWindowIsolated) funnel through here so the
    /// "capture moment" is identical regardless of how the image was produced.
    private func finishCapture(image: NSImage, rect: CGRect, on screen: NSScreen, historyManager: HistoryManager, isWindowCapture: Bool) {
        playCaptureSound()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        var presented = image
        // Diagnostic trail for the supersampled window-shot reports: one line per
        // capture with the exact point/pixel geometry each stage saw, so a bad
        // presented PNG can be traced to its stage from `log show` after the fact.
        let rawCG = image.bestCGImage
        Self.captureLog.info("finishCapture: window=\(isWindowCapture) pointSize=\(String(describing: image.size)) pixels=\(rawCG?.width ?? -1)x\(rawCG?.height ?? -1) rect=\(String(describing: rect)) screen=\(screen.localizedName, privacy: .public) scaleSetting=\(Settings.captureScale.rawValue, privacy: .public)")
        if isWindowCapture {
            let options = AnnotationWindowController.windowShotBackground(for: image, captureRect: rect)
            if options.isEnabled {
                presented = ScreenshotBackgroundComposer.composeIfNeeded(image, options: options)
                let pCG = presented.bestCGImage
                Self.captureLog.info("finishCapture: composed pointSize=\(String(describing: presented.size)) pixels=\(pCG?.width ?? -1)x\(pCG?.height ?? -1) style=\(String(describing: options.style), privacy: .public)")
            }
        } else if let options = TemplateStore.defaultBackgroundOptions(for: screen) {
            // Common shot with a default template: the overlay card, clipboard and
            // autosave all show the finished image composed onto the default
            // background, matching what the editor opens with.
            presented = ScreenshotBackgroundComposer.composeIfNeeded(image, options: options)
        }

        // History keeps the RAW shot in imagePath so the editor always re-edits
        // from the original; the THUMBNAIL comes from the presented image so the
        // history band shows the finished result the user actually saw.
        let item = historyManager.add(image: image, rect: rect, isWindowCapture: isWindowCapture,
                                      presentedImage: presented)

        // One-shot completion (krit:// then= on interactive flows, Snap & Paste).
        // Fires with the PRESENTED image and clears itself so it can't bleed into
        // a later capture.
        fireOnNextCaptureFinished(image: presented, item: item)

        // After-capture auto-actions (from Preferences)
        if Settings.afterCaptureCopyToClipboard {
            ImageExporter.copyToClipboard(image: presented)
        }
        if Settings.afterCaptureSaveAutomatically {
            let dir = Settings.autoSaveLocation
            let name = ImageExporter.timestampedName
            let ext = Settings.screenshotFormat
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
            ImageExporter.save(image: presented, to: url)
        }

        // The capture "moment", as ONE continuous motion: the card is born
        // invisible at its real slot, the flash ghost flies INTO that exact slot,
        // and the card fades in under the ghost's fade-out. (The old order, ghost
        // flying to a hardcoded 240×150 corner guess on top of an already-sliding
        // card, was the post-capture grow/shrink flicker.)
        if Settings.afterCaptureShowOverlay {
            let slot = QuickAccessOverlay.show(
                image: presented, historyItem: item, historyManager: historyManager,
                screen: screen, entrance: .handoff
            )
            let flyTime = CaptureFlash.play(rect: rect, on: screen, image: presented,
                                            landLeft: Settings.overlayOnLeft, target: slot)
            QuickAccessOverlay.revealPendingHandoff(after: max(flyTime - 0.15, 0))
        } else {
            CaptureFlash.play(rect: rect, on: screen, image: nil, landLeft: Settings.overlayOnLeft)
        }
    }

    /// Captures a single window in ISOLATION via ScreenCaptureKit's
    /// desktop-independent filter, the same path CleanShot/macOS use. Unlike a
    /// screen-rect crop, this returns ONLY the target window's pixels with its
    /// real rounded corners and shadow as transparency (alpha), and is immune to
    /// anything stacked on top of it. The countdown gate and the full finishing
    /// (sound/flash/overlay/history) match the common path exactly. Falls back to
    /// the rect crop when SCK is unavailable or the window can't be resolved.
    @available(macOS 14.0, *)
    private func captureWindowIsolated(windowID: CGWindowID, rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        let countdown = Settings.captureCountdownSeconds
        if countdown > 0 {
            guard !countdownActive else { return }
            let proceed = await runCountdown(countdown, on: screen)
            guard proceed else { return }
        }

        // Refresh the live wallpaper cache for this display BEFORE finishing, so
        // windowShotBackground (read synchronously inside finishCapture) composes
        // against the desktop the user actually sees, not a guessed file. A failed
        // grab leaves the cache alone and the sync path keeps its static fallback.
        // The short settle keeps the picker/dim chrome (mid fade-out when this
        // runs) out of the display-exclude wallpaper frame; without it the grab
        // could catch leftover chrome and poison the cache (white-background
        // window shots). The grab itself also rejects uniform frames.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await SystemWallpaperSource.refreshCurrentWallpaper(for: screen)
        Self.captureLog.info("window-shot wallpaper grab: \(SystemWallpaperSource.uiTestLastWallpaperGrab, privacy: .public)")

        guard let image = await isolatedWindowImage(windowID: windowID) else {
            // SCK couldn't resolve/grab the window in isolation, fall back to the
            // legacy rect crop so a window capture never silently fails. The
            // countdown already ran above, so grab directly without re-gating.
            guard let cropped = await captureRectToImage(rect, on: screen) else {
                if lastCaptureFailureWasPermission {
                    PermissionsManager.showPermissionDeniedAlert()
                } else {
                    ToastWindow.show(message: "Capture failed. Try again or check Screen Recording permission")
                }
                return
            }
            finishCapture(image: cropped, rect: rect, on: screen, historyManager: historyManager, isWindowCapture: true)
            return
        }
        finishCapture(image: image, rect: rect, on: screen, historyManager: historyManager, isWindowCapture: true)
    }

    /// Grabs `windowID` in isolation as an NSImage with the window's native pixel
    /// size and transparent corners/shadow preserved (no scaling, no background).
    @available(macOS 14.0, *)
    private func isolatedWindowImage(windowID: CGWindowID) async -> NSImage? {
        lastCaptureFailureWasPermission = false
        do {
            let content = try await Self.shareableContent(includeWindows: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                Self.captureLog.error("isolatedWindowImage: window \(windowID) not in shareable content; falling back")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let mult = Settings.captureScale.multiplier
            let logicalSize = window.frame.size
            let config = SCStreamConfiguration()
            config.width = min(max(1, Int(logicalSize.width * scale * mult)), Self.maxCaptureEdge)
            config.height = min(max(1, Int(logicalSize.height * scale * mult)), Self.maxCaptureEdge)
            // Supersampled buffer: SCK must scale the window content INTO the
            // larger buffer. With scalesToFit false the content keeps its native
            // pixel size and the grab comes out cropped/anchored with the rest
            // of the buffer empty (the white-border window shots). The native 1x
            // path keeps false, exactly the long-proven configuration.
            config.scalesToFit = mult > 1
            config.showsCursor = false
            config.captureResolution = .best
            // The default opaque background would fill the rounded corners and
            // shadow region with black; a clear color keeps them transparent so
            // the editor composites the window over its generated background.
            config.backgroundColor = .clear
            // Drop the native window shadow from the grab. The buffer is sized
            // from window.frame, which does NOT include the shadow margin: with
            // the shadow kept, SCK shrinks the window to fit window+shadow into
            // the buffer and the clipped shadow halo composes as a ghost rounded
            // rect around every supersampled window shot ("invisible border").
            // The template draws its own shadow, so the native one only doubles.
            config.ignoreShadowsSingleWindow = true

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Self.nsImage(from: cgImage, logicalSize: logicalSize)
        } catch {
            let nsError = error as NSError
            Self.captureLog.error("isolatedWindowImage failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                lastCaptureFailureWasPermission = true
            }
            return nil
        }
    }

    /// Test-only: grabs `windowID` in isolation through the exact production
    /// path (isolatedWindowImage), so the harness can prove the SCK isolated
    /// grab yields real pixels with transparent rounded corners.
    @available(macOS 14.0, *)
    func uiTestIsolatedWindowImage(windowID: CGWindowID) async -> NSImage? {
        await isolatedWindowImage(windowID: windowID)
    }

    /// Test-only: runs the FULL production window-shot flow (wallpaper refresh,
    /// isolated grab, finishCapture with compose + history add + overlay), so
    /// the harness can prove the presented PNG the user actually drags out, not
    /// just the individual links.
    @available(macOS 14.0, *)
    func uiTestFullWindowCapture(windowID: CGWindowID, rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        await captureWindowIsolated(windowID: windowID, rect: rect, on: screen, historyManager: historyManager)
    }

    /// Runs the countdown with the `countdownActive` latch guaranteed to clear on
    /// every exit (return, Esc, cancellation, throw), so a countdown that's torn
    /// down mid-flight can never permanently block all future captures.
    private func runCountdown(_ seconds: Int, on screen: NSScreen) async -> Bool {
        countdownActive = true
        defer { countdownActive = false }
        return await CountdownWindow.run(seconds: seconds, on: screen)
    }

    private func playCaptureSound() {
        SoundManager.play(.capture)
    }

    /// SPM's synthesized Bundle.module only probes the .app root and the original
    /// build path in /tmp, so it fatalErrors after a reboot wipes /tmp. Resolve the
    /// resource bundle from the locations our layouts actually use instead.
    static let resourceBundle: Bundle = {
        let bundleName = "Krit_KritKit.bundle"
        let candidates = [
            Bundle.main.resourceURL,  // .app bundle: Contents/Resources/
            Bundle.main.bundleURL,    // swift build: alongside the binary
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.main
    }()

    static func warmCaptureSound() {
        SoundManager.warmUp()
    }

    func captureRectToImage(_ rect: CGRect, on screen: NSScreen) async -> NSImage? {
        if #available(macOS 14.0, *) {
            return await captureRectSCK(rect, on: screen)
        } else {
            return fallbackCapture(rect: rect)
        }
    }

    @available(macOS 14.0, *)
    private func captureRectSCK(_ rect: CGRect, on screen: NSScreen) async -> NSImage? {
        lastCaptureFailureWasPermission = false
        do {
            // captureRectSCK only needs the display list, no window enumeration.
            let content = try await Self.shareableContent(includeWindows: false)
            // Casar por displayID, nunca por frame: rect está em coordenadas
            // AppKit (y pra cima) e SCDisplay.frame em CoreGraphics (y pra
            // baixo), a interseção só coincide no monitor principal; num
            // segundo monitor casava o display errado.
            let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == screenID })
                ?? content.displays.first(where: { $0.frame.intersects(rect) }) else {
                Self.captureLog.error("captureRectSCK: no display matches screen \(String(describing: screenID)); falling back")
                return fallbackCapture(rect: rect)
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let s: CGFloat = CGFloat(filter.pointPixelScale)

            // Snap rect to integer pixel boundaries to avoid subpixel sampling.
            // Fractional sourceRect coords cause SCK to interpolate between pixels,
            // softening text and sharp edges.
            let ox = floor((rect.origin.x - screen.frame.origin.x) * s) / s
            let oy = floor((rect.origin.y - screen.frame.origin.y) * s) / s
            let w  = ceil(rect.width * s) / s
            let h  = ceil(rect.height * s) / s

            // Convert from AppKit (bottom-left origin) to ScreenCaptureKit (top-left origin)
            let screenHeight = screen.frame.height
            let sckRect = CGRect(x: ox, y: screenHeight - oy - h, width: w, height: h)

            // Supersample on top of the native scale when the user asks for more
            // density (Settings.captureScale). Clamped so an extreme display +
            // Maximum can't ask SCK for a buffer past its texture limit.
            let mult = Settings.captureScale.multiplier
            let pixelW = min(Int(w * s * mult), Self.maxCaptureEdge)
            let pixelH = min(Int(h * s * mult), Self.maxCaptureEdge)

            let config = SCStreamConfiguration()
            config.sourceRect = sckRect
            config.width = pixelW
            config.height = pixelH
            // Same supersampling rule as the window path: only a buffer larger
            // than the native sourceRect pixels needs scalesToFit.
            config.scalesToFit = mult > 1
            config.showsCursor = false
            config.captureResolution = .best
            // Don't set colorSpaceName, SCK defaults to the display's native
            // calibrated ICC profile, preserving exact on-screen colors.
            // Forcing sRGB or Display P3 overrides the display calibration.

            let logicalSize = NSSize(width: w, height: h)
            Self.captureLog.info("captureRectSCK: rect=\(String(describing: rect)) scale=\(s) sckRect=\(String(describing: sckRect)) pixels=\(pixelW)x\(pixelH)")
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let flat = Self.uniformColorDescription(cgImage) {
                // A flat frame (all-black OR all-white) usually means the
                // screenshot service handed back an empty surface, retry
                // through a one-frame SCStream before trusting it.
                Self.captureLog.error("captureRectSCK: screenshot came back uniform (\(flat)); retrying via stream")
                if let streamImage = try? await captureRectStream(filter: filter, configuration: config) {
                    let retryFlat = Self.uniformColorDescription(streamImage)
                    Self.captureLog.info("captureRectSCK: stream retry result uniform=\(retryFlat ?? "no, has content")")
                    return Self.nsImage(from: streamImage, logicalSize: logicalSize)
                }
            }

            return Self.nsImage(from: cgImage, logicalSize: logicalSize)
        } catch {
            let nsError = error as NSError
            Self.captureLog.error("captureRectSCK failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            // -3801 = user declined / missing Screen Recording TCC consent
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                lastCaptureFailureWasPermission = true
                return nil
            }
            return fallbackCapture(rect: rect)
        }
    }

    @available(macOS 14.0, *)
    private func captureRectStream(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await SingleFrameImageCapture().capture(filter: filter, configuration: configuration)
    }

    private func fallbackCapture(rect: CGRect) -> NSImage? {
        // CGWindowListCreateImage was obsoleted in macOS 15, on modern systems
        // it returns nil or a blank surface, which used to ship as an empty
        // "white screenshot". Never use it there.
        if #available(macOS 15.0, *) {
            Self.captureLog.error("fallbackCapture: legacy CGWindowListCreateImage unavailable on this macOS; capture failed")
            return nil
        }
        guard let cgImage = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, .bestResolution) else { return nil }
        return Self.nsImage(from: cgImage, logicalSize: rect.size)
    }

    /// Creates an NSImage backed by NSBitmapImageRep so the raw CGImage pixels
    /// are preserved through the entire pipeline (no CoreGraphics re-render).
    /// Safe to call from any thread, touches no actor-isolated state.
    nonisolated static func nsImage(from cgImage: CGImage, logicalSize: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize   // logical size for display; pixel data untouched
        let image = NSImage(size: logicalSize)
        image.addRepresentation(rep)
        return image
    }

    /// Returns a description like "white(252)" when the frame is one flat color
    /// (the signature of an empty surface from the capture service), nil when it
    /// has real content.
    nonisolated static func uniformColorDescription(_ cgImage: CGImage) -> String? {
        let width = min(max(cgImage.width, 1), 32)
        let height = min(max(cgImage.height, 1), 32)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minV: UInt8 = 255
        var maxV: UInt8 = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let v = max(pixels[index], pixels[index + 1], pixels[index + 2])
            let lo = min(pixels[index], pixels[index + 1], pixels[index + 2])
            if v > maxV { maxV = v }
            if lo < minV { minV = lo }
            if maxV - minV > 6 { return nil }
        }
        if maxV <= 8 { return "black(\(maxV))" }
        if minV >= 247 { return "white(\(minV))" }
        return "flat(\(minV)-\(maxV))"
    }

    // MARK: - OCR notification

    private func showOCRNotification(text: String) {
        let preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        let recognized = !preview.isEmpty
        let message = recognized ? "✓ Text copied to clipboard" : "No text recognized"
        SoundManager.play(recognized ? .ocr : .error)
        ToastWindow.show(message: message)
    }
}

@available(macOS 14.0, *)
private final class SingleFrameImageCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let sampleQueue = DispatchQueue(label: "com.krit.capture.single-frame", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?

    func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                begin(filter: filter, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            self.cancelCapture()
        }
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration, continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        lock.lock()
        self.stream = stream
        lock.unlock()

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            finish(.failure(error))
            return
        }

        Task {
            do {
                try await stream.startCapture()
            } catch {
                finish(.failure(error))
            }
        }

        sampleQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish(.failure(SingleFrameImageCaptureError.timeout))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let cgImage = Self.ciContext.createCGImage(image, from: extent) else {
            return
        }
        finish(.success(cgImage))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        Task {
            if let stream {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .screen)
            }
            switch result {
            case .success(let image):
                continuation.resume(returning: image)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func cancelCapture() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        Task {
            if let stream {
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(self, type: .screen)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] else {
            return false
        }
        if let status = rawStatus as? SCFrameStatus { return status == .complete }
        if let raw = rawStatus as? Int { return SCFrameStatus(rawValue: raw) == .complete }
        if let raw = rawStatus as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) == .complete }
        return false
    }
}

private enum SingleFrameImageCaptureError: Error {
    case timeout
}

@MainActor
private struct RecordingWindowChoice {
    let window: SCWindow
    let appName: String
    let title: String
    let frame: CGRect
    let screen: NSScreen
    let previewRect: CGRect
    let previewImage: NSImage?
    let appIcon: NSImage?

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var subtitle: String {
        "\(appName) · \(Int(frame.width)) × \(Int(frame.height))"
    }
}

@MainActor
private enum RecordingTargetKind {
    case area
    case window
    case fullscreen

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Display"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        }
    }
}

@MainActor
private final class RecordingWindowChooserWindow: NSWindow {

    private static var openWindows: [RecordingWindowChooserWindow] = []
    private static let panelWidth: CGFloat = 724
    private static let panelHeight: CGFloat = 560
    private static let headerHeight: CGFloat = 84

    private let choices: [RecordingWindowChoice]
    private let selectHandler: (RecordingWindowChoice) -> Void
    private let closeHandler: () -> Void
    private var keyMonitor: Any?
    private var didClose = false

    init(choices: [RecordingWindowChoice], selectHandler: @escaping (RecordingWindowChoice) -> Void, closeHandler: @escaping () -> Void) {
        self.choices = choices
        self.selectHandler = selectHandler
        self.closeHandler = closeHandler
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionChooser()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildContent() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.58
        root.layer?.shadowRadius = 28
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        // Liquid Glass backing through the app-wide gate (real glass on 26+,
        // HUD blur before), replacing the old opaque near-black slab that could
        // not adapt to light mode and ignored the chrome language the rest of
        // the app speaks.
        let glass = ChromeFactory.backing(frame: root.bounds, cornerRadius: ChromeFactory.Radius.dock)
        root.addSubview(glass)

        let panel = NSView(frame: root.bounds)
        root.addSubview(panel)

        let title = label("Choose window", size: 16, weight: .bold, color: .labelColor)
        title.frame = NSRect(x: 24, y: frame.height - 42, width: 220, height: 20)
        panel.addSubview(title)

        let subtitle = label("Select a window to record without blocking other apps", size: 10.5, weight: .semibold, color: .secondaryLabelColor)
        subtitle.frame = NSRect(x: 24, y: frame.height - 63, width: 360, height: 14)
        panel.addSubview(subtitle)

        let closeButton = RecordingChooserCloseButton(frame: NSRect(x: frame.width - 44, y: frame.height - 44, width: 28, height: 28))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        panel.addSubview(closeButton)

        let scrollFrame = NSRect(x: 16, y: 16, width: frame.width - 48, height: frame.height - Self.headerHeight - 18)
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        panel.addSubview(scroll)

        let rowHeight: CGFloat = 150
        let documentHeight = max(scrollFrame.height, CGFloat(choices.count) * rowHeight)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: scrollFrame.width, height: documentHeight))
        scroll.documentView = document

        for (index, choice) in choices.enumerated() {
            let y = documentHeight - CGFloat(index + 1) * rowHeight
            let button = RecordingWindowChoiceButton(frame: NSRect(x: 0, y: y + 6, width: scrollFrame.width - 8, height: rowHeight - 12), choice: choice)
            button.target = self
            button.action = #selector(windowChosen(_:))
            document.addSubview(button)
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func positionChooser() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 72)
        setFrameOrigin(NSPoint(x: max(visible.minX + 24, min(origin.x, visible.maxX - frame.width - 24)), y: max(visible.minY + 24, origin.y)))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closeChooser()
                return nil
            }
            return event
        }
    }

    private func closeChooser(notify: Bool = true) {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        if notify { closeHandler() }
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    @objc private func windowChosen(_ sender: RecordingWindowChoiceButton) {
        let choice = sender.choice
        closeChooser(notify: false)
        selectHandler(choice)
    }

    @objc private func closeTapped() {
        closeChooser()
    }
}

@MainActor
private final class RecordingWindowChoiceButton: NSButton {

    let choice: RecordingWindowChoice
    private let idleBackground = KritColors.overlayTint
    private let pressedBackground = KritColors.cornerButtonBackground

    init(frame: NSRect, choice: RecordingWindowChoice) {
        self.choice = choice
        super.init(frame: frame)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.panel
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = idleBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = KritColors.overlayBorder.cgColor

        let previewFrame = NSRect(x: 12, y: 12, width: 180, height: frame.height - 24)
        let preview = RecordingWindowPreviewView(frame: previewFrame, image: choice.previewImage, appIcon: choice.appIcon)
        addSubview(preview)

        let icon = NSImageView(frame: NSRect(x: 214, y: frame.height - 44, width: 22, height: 22))
        icon.image = choice.appIcon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        let titleField = NSTextField(labelWithString: choice.displayTitle)
        titleField.font = .systemFont(ofSize: 14, weight: .bold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(x: 244, y: frame.height - 43, width: frame.width - 390, height: 18)
        addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: choice.subtitle)
        subtitleField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.frame = NSRect(x: 244, y: frame.height - 62, width: frame.width - 390, height: 13)
        addSubview(subtitleField)

        let description = NSTextField(labelWithString: "Preview the target, then continue to recording controls.")
        description.font = .systemFont(ofSize: 11, weight: .medium)
        description.textColor = .tertiaryLabelColor
        description.lineBreakMode = .byTruncatingTail
        description.frame = NSRect(x: 214, y: 48, width: frame.width - 358, height: 15)
        addSubview(description)

        let sizePill = RecordingWindowPillLabel(text: "\(Int(choice.frame.width)) × \(Int(choice.frame.height))")
        sizePill.frame = NSRect(x: 214, y: 18, width: 92, height: 24)
        addSubview(sizePill)

        let selectPill = RecordingWindowSelectPill(frame: NSRect(x: frame.width - 120, y: 52, width: 82, height: 32))
        addSubview(selectPill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedBackground.cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = idleBackground.cgColor
    }
}

@MainActor
private final class RecordingWindowPreviewView: NSView {

    private let image: NSImage?
    private let appIcon: NSImage?

    init(frame: NSRect, image: NSImage?, appIcon: NSImage?) {
        self.image = image
        self.appIcon = appIcon
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .high

        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: ChromeFactory.Radius.card, yRadius: ChromeFactory.Radius.card)
        KritColors.overlayContainerFill.setFill()
        backgroundPath.fill()

        let inner = bounds.insetBy(dx: 8, dy: 8)
        let imageRect = image.map { Self.aspectFitRect(imageSize: $0.size, in: inner) }
        if let image, let imageRect {
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            drawPlaceholder(in: inner)
        }

        if let appIcon {
            let iconRect = NSRect(x: bounds.minX + 12, y: bounds.minY + 12, width: 30, height: 30)
            NSColor.black.withAlphaComponent(0.34).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10).fill()
            appIcon.draw(in: iconRect)
        }

        KritColors.overlayBorder.setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()
    }

    private func drawPlaceholder(in rect: NSRect) {
        let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold))?.draw(
            in: NSRect(x: rect.midX - 18, y: rect.midY - 18, width: 36, height: 36),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.54
        )
    }

    private static func aspectFitRect(imageSize: CGSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

@MainActor
private final class RecordingWindowSelectPill: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        KritColors.accent.withAlphaComponent(0.16).setFill()
        path.fill()
        KritColors.accent.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = "Select" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: KritColors.accent.withAlphaComponent(0.96)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(x: bounds.midX - textSize.width / 2 - 5, y: bounds.midY - textSize.height / 2, width: textSize.width, height: textSize.height)
        text.draw(in: textRect, withAttributes: attributes)

        let chevron = NSBezierPath()
        let x = textRect.maxX + 8
        let y = bounds.midY
        chevron.move(to: NSPoint(x: x - 2, y: y + 4))
        chevron.line(to: NSPoint(x: x + 2, y: y))
        chevron.line(to: NSPoint(x: x - 2, y: y - 4))
        KritColors.accent.withAlphaComponent(0.86).setStroke()
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
}

@MainActor
private final class RecordingWindowPillLabel: NSView {

    private let textField: NSTextField

    init(text: String) {
        textField = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = KritColors.overlayTint.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = KritColors.overlayBorder.cgColor

        textField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        textField.textColor = .secondaryLabelColor
        textField.alignment = .center
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        textField.frame = bounds.insetBy(dx: 8, dy: 5)
    }
}

@MainActor
private final class RecordingScreenChooserWindow: NSWindow {

    private static var openWindows: [RecordingScreenChooserWindow] = []
    private static let panelWidth: CGFloat = 384
    private static let headerHeight: CGFloat = 80
    private static let rowStride: CGFloat = 52
    private static let rowHeight: CGFloat = 44
    private static let bottomPadding: CGFloat = 16

    private let screens: [NSScreen]
    private let selectHandler: (NSScreen) -> Void
    private let closeHandler: () -> Void
    private var keyMonitor: Any?
    private var didClose = false

    init(screens: [NSScreen], selectHandler: @escaping (NSScreen) -> Void, closeHandler: @escaping () -> Void) {
        self.screens = screens
        self.selectHandler = selectHandler
        self.closeHandler = closeHandler

        let height = Self.headerHeight + CGFloat(screens.count) * Self.rowStride + Self.bottomPadding
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height), styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionChooser()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func closeChooser() {
        closeChooser(notify: true)
    }

    private func buildContent() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.58
        root.layer?.shadowRadius = 28
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        // Same glass language as the window chooser: ChromeFactory backing
        // instead of a fixed dark slab, native label colors on top.
        let glass = ChromeFactory.backing(frame: root.bounds, cornerRadius: ChromeFactory.Radius.dock)
        root.addSubview(glass)

        let panel = NSView(frame: root.bounds)
        root.addSubview(panel)

        let title = label("Choose screen", size: 14, weight: .bold, color: .labelColor)
        title.frame = NSRect(x: 20, y: frame.height - 38, width: 220, height: 18)
        panel.addSubview(title)

        let subtitle = label("Select which display to record fullscreen", size: 10.5, weight: .semibold, color: .secondaryLabelColor)
        subtitle.frame = NSRect(x: 20, y: frame.height - 59, width: 288, height: 14)
        panel.addSubview(subtitle)

        let closeButton = RecordingChooserCloseButton(frame: NSRect(x: frame.width - 42, y: frame.height - 42, width: 28, height: 28))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        panel.addSubview(closeButton)

        for (index, screen) in screens.enumerated() {
            let y = frame.height - Self.headerHeight - Self.rowHeight - CGFloat(index) * Self.rowStride
            let button = RecordingScreenChoiceButton(
                frame: NSRect(x: 14, y: y, width: frame.width - 28, height: Self.rowHeight),
                title: screenTitle(for: screen, index: index),
                subtitle: screenSubtitle(for: screen)
            )
            button.tag = index
            button.target = self
            button.action = #selector(screenChosen(_:))
            panel.addSubview(button)
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func screenTitle(for screen: NSScreen, index: Int) -> String {
        if let main = NSScreen.main, screen === main {
            return "Display \(index + 1) · Main"
        }
        return "Display \(index + 1)"
    }

    private func screenSubtitle(for screen: NSScreen) -> String {
        "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
    }

    private func positionChooser() {
        let screen = NSScreen.main ?? screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 72)
        setFrameOrigin(pixelAligned(NSPoint(x: max(visible.minX + 24, min(origin.x, visible.maxX - frame.width - 24)), y: max(visible.minY + 24, origin.y)), scale: screen?.backingScaleFactor ?? 2))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closeChooser()
                return nil
            }
            return event
        }
    }

    private func closeChooser(notify: Bool) {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        if notify { closeHandler() }
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    @objc private func screenChosen(_ sender: NSButton) {
        guard screens.indices.contains(sender.tag) else { return }
        let screen = screens[sender.tag]
        closeChooser(notify: false)
        selectHandler(screen)
    }

    @objc private func closeTapped() {
        closeChooser()
    }
}

@MainActor
private final class RecordingScreenChoiceButton: NSButton {

    init(frame: NSRect, title: String, subtitle: String) {
        super.init(frame: frame)
        isBordered = false
        self.title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.card
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = KritColors.overlayTint.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = KritColors.overlayBorder.cgColor

        let icon = NSImageView(frame: NSRect(x: 14, y: 14, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .bold)
        titleField.textColor = .labelColor
        titleField.frame = NSRect(x: 42, y: 22, width: frame.width - 104, height: 15)
        addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: subtitle)
        subtitleField.font = .systemFont(ofSize: 10.5, weight: .semibold)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.frame = NSRect(x: 42, y: 8, width: 120, height: 13)
        addSubview(subtitleField)

        let actionField = NSTextField(labelWithString: "Record")
        actionField.font = .systemFont(ofSize: 10, weight: .bold)
        actionField.textColor = KritColors.accent.withAlphaComponent(0.92)
        actionField.alignment = .right
        actionField.frame = NSRect(x: frame.width - 78, y: 15, width: 56, height: 13)
        addSubview(actionField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = KritColors.cornerButtonBackground.cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = KritColors.overlayTint.cgColor
    }
}

@MainActor
private final class RecordingChooserCloseButton: NSButton {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = KritColors.overlayTint.cgColor
        contentTintColor = .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?.withSymbolConfiguration(config)
        toolTip = "Cancel"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class RecordingControlsWindow: NSWindow {

    private static var openWindows: [RecordingControlsWindow] = []
    private static let barHeight: CGFloat = 56
    private static let expandedHeight: CGFloat = 92
    private static let panelWidth: CGFloat = 728
    private static let chromeInset: CGFloat = 8

    private let captureRect: CGRect
    private let targetScreen: NSScreen
    private let target: RecordingTargetKind
    private let selectedWindow: SCWindow?
    private let startHandler: (CGRect, NSScreen, SCWindow?) -> Void
    private let closeHandler: () -> Void

    private var keyMonitor: Any?
    private var didClose = false

    private let systemAudioButton = RecordingToggleButton(symbol: "speaker.wave.2.fill", title: "System audio")
    private let microphoneButton = RecordingToggleButton(symbol: "mic.fill", title: "Microphone", activeTint: .systemGreen)
    private let cameraButton = RecordingToggleButton(symbol: "video.fill", title: "Camera")
    private let cursorButton = RecordingToggleButton(symbol: "cursorarrow.rays", title: "Cursor")
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneContainer = NSView()
    private let microphoneLevelMeter = RecordingAudioLevelMeter()
    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cameraContainer = NSView()
    private var microphoneMonitorSession: AVCaptureSession?
    private var microphoneMonitorOutput: AVCaptureAudioDataOutput?
    private var microphoneMonitorDelegate: MicrophoneLevelMonitor?

    init(rect: CGRect, screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow?, startHandler: @escaping (CGRect, NSScreen, SCWindow?) -> Void, closeHandler: @escaping () -> Void) {
        self.captureRect = rect
        self.targetScreen = screen
        self.target = target
        self.selectedWindow = selectedWindow
        self.startHandler = startHandler
        self.closeHandler = closeHandler

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.chromeInset * 2, height: Self.windowHeight(expanded: Self.isExpanded)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        buildContent()
        installKeyMonitor()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        Self.openWindows.append(self)
        positionPanel()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)

        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func buildContent() {
        let screenScale = targetScreen.backingScaleFactor
        let root = RecordingPanelContentView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.contentsScale = screenScale
        contentView = root

        // Device pickers live in the expanded zone under the bar. Mic on the left,
        // camera on the right; each appears only when its toggle is on.
        styleDeviceContainer(microphoneContainer, frame: NSRect(x: Self.chromeInset + 158, y: Self.chromeInset + 62, width: 270, height: 30))
        root.addSubview(microphoneContainer)

        microphonePopup.frame = NSRect(x: 12, y: 2, width: 246, height: 26)
        microphonePopup.bezelStyle = .shadowlessSquare
        microphonePopup.isBordered = false
        microphonePopup.controlSize = .small
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        microphoneContainer.addSubview(microphonePopup)

        styleDeviceContainer(cameraContainer, frame: NSRect(x: Self.chromeInset + 438, y: Self.chromeInset + 62, width: 270, height: 30))
        root.addSubview(cameraContainer)

        cameraPopup.frame = NSRect(x: 12, y: 2, width: 246, height: 26)
        cameraPopup.bezelStyle = .shadowlessSquare
        cameraPopup.isBordered = false
        cameraPopup.controlSize = .small
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraDeviceChanged)
        cameraContainer.addSubview(cameraPopup)

        // The preflight bar is the dock-scale glass surface. The glass backing
        // draws the fill and rim light (ChromeFactory adds a hairline only on the
        // pre-26 fallback); the controls live on a transparent content view that
        // sits flat above it. One glass view for the whole bar, flat controls on
        // top: glass-on-glass is never used here.
        let barFrame = NSRect(x: Self.chromeInset, y: Self.chromeInset, width: Self.panelWidth, height: Self.barHeight)
        let barGlass = ChromeFactory.backing(frame: barFrame, cornerRadius: ChromeFactory.Radius.dock)
        // The bar is anchored to the bottom inset; only the device row above it
        // grows when pickers expand, so pin the glass to the bottom rather than
        // letting it stretch with the window.
        barGlass.autoresizingMask = [.maxYMargin]
        // Shadow on a host layer behind the glass, glass owns its own rim light.
        let barShadowHost = NSView(frame: barFrame)
        barShadowHost.wantsLayer = true
        barShadowHost.autoresizingMask = [.maxYMargin]
        barShadowHost.layer?.shadowColor = NSColor.black.cgColor
        barShadowHost.layer?.shadowOpacity = 0.58
        barShadowHost.layer?.shadowRadius = 24
        barShadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)
        barShadowHost.layer?.shadowPath = CGPath(roundedRect: barGlass.bounds, cornerWidth: ChromeFactory.Radius.dock, cornerHeight: ChromeFactory.Radius.dock, transform: nil)
        root.addSubview(barShadowHost)
        root.addSubview(barGlass)

        let bar = RecordingPanelContentView(frame: barFrame)
        bar.autoresizingMask = [.maxYMargin]
        root.addSubview(bar)

        let grip = label("⋮⋮", size: 15, weight: .bold, color: NSColor.white.withAlphaComponent(0.24))
        grip.frame = NSRect(x: 10, y: 18, width: 20, height: 20)
        bar.addSubview(grip)

        let sourcePill = pillLabel("\(target.title) · \(Int(captureRect.width)) × \(Int(captureRect.height))", symbol: target.symbol)
        sourcePill.frame = NSRect(x: 32, y: 9, width: 190, height: 38)
        bar.addSubview(sourcePill)

        let audioGroup = segmentContainer(frame: NSRect(x: 234, y: 8, width: 222, height: 40))
        bar.addSubview(audioGroup)
        bar.addSubview(divider(x: 280, height: 22))
        bar.addSubview(divider(x: 326, height: 22))
        bar.addSubview(divider(x: 362, height: 22))
        bar.addSubview(divider(x: 408, height: 22))

        systemAudioButton.frame = NSRect(x: 238, y: 9, width: 40, height: 38)
        microphoneButton.frame = NSRect(x: 284, y: 9, width: 40, height: 38)
        microphoneLevelMeter.frame = NSRect(x: 332, y: 16, width: 32, height: 24)
        microphoneLevelMeter.isHidden = true
        bar.addSubview(microphoneLevelMeter)
        cursorButton.frame = NSRect(x: 366, y: 9, width: 40, height: 38)
        cameraButton.frame = NSRect(x: 412, y: 9, width: 40, height: 38)
        for button in [systemAudioButton, microphoneButton, cursorButton, cameraButton] {
            button.target = self
            button.action = #selector(toggleChanged(_:))
            bar.addSubview(button)
        }

        let settingsGroup = segmentContainer(frame: NSRect(x: 464, y: 8, width: 166, height: 40))
        bar.addSubview(settingsGroup)
        bar.addSubview(divider(x: 548, height: 22))

        configurePopup(qualityPopup, items: [("Balanced", "balanced"), ("High", "high"), ("Max", "max")])
        qualityPopup.frame = NSRect(x: 470, y: 14, width: 72, height: 28)
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)
        bar.addSubview(qualityPopup)

        configurePopup(fpsPopup, items: [("30 fps", "30"), ("60 fps", "60")])
        fpsPopup.frame = NSRect(x: 556, y: 14, width: 68, height: 28)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        bar.addSubview(fpsPopup)

        let recordButton = RecordingActionButton(symbol: "record.circle", title: "Record", isPrimary: true)
        recordButton.frame = NSRect(x: 648, y: 9, width: 38, height: 38)
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        bar.addSubview(recordButton)

        let cancelButton = RecordingActionButton(symbol: "xmark", title: "Cancel", tint: .secondaryLabelColor)
        cancelButton.frame = NSRect(x: 688, y: 9, width: 32, height: 38)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        bar.addSubview(cancelButton)

        let escHint = keyHint("esc")
        escHint.frame = NSRect(x: 692, y: 3, width: 24, height: 12)
        bar.addSubview(escHint)

        syncFromSettings()
    }

    private func syncFromSettings() {
        systemAudioButton.isOn = Settings.recordingSystemAudio
        microphoneButton.isOn = Settings.recordingMicrophone
        cameraButton.isOn = Settings.recordingWebcam
        cursorButton.isOn = Settings.recordingShowsCursor
        selectItem(in: qualityPopup, representedObject: Settings.recordingQuality)
        selectItem(in: fpsPopup, representedObject: String(Settings.recordingFPS))
        reloadMicrophones()
        reloadCameras()
        updateDeviceVisibility()
    }

    private func reloadMicrophones() {
        microphonePopup.removeAllItems()
        microphonePopup.addItem(withTitle: "System Default")
        microphonePopup.lastItem?.representedObject = ""
        for device in RecordingMicrophoneDeviceProvider.options {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.id
        }
        if !selectItem(in: microphonePopup, representedObject: Settings.recordingMicrophoneDeviceID) {
            microphonePopup.selectItem(at: 0)
            Settings.recordingMicrophoneDeviceID = ""
        }
    }

    private func reloadCameras() {
        cameraPopup.removeAllItems()
        for option in RecordingCameraDeviceProvider.options {
            cameraPopup.addItem(withTitle: option.name)
            cameraPopup.lastItem?.representedObject = option.id
        }
        if !selectItem(in: cameraPopup, representedObject: Settings.recordingWebcamDeviceID) {
            cameraPopup.selectItem(at: 0)
            Settings.recordingWebcamDeviceID = cameraPopup.itemArray.first?.representedObject as? String ?? ""
        }
    }

    private func updateDeviceVisibility() {
        microphoneContainer.isHidden = !Settings.recordingMicrophone
        microphoneLevelMeter.isHidden = !Settings.recordingMicrophone
        if Settings.recordingMicrophone {
            startMicrophoneMonitorIfNeeded()
        } else {
            stopMicrophoneMonitor()
            microphoneLevelMeter.setLevel(0)
        }
        cameraContainer.isHidden = !Settings.recordingWebcam
        resizeForDeviceState()
    }

    private func startMicrophoneMonitorIfNeeded() {
        guard microphoneMonitorSession == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureMicrophoneMonitor()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted, Settings.recordingMicrophone {
                        self.configureMicrophoneMonitor()
                    } else {
                        Settings.recordingMicrophone = false
                        self.microphoneButton.isOn = false
                        self.updateDeviceVisibility()
                    }
                }
            }
        case .denied, .restricted:
            Settings.recordingMicrophone = false
            microphoneButton.isOn = false
            updateDeviceVisibility()
            ToastWindow.show(message: "Microphone permission is required")
        @unknown default:
            break
        }
    }

    private func configureMicrophoneMonitor() {
        guard microphoneMonitorSession == nil,
              let device = RecordingMicrophoneDeviceProvider.device(for: Settings.recordingMicrophoneDeviceID) else { return }
        do {
            let session = AVCaptureSession()
            session.beginConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecordingControlsError.cannotMonitorMicrophone }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            let delegate = MicrophoneLevelMonitor { [weak self] level in
                self?.microphoneLevelMeter.setLevel(level)
            }
            output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.krit.recording.mic-meter", qos: .userInteractive))
            guard session.canAddOutput(output) else { throw RecordingControlsError.cannotMonitorMicrophone }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()

            microphoneMonitorSession = session
            microphoneMonitorOutput = output
            microphoneMonitorDelegate = delegate
        } catch {
            microphoneLevelMeter.setLevel(0)
            print("[KRIT] Microphone meter failed: \(error)")
        }
    }

    private func stopMicrophoneMonitor() {
        microphoneMonitorSession?.stopRunning()
        microphoneMonitorSession = nil
        microphoneMonitorOutput = nil
        microphoneMonitorDelegate = nil
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, String)]) {
        popup.removeAllItems()
        popup.bezelStyle = .shadowlessSquare
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12, weight: .semibold)
        popup.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        for item in items {
            popup.addItem(withTitle: item.0)
            popup.lastItem?.representedObject = item.1
        }
    }

    private func resizeForDeviceState() {
        let newHeight = Self.windowHeight(expanded: Self.isExpanded)
        guard abs(frame.height - newHeight) > 0.5 else { return }
        let oldFrame = frame
        setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - newHeight, width: oldFrame.width, height: newHeight), display: true)
    }

    /// The expanded device-picker row shows when either the mic or the camera is
    /// on, so the user can pick that device before recording.
    private static var isExpanded: Bool {
        Settings.recordingMicrophone || Settings.recordingWebcam
    }

    private static func windowHeight(expanded: Bool) -> CGFloat {
        (expanded ? expandedHeight : barHeight) + chromeInset * 2
    }

    @discardableResult
    private func selectItem(in popup: NSPopUpButton, representedObject: String) -> Bool {
        for item in popup.itemArray where item.representedObject as? String == representedObject {
            popup.select(item)
            return true
        }
        return false
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func pillLabel(_ text: String, symbol: String) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.105).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor

        let icon = NSImageView(frame: NSRect(x: 12, y: 11, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white.withAlphaComponent(0.86)
        view.addSubview(icon)

        let textField = label(text, size: 11, weight: .bold, color: NSColor.white.withAlphaComponent(0.86))
        textField.frame = NSRect(x: 36, y: 11, width: 146, height: 16)
        textField.lineBreakMode = .byTruncatingTail
        view.addSubview(textField)
        return view
    }

    private func keyHint(_ text: String) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let field = label(text, size: 7.5, weight: .bold, color: NSColor.white.withAlphaComponent(0.42))
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 1, width: 24, height: 9)
        view.addSubview(field)
        return view
    }

    /// A flat grouping chip that sits on the glass bar. It stays flat on purpose:
    /// glass cannot sample glass, so nothing layered on the bar becomes glass too.
    /// Its radius is concentric to the dock-scale bar (inset by the chip's vertical
    /// inset) so the corners stay parallel.
    private func segmentContainer(frame: NSRect) -> NSView {
        let inset = (Self.barHeight - frame.height) / 2
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = ChromeFactory.concentricRadius(outer: ChromeFactory.Radius.dock, inset: inset)
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
        return view
    }

    private func styleDeviceContainer(_ container: NSView, frame: NSRect) {
        container.frame = frame
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.98).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
    }

    private func divider(x: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: x, y: (Self.barHeight - height) / 2, width: 1, height: height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }

    private func positionPanel() {
        let visible = targetScreen.visibleFrame
        let visibleHeight = Self.isExpanded ? Self.expandedHeight : Self.barHeight
        let x = visible.midX - Self.panelWidth / 2
        let y = min(visible.maxY - visibleHeight - 28, captureRect.maxY - visibleHeight - 14)
        let visibleOrigin = NSPoint(
            x: max(visible.minX + 16, min(x, visible.maxX - Self.panelWidth - 16)),
            y: max(visible.minY + 16, y)
        )
        setFrameOrigin(pixelAligned(NSPoint(x: visibleOrigin.x - Self.chromeInset, y: visibleOrigin.y - Self.chromeInset)))
    }

    private func pixelAligned(_ point: NSPoint) -> NSPoint {
        let scale = targetScreen.backingScaleFactor
        return NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            return event
        }
    }

    private func closePanel() {
        guard !didClose else { return }
        didClose = true
        stopMicrophoneMonitor()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        orderOut(nil)
        Self.openWindows.removeAll { $0 === self }
        closeHandler()
        if Self.openWindows.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    func closeControls() {
        closePanel()
    }

    @objc private func toggleChanged(_ sender: RecordingToggleButton) {
        switch sender {
        case systemAudioButton:
            Settings.recordingSystemAudio = sender.isOn
        case microphoneButton:
            Settings.recordingMicrophone = sender.isOn
            if sender.isOn { reloadMicrophones() }
            updateDeviceVisibility()
        case cameraButton:
            Settings.recordingWebcam = sender.isOn
            if sender.isOn {
                reloadCameras()
                ensureCameraPermission()
            }
            updateDeviceVisibility()
        case cursorButton:
            Settings.recordingShowsCursor = sender.isOn
        default:
            break
        }
    }

    private func ensureCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if !granted {
                        Settings.recordingWebcam = false
                        self.cameraButton.isOn = false
                        self.updateDeviceVisibility()
                    }
                }
            }
        case .denied, .restricted:
            Settings.recordingWebcam = false
            cameraButton.isOn = false
            updateDeviceVisibility()
            ToastWindow.show(message: "Enable camera access for KRIT in System Settings")
            // Take the user straight to the right pane; a toast alone leaves
            // them hunting through Settings for the camera list.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    @objc private func cameraDeviceChanged() {
        Settings.recordingWebcamDeviceID = cameraPopup.selectedItem?.representedObject as? String ?? ""
    }

    @objc private func qualityChanged() {
        if let value = qualityPopup.selectedItem?.representedObject as? String {
            Settings.recordingQuality = value
        }
    }

    @objc private func fpsChanged() {
        if let value = fpsPopup.selectedItem?.representedObject as? String, let fps = Int(value) {
            Settings.recordingFPS = fps
        }
    }

    @objc private func microphoneChanged() {
        Settings.recordingMicrophoneDeviceID = microphonePopup.selectedItem?.representedObject as? String ?? ""
        if Settings.recordingMicrophone {
            stopMicrophoneMonitor()
            startMicrophoneMonitorIfNeeded()
        }
    }

    @objc private func recordTapped() {
        qualityChanged()
        fpsChanged()
        microphoneChanged()
        cameraDeviceChanged()
        Settings.recordingSystemAudio = systemAudioButton.isOn
        Settings.recordingMicrophone = microphoneButton.isOn
        Settings.recordingWebcam = cameraButton.isOn
        Settings.recordingShowsCursor = cursorButton.isOn
        closePanel()
        startHandler(captureRect, targetScreen, selectedWindow)
    }

    @objc private func cancelTapped() {
        closePanel()
    }
}

private struct RecordingMicrophoneOption {
    let id: String
    let name: String
}

private enum RecordingControlsError: Error {
    case cannotMonitorMicrophone
}

private enum RecordingMicrophoneDeviceProvider {
    static var options: [RecordingMicrophoneOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified)
            .devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map { RecordingMicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }
}

private enum RecordingCameraDeviceProvider {
    static var options: [RecordingMicrophoneOption] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external, .continuityCamera]
        }
        var result = [RecordingMicrophoneOption(id: "", name: "System Default")]
        result += AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map { RecordingMicrophoneOption(id: $0.uniqueID, name: $0.localizedName) }
        return result
    }
}

@MainActor
private final class RecordingPanelContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class RecordingToggleButton: NSButton {

    var isOn: Bool = false {
        didSet { updateAppearance() }
    }

    private let symbol: String
    private let label: String
    private let activeTint: NSColor

    init(symbol: String, title: String, activeTint: NSColor = KritColors.accent) {
        self.symbol = symbol
        self.label = title
        self.activeTint = activeTint
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.title = ""
        toolTip = label
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let action, let target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = isOn
            ? activeTint.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(0.07).cgColor
        contentTintColor = isOn ? activeTint : NSColor.white.withAlphaComponent(0.48)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }
}

@MainActor
private final class RecordingActionButton: NSButton {

    private let symbol: String
    private let buttonTint: NSColor
    private let isPrimary: Bool

    /// `isPrimary` marks the single primary action (Record). Only it carries the
    /// accent wash, keeping the tint reserved for one action per the glass rules;
    /// secondary actions (Cancel) stay neutral.
    init(symbol: String, title: String, tint: NSColor = KritColors.accent, isPrimary: Bool = false) {
        self.symbol = symbol
        self.buttonTint = tint
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.title = ""
        toolTip = title
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = idleBackground
        contentTintColor = buttonTint
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var idleBackground: CGColor {
        isPrimary
            ? buttonTint.withAlphaComponent(0.20).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = buttonTint.withAlphaComponent(isPrimary ? 0.30 : 0.16).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = idleBackground
    }
}

@MainActor
private final class RecordingAudioLevelMeter: NSView {

    private let bars: [NSView]
    private var smoothedLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in NSView(frame: .zero) }
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.cornerCurve = .continuous
            addSubview(bar)
        }
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.62 + clamped * 0.38
        let gap: CGFloat = 3
        let barWidth: CGFloat = 3
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.17
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.65))
            let height = baseHeight + response * (bounds.height - baseHeight)
            let x = CGFloat(index) * (barWidth + gap)
            bar.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.18).cgColor
        }
    }
}

private final class MicrophoneLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let levelHandler: @MainActor (CGFloat) -> Void

    init(levelHandler: @escaping @MainActor (CGFloat) -> Void) {
        self.levelHandler = levelHandler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let level = Self.level(from: sampleBuffer)
        Task { @MainActor [levelHandler] in
            levelHandler(level)
        }
    }

    private static func level(from sampleBuffer: CMSampleBuffer) -> CGFloat {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData,
              bufferList.mBuffers.mDataByteSize > 0 else {
            return 0
        }

        let sampleCount: Int
        let sumSquares: Double
        if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let value = Double(sample)
                return partial + value * value
            }
        } else if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 64 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Double>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: sampleCount)
            sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        } else if streamDescription.mBitsPerChannel == 16 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + normalized * normalized
            }
        } else if streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int32.max)
                return partial + normalized * normalized
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(max(rms, 0.000_001))
        return CGFloat(max(0, min(1, (decibels + 55) / 45)))
    }
}
