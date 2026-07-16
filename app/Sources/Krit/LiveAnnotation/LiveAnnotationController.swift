import AppKit

/// Live Screen Annotation: ZoomIt-style "draw on top of your screen right now"
/// mode, distinct from the screenshot editor's `AnnotationCanvas` (which draws
/// over a captured bitmap). Here the ink floats over the REAL, live desktop, so
/// a presenter can circle something in another app without ever taking a shot.
///
/// State machine:
///   - `.off`:     nothing on screen, no windows exist.
///   - `.drawing`: the overlay accepts mouse input (crosshair, tools live) and
///                 owns the keyboard (Esc, ⌘Z) via a non-activating key panel,
///                 exactly like `AreaSelectionWindow`'s selection overlay.
///   - `.passive`: the ink stays on screen exactly as drawn, but the overlay
///                 window ignores mouse events and hands keyboard focus back,
///                 so the presenter's own apps get mouse and keyboard again
///                 immediately — the click-through trick `PresentationZoomController`
///                 uses for its magnifier, applied to a static drawing instead
///                 of a live magnified frame.
///
/// `toggleDrawMode()` is the hotkey entry point: off engages fresh, drawing
/// steps back to passive, passive re-arms drawing. Esc (handled by the surface
/// view) and the toolbar's close button both call `exitDrawModeKeepingAnnotations()`
/// / `deactivate(clearing:)` respectively — see their doc comments for the
/// difference between "step back but keep everything" and "tear down, remember
/// the ink for next time."
@MainActor
final class LiveAnnotationController {

    enum Mode {
        case off
        case drawing
        case passive
    }

    private(set) var mode: Mode = .off
    var isActive: Bool { mode != .off }

    /// Ink count for automation/introspection (`UIIntrospection.snapshot`): the
    /// live surface view's objects while on screen, or the persisted count while
    /// `.off` (the ink a future `toggleDrawMode()` would resume with).
    var annotationObjectCount: Int {
        overlayWindow?.surfaceView.objects.count ?? persistedObjects.count
    }

    /// Integration hooks, wired by the app delegate once this feature is wired
    /// up. Declared here (per spec) with their real types; this file never
    /// calls into `captureEngine` itself — the toolbar's camera button only
    /// fires `onCaptureRequested`, and the actual capture call is the
    /// integrator's job. `presentationZoom` IS used below: engaging live
    /// annotation exits any active presentation zoom first, the same way every
    /// capture entry point in AppDelegate calls `presentationZoom.exitForCapture()`
    /// before it starts — two full-screen `.screenSaver`-level overlays at once
    /// (a magnified live frame and a drawing surface) would fight for the same
    /// pixels and neither reads as intentional.
    weak var captureEngine: CaptureEngine?
    weak var presentationZoom: PresentationZoomController?

    /// Fired when the toolbar's camera button is pressed. The controller does
    /// not reach into `captureEngine` itself for this (see above); the caller
    /// decides what "capture" means here (e.g. shoot the annotated screen).
    var onCaptureRequested: (() -> Void)?

    private var overlayWindow: LiveAnnotationOverlayWindow?
    private var toolbarWindow: LiveAnnotationToolbarWindow?
    private var anchorScreen: NSScreen?

    /// Whoever was frontmost before we borrowed the keyboard, so leaving
    /// drawing hands focus back by ACTIVATING that app — the same pattern
    /// `QuickAccessOverlay.grabKey()/releaseKey()` uses, with the same reason:
    /// calling `NSWindow.resignKey()` directly is documented as forbidden and
    /// leaves `NSApp.keyWindow` pointing at a window that silently refuses to
    /// become key again.
    private var borrowedFromApp: NSRunningApplication?

    /// Survives a `deactivate(clearing: false)` so the next `toggleDrawMode()`
    /// resumes exactly where the presenter left off instead of starting blank.
    private var persistedObjects: [any AnnotationObject] = []

    private var screenChangeObserver: Any?

    init() {
        // Mirrors PresentationZoomController: a display reconfiguring while
        // engaged invalidates the anchor screen's geometry wholesale, so bail
        // out cleanly instead of animating stale coordinates.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.abortForScreenChange() }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    // MARK: - Public state machine

    /// Global-hotkey entry point. Safe to invoke repeatedly from the same
    /// shortcut: off engages fresh on the screen under the cursor, drawing
    /// steps back to a click-through passive view, passive re-arms drawing on
    /// the same anchored screen.
    func toggleDrawMode() {
        switch mode {
        case .off:     engage()
        case .drawing: exitDrawModeKeepingAnnotations()
        case .passive: enterDrawing()
        }
    }

    /// Steps out of interactive drawing (Esc, or the toolbar's close button)
    /// while leaving every mark on screen: the overlay goes click-through and
    /// gives the keyboard back immediately, but nothing is torn down.
    func exitDrawModeKeepingAnnotations() {
        guard mode == .drawing else { return }
        // Commit any in-progress text first so a mark the user just typed counts
        // toward "is anything drawn?" below.
        overlayWindow?.surfaceView.commitTextField()
        // Spec: leaving draw mode with nothing on screen tears everything down
        // rather than parking an empty click-through overlay and toolbar.
        if overlayWindow?.surfaceView.objects.isEmpty ?? true {
            deactivate(clearing: true)
        } else {
            enterPassive()
        }
    }

    /// Fully removes the overlay and toolbar. `clearing: true` also wipes the
    /// ink, so the next `toggleDrawMode()` starts blank; `false` keeps it in
    /// memory so re-engaging resumes the same drawing (the toolbar's close
    /// button uses `false` — closing the chrome isn't the same as discarding
    /// work, that's what the trash button is for).
    func deactivate(clearing: Bool) {
        guard mode != .off else { return }
        if let view = overlayWindow?.surfaceView {
            view.commitTextField()
            persistedObjects = clearing ? [] : view.objects
        } else if clearing {
            persistedObjects = []
        }
        if let overlayWindow {
            NSApp.removeActivationPersistentWindow(overlayWindow)
        }
        releaseKey()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        toolbarWindow?.orderOut(nil)
        toolbarWindow = nil
        anchorScreen = nil
        mode = .off
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    // MARK: - Engage / transitions

    private func engage() {
        guard mode == .off else { return }
        guard let screen = screenUnderCursor() else { return }
        presentationZoom?.exitForCapture()

        anchorScreen = screen
        buildOverlay(on: screen)
        buildToolbar(on: screen)
        overlayWindow?.surfaceView.objects = persistedObjects
        mode = .drawing
        grabKeyAndMouse()
    }

    private func enterPassive() {
        guard mode == .drawing else { return }
        overlayWindow?.surfaceView.commitTextField()
        // Drop any selection so a dashed selection outline never lingers over
        // the live desktop while the ink is meant to look clean.
        overlayWindow?.surfaceView.setSelection([])
        overlayWindow?.ignoresMouseEvents = true
        // Passive is a chrome-free viewing state (spec: "toolbar hides"); the
        // ink stays, the controls go.
        toolbarWindow?.orderOut(nil)
        mode = .passive
        if let overlayWindow {
            NSApp.removeActivationPersistentWindow(overlayWindow)
        }
        releaseKey()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    private func enterDrawing() {
        guard mode == .passive else { return }
        // Same mutex as engage(): two full-screen `.screenSaver`-level overlays
        // (a live magnified frame and this drawing surface) must never be up at
        // once, so re-arming drawing drops any active presentation zoom too.
        presentationZoom?.exitForCapture()
        toolbarWindow?.orderFrontRegardless()
        mode = .drawing
        grabKeyAndMouse()
    }

    private func abortForScreenChange() {
        guard isActive else { return }
        deactivate(clearing: false)
    }

    private func grabKeyAndMouse() {
        overlayWindow?.ignoresMouseEvents = false
        if let overlayWindow {
            NSApp.addActivationPersistentWindow(overlayWindow)
        }
        grabKey()
        overlayWindow?.makeKeyAndOrderFront(nil)
        if let view = overlayWindow?.surfaceView {
            overlayWindow?.makeFirstResponder(view)
        }
        ensureKeyGrab(remaining: [0.05, 0.15, 0.30, 0.50])
    }

    /// macOS 14+ cooperative activation can silently no-op an `activate()` issued
    /// right after a recent deactivate — exactly the passive→drawing re-arm,
    /// which follows `enterPassive()`'s `releaseKey()`. When it does, the panel
    /// never becomes key and Esc/⌘Z go dead until the user clicks the surface.
    /// Re-assert on the same short ladder `QuickAccessOverlay.grabKey()` uses,
    /// stopping as soon as the panel actually holds key.
    private func ensureKeyGrab(remaining: [TimeInterval]) {
        guard let delay = remaining.first else { return }
        guard mode == .drawing, let window = overlayWindow, !window.isKeyWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.mode == .drawing,
                  let window = self.overlayWindow, !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.surfaceView)
            self.ensureKeyGrab(remaining: Array(remaining.dropFirst()))
        }
    }

    // MARK: - Window building

    private func buildOverlay(on screen: NSScreen) {
        let window = LiveAnnotationOverlayWindow(screenFrame: screen.frame)
        // Resume the tool/color/width remembered from the last activation
        // (this session or a previous launch) instead of always starting
        // back at the surface view's hardcoded arrow/accent/medium defaults.
        window.surfaceView.activeTool = Settings.liveAnnotationDefaultTool
        window.surfaceView.activeColor = Settings.liveAnnotationDefaultColor
        window.surfaceView.activeLineWidth = CGFloat(Settings.liveAnnotationDefaultWidth)
        window.surfaceView.onRequestExitDrawMode = { [weak self] in
            self?.exitDrawModeKeepingAnnotations()
        }
        window.surfaceView.onUndoStateChanged = { [weak self] canUndo, canRedo in
            self?.toolbarWindow?.setUndoRedoEnabled(canUndo: canUndo, canRedo: canRedo)
        }
        window.orderFrontRegardless()
        overlayWindow = window
    }

    private func buildToolbar(on screen: NSScreen) {
        let toolbar = LiveAnnotationToolbarWindow()
        // Mirror the surface view's restored tool/color/width (buildOverlay)
        // in the chrome's button highlights, so the toolbar never shows the
        // stale arrow/accent/medium selection its own init() hardcodes.
        toolbar.syncInitialSelection(
            tool: Settings.liveAnnotationDefaultTool,
            color: Settings.liveAnnotationDefaultColor,
            width: CGFloat(Settings.liveAnnotationDefaultWidth)
        )
        toolbar.onToolSelected = { [weak self] tool in
            guard let self else { return }
            self.overlayWindow?.surfaceView.activeTool = tool
            Settings.liveAnnotationDefaultTool = tool
            // Picking a tool from the toolbar while passively viewing the ink
            // reads as "I want to draw again" — re-arm interaction instead of
            // silently ignoring the click.
            if self.mode == .passive { self.enterDrawing() }
        }
        toolbar.onColorSelected = { [weak self] color in
            self?.overlayWindow?.surfaceView.activeColor = color
            Settings.liveAnnotationDefaultColor = color
        }
        toolbar.onWidthSelected = { [weak self] width in
            self?.overlayWindow?.surfaceView.activeLineWidth = width
            Settings.liveAnnotationDefaultWidth = Double(width)
        }
        toolbar.onUndo = { [weak self] in self?.overlayWindow?.surfaceView.performUndo() }
        toolbar.onRedo = { [weak self] in self?.overlayWindow?.surfaceView.performRedo() }
        toolbar.onToggleVisibility = { [weak self] in self?.toggleInkVisibility() }
        toolbar.onClearAll = { [weak self] in self?.overlayWindow?.surfaceView.clearAll() }
        toolbar.onCaptureRequested = { [weak self] in self?.onCaptureRequested?() }
        // Settings.liveAnnotationKeepOnExit governs whether closing the
        // chrome remembers the drawing for next time or wipes it.
        toolbar.onClose = { [weak self] in self?.deactivate(clearing: !Settings.liveAnnotationKeepOnExit) }
        toolbar.showAnchored(on: screen)
        toolbarWindow = toolbar
    }

    /// Automation hook (`live-annotation --action seed-ink`): only meaningful
    /// while drawing, where the surface view exists to receive the stroke.
    func seedTestInk() {
        guard mode == .drawing else { return }
        overlayWindow?.surfaceView.seedTestInk()
    }

    private func toggleInkVisibility() {
        guard let view = overlayWindow?.surfaceView else { return }
        view.inkVisible.toggle()
        toolbarWindow?.setInkVisible(view.inkVisible)
    }

    // MARK: - Key borrowing

    /// Escalates to `.accessory` and activates so the non-activating overlay
    /// panel starts receiving keys, mirroring `QuickAccessOverlay.grabKey()`.
    /// Only remembers the previously-frontmost app when KRIT wasn't already
    /// active, so a rapid drawing⇄passive⇄drawing cycle never overwrites the
    /// real "app to hand back to" with KRIT itself.
    private func grabKey() {
        if !NSApp.isActive {
            borrowedFromApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hands focus back by ACTIVATING the borrowed-from app instead of calling
    /// `resignKey()` directly (forbidden by the docs) or bare `NSApp.deactivate()`
    /// with no target — either leaves `NSApp.keyWindow` in a zombie state where
    /// later `makeKeyAndOrderFront` calls silently no-op.
    private func releaseKey() {
        let previous = borrowedFromApp
        borrowedFromApp = nil
        if let previous, !previous.isTerminated,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate()
        } else {
            NSApp.deactivate()
        }
    }

    // MARK: - Anchor screen

    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
