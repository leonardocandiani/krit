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

/// The still-capture primitive depends on the OS features available, while the
/// user-facing intent stays the same. macOS 13 has ScreenCaptureKit streams but
/// not `SCScreenshotManager`, so icon exclusion must choose the one-frame stream.
enum ScreenImageCaptureBackend: Equatable {
    case screenshotManager
    case oneFrameStream
    case coreGraphics

    static func resolve(
        excludeDesktopIcons: Bool,
        screenshotManagerAvailable: Bool,
        streamAvailable: Bool
    ) -> Self {
        if screenshotManagerAvailable { return .screenshotManager }
        if excludeDesktopIcons && streamAvailable { return .oneFrameStream }
        return .coreGraphics
    }
}

struct WindowCaptureDescriptor: Equatable {
    let id: CGWindowID
    let ownerProcessID: pid_t?
    let ownerBundleIdentifier: String?
    let layer: Int
    let frame: CGRect
    let title: String?
}

struct IsolatedWindowCapturePlan: Equatable {
    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    let targetID: CGWindowID
    let logicalSize: CGSize

    func pixelSize(scale: CGFloat, maxEdge: Int) -> PixelSize {
        PixelSize(
            width: min(max(1, Int(logicalSize.width * scale)), maxEdge),
            height: min(max(1, Int(logicalSize.height * scale)), maxEdge)
        )
    }
}

struct NormalizedWindowCapture {
    let image: CGImage
    let logicalSize: CGSize
    let didCrop: Bool
}

/// Some Chromium-based apps publish a transparent framing surface inside the
/// SCWindow that ScreenCaptureKit returns. That surface is app-owned content,
/// so `ignoreShadowsSingleWindow` cannot remove it. Limit pixel normalization
/// to known offenders so real transparent windows from other apps stay intact.
enum WindowCaptureImageNormalizer {
    private static let framedWindowBundleIdentifiers: Set<String> = [
        "at.studio.AsideBrowser"
    ]

    static func normalize(
        _ image: CGImage,
        logicalSize: CGSize,
        bundleIdentifier: String?
    ) -> NormalizedWindowCapture {
        let unchanged = NormalizedWindowCapture(
            image: image,
            logicalSize: logicalSize,
            didCrop: false
        )
        guard let bundleIdentifier,
              framedWindowBundleIdentifiers.contains(bundleIdentifier),
              logicalSize.width > 0,
              logicalSize.height > 0,
              let cropRect = nearlyOpaqueContentRect(in: image) else {
            return unchanged
        }

        let left = cropRect.minX
        let right = CGFloat(image.width) - cropRect.maxX
        let top = cropRect.minY
        let bottom = CGFloat(image.height) - cropRect.maxY
        let tolerance = CGFloat(max(image.width, image.height)) * 0.02
        guard min(left, right, top, bottom) > tolerance else {
            return unchanged
        }

        let widthRatio = cropRect.width / CGFloat(image.width)
        let heightRatio = cropRect.height / CGFloat(image.height)
        guard widthRatio >= 0.6, heightRatio >= 0.6,
              let cropped = image.cropping(to: cropRect) else {
            return unchanged
        }

        let scaleX = CGFloat(image.width) / logicalSize.width
        let scaleY = CGFloat(image.height) / logicalSize.height
        let croppedLogicalSize = CGSize(
            width: CGFloat(cropped.width) / scaleX,
            height: CGFloat(cropped.height) / scaleY
        )
        return NormalizedWindowCapture(
            image: cropped,
            logicalSize: croppedLogicalSize,
            didCrop: true
        )
    }

    /// Finds the straight window edges along the middle row and column. Rounded
    /// corner transparency remains inside this rect, while an external halo is
    /// excluded. Requiring nearly opaque pixels avoids guessing at legitimately
    /// translucent content.
    private static func nearlyOpaqueContentRect(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 4,
              height > 4,
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }

        let alphaInfo = image.alphaInfo
        let hasAlpha = alphaInfo == .premultipliedFirst
            || alphaInfo == .first
            || alphaInfo == .premultipliedLast
            || alphaInfo == .last
        guard hasAlpha else { return nil }

        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first
        let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaOffset = (alphaFirst != littleEndian) ? 0 : 3
        let bytesPerRow = image.bytesPerRow
        func alpha(x: Int, y: Int) -> UInt8 {
            pointer[y * bytesPerRow + x * 4 + alphaOffset]
        }

        let midX = width / 2
        let midY = height / 2
        guard let minX = (0..<width).first(where: { alpha(x: $0, y: midY) > 250 }),
              let maxX = stride(from: width - 1, through: 0, by: -1)
                .first(where: { alpha(x: $0, y: midY) > 250 }),
              let minY = (0..<height).first(where: { alpha(x: midX, y: $0) > 250 }),
              let maxY = stride(from: height - 1, through: 0, by: -1)
                .first(where: { alpha(x: midX, y: $0) > 250 }),
              maxX >= minX,
              maxY >= minY else {
            return nil
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}

/// Aside publishes an untitled shadow window plus the real titled
/// window as two separate ScreenCaptureKit entries. Resolve that exact geometry
/// before capture instead of guessing from pixels and risking real alpha content.
enum WindowCaptureTargetResolver {
    private static let shadowHostBundleIdentifiers: Set<String> = [
        "at.studio.AsideBrowser"
    ]

    static func targetID(
        selected: WindowCaptureDescriptor,
        candidates: [WindowCaptureDescriptor]
    ) -> CGWindowID {
        guard selected.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              let ownerProcessID = selected.ownerProcessID,
              let ownerBundleIdentifier = selected.ownerBundleIdentifier,
              shadowHostBundleIdentifiers.contains(ownerBundleIdentifier),
              selected.frame.width > 0,
              selected.frame.height > 0 else {
            return selected.id
        }

        let replacements = candidates
            .filter { candidate in
                candidate.id != selected.id
                    && candidate.ownerProcessID == ownerProcessID
                    && candidate.layer == selected.layer
                    && isCenteredContentWindow(candidate, inside: selected)
            }
        guard replacements.count == 1 else { return selected.id }
        return replacements[0].id
    }

    static func capturePlan(
        selectedID: CGWindowID,
        candidates: [WindowCaptureDescriptor]
    ) -> IsolatedWindowCapturePlan? {
        guard let selected = candidates.first(where: { $0.id == selectedID }) else {
            return nil
        }
        let targetID = targetID(selected: selected, candidates: candidates)
        guard let target = candidates.first(where: { $0.id == targetID }) else {
            return nil
        }
        return IsolatedWindowCapturePlan(targetID: target.id, logicalSize: target.frame.size)
    }

    private static func isCenteredContentWindow(
        _ candidate: WindowCaptureDescriptor,
        inside host: WindowCaptureDescriptor
    ) -> Bool {
        guard let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              candidate.frame.width >= 64,
              candidate.frame.height >= 64 else {
            return false
        }

        let left = candidate.frame.minX - host.frame.minX
        let right = host.frame.maxX - candidate.frame.maxX
        let top = candidate.frame.minY - host.frame.minY
        let bottom = host.frame.maxY - candidate.frame.maxY
        let insets = [left, right, top, bottom]
        guard let minimumInset = insets.min(),
              let maximumInset = insets.max(),
              minimumInset >= 4,
              maximumInset <= 128 else {
            return false
        }

        let averageInset = insets.reduce(0, +) / CGFloat(insets.count)
        let minimumHostEdge = min(host.frame.width, host.frame.height)
        let insetRatio = averageInset / minimumHostEdge
        guard insetRatio >= 0.02, insetRatio <= 0.15 else { return false }

        let symmetryTolerance = max(2, averageInset * 0.03)
        guard maximumInset - minimumInset <= symmetryTolerance else {
            return false
        }

        let areaRatio = (candidate.frame.width * candidate.frame.height)
            / (host.frame.width * host.frame.height)
        return areaRatio >= 0.70 && areaRatio <= 0.95
    }
}

struct AllInOneRestoredSelection: Equatable {
    let rect: CGRect
    let screenIndex: Int
}

enum AllInOneSelectionRestore {
    static func resolve(
        candidates: [CGRect?],
        screenFrames: [CGRect]
    ) -> AllInOneRestoredSelection? {
        for case let rect? in candidates where isReusable(rect) {
            if let screenIndex = screenFrames.firstIndex(where: { $0.contains(rect) }) {
                return AllInOneRestoredSelection(rect: rect, screenIndex: screenIndex)
            }
        }
        return nil
    }

    static func defaultRect(in screenFrame: CGRect) -> CGRect {
        let width = screenFrame.width * 0.6
        let height = screenFrame.height * 0.6
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func isReusable(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isEmpty
            && rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}

/// Resolves the app that should receive an interactive capture follow-up. The
/// All-in-One controller activates KRIT while it is visible, so its original
/// source must be remembered before presentation rather than read later from
/// the current frontmost app.
enum InteractiveCaptureRoute {
    static func allInOneSourceProcessIdentifier(
        frontmostProcessIdentifier: pid_t?,
        kritProcessIdentifier: pid_t
    ) -> pid_t? {
        guard let frontmostProcessIdentifier,
              frontmostProcessIdentifier != kritProcessIdentifier else {
            return nil
        }
        return frontmostProcessIdentifier
    }

    static func snapAndPasteTargetProcessIdentifier(
        allInOneSourceProcessIdentifier: pid_t?,
        frontmostProcessIdentifier: pid_t?
    ) -> pid_t? {
        allInOneSourceProcessIdentifier ?? frontmostProcessIdentifier
    }
}

/// Preserves event-receipt order while capture work waits for the main actor.
/// The engine's intent token handles replacement after a request starts; this
/// gate prevents an older queued entry point from starting after a newer one.
struct InteractiveCaptureDispatchGate {
    private var latestRequestID = UUID()

    mutating func beginRequest() -> UUID {
        let requestID = UUID()
        latestRequestID = requestID
        return requestID
    }

    func isLatest(_ requestID: UUID) -> Bool {
        latestRequestID == requestID
    }
}

/// Central coordinator for all capture modes.
@MainActor
final class CaptureEngine {

    static let captureLog = Logger(subsystem: "com.krit.app", category: "capture")

    /// Hard ceiling on a captured buffer's edge in pixels. ScreenCaptureKit
    /// rejects configurations past the GPU texture limit; clamp the supersampled
    /// width/height here so Maximum on a huge display degrades instead of failing.
    static let maxCaptureEdge = ScreenCaptureDisplayGeometry.maxCaptureEdge

    /// Set when the SCK path fails because Screen Recording consent is missing,
    /// so callers can surface the permission alert instead of failing silently.
    private(set) var lastCaptureFailureWasPermission = false

    /// Runs just before any screen grab or recording start that funnels
    /// straight into the engine (headless krit:// commands, automation port).
    /// Interactive entry points already drop the presentation zoom at the
    /// hotkey/menu layer; this hook covers the scripted paths, so a
    /// programmatic capture never includes the magnifier overlay. Wired by
    /// AppDelegate; a repeat call while the zoom is off is a no-op.
    var willCaptureScreenHook: (() -> Void)?

    // Remembers the last selected area for "Capture Previous Area"
    private(set) var lastCaptureRect: CGRect?

    /// A capture owns its follow-up from acceptance until it either finishes or
    /// cancels. A rejected request never receives an attempt and therefore cannot
    /// clear an in-flight request's metadata or `then=` chain.
    private struct CaptureAttempt {
        let id = UUID()
        let followUp: ((CaptureDeliveryReceipt) -> Void)?
    }

    private var activeCaptureAttempt: CaptureAttempt?

    private struct AllInOneStartPlan {
        let screen: NSScreen
        let initialRect: CGRect
    }

    private func beginCaptureAttempt(
        followUp: ((CaptureDeliveryReceipt) -> Void)? = nil
    ) -> CaptureAttempt? {
        guard activeCaptureAttempt == nil else { return nil }
        let attempt = CaptureAttempt(followUp: followUp)
        activeCaptureAttempt = attempt
        return attempt
    }

    /// Takes an accepted attempt exactly once. A stale completion cannot deliver a
    /// screenshot after its original attempt has already been cancelled.
    private func takeCaptureAttempt(_ attempt: CaptureAttempt) -> CaptureAttempt? {
        guard let activeCaptureAttempt, activeCaptureAttempt.id == attempt.id else { return nil }
        self.activeCaptureAttempt = nil
        return activeCaptureAttempt
    }

    /// Ends a screenshot attempt that never reached `finishCapture`. Source-app
    /// metadata belongs to the same attempt, so only the owner may clear it.
    private func abandonCaptureAttempt(_ attempt: CaptureAttempt, historyManager: HistoryManager) {
        guard takeCaptureAttempt(attempt) != nil else { return }
        historyManager.cancelPreparedCapture()
    }

    private var areaSelectionWindow: AreaSelectionWindow?
    // Guards back-to-back fullscreen/previous triggers from stacking countdowns
    // (those paths have no area-selection re-entry guard).
    private var countdownActive = false
    private var scrollingCapture: ScrollingCaptureController?
    private var allInOneController: AllInOneController?
    private var allInOneSessionID: UUID?
    private var allInOneSourceProcessIdentifier: pid_t?
    private var interactiveCaptureIntentID = UUID()
    private var interactiveCaptureDispatchGate = InteractiveCaptureDispatchGate()
    private var recordingControlsWindow: RecordingControlsWindow?
    private(set) var uiTestLegacyWindowPreviewFallbackCount = 0
    private var recordingScreenChooserWindow: RecordingScreenChooserWindow?
    private var recordingWindowChooserWindow: RecordingWindowChooserWindow?
    private let recordingEngine = RecordingEngine()

    var recordingActive: Bool { recordingEngine.active }
    var recordingActionsEnabled: Bool { !recordingEngine.active && !recordingSetupActive }

    /// Claims the newest external interactive request before scheduling its
    /// asynchronous work. This keeps URL commands, menu actions and hotkeys in
    /// receipt order even when several arrive in one run-loop turn.
    func enqueueInteractiveRequest(_ operation: @escaping @MainActor () async -> Void) {
        let requestID = interactiveCaptureDispatchGate.beginRequest()
        Task { @MainActor [weak self] in
            guard let self,
                  self.interactiveCaptureDispatchGate.isLatest(requestID) else {
                return
            }
            await operation()
        }
    }

    private var recordingSetupActive: Bool {
        areaSelectionWindow != nil || allInOneController != nil || recordingControlsWindow != nil || recordingScreenChooserWindow != nil || recordingWindowChooserWindow != nil
    }

    /// Every interactive capture surface must leave the WindowServer before a
    /// new capture flow can create its own overlay. All-in-One owns two windows,
    /// so merely starting another area picker could otherwise leave its frozen
    /// backdrop and dock in the next grab.
    private func dismissAllInOneForReplacement() async {
        guard let controller = allInOneController else { return }
        let sessionID = allInOneSessionID
        controller.dismissForReplacement()
        if let sessionID {
            clearAllInOneSession(id: sessionID)
        }
        // Match the existing selection handoff delay. `orderOut` is synchronous,
        // but the compositor needs one short turn before another capture samples
        // the screen beneath it.
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// An interactive command may need to wait for a dismissed All-in-One dock to
    /// leave the compositor. The newest command owns the screen if another intent
    /// arrives during that yield, so every replacement revalidates this token
    /// before creating its own surface.
    private func beginInteractiveCaptureIntent() -> UUID {
        dismissPendingInteractiveSurfaces()
        let intentID = UUID()
        interactiveCaptureIntentID = intentID
        return intentID
    }

    /// Closes setup-only surfaces before a newer interactive intent takes over.
    /// Ongoing recording and a running scrolling capture are deliberately left
    /// alone: their stop actions own real media work and must not be torn down by
    /// an unrelated screenshot hotkey.
    private func dismissPendingInteractiveSurfaces() {
        if let selection = areaSelectionWindow {
            selection.cancel()
            if areaSelectionWindow === selection {
                areaSelectionWindow = nil
            }
        }

        if let scrollingCapture {
            scrollingCapture.cancelPendingSelection()
            if !scrollingCapture.isActive, self.scrollingCapture === scrollingCapture {
                self.scrollingCapture = nil
            }
        }

        if let controls = recordingControlsWindow {
            controls.closeControls()
            if recordingControlsWindow === controls {
                recordingControlsWindow = nil
            }
        }

        if let chooser = recordingScreenChooserWindow {
            chooser.closeChooser()
            if recordingScreenChooserWindow === chooser {
                recordingScreenChooserWindow = nil
            }
        }

        if let chooser = recordingWindowChooserWindow {
            chooser.closeChooser()
            if recordingWindowChooserWindow === chooser {
                recordingWindowChooserWindow = nil
            }
        }
    }

    private func ownsInteractiveCaptureIntent(_ intentID: UUID) -> Bool {
        interactiveCaptureIntentID == intentID
    }

    private func beginAllInOneReplacement() async -> UUID {
        let intentID = beginInteractiveCaptureIntent()
        await dismissAllInOneForReplacement()
        return intentID
    }

    /// A continuation selected inside All-in-One already owns a valid intent.
    /// External entry points claim a new one and dismiss any pending surface.
    private func acquireInteractiveCaptureIntent(
        continuing existingIntentID: UUID?
    ) async -> UUID? {
        if let existingIntentID {
            return ownsInteractiveCaptureIntent(existingIntentID) ? existingIntentID : nil
        }
        return await beginAllInOneReplacement()
    }

    // MARK: - Area Capture

    func startAreaCapture(
        historyManager: HistoryManager,
        followUp: ((CaptureDeliveryReceipt) -> Void)? = nil
    ) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else {
            return
        }
        guard let attempt = beginCaptureAttempt(followUp: followUp) else { return }
        AreaSelectionDiag.mark("startAreaCapture")
        // Snapshot the source app BEFORE the overlay activates KRIT and steals focus,
        // so the history thumbnail can badge where the shot came from.
        historyManager.prepareForCapture()
        // Desktop icons are hidden the Snapzy way — by excluding Finder from the
        // SCK grab (both prepareAndShow's frozen backdrop and the final shot) — not
        // with a light cover window, so nothing light is ever painted on screen.
        let hideIcons = Settings.hideDesktopIconsWhileCapturing
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            guard self.ownsInteractiveCaptureIntent(intentID) else {
                self.abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            guard let rect else {
                self.areaSelectionWindow = nil
                self.abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            self.rememberReusableArea(rect, on: screen)
            // Fast path (no self-timer): build the shot by cropping the frozen frame
            // the overlay already holds (dark, icon-free) instead of tearing the
            // overlay down to re-grab the live screen. The re-grab is what briefly
            // reveals the desktop — the paused aerial's light poster — the dark→light
            // flash at print time. Cropping is instant and keeps the dark overlay up
            // through the shutter, so the live screen is never exposed mid-capture.
            if Settings.captureCountdownSeconds == 0,
               let shot = self.areaSelectionWindow?.croppedFrozenImage(globalRect: rect, on: screen) {
                self.captureMoment(rect: rect, on: screen)
                self.areaSelectionWindow = nil
                self.finishCapture(
                    image: shot,
                    rect: rect,
                    on: screen,
                    historyManager: historyManager,
                    isWindowCapture: false,
                    attempt: attempt
                )
                return
            }
            // Self-timer (or a missing frozen frame): re-grab live, still icon-free.
            self.areaSelectionWindow = nil
            Task {
                await self.captureRect(
                    rect,
                    on: screen,
                    historyManager: historyManager,
                    excludeDesktopIcons: hideIcons,
                    attempt: attempt
                )
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    // MARK: - Color Pick

    /// Eyedropper: same fullscreen overlay as area capture (loupe over the
    /// frozen frame), but a click copies the pixel's hex to the clipboard
    /// instead of starting a drag. Desktop icons stay visible on purpose: the
    /// user is sampling the screen exactly as it looks.
    func startColorPick() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else { return } // already selecting
        let picker = AreaSelectionWindow(mode: .colorPick) { [weak self] _, _, _ in
            // Cancel path (Esc / click before the frozen frame lands).
            guard self?.ownsInteractiveCaptureIntent(intentID) == true else { return }
            self?.areaSelectionWindow = nil
        }
        picker.onColorPicked = { [weak self] hex in
            guard self?.ownsInteractiveCaptureIntent(intentID) == true else { return }
            self?.areaSelectionWindow = nil
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            ToastWindow.show(message: "\(hex) copied")
        }
        areaSelectionWindow = picker
        await picker.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    // MARK: - All-in-One

    /// CleanShot-style All-in-One: shows the latest reusable selection (or a
    /// centered default the first time) with handles and a floating options panel.
    /// Each option routes to the real capture/record/tool path.
    func startAllInOne(historyManager: HistoryManager) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        // Repeated All-in-One invokes leave the existing dock alone. Any other
        // pending interactive surface is replaced below by the new intent.
        guard allInOneController == nil else { return }
        let intentID = beginInteractiveCaptureIntent()

        guard let plan = makeAllInOneStartPlan(
            screens: NSScreen.screens,
            cursor: NSEvent.mouseLocation
        ) else { return }

        let sessionID = UUID()
        let sourceProcessIdentifier = InteractiveCaptureRoute.allInOneSourceProcessIdentifier(
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            kritProcessIdentifier: pid_t(ProcessInfo.processInfo.processIdentifier)
        )
        let controller = AllInOneController(
            screen: plan.screen,
            initialRect: plan.initialRect,
            onAction: { [weak self] action, rect, screen in
                guard let self else { return }
                guard self.ownsInteractiveCaptureIntent(intentID),
                      self.allInOneSessionID == sessionID else { return }
                self.clearAllInOneSession(id: sessionID)
                self.handleAllInOne(
                    action: action,
                    rect: rect,
                    on: screen,
                    historyManager: historyManager,
                    intentID: intentID
                )
            },
            onCancel: { [weak self] in
                self?.clearAllInOneSession(id: sessionID)
            }
        )
        allInOneController = controller
        allInOneSessionID = sessionID
        allInOneSourceProcessIdentifier = sourceProcessIdentifier
        await controller.prepareAndShow(engine: self)
    }

    private func clearAllInOneSession(id: UUID) {
        guard allInOneSessionID == id else { return }
        allInOneController = nil
        allInOneSessionID = nil
        allInOneSourceProcessIdentifier = nil
    }

    /// The newest valid area wins for this process, then the persisted fallback
    /// carries that selection across relaunch. A rect that no longer belongs to
    /// one current display is deliberately discarded instead of being clamped.
    private func restoredAllInOneSelection(in screens: [NSScreen]) -> AllInOneRestoredSelection? {
        AllInOneSelectionRestore.resolve(
            candidates: [lastCaptureRect, Settings.allInOneRect],
            screenFrames: screens.map(\.frame)
        )
    }

    private func makeAllInOneStartPlan(
        screens: [NSScreen],
        cursor: CGPoint
    ) -> AllInOneStartPlan? {
        guard !screens.isEmpty else { return nil }
        let cursorScreen = screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main ?? screens[0]
        let restoredSelection = restoredAllInOneSelection(in: screens)
        let screen: NSScreen
        if let restoredSelection, screens.indices.contains(restoredSelection.screenIndex) {
            // Keep the area on its owning display. Moving it into the display
            // under the cursor would silently select different content.
            screen = screens[restoredSelection.screenIndex]
        } else {
            screen = cursorScreen
        }
        return AllInOneStartPlan(
            screen: screen,
            initialRect: restoredAllInOneRect(on: screen, restoredSelection: restoredSelection)
        )
    }

    /// The starting rect for All-in-One in AppKit global coordinates: the saved
    /// rect if it belongs to this screen, otherwise a centered 60% box on `screen`.
    private func restoredAllInOneRect(
        on screen: NSScreen,
        restoredSelection: AllInOneRestoredSelection?
    ) -> CGRect {
        if let restored = restoredSelection,
           screen.frame.contains(restored.rect) {
            return restored.rect
        }
        return AllInOneSelectionRestore.defaultRect(in: screen.frame)
    }

    private func rememberReusableArea(_ rect: CGRect, on screen: NSScreen) {
        lastCaptureRect = rect
        guard AllInOneSelectionRestore.resolve(
            candidates: [rect],
            screenFrames: [screen.frame]
        ) != nil else { return }
        Settings.allInOneRect = rect
    }

    private func handleAllInOne(
        action: AllInOneAction,
        rect: CGRect,
        on screen: NSScreen,
        historyManager: HistoryManager,
        intentID: UUID
    ) {
        guard ownsInteractiveCaptureIntent(intentID) else { return }
        rememberReusableArea(rect, on: screen)
        switch action {
        case .capture:
            Task { [weak self] in
                guard let self, self.ownsInteractiveCaptureIntent(intentID) else { return }
                await self.captureRect(
                    rect,
                    on: screen,
                    historyManager: historyManager,
                    continuationIntentID: intentID
                )
            }
        case .record:
            guard recordingActionsEnabled else {
                ToastWindow.show(message: "Finish or stop the current recording first")
                return
            }
            // Route through the preflight controls so the user picks mic/system
            // audio/camera before recording, same as the dedicated area path.
            showRecordingControls(rect: rect, on: screen, target: .area)
        case .ocr:
            Task { [weak self] in
                guard let self, self.ownsInteractiveCaptureIntent(intentID) else { return }
                await self.runOCR(
                    on: rect,
                    screen: screen,
                    excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing,
                    intentID: intentID
                )
            }
        case .window:
            Task { [weak self] in
                guard let self, self.ownsInteractiveCaptureIntent(intentID) else { return }
                await self.startWindowCapture(
                    historyManager: historyManager,
                    continuationIntentID: intentID
                )
            }
        case .fullscreen:
            Task { [weak self] in
                guard let self, self.ownsInteractiveCaptureIntent(intentID) else { return }
                await self.captureFullscreen(
                    historyManager: historyManager,
                    continuationIntentID: intentID
                )
            }
        case .scrolling:
            Task { [weak self] in
                guard let self, self.ownsInteractiveCaptureIntent(intentID) else { return }
                await self.startScrollingCapture(
                    historyManager: historyManager,
                    continuationIntentID: intentID
                )
            }
        }
    }

    // MARK: - Window Capture

    func startWindowCapture(
        historyManager: HistoryManager,
        followUp: ((CaptureDeliveryReceipt) -> Void)? = nil,
        continuationIntentID: UUID? = nil
    ) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard let intentID = await acquireInteractiveCaptureIntent(
            continuing: continuationIntentID
        ) else { return }
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else {
            return
        }
        guard let attempt = beginCaptureAttempt(followUp: followUp) else { return }
        historyManager.prepareForCapture()
        // Desktop icons are hidden by excluding Finder from the picker's frozen
        // grab (Snapzy style, see prepareAndShow), not with a light cover window —
        // so the theme never flicks to white when the picker opens.
        areaSelectionWindow = AreaSelectionWindow(mode: .window) { [weak self] rect, screen, windowID in
            guard let self else { return }
            guard self.ownsInteractiveCaptureIntent(intentID) else {
                self.abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            self.areaSelectionWindow = nil
            guard let rect else {
                self.abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            Task {
                // Prefer the isolated-window grab (clean alpha corners, immune to
                // overlapping windows); fall back to the rect crop on older macOS.
                if #available(macOS 14.0, *), let windowID {
                    await self.captureWindowIsolated(
                        windowID: windowID,
                        rect: rect,
                        on: screen,
                        historyManager: historyManager,
                        attempt: attempt
                    )
                } else {
                    await self.captureRect(
                        rect,
                        on: screen,
                        historyManager: historyManager,
                        isWindowCapture: true,
                        excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing,
                        attempt: attempt
                    )
                }
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    // MARK: - Fullscreen

    func captureFullscreen(
        historyManager: HistoryManager,
        followUp: ((CaptureDeliveryReceipt) -> Void)? = nil,
        continuationIntentID: UUID? = nil
    ) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard let intentID = await acquireInteractiveCaptureIntent(
            continuing: continuationIntentID
        ) else { return }
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else {
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return
        }
        guard let attempt = beginCaptureAttempt(followUp: followUp) else { return }
        historyManager.prepareForCapture()
        // Capture the display under the cursor so the global hotkey targets the
        // screen the user is looking at on a multi-monitor setup (NSScreen.main is
        // the menu-bar/key-window screen, not necessarily where the cursor is).
        // Icons are excluded from the SCK grab itself (the Finder-exclusion
        // filter, same as area/window capture): nothing is painted over the real
        // desktop, so an aerial dark wallpaper never flips to its light poster
        // mid-print the way the old wallpaper cover window made it.
        let mouse = NSEvent.mouseLocation
        let screen = screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? screens[0]
        let rect = screen.frame
        await captureRect(
            rect,
            on: screen,
            historyManager: historyManager,
            excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing,
            attempt: attempt
        )
    }

    // MARK: - Screen Recording

    func startAreaRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              canBeginRecordingSetup() else { return }

        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            guard self.ownsInteractiveCaptureIntent(intentID) else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.rememberReusableArea(rect, on: screen)
            self.showRecordingControls(rect: rect, on: screen, target: .area)
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    func startWindowRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              canBeginRecordingSetup() else { return }

        do {
            let snapshot = try await ScreenCaptureCatalog.shared.windows(.windowPicker)
            guard ownsInteractiveCaptureIntent(intentID),
                  allInOneController == nil,
                  canBeginRecordingSetup() else { return }
            let choices = await recordingWindowChoices(from: snapshot.windows)
            guard ownsInteractiveCaptureIntent(intentID),
                  allInOneController == nil,
                  canBeginRecordingSetup() else { return }
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
            guard ownsInteractiveCaptureIntent(intentID) else { return }
            ToastWindow.show(message: "Could not list windows. Check permissions.")
            print("[KRIT] Window picker failed: \(error)")
        }
    }

    func startFullscreenRecording() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              canBeginRecordingSetup() else { return }
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
        if #available(macOS 14.0, *) {
            if let image = await screenCaptureKitWindowPreview(for: window) {
                return image
            }
            // A just-opened or recently-resized window can briefly miss the first
            // SCK snapshot. Retry once, but never fall through to the obsolete
            // CoreGraphics window capture path on modern macOS.
            try? await Task.sleep(nanoseconds: 80_000_000)
            return await screenCaptureKitWindowPreview(for: window)
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
        uiTestLegacyWindowPreviewFallbackCount += 1
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

    /// `SCWindow.frame` is in global CoreGraphics coordinates. Compare it with
    /// `CGDisplayBounds`, never with `NSScreen.frame` (AppKit coordinates).
    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsID = ScreenCaptureCatalog.displayID(of: lhs) ?? CGMainDisplayID()
            let rhsID = ScreenCaptureCatalog.displayID(of: rhs) ?? CGMainDisplayID()
            let lhsIntersection = CGDisplayBounds(lhsID).intersection(rect)
            let rhsIntersection = CGDisplayBounds(rhsID).intersection(rect)
            let lhsArea = lhsIntersection.isNull ? 0 : lhsIntersection.width * lhsIntersection.height
            let rhsArea = rhsIntersection.isNull ? 0 : rhsIntersection.width * rhsIntersection.height
            return lhsArea < rhsArea
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
        willCaptureScreenHook?()
        await recordingEngine.startRecording(rect: rect, on: screen)
    }

    /// GUI test hook: live dim panel count while a recording runs.
    var uiTestDimPanelCount: Int { recordingEngine.uiTestDimPanelCount }

    /// GUI test hook: whether scrolling owns a private selection or capture phase.
    var uiTestScrollingCaptureActive: Bool { scrollingCapture?.isActive == true }

    /// The in-flight selection overlay (area / window / colorPick), if any.
    var uiTestActiveSelection: AreaSelectionWindow? { areaSelectionWindow }

    /// Test-only bridge for the state committed by an accepted area selection.
    func uiTestRememberReusableArea(_ rect: CGRect, on screen: NSScreen) {
        rememberReusableArea(rect, on: screen)
    }

    /// Test-only state restoration so scenarios do not leak their synthetic
    /// selection into whichever scenario runs next in the same harness.
    func uiTestRestoreLastCaptureRect(_ rect: CGRect?) {
        lastCaptureRect = rect
    }

    /// Tests the exact target screen and initial rect the production All-in-One
    /// entry point would choose, without requiring a screen-capture permission.
    func uiTestAllInOneStartPlan(cursor: CGPoint) -> (rect: CGRect, screenFrame: CGRect)? {
        guard let plan = makeAllInOneStartPlan(screens: NSScreen.screens, cursor: cursor) else { return nil }
        return (plan.initialRect, plan.screen.frame)
    }

    /// GUI test hooks for the actual engine-owned All-in-One path.
    var uiTestAllInOneInitialRect: CGRect? { allInOneController?.uiTestInitialRect }
    var uiTestAllInOneScreenFrame: CGRect? { allInOneController?.uiTestScreenFrame }
    func uiTestCloseAllInOne() { allInOneController?.uiTestCancel() }

    /// GUI test hook: reports the follow-up owned by the current capture attempt.
    var uiTestHasPendingCaptureFollowUp: Bool { activeCaptureAttempt?.followUp != nil }

    /// GUI test hook: lets replacement scenarios prove a newer selector owns a
    /// fresh capture attempt instead of inheriting the previous request.
    var uiTestActiveCaptureAttemptID: UUID? { activeCaptureAttempt?.id }

    /// GUI test hook: outcome of the last recording finish (saved/failed + reason).
    var uiTestRecordingOutcome: String { recordingEngine.uiTestLastFinishOutcome }

    /// GUI test hook: pause/resume the real recording engine without routing
    /// through a simulated button click.
    func uiTestToggleRecordingPause() { recordingEngine.togglePause() }

    var uiTestRecordingDuration: Double? { recordingEngine.uiTestLastRecordingDuration }
    var uiTestRecordingPaused: Bool { recordingEngine.uiTestIsPaused }

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
        recordingEngine.reopenResultPanel()
    }

    // MARK: - Previous Area

    func capturePreviousArea(historyManager: HistoryManager) async {
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else { return }
        let screens = NSScreen.screens
        guard let restored = restoredAllInOneSelection(in: screens),
              screens.indices.contains(restored.screenIndex) else {
            await startAreaCapture(historyManager: historyManager)
            return
        }
        await captureRect(
            restored.rect,
            on: screens[restored.screenIndex],
            historyManager: historyManager,
            excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing
        )
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

        // Grab the target before replacing All-in-One. Its panel makes KRIT
        // frontmost, so Snap and Paste must prefer the app that originally opened
        // that session instead of saving KRIT as its own paste target.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let targetProcessIdentifier = InteractiveCaptureRoute.snapAndPasteTargetProcessIdentifier(
            allInOneSourceProcessIdentifier: allInOneSourceProcessIdentifier,
            frontmostProcessIdentifier: frontmost?.processIdentifier
        )
        let target = targetProcessIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? (allInOneSourceProcessIdentifier == nil ? frontmost : nil)
        await startAreaCapture(historyManager: historyManager) { [weak self] receipt in
            self?.completeSnapAndPaste(receipt: receipt, target: target)
        }
    }

    private func completeSnapAndPaste(
        receipt: CaptureDeliveryReceipt,
        target: NSRunningApplication?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let artifact = receipt.presentedArtifact,
               let png = await artifact.encoded(as: .png)?.data {
                ImageExporter.copyPNGToClipboard(png)
            } else {
                ImageExporter.copyToClipboard(image: receipt.presentedImage)
            }
            self.finishSnapAndPasteAfterCopy(target: target)
        }
    }

    private func finishSnapAndPasteAfterCopy(target: NSRunningApplication?) {
        guard AXIsProcessTrusted() else {
            // Copy still works; tell the user how to unlock the auto-paste half.
            ToastWindow.show(message: "Grant Accessibility access to auto-paste (System Settings > Privacy & Security > Accessibility)")
            if !Settings.didPromptAccessibilityForPaste {
                Settings.didPromptAccessibilityForPaste = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

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
        let screens = NSScreen.screens
        guard let restored = AllInOneSelectionRestore.resolve(
            candidates: [appKit],
            screenFrames: screens.map(\.frame)
        ), screens.indices.contains(restored.screenIndex) else { return nil }
        return (appKit, screens[restored.screenIndex])
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
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else { completion(nil); return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, _, _ in
            guard let self else { completion(nil); return }
            guard self.ownsInteractiveCaptureIntent(intentID) else { return }
            self.areaSelectionWindow = nil
            guard let rect else { completion(nil); return }
            completion(self.topLeftRect(fromAppKit: rect))
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
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

    func startScrollingCapture(
        historyManager: HistoryManager,
        continuationIntentID: UUID? = nil
    ) async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        guard let intentID = await acquireInteractiveCaptureIntent(
            continuing: continuationIntentID
        ) else { return }
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil,
              scrollingCapture?.isActive != true else { return }
        let controller = ScrollingCaptureController { [weak self] rect, screen in
            self?.rememberReusableArea(rect, on: screen)
        }
        scrollingCapture = controller
        await controller.start(
            historyManager: historyManager,
            excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing,
            canPresent: { [weak self] in
                self?.ownsInteractiveCaptureIntent(intentID) == true
            }
        )
        if !ownsInteractiveCaptureIntent(intentID), scrollingCapture === controller {
            scrollingCapture = nil
        }
    }

    // MARK: - OCR Capture

    func startOCRCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else { return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            guard self.ownsInteractiveCaptureIntent(intentID) else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.rememberReusableArea(rect, on: screen)
            Task {
                await self.runOCR(on: rect, screen: screen,
                                  excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing,
                                  intentID: intentID)
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    /// Grabs `rect`, recognizes its text, and copies it to the clipboard. Shared
    /// by the area OCR path and the All-in-One OCR option, which already has a rect.
    func runOCR(
        on rect: CGRect,
        screen: NSScreen,
        excludeDesktopIcons: Bool = false,
        intentID: UUID? = nil
    ) async {
        guard let image = await captureRectToImage(rect, on: screen, excludeDesktopIcons: excludeDesktopIcons) else { return }
        guard intentID.map({ ownsInteractiveCaptureIntent($0) }) ?? true else { return }
        let text = await OCREngine.recognizeText(in: image)
        guard intentID.map({ ownsInteractiveCaptureIntent($0) }) ?? true else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showOCRNotification(text: text)
    }

    // MARK: - QR Capture

    func startQRCodeCapture() async {
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert(); return
        }
        let intentID = await beginAllInOneReplacement()
        guard ownsInteractiveCaptureIntent(intentID),
              allInOneController == nil,
              areaSelectionWindow == nil else { return }
        areaSelectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            guard self.ownsInteractiveCaptureIntent(intentID) else { return }
            self.areaSelectionWindow = nil
            guard let rect else { return }
            self.rememberReusableArea(rect, on: screen)
            Task {
                guard let image = await self.captureRectToImage(
                    rect, on: screen,
                    excludeDesktopIcons: Settings.hideDesktopIconsWhileCapturing
                ) else { return }
                guard self.ownsInteractiveCaptureIntent(intentID) else { return }
                let results = await QRCodeEngine.detect(in: image)
                await MainActor.run {
                    guard self.ownsInteractiveCaptureIntent(intentID) else { return }
                    if results.isEmpty {
                        ToastWindow.show(message: "No QR code found in this selection")
                    } else {
                        QRCodeResultWindow.show(results: results)
                    }
                }
            }
        }
        await areaSelectionWindow?.prepareAndShow(engine: self, canPresent: { [weak self] in
            self?.ownsInteractiveCaptureIntent(intentID) == true
        })
    }

    // MARK: - Core capture

    func captureRect(
        _ rect: CGRect,
        on screen: NSScreen,
        historyManager: HistoryManager,
        isWindowCapture: Bool = false,
        excludeDesktopIcons: Bool = false,
        continuationIntentID: UUID? = nil
    ) async {
        guard continuationIntentID.map({ ownsInteractiveCaptureIntent($0) }) ?? true else { return }
        guard let attempt = beginCaptureAttempt() else { return }
        await captureRect(
            rect,
            on: screen,
            historyManager: historyManager,
            isWindowCapture: isWindowCapture,
            excludeDesktopIcons: excludeDesktopIcons,
            attempt: attempt
        )
    }

    private func captureRect(
        _ rect: CGRect,
        on screen: NSScreen,
        historyManager: HistoryManager,
        isWindowCapture: Bool = false,
        excludeDesktopIcons: Bool = false,
        attempt: CaptureAttempt
    ) async {
        // D1 self-timer: count down on the captured display before grabbing.
        // Gating here covers all four screenshot modes (area/window/fullscreen/
        // previous) and leaves OCR/QR/automation untouched, they call
        // captureRectToImage directly. Esc aborts before any side effect fires.
        let countdown = Settings.captureCountdownSeconds
        if countdown > 0 {
            guard !countdownActive else {
                abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            let proceed = await runCountdown(countdown, on: screen)
            guard proceed else {
                abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
        }
        captureMoment(rect: rect, on: screen)
        guard let image = await captureRectToImage(rect, on: screen, excludeDesktopIcons: excludeDesktopIcons) else {
            abandonCaptureAttempt(attempt, historyManager: historyManager)
            if lastCaptureFailureWasPermission {
                PermissionsManager.showPermissionDeniedAlert()
            } else {
                ToastWindow.show(message: "Capture failed. Try again or check Screen Recording permission")
            }
            return
        }
        finishCapture(
            image: image,
            rect: rect,
            on: screen,
            historyManager: historyManager,
            isWindowCapture: isWindowCapture,
            attempt: attempt
        )
    }

    /// The shutter "moment": sound + haptic + white blink, fired BEFORE the SCK
    /// grab so the response to the gesture is instant. The heavy pipeline (grab
    /// at supersampling scale, template compose, encodes) runs behind it; the
    /// blink window is never capturable, so it cannot leak into the shot it
    /// announces. Both capture funnels (captureRect, captureWindowIsolated)
    /// call this right before their grab.
    private func captureMoment(rect: CGRect, on screen: NSScreen) {
        playCaptureSound()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        CaptureFlash.blink(rect: rect, on: screen)
    }

    /// Shared post-capture finishing: history, auto-actions, and the
    /// flash/overlay handoff. Both the rect crop (captureRect) and the
    /// isolated-window grab (captureWindowIsolated) funnel through here so the
    /// "capture moment" is identical regardless of how the image was produced.
    /// Sound/haptic/blink already fired at the gesture (captureMoment).
    private func finishCapture(
        image: NSImage,
        rect: CGRect,
        on screen: NSScreen,
        historyManager: HistoryManager,
        isWindowCapture: Bool,
        attempt: CaptureAttempt
    ) {
        guard let completedAttempt = takeCaptureAttempt(attempt) else { return }
        var presented = image
        // Diagnostic trail for the supersampled window-shot reports: one line per
        // capture with the exact point/pixel geometry each stage saw, so a bad
        // presented PNG can be traced to its stage from `log show` after the fact.
        let rawCG = image.bestCGImage
        Self.captureLog.info("finishCapture: window=\(isWindowCapture) pointSize=\(String(describing: image.size)) pixels=\(rawCG?.width ?? -1)x\(rawCG?.height ?? -1) rect=\(String(describing: rect)) screen=\(screen.localizedName, privacy: .public)")
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

        var automaticActions: [CaptureAction] = []
        if Settings.afterCaptureCopyToClipboard {
            automaticActions.append(.copy)
        }
        if Settings.afterCaptureSaveAutomatically {
            automaticActions.append(.save)
        }
        let ext = Settings.screenshotFormat
        let actionRequest = automaticActions.isEmpty ? nil : CaptureActionRequest(
            actions: automaticActions,
            format: ext,
            jpegQuality: Settings.jpegQuality,
            saveURL: URL(fileURLWithPath: Settings.autoSaveLocation)
                .appendingPathComponent("\(ImageExporter.timestampedName).\(ext)")
        )

        CaptureDelivery.submit(
            .init(
                rawImage: image,
                presentedImage: presented,
                rect: rect,
                screen: screen,
                isWindowCapture: isWindowCapture,
                showOverlay: Settings.afterCaptureShowOverlay,
                automaticActions: actionRequest
            ),
            historyManager: historyManager,
            followUp: completedAttempt.followUp
        )
    }

    /// Captures a single window in ISOLATION via ScreenCaptureKit's
    /// desktop-independent filter, the same path CleanShot/macOS use. Unlike a
    /// screen-rect crop, this returns ONLY the target window's pixels with its
    /// real rounded corners as transparency (alpha), and is immune to
    /// anything stacked on top of it. The countdown gate and the full finishing
    /// (sound/flash/overlay/history) match the common path exactly. Falls back to
    /// the rect crop when SCK is unavailable or the window can't be resolved.
    @available(macOS 14.0, *)
    private func captureWindowIsolated(
        windowID: CGWindowID,
        rect: CGRect,
        on screen: NSScreen,
        historyManager: HistoryManager,
        attempt: CaptureAttempt
    ) async {
        let countdown = Settings.captureCountdownSeconds
        if countdown > 0 {
            guard !countdownActive else {
                abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
            let proceed = await runCountdown(countdown, on: screen)
            guard proceed else {
                abandonCaptureAttempt(attempt, historyManager: historyManager)
                return
            }
        }
        captureMoment(rect: rect, on: screen)

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
                abandonCaptureAttempt(attempt, historyManager: historyManager)
                if lastCaptureFailureWasPermission {
                    PermissionsManager.showPermissionDeniedAlert()
                } else {
                    ToastWindow.show(message: "Capture failed. Try again or check Screen Recording permission")
                }
                return
            }
            finishCapture(
                image: cropped,
                rect: rect,
                on: screen,
                historyManager: historyManager,
                isWindowCapture: true,
                attempt: attempt
            )
            return
        }
        finishCapture(
            image: image,
            rect: rect,
            on: screen,
            historyManager: historyManager,
            isWindowCapture: true,
            attempt: attempt
        )
    }

    /// Grabs `windowID` in isolation as an NSImage with native pixel density and
    /// transparent corners preserved (no scaling, no background).
    @available(macOS 14.0, *)
    private func isolatedWindowImage(windowID: CGWindowID) async -> NSImage? {
        lastCaptureFailureWasPermission = false
        do {
            let snapshot = try await ScreenCaptureCatalog.shared.windows(.visibleContent)
            let candidates = snapshot.windows.map {
                WindowCaptureDescriptor(
                    id: CGWindowID($0.windowID),
                    ownerProcessID: $0.owningApplication?.processID,
                    ownerBundleIdentifier: $0.owningApplication?.bundleIdentifier,
                    layer: $0.windowLayer,
                    frame: $0.frame,
                    title: $0.title
                )
            }
            guard let plan = WindowCaptureTargetResolver.capturePlan(
                selectedID: windowID,
                candidates: candidates
            ), let window = snapshot.window(id: plan.targetID) else {
                Self.captureLog.error("isolatedWindowImage: window \(windowID) not in shareable content; falling back")
                return nil
            }
            if plan.targetID != windowID {
                Self.captureLog.info(
                    "isolatedWindowImage: resolved shadow host \(windowID, privacy: .public) to content window \(plan.targetID, privacy: .public)"
                )
            }

            // Bring the target window forward so the grab catches it ACTIVE (colored
            // traffic lights, full-contrast chrome) instead of the dimmed inactive
            // look it fell into when KRIT's picker took focus. For another app,
            // activating it makes its front window key; for our own window, raise it
            // directly. A short settle lets the window server repaint the active
            // state before SCK reads the frame. KRIT regains focus when the editor
            // opens right after.
            if let pid = window.owningApplication?.processID {
                await MainActor.run {
                    if pid == ProcessInfo.processInfo.processIdentifier {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first { $0.windowNumber == Int(plan.targetID) }?.makeKeyAndOrderFront(nil)
                    } else {
                        NSRunningApplication(processIdentifier: pid)?.activate()
                    }
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let logicalSize = plan.logicalSize
            // Real backing scale of the display the window sits on, not
            // filter.pointPixelScale (which can report 2 on a 1x external display
            // and leave the grab anchored in a half-empty buffer). SCWindow.frame
            // is in CoreGraphics coords (top-left origin); convert its center to
            // AppKit to find the host NSScreen.
            let scale = screen(containing: window.frame)?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let config = SCStreamConfiguration()
            // Native pixel-exact grab: the buffer matches the window's on-screen
            // pixels. Screen content has no detail beyond the display's native
            // density, so upscaling it would only soften the result and bloat the
            // file, native is the sharpest a screen grab can be. scalesToFit stays
            // false so SCK never anchors the content inside a larger buffer.
            let pixelSize = plan.pixelSize(scale: scale, maxEdge: Self.maxCaptureEdge)
            config.width = pixelSize.width
            config.height = pixelSize.height
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            // The default opaque background would fill the rounded corners and
            // shadow region with black; a clear color keeps them transparent so
            // the editor composites the window over its generated background.
            config.backgroundColor = .clear
            // Drop the native window shadow from the grab. The template draws
            // its own shadow, so retaining the native one only doubles it.
            config.ignoreShadowsSingleWindow = true

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let normalized = WindowCaptureImageNormalizer.normalize(
                cgImage,
                logicalSize: logicalSize,
                bundleIdentifier: window.owningApplication?.bundleIdentifier
            )
            if normalized.didCrop {
                Self.captureLog.info(
                    "isolatedWindowImage: removed embedded transparent framing from \(cgImage.width)x\(cgImage.height) to \(normalized.image.width)x\(normalized.image.height)"
                )
            }
            return Self.nsImage(from: normalized.image, logicalSize: normalized.logicalSize)
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

    /// Test-only: resolves the live SCWindow and runs the exact chooser-preview
    /// path, including its bounded SCK retry and modern no-CoreGraphics rule.
    @available(macOS 14.0, *)
    func uiTestWindowPreviewImage(windowID: CGWindowID) async -> NSImage? {
        guard let snapshot = try? await ScreenCaptureCatalog.shared.windows(.allContent),
              let window = snapshot.window(id: windowID) else { return nil }
        return await windowPreviewImage(for: window)
    }

    /// Test-only: runs the FULL production window-shot flow (wallpaper refresh,
    /// isolated grab, finishCapture with compose + history add + overlay), so
    /// the harness can prove the presented PNG the user actually drags out, not
    /// just the individual links.
    @available(macOS 14.0, *)
    func uiTestFullWindowCapture(windowID: CGWindowID, rect: CGRect, on screen: NSScreen, historyManager: HistoryManager) async {
        guard let attempt = beginCaptureAttempt() else { return }
        historyManager.prepareForCapture()
        await captureWindowIsolated(
            windowID: windowID,
            rect: rect,
            on: screen,
            historyManager: historyManager,
            attempt: attempt
        )
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

    /// Grabs `rect` at the display's native pixel density (pixel-exact). There is
    /// no quality knob: the screen content has no detail past its native density,
    /// so the native grab is always the sharpest possible and any upscale would
    /// only soften it.
    func captureRectToImage(_ rect: CGRect, on screen: NSScreen, excludeDesktopIcons: Bool = false) async -> NSImage? {
        willCaptureScreenHook?()
        let screenshotManagerAvailable: Bool
        if #available(macOS 14.0, *) {
            screenshotManagerAvailable = true
        } else {
            screenshotManagerAvailable = false
        }
        let streamAvailable: Bool
        if #available(macOS 13.0, *) {
            streamAvailable = true
        } else {
            streamAvailable = false
        }

        switch ScreenImageCaptureBackend.resolve(
            excludeDesktopIcons: excludeDesktopIcons,
            screenshotManagerAvailable: screenshotManagerAvailable,
            streamAvailable: streamAvailable
        ) {
        case .screenshotManager:
            if #available(macOS 14.0, *) {
                return await captureRectSCK(rect, on: screen, excludeDesktopIcons: excludeDesktopIcons)
            }
        case .oneFrameStream:
            if #available(macOS 13.0, *) {
                return await captureRectStreamExcludingDesktopIcons(rect, on: screen)
            }
        case .coreGraphics:
            break
        }
        return fallbackCapture(rect: rect)
    }

    /// Ventura has ScreenCaptureKit streams and application filters, but not
    /// `SCScreenshotManager`. Use a single stream frame when Finder must be
    /// excluded so the Hide desktop icons preference is honored on macOS 13.
    @available(macOS 13.0, *)
    private func captureRectStreamExcludingDesktopIcons(_ rect: CGRect, on screen: NSScreen) async -> NSImage? {
        lastCaptureFailureWasPermission = false
        do {
            guard let screenID = ScreenCaptureCatalog.displayID(of: screen) else {
                Self.captureLog.error("captureRectStreamExcludingDesktopIcons: screen has no display ID; falling back")
                return fallbackCapture(rect: rect)
            }
            let snapshot = try await ScreenCaptureCatalog.shared.windows(.visibleContent)
            guard let display = snapshot.display(id: screenID) else {
                Self.captureLog.error("captureRectStreamExcludingDesktopIcons: no display matches screen \(screenID); falling back")
                return fallbackCapture(rect: rect)
            }

            let geometry = ScreenCaptureDisplayGeometry(
                displayID: display.displayID,
                appKitFrame: screen.frame,
                coreGraphicsFrame: display.frame,
                backingScale: max(screen.backingScaleFactor, 1)
            )
            let region = try geometry.sourceRegion(
                for: rect,
                evenPixelDimensions: false,
                maxEdge: Self.maxCaptureEdge
            )
            let config = SCStreamConfiguration()
            config.sourceRect = region.sourceRect
            config.width = region.pixelWidth
            config.height = region.pixelHeight
            config.scalesToFit = false
            config.showsCursor = false

            let filter = Self.captureContentFilter(
                display: display,
                snapshot: snapshot,
                excludeDesktopIcons: true
            )
            let cgImage = try await captureRectStream(filter: filter, configuration: config)
            return Self.nsImage(from: cgImage, logicalSize: region.appKitRect.size)
        } catch {
            let nsError = error as NSError
            Self.captureLog.error("captureRectStreamExcludingDesktopIcons failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                lastCaptureFailureWasPermission = true
                return nil
            }
            return fallbackCapture(rect: rect)
        }
    }

    /// Builds the capture filter, copying Snapzy's icon-hiding approach. To hide
    /// desktop icons we EXCLUDE the Finder application (its desktop-icon windows
    /// live on layer > 0) plus KRIT's own windows, and re-include normal Finder
    /// windows via exceptingWindows. The wallpaper is drawn by the Dock/Wallpaper
    /// Agent, NOT Finder, so it survives at its REAL (dark) appearance — no cover
    /// window painting a light fallback still. With icons shown, nothing excluded.
    @available(macOS 13.0, *)
    private static func captureContentFilter(display: SCDisplay, snapshot: ScreenCaptureWindowSnapshot, excludeDesktopIcons: Bool) -> SCContentFilter {
        guard excludeDesktopIcons else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        // Exclude ONLY Finder (the desktop-icon layer). KRIT's own app must NOT
        // be excluded: real windows (Preferences, editor, history) are content
        // the user screenshots too, and excluding the whole app made them vanish
        // from every capture whenever hide-desktop-icons was on. Capture chrome
        // (flash, HUD, overlay cards, selection UI) stays out of grabs through
        // sharingType .none on each window, same as in the default no-exclusion
        // path, so this filter needs no app-level carve-out for ourselves.
        let excludedApps = snapshot.applications.filter {
            $0.bundleIdentifier == "com.apple.finder"
        }
        guard !excludedApps.isEmpty else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        let keepFinderWindows = snapshot.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == 0 && $0.isOnScreen
        }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: keepFinderWindows)
    }

    @available(macOS 14.0, *)
    private func captureRectSCK(_ rect: CGRect, on screen: NSScreen, excludeDesktopIcons: Bool) async -> NSImage? {
        lastCaptureFailureWasPermission = false
        do {
            // Display lookup is always by ID. Intersecting `SCDisplay.frame` with
            // an AppKit rect compares opposite Y coordinate systems and can select
            // the wrong monitor.
            guard let screenID = ScreenCaptureCatalog.displayID(of: screen) else {
                Self.captureLog.error("captureRectSCK: screen has no display ID; falling back")
                return fallbackCapture(rect: rect)
            }

            let display: SCDisplay
            let filter: SCContentFilter
            if excludeDesktopIcons {
                let snapshot = try await ScreenCaptureCatalog.shared.windows(.visibleContent)
                guard let matched = snapshot.display(id: screenID) else {
                    Self.captureLog.error("captureRectSCK: no display matches screen \(screenID); falling back")
                    return fallbackCapture(rect: rect)
                }
                display = matched
                filter = Self.captureContentFilter(
                    display: matched,
                    snapshot: snapshot,
                    excludeDesktopIcons: true
                )
            } else {
                let snapshot = try await ScreenCaptureCatalog.shared.displays()
                guard let matched = snapshot.display(id: screenID) else {
                    Self.captureLog.error("captureRectSCK: no display matches screen \(screenID); falling back")
                    return fallbackCapture(rect: rect)
                }
                display = matched
                filter = SCContentFilter(display: matched, excludingWindows: [])
            }

            // Use the display's REAL backing scale, not filter.pointPixelScale.
            // Shared geometry keeps screenshots and recordings on the same pixel
            // grid, including 1x external displays and negative screen origins.
            let geometry = ScreenCaptureDisplayGeometry(
                displayID: display.displayID,
                appKitFrame: screen.frame,
                coreGraphicsFrame: display.frame,
                backingScale: max(screen.backingScaleFactor, 1)
            )
            let region = try geometry.sourceRegion(
                for: rect,
                evenPixelDimensions: false,
                maxEdge: Self.maxCaptureEdge
            )

            let config = SCStreamConfiguration()
            config.sourceRect = region.sourceRect
            config.width = region.pixelWidth
            config.height = region.pixelHeight
            // Native buffer == sourceRect pixels, so no fitting needed.
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            // Don't set colorSpaceName, SCK defaults to the display's native
            // calibrated ICC profile, preserving exact on-screen colors.
            // Forcing sRGB or Display P3 overrides the display calibration.

            let logicalSize = region.appKitRect.size
            Self.captureLog.info("captureRectSCK: rect=\(String(describing: rect)) scale=\(geometry.backingScale) sckRect=\(String(describing: region.sourceRect)) pixels=\(region.pixelWidth)x\(region.pixelHeight)")
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

    @available(macOS 13.0, *)
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

@available(macOS 13.0, *)
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
        sharingType = .none
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
        animateSpringEntrance()
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

    func closeChooser() {
        closeChooser(notify: true)
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
        sharingType = .none
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
        animateSpringEntrance()
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
private final class RecordingControlsWindow: NSWindow, NSWindowDelegate {

    private static var openWindows: [RecordingControlsWindow] = []
    private static let barHeight = RecordingPreflightLayout().shell.height
    private static let panelWidth = RecordingPreflightLayout().shell.width
    private static let chromeInset: CGFloat = 8

    private let captureRect: CGRect
    private let targetScreen: NSScreen
    private let target: RecordingTargetKind
    private let selectedWindow: SCWindow?
    private let startHandler: (CGRect, NSScreen, SCWindow?) -> Void
    private let closeHandler: () -> Void

    private var keyMonitor: Any?
    private var didClose = false

    private let systemAudioButton = RecordingToggleButton(
        symbol: "speaker.wave.2.fill",
        title: "Audio",
        accessibilityTitle: "System audio"
    )
    private let microphoneButton = RecordingToggleButton(
        symbol: "mic.fill",
        title: "Mic",
        accessibilityTitle: "Microphone"
    )
    private let cameraButton = RecordingToggleButton(symbol: "video.fill", title: "Camera")
    private let cursorButton = RecordingToggleButton(symbol: "cursorarrow.rays", title: "Cursor")
    private let optionsButton = RecordingChromeButton(
        symbol: "slider.horizontal.3",
        title: "Recording options",
        role: .neutral,
        presentation: .horizontal
    )
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneLevelMeter = RecordingLevelMeter()
    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let optionsPopover = NSPopover()
    private var microphoneMonitorSession: AVCaptureSession?
    private var microphoneMonitorOutput: AVCaptureAudioDataOutput?
    private var microphoneMonitorDelegate: MicrophoneLevelMonitor?
    private var microphoneMonitorEpoch = MicrophoneMonitorEpoch()
    private let microphoneMeterQueue = DispatchQueue(
        label: "com.krit.recording.mic-meter",
        qos: .userInteractive
    )
    private let microphoneMonitorSessionQueue = DispatchQueue(
        label: "com.krit.recording.preflight-microphone-session",
        qos: .userInitiated
    )

    init(rect: CGRect, screen: NSScreen, target: RecordingTargetKind, selectedWindow: SCWindow?, startHandler: @escaping (CGRect, NSScreen, SCWindow?) -> Void, closeHandler: @escaping () -> Void) {
        self.captureRect = rect
        self.targetScreen = screen
        self.target = target
        self.selectedWindow = selectedWindow
        self.startHandler = startHandler
        self.closeHandler = closeHandler

        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.panelWidth + Self.chromeInset * 2,
                height: Self.barHeight + Self.chromeInset * 2
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        sharingType = .none
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        delegate = self
        NSApp.addActivationPersistentWindow(self)

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
        alphaValue = 1
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
    }

    private func buildContent() {
        let layout = RecordingPreflightLayout()
        let screenScale = targetScreen.backingScaleFactor
        let root = RecordingPanelContentView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.contentsScale = screenScale
        contentView = root

        let barFrame = NSRect(
            x: Self.chromeInset,
            y: Self.chromeInset,
            width: layout.shell.width,
            height: layout.shell.height
        )
        let barGlass = ChromeFactory.backing(
            frame: barFrame,
            cornerRadius: RecordingChrome.preflightShellRadius,
            variant: .regular
        )
        let barShadowHost = NSView(frame: barFrame)
        barShadowHost.wantsLayer = true
        barShadowHost.layer?.shadowColor = NSColor.black.cgColor
        barShadowHost.layer?.shadowOpacity = RecordingChrome.overlayShadow.opacity
        barShadowHost.layer?.shadowRadius = RecordingChrome.overlayShadow.radius
        barShadowHost.layer?.shadowOffset = RecordingChrome.overlayShadow.offset
        barShadowHost.layer?.shadowPath = CGPath(
            roundedRect: barGlass.bounds,
            cornerWidth: RecordingChrome.preflightShellRadius,
            cornerHeight: RecordingChrome.preflightShellRadius,
            transform: nil
        )
        root.addSubview(barShadowHost)
        root.addSubview(barGlass)

        let barScrim = NSView(frame: barFrame)
        barScrim.wantsLayer = true
        barScrim.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(RecordingChrome.effectiveContrastFloorAlpha)
            .cgColor
        barScrim.layer?.cornerRadius = RecordingChrome.preflightShellRadius
        barScrim.layer?.cornerCurve = .continuous
        root.addSubview(barScrim)

        let bar = RecordingPanelContentView(frame: barFrame)
        root.addSubview(bar)

        let sourcePill = pillLabel("\(target.title) · \(Int(captureRect.width)) × \(Int(captureRect.height))", symbol: target.symbol)
        sourcePill.frame = layout.source
        sourcePill.identifier = NSUserInterfaceItemIdentifier("recording.preflight.source")
        bar.addSubview(sourcePill)

        let sectionDividers: [(String, CGFloat)] = [
            ("source", 188),
            ("toggles", 404),
            ("options", 548),
        ]
        for (name, x) in sectionDividers {
            let divider = RecordingChrome.makeSectionDivider(
                identifier: "recording.preflight.section-divider.\(name)"
            )
            divider.frame = NSRect(x: x - 0.5, y: 20, width: 1, height: 32)
            bar.addSubview(divider)
        }

        let toggleRailFrame = layout.toggles.dropFirst().reduce(layout.toggles[0]) { partial, frame in
            partial.union(frame)
        }
        let toggleRail = RecordingToggleRail(frame: toggleRailFrame)
        toggleRail.identifier = NSUserInterfaceItemIdentifier("recording.preflight.toggle-rail")
        toggleRail.wantsLayer = true
        toggleRail.layer?.backgroundColor = NSColor.clear.cgColor
        bar.addSubview(toggleRail)
        for index in 1..<layout.toggles.count {
            let divider = NSView(
                frame: NSRect(
                    x: layout.toggles[index].minX - toggleRailFrame.minX,
                    y: 16,
                    width: 1,
                    height: 24
                )
            )
            divider.identifier = NSUserInterfaceItemIdentifier("recording.preflight.toggle-divider.\(index)")
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white
                .withAlphaComponent(RecordingChrome.sectionDividerAlpha)
                .cgColor
            toggleRail.addSubview(divider)
        }

        let toggleButtons = [systemAudioButton, microphoneButton, cursorButton, cameraButton]
        let toggleIdentifiers = [
            "recording.preflight.system-audio",
            "recording.preflight.microphone",
            "recording.preflight.cursor",
            "recording.preflight.camera",
        ]
        for (index, button) in toggleButtons.enumerated() {
            let identifier = toggleIdentifiers[index]
            button.frame = layout.toggles[index]
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.setAccessibilityIdentifier(identifier)
            button.target = self
            button.action = #selector(toggleChanged(_:))
            bar.addSubview(button)
        }

        microphoneLevelMeter.frame = NSRect(
            x: layout.toggles[1].midX - 11,
            y: layout.toggles[1].minY + 6,
            width: 22,
            height: 8
        )
        microphoneLevelMeter.isHidden = true
        bar.addSubview(microphoneLevelMeter)

        optionsButton.frame = layout.options
        optionsButton.identifier = NSUserInterfaceItemIdentifier("recording.preflight.options")
        optionsButton.setAccessibilityIdentifier("recording.preflight.options")
        optionsButton.target = self
        optionsButton.action = #selector(optionsTapped)
        bar.addSubview(optionsButton)

        let recordButton = RecordingChromeButton(
            symbol: "record.circle",
            title: "Record",
            role: .primary,
            presentation: .horizontal
        )
        recordButton.frame = layout.record
        recordButton.identifier = NSUserInterfaceItemIdentifier("recording.preflight.record")
        recordButton.setAccessibilityIdentifier("recording.preflight.record")
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        bar.addSubview(recordButton)

        let cancelButton = RecordingChromeButton(
            symbol: "xmark",
            title: "Cancel",
            role: .neutral,
            presentation: .glyph
        )
        cancelButton.frame = layout.cancel
        cancelButton.identifier = NSUserInterfaceItemIdentifier("recording.preflight.cancel")
        cancelButton.setAccessibilityIdentifier("recording.preflight.cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        bar.addSubview(cancelButton)

        buildOptionsPopover()
        syncFromSettings()
    }

    private func buildOptionsPopover() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 216))
        content.wantsLayer = true

        let heading = NSTextField(labelWithString: "Recording Options")
        heading.font = KritType.heading.nsFont
        heading.frame = NSRect(x: 20, y: 176, width: 296, height: 22)
        content.addSubview(heading)

        configurePopup(qualityPopup, items: [("Balanced", "balanced"), ("High", "high"), ("Max", "max")])
        configurePopup(fpsPopup, items: [("30 fps", "30"), ("60 fps", "60")])
        configureDevicePopup(microphonePopup, accessibilityLabel: "Microphone device")
        configureDevicePopup(cameraPopup, accessibilityLabel: "Camera device")

        addOptionsRow(title: "Quality", control: qualityPopup, y: 136, to: content)
        addOptionsRow(title: "Frame rate", control: fpsPopup, y: 96, to: content)
        addOptionsRow(title: "Microphone", control: microphonePopup, y: 56, to: content)
        addOptionsRow(title: "Camera", control: cameraPopup, y: 16, to: content)

        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraDeviceChanged)

        let controller = NSViewController()
        controller.view = content
        optionsPopover.contentViewController = controller
        optionsPopover.behavior = .transient
        optionsPopover.animates = !Motion.reduced
    }

    private func addOptionsRow(title: String, control: NSControl, y: CGFloat, to content: NSView) {
        let field = NSTextField(labelWithString: title)
        field.font = KritType.body.nsFont
        field.textColor = .secondaryLabelColor
        field.frame = NSRect(x: 20, y: y + 5, width: 96, height: 20)
        content.addSubview(field)

        control.frame = NSRect(x: 120, y: y, width: 196, height: 28)
        control.setAccessibilityLabel(title)
        content.addSubview(control)
    }

    private func configureDevicePopup(_ popup: NSPopUpButton, accessibilityLabel: String) {
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.font = KritType.callout.nsFont
        popup.setAccessibilityLabel(accessibilityLabel)
    }

    private func syncFromSettings() {
        systemAudioButton.isOn = Settings.recordingSystemAudio
        microphoneButton.isOn = Settings.recordingMicrophone
        cameraButton.isOn = Settings.recordingWebcam
        cursorButton.isOn = Settings.recordingShowsCursor
        selectItem(in: qualityPopup, representedObject: Settings.recordingQuality)
        selectItem(in: fpsPopup, representedObject: String(Settings.recordingFPS))
        updateDeviceVisibility()
        updateOptionsSummary()
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
        microphoneLevelMeter.isHidden = !Settings.recordingMicrophone
        microphonePopup.isEnabled = Settings.recordingMicrophone
        if Settings.recordingMicrophone {
            startMicrophoneMonitorIfNeeded()
        } else {
            stopMicrophoneMonitor()
            microphoneLevelMeter.setLevel(0)
        }
        cameraPopup.isEnabled = Settings.recordingWebcam
    }

    private func startMicrophoneMonitorIfNeeded() {
        guard !didClose, microphoneMonitorSession == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureMicrophoneMonitor()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, !self.didClose else { return }
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
        guard !didClose,
              microphoneMonitorSession == nil,
              let device = RecordingMicrophoneDeviceProvider.device(for: Settings.recordingMicrophoneDeviceID) else { return }
        do {
            let session = AVCaptureSession()
            session.beginConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecordingControlsError.cannotMonitorMicrophone }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            guard session.canAddOutput(output) else { throw RecordingControlsError.cannotMonitorMicrophone }
            let token = microphoneMonitorEpoch.begin()
            let delegate = MicrophoneLevelMonitor { [weak self] level in
                guard let self,
                      !self.didClose,
                      self.microphoneMonitorEpoch.accepts(token) else { return }
                self.microphoneLevelMeter.setLevel(level)
            }
            output.setSampleBufferDelegate(delegate, queue: microphoneMeterQueue)
            session.addOutput(output)
            session.commitConfiguration()

            microphoneMonitorSession = session
            microphoneMonitorOutput = output
            microphoneMonitorDelegate = delegate
            runMicrophoneMonitorSession(session, start: true)
        } catch {
            microphoneLevelMeter.setLevel(0)
            print("[KRIT] Microphone meter failed: \(error)")
        }
    }

    private func stopMicrophoneMonitor() {
        microphoneMonitorEpoch.invalidate()
        let output = microphoneMonitorOutput
        let session = microphoneMonitorSession
        output?.setSampleBufferDelegate(nil, queue: nil)
        microphoneMonitorSession = nil
        microphoneMonitorOutput = nil
        microphoneMonitorDelegate = nil
        microphoneLevelMeter.setLevel(0)
        if let session {
            runMicrophoneMonitorSession(session, start: false)
        }
    }

    private func runMicrophoneMonitorSession(_ session: AVCaptureSession, start: Bool) {
        // AVFoundation predates Swift concurrency. This session is fully
        // configured before it crosses into the one serial queue that owns its
        // start/stop calls, so the non-Sendable bridge cannot race another
        // session operation.
        nonisolated(unsafe) let session = session
        microphoneMonitorSessionQueue.async {
            if start {
                session.startRunning()
            } else {
                session.stopRunning()
            }
        }
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, String)]) {
        popup.removeAllItems()
        popup.bezelStyle = .rounded
        popup.isBordered = true
        popup.controlSize = .small
        popup.font = KritType.callout.nsFont
        for item in items {
            popup.addItem(withTitle: item.0)
            popup.lastItem?.representedObject = item.1
        }
    }

    @discardableResult
    private func selectItem(in popup: NSPopUpButton, representedObject: String) -> Bool {
        for item in popup.itemArray where item.representedObject as? String == representedObject {
            popup.select(item)
            return true
        }
        return false
    }

    private func pillLabel(_ text: String, symbol: String) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Recording source: \(text)")

        let icon = NSImageView(frame: NSRect(x: 16, y: 20, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .white.withAlphaComponent(0.86)
        view.addSubview(icon)

        let textField = NSTextField(labelWithString: text)
        textField.font = KritType.bodyEmphasis.nsFont
        textField.textColor = NSColor.white.withAlphaComponent(0.9)
        textField.frame = NSRect(x: 40, y: 19, width: 128, height: 18)
        textField.lineBreakMode = .byTruncatingTail
        view.addSubview(textField)
        return view
    }

    private func positionPanel() {
        let visible = targetScreen.visibleFrame
        let visibleHeight = Self.barHeight
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
        optionsPopover.close()
        stopMicrophoneMonitor()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        NSApp.removeActivationPersistentWindow(self)
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

    func windowWillClose(_ notification: Notification) {
        closePanel()
    }

    @objc private func toggleChanged(_ sender: RecordingToggleButton) {
        sender.commitControlState()
        switch sender {
        case systemAudioButton:
            Settings.recordingSystemAudio = sender.isOn
        case microphoneButton:
            Settings.recordingMicrophone = sender.isOn
            updateDeviceVisibility()
        case cameraButton:
            Settings.recordingWebcam = sender.isOn
            if sender.isOn {
                ensureCameraPermission()
            }
            updateDeviceVisibility()
        case cursorButton:
            Settings.recordingShowsCursor = sender.isOn
        default:
            break
        }
        updateOptionsSummary()
    }

    @objc private func optionsTapped() {
        if optionsPopover.isShown {
            optionsPopover.close()
            return
        }

        reloadMicrophones()
        reloadCameras()
        selectItem(in: microphonePopup, representedObject: Settings.recordingMicrophoneDeviceID)
        selectItem(in: cameraPopup, representedObject: Settings.recordingWebcamDeviceID)
        microphonePopup.isEnabled = Settings.recordingMicrophone
        cameraPopup.isEnabled = Settings.recordingWebcam
        optionsPopover.show(relativeTo: optionsButton.bounds, of: optionsButton, preferredEdge: .maxY)
    }

    private func updateOptionsSummary() {
        let quality = Settings.recordingQuality.capitalized
        let summary = "\(quality) · \(Settings.recordingFPS) fps"
        optionsButton.title = summary
        optionsButton.toolTip = "Recording options · \(summary)"
        optionsButton.setAccessibilityLabel("Recording options: \(summary)")
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
        guard let selected = cameraPopup.selectedItem else { return }
        Settings.recordingWebcamDeviceID = selected.representedObject as? String ?? ""
    }

    @objc private func qualityChanged() {
        if let value = qualityPopup.selectedItem?.representedObject as? String {
            Settings.recordingQuality = value
            updateOptionsSummary()
        }
    }

    @objc private func fpsChanged() {
        if let value = fpsPopup.selectedItem?.representedObject as? String, let fps = Int(value) {
            Settings.recordingFPS = fps
            updateOptionsSummary()
        }
    }

    @objc private func microphoneChanged() {
        guard let selected = microphonePopup.selectedItem else { return }
        Settings.recordingMicrophoneDeviceID = selected.representedObject as? String ?? ""
        if Settings.recordingMicrophone {
            stopMicrophoneMonitor()
            startMicrophoneMonitorIfNeeded()
        }
    }

    @objc private func recordTapped() {
        qualityChanged()
        fpsChanged()
        if microphonePopup.selectedItem != nil { microphoneChanged() }
        if cameraPopup.selectedItem != nil { cameraDeviceChanged() }
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

struct MicrophoneLevelDeliveryGate {
    private let minimumInterval: TimeInterval
    private var lastDelivery: TimeInterval?

    init(maximumUpdatesPerSecond: Double = 30) {
        precondition(maximumUpdatesPerSecond > 0)
        minimumInterval = 1 / maximumUpdatesPerSecond
    }

    mutating func shouldDeliver(at now: TimeInterval) -> Bool {
        guard let lastDelivery else {
            self.lastDelivery = now
            return true
        }
        guard now - lastDelivery >= minimumInterval else { return false }
        self.lastDelivery = now
        return true
    }
}

struct MicrophoneMonitorEpoch {
    private(set) var value: UInt64 = 0

    mutating func begin() -> UInt64 {
        value &+= 1
        return value
    }

    mutating func invalidate() {
        value &+= 1
    }

    func accepts(_ token: UInt64) -> Bool {
        value == token
    }
}

private enum RecordingMicrophoneDeviceProvider {
    static var options: [RecordingMicrophoneOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
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
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class RecordingToggleButton: RecordingChromeButton {

    private let activeIndicator = NSView()

    var isOn: Bool = false {
        didSet {
            let expectedState: NSControl.StateValue = isOn ? .on : .off
            if state != expectedState {
                state = expectedState
            }
            setToggleState(isOn)
            updateActiveIndicator()
        }
    }

    init(symbol: String, title: String, accessibilityTitle: String? = nil) {
        super.init(
            symbol: symbol,
            title: title,
            role: .neutral,
            presentation: .vertical,
            chromeStyle: .groupedToggle
        )
        if let accessibilityTitle {
            setAccessibilityLabel(accessibilityTitle)
            toolTip = accessibilityTitle
        }
        setButtonType(.toggle)
        activeIndicator.wantsLayer = true
        activeIndicator.layer?.cornerRadius = 1.5
        activeIndicator.layer?.cornerCurve = .continuous
        activeIndicator.layer?.backgroundColor = KritColors.accent.cgColor
        addSubview(activeIndicator)
        setToggleState(false)
        updateActiveIndicator()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        activeIndicator.frame = NSRect(
            x: (bounds.width - 14) / 2,
            y: 5,
            width: 14,
            height: 3
        )
    }

    func commitControlState() {
        isOn = state == .on
    }

    private func updateActiveIndicator() {
        activeIndicator.isHidden = !isOn
    }
}

@MainActor
private final class RecordingToggleRail: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MicrophoneLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private let levelHandler: @MainActor (CGFloat) -> Void
    private var deliveryGate = MicrophoneLevelDeliveryGate()

    init(levelHandler: @escaping @MainActor (CGFloat) -> Void) {
        self.levelHandler = levelHandler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard deliveryGate.shouldDeliver(at: now) else { return }
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
