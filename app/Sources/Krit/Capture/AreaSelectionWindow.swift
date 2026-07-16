import AppKit

enum SelectionMode { case area, window, colorPick }

/// Full-screen translucent overlay that lets the user drag-select a region.
/// In `.window` mode it highlights the window under the cursor instead. In
/// `.colorPick` mode a click samples the pixel under the loupe and reports
/// its hex through `onColorPicked` (the rect completion only fires on cancel).
@MainActor
final class AreaSelectionWindow: NSObject {

    // Completion: selected rect in screen coordinates (AppKit, bottom-left), or
    // nil if cancelled. In `.window` mode the third argument carries the
    // CGWindowID under the cursor so the caller can grab that window in
    // isolation (SCK) instead of recropping the screen rect.
    typealias Completion = (CGRect?, NSScreen, CGWindowID?) -> Void

    /// `.colorPick` success path: the sampled pixel as "#RRGGBB".
    var onColorPicked: ((String) -> Void)?

    private let mode: SelectionMode
    private let completion: Completion
    private var overlays: [SelectionOverlayWindow] = []
    private var activeOverlay: SelectionOverlayWindow?
    /// The frozen crop latched by `finish()` right before `tearDown()` empties
    /// `overlays`. The completion fires 0.08s AFTER teardown, so reading the crop
    /// lazily from the overlays there always came back nil and the engine fell to
    /// the live re-grab, the fast path was dead. One-shot: consumed on first read.
    private var pendingFrozenCrop: NSImage?
    /// The app that was frontmost before `prepareAndShow` activated KRIT to raise
    /// the overlay. On cancel we hand activation straight back to it: leaving KRIT
    /// "active but .prohibited" (what `tearDown` does with nothing left on screen)
    /// made macOS throttle KRIT's NEXT activation, so re-pressing the capture
    /// hotkey right after Esc felt laggy and the overlay barely held focus. Nil
    /// when KRIT itself was already frontmost, so we never steal focus back to it.
    private weak var appToRestoreOnCancel: NSRunningApplication?
    private var pendingCompletion: DispatchWorkItem?
    private var didFinish = false
    private var didCancel = false
    private var cursorPushed = false

    init(mode: SelectionMode, completion: @escaping Completion) {
        self.mode = mode
        self.completion = completion
    }

    private var keyMonitor: Any?

    func prepareAndShow(
        engine: CaptureEngine,
        canPresent: @escaping () -> Bool = { true }
    ) async {
        AreaSelectionDiag.mark("prepareEntry")

        // Freeze each display's desktop FIRST, before activating KRIT or raising
        // the overlay. Two reasons, both proven on a video (aerial) wallpaper:
        //   1. Activating KRIT and covering the screen with the full-screen panel
        //      make macOS pause the wallpaper video and fall back to its still
        //      poster frame, which on a dynamic light/dark wallpaper is the LIGHT
        //      variant — that was the "screen flips to light on selection" bug.
        //      Grabbing first catches the live DARK desktop the user actually has.
        //   2. The grab does not exclude KRIT's own windows, so once the overlay
        //      (now an opaque backdrop) is up the freeze would capture the overlay
        //      ITSELF — a black frame — painting the backdrop black forever.
        // Captured in parallel at native scale so the hotkey-to-overlay latency
        // stays small; the overlay opens already backed by a real frozen frame.
        // If a grab fails the overlay falls back to the original near-transparent
        // tint (see drawFrozenBackdrop), never a dead black panel.
        let screens = NSScreen.screens
        // Hide desktop icons the Snapzy way: exclude Finder from the SCK grab, so
        // the frozen frame is the real dark wallpaper WITHOUT icons — and without a
        // light cover window. Color-pick keeps icons (it samples the screen as-is).
        let excludeIcons = mode != .colorPick && Settings.hideDesktopIconsWhileCapturing
        let frozenFrames: [CGImage?] = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, screen) in screens.enumerated() {
                group.addTask {
                    let image = await engine.captureRectToImage(screen.frame, on: screen, excludeDesktopIcons: excludeIcons)
                    var rect = NSRect(origin: .zero, size: screen.frame.size)
                    guard let cg = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                        return (index, nil)
                    }
                    // A uniform all-black/all-white grab is a failed capture (the
                    // -3811 frame this Mac hits on a video wallpaper), not a real
                    // desktop. Painting it would black out the selection, so drop it
                    // and let the overlay fall back to the transparent tint.
                    if CaptureEngine.uniformColorDescription(cg) != nil { return (index, nil) }
                    return (index, cg)
                }
            }
            var frames = [CGImage?](repeating: nil, count: screens.count)
            for await (index, cg) in group { frames[index] = cg }
            return frames
        }
        AreaSelectionDiag.mark("freezesCaptured")

        // The frozen backdrop is asynchronous. A newer interactive intent may
        // claim the screen while it is in flight, in which case this selector
        // must disappear instead of presenting above the newer surface.
        guard !didCancel, canPresent() else {
            AreaSelectionDiag.mark("presentationCancelled")
            return
        }

        // KRIT is an LSUIElement accessory app: while another app is frontmost it
        // stays inactive, and a non-activating panel of an inactive accessory app
        // does NOT reliably order in front of the active app's window — the
        // overlay "didn't show up" when any app was in front. Activating KRIT
        // makes the overlay appear and take the drag on every app. The capture
        // re-grabs the live screen on mouse-up (at the configured supersampling),
        // so the result is the screen at release time. The activation POLICY only
        // decides whether that activation also flashes a Dock icon for the
        // selection's duration: `.regular` shows one, `.accessory` does not.
        // Default to `.accessory` (no Dock flash, like every other KRIT window);
        // the showDockIconDuringCapture setting opts back into `.regular`.
        // Remember who to hand activation back to on cancel (see the property
        // note). Snapshot BEFORE activating KRIT, and only when it wasn't already us.
        let frontmost = NSWorkspace.shared.frontmostApplication
        appToRestoreOnCancel = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        NSApp.setActivationPolicy(Settings.showDockIconDuringCapture ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)

        // Overlays go up with their frozen frame already in hand, so the backdrop
        // is opaque (and correct) from the very first draw — no transparent
        // window through which the paused wallpaper could flash.
        for (index, screen) in screens.enumerated() {
            let overlay = SelectionOverlayWindow(screen: screen, mode: mode, frozenImage: frozenFrames[index])
            overlay.selectionHandler = { [weak self] rect, windowID in self?.finish(rect: rect, screen: screen, windowID: windowID) }
            overlay.cancelHandler = { [weak self] in self?.cancel() }
            overlay.colorPickHandler = { [weak self] hex in self?.finishColorPick(hex) }
            overlay.show()
            overlays.append(overlay)
        }

        AreaSelectionDiag.mark("overlaysShown")
        focusFirstOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusFirstOverlay()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusFirstOverlay()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }

        NSCursor.crosshair.push()
        cursorPushed = true
    }
    private func focusFirstOverlay() {
        guard !overlays.isEmpty, let first = overlays.first else { return }
        guard first.isVisible else { return }
        // Painel não-ativante: makeKey entrega teclado (Esc) sem tirar o app do
        // usuário do estado ativo.
        first.makeKeyAndOrderFront(nil)
        first.makeFirstResponder(first.contentView)
    }

    private func finish(rect: CGRect, screen: NSScreen, windowID: CGWindowID? = nil) {
        guard !didFinish, !didCancel else { return }
        didFinish = true
        popCursorIfNeeded()
        // Latch the frozen crop while the overlays still exist: tearDown() empties
        // them, and the deferred completion below is what reads the crop.
        pendingFrozenCrop = croppedFrozenImage(globalRect: rect, on: screen)
        tearDown()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didCancel else { return }
            self.pendingCompletion = nil
            self.completion(rect, screen, windowID)
        }
        pendingCompletion = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    /// Automation/test hook: completes the selection exactly like a mouse-up,
    /// including overlay teardown timing. Used to reproduce the interactive
    /// capture path without user input.
    func simulateSelection(rect: CGRect, on screen: NSScreen, windowID: CGWindowID? = nil) {
        finish(rect: rect, screen: screen, windowID: windowID)
    }

    /// Test hooks: drive the color-pick click without synthetic mouse events
    /// (CGEvent fights the user's physical mouse). Runs the exact mouseDown
    /// sampling path against the real frozen frame.
    var uiTestHasFrozenFrame: Bool { overlays.contains { $0.uiTestHasFrozenFrame } }

    /// Crops the already-grabbed frozen frame of `screen` to `globalRect`, so the
    /// area shot is produced without a live re-grab (which would flash the screen
    /// light at print time). While the overlays are up this crops live; after
    /// `finish()` tore them down it serves the crop latched there (one-shot).
    /// nil if the grab was missing, so the caller falls back to a live capture.
    func croppedFrozenImage(globalRect: CGRect, on screen: NSScreen) -> NSImage? {
        if !overlays.isEmpty {
            return (overlays.first { $0.coversScreen(screen) } ?? overlays.first)?
                .croppedFrozenImage(globalRect: globalRect)
        }
        let latched = pendingFrozenCrop
        pendingFrozenCrop = nil
        return latched
    }

    func uiTestPickColor(atScreen screenPoint: NSPoint) {
        let overlay = overlays.first(where: { $0.frame.contains(screenPoint) }) ?? overlays.first
        overlay?.uiTestPickColor(atScreen: screenPoint)
    }

    /// Test hook: stands one overlay up with a SYNTHETIC frozen frame instead of
    /// the SCK grab in prepareAndShow, so the frozen-crop fast path (latch in
    /// finish, one-shot read after teardown) can be exercised headless and
    /// deterministically. The overlay is never shown on screen.
    func uiTestPrepareSynthetic(frozen: CGImage, on screen: NSScreen) {
        let overlay = SelectionOverlayWindow(screen: screen, mode: mode, frozenImage: frozen)
        overlays = [overlay]
    }

    /// Read-only: is every overlay genuinely on screen? A non-activating panel
    /// of an inactive accessory app can be ordered but not actually visible /
    /// occluded behind the active app's window. Reports per-overlay flags and an
    /// allOnScreen verdict (visible && unoccluded && on the active Space).
    func uiTestOverlayVisibility() -> [String: Any] {
        var d: [String: Any] = [:]
        d["overlayCount"] = overlays.count
        var visibleFlags: [Bool] = []
        var unoccludedFlags: [Bool] = []
        var onActiveSpaceFlags: [Bool] = []
        var keyFlags: [Bool] = []
        var levels: [Int] = []
        for o in overlays {
            visibleFlags.append(o.isVisible)
            unoccludedFlags.append(o.occlusionState.contains(.visible))
            onActiveSpaceFlags.append(o.isOnActiveSpace)
            keyFlags.append(o.isKeyWindow)
            levels.append(o.level.rawValue)
        }
        d["visible"] = visibleFlags
        d["unoccluded"] = unoccludedFlags
        d["onActiveSpace"] = onActiveSpaceFlags
        d["isKey"] = keyFlags
        d["levels"] = levels
        d["allOnScreen"] = !overlays.isEmpty
            && zip(visibleFlags, zip(unoccludedFlags, onActiveSpaceFlags)).allSatisfy { $0 && $1.0 && $1.1 }
        return d
    }

    /// Read-only probe of the pick path: which overlay the point routes to,
    /// whether it holds a frozen frame and what the sampler returns there.
    /// Fires no handlers, so a scenario can report WHY a pick failed.
    func uiTestPickDiag(atScreen screenPoint: NSPoint) -> [String: Any] {
        var d: [String: Any] = [:]
        d["overlayCount"] = overlays.count
        d["frozenFlags"] = overlays.map { $0.uiTestHasFrozenFrame }
        let chosen = overlays.first(where: { $0.frame.contains(screenPoint) }) ?? overlays.first
        d["chosenHasFrozen"] = chosen?.uiTestHasFrozenFrame ?? false
        d["chosenFrame"] = chosen.map { NSStringFromRect($0.frame) } ?? "nil"
        d["pointInChosen"] = chosen?.frame.contains(screenPoint) ?? false
        d["probedHex"] = chosen?.uiTestSampleHex(atScreen: screenPoint) ?? "nil"
        return d
    }

    private func finishColorPick(_ hex: String) {
        guard !didFinish, !didCancel else { return }
        didFinish = true
        popCursorIfNeeded()
        tearDown()
        onColorPicked?(hex)
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        pendingCompletion?.cancel()
        pendingCompletion = nil
        popCursorIfNeeded()
        pendingFrozenCrop = nil
        tearDown()
        // Hand activation back to the app the overlay stole it from, rather than
        // letting KRIT sit "active but .prohibited" (which throttles its next
        // activation, the source of the post-Esc hotkey lag). Reactivating the
        // prior app relinquishes activation cleanly (memory: never leave a zombie
        // active state). No-op when KRIT was already frontmost.
        appToRestoreOnCancel?.activate()
        appToRestoreOnCancel = nil
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        completion(nil, screen, nil)
    }

    private func popCursorIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    private func tearDown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        // Drop the dock presence raised in prepareAndShow back to the menu-bar
        // accessory state, unless another KRIT window legitimately needs .regular.
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }
}

// MARK: - Overlay NSWindow

/// Timeline diagnostics for the hotkey-to-selection path (UI tests read it).
enum AreaSelectionDiag {
    nonisolated(unsafe) static var timeline: [String: CFTimeInterval] = [:]
    static func mark(_ name: String) { timeline[name] = CACurrentMediaTime() }
}

/// The capture pipeline owns one ScreenCaptureKit display at a time, so an area
/// gesture must never produce a rect that crosses into a neighboring display.
enum AreaSelectionGeometry {
    static func rect(from start: CGPoint, to current: CGPoint, constrainedTo bounds: CGRect) -> CGRect {
        let boundedStart = clampedPoint(start, to: bounds)
        let boundedCurrent = clampedPoint(current, to: bounds)
        return CGRect(
            x: min(boundedStart.x, boundedCurrent.x),
            y: min(boundedStart.y, boundedCurrent.y),
            width: abs(boundedCurrent.x - boundedStart.x),
            height: abs(boundedCurrent.y - boundedStart.y)
        )
    }

    static func clampedPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

@MainActor
private final class SelectionOverlayWindow: NSPanel {

    var selectionHandler: ((CGRect, CGWindowID?) -> Void)?
    var cancelHandler: (() -> Void)?
    var colorPickHandler: ((String) -> Void)? {
        didSet { overlayView.colorPickHandler = colorPickHandler }
    }

    private let overlayView: SelectionOverlayView
    private let targetScreen: NSScreen
    private let mode: SelectionMode

    init(screen: NSScreen, mode: SelectionMode, frozenImage: CGImage?) {
        self.targetScreen = screen
        self.mode = mode
        self.overlayView = SelectionOverlayView(mode: mode, frozenImage: frozenImage)
        // .nonactivatingPanel (estilo Spotlight): o painel recebe teclado e
        // mouse SEM ativar o KRIT, então o app do usuário continua frontmost
        // com seleção/realce intactos durante toda a seleção de área.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Opaque whenever we already hold the frozen backdrop (the common path: it
        // is grabbed BEFORE the overlay goes up). A clear panel lets the live
        // (paused→light) wallpaper composite through the layer-backed first-frame
        // gap; opaque + the synchronous draw in show() guarantees the dark backdrop
        // is the first thing on screen. Only the freeze-nil fallback stays clear (it
        // paints a solid dark fill instead, see drawFrozenBackdrop).
        let hasFrozenBackdrop = frozenImage != nil
        isOpaque = hasFrozenBackdrop
        backgroundColor = hasFrozenBackdrop ? .black : .clear
        // Shielding level (the capture-overlay level macOS uses for the login/screen
        // shield) instead of .screenSaver: some apps float their own window ABOVE
        // .screenSaver (Zentty and other always-on-top typing/teleprompter tools),
        // and at .screenSaver the selection sat UNDER them, so you could only draw
        // the rect on the bare sides, never over the app you wanted to shoot. Still
        // a non-activating panel, so that app stays frontmost underneath.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.selectionHandler = { [weak self] rect, windowID in self?.selectionHandler?(rect, windowID) }
        overlayView.cancelHandler   = { [weak self] in self?.cancelHandler?() }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        if AreaSelectionDiag.timeline["becameKey"] == nil { AreaSelectionDiag.mark("becameKey") }
    }

    /// Late-arriving frozen frame (captured async after the overlay is already
    /// on screen): hands it to the view so the loupe starts sampling.
    func setFrozenImage(_ image: CGImage) {
        overlayView.setFrozenImage(image)
    }

    func coversScreen(_ screen: NSScreen) -> Bool { targetScreen.frame == screen.frame }
    func croppedFrozenImage(globalRect: CGRect) -> NSImage? {
        overlayView.croppedFrozenImage(globalRect: globalRect, screenFrame: targetScreen.frame)
    }

    func show() {
        // Commit the opaque backdrop into the layer BEFORE the panel is ever on
        // screen. The content view is layer-backed (.onSetNeedsDisplay), so without
        // a forced synchronous draw the first composited frame is the CLEAR panel
        // and drawFrozenBackdrop() only lands on the NEXT CATransaction. During that
        // one-frame gap the panel already covers the desktop, macOS pauses the
        // aerial wallpaper to its LIGHT poster frame, and that light composites
        // straight through the clear panel — the dark→light flash the user saw.
        // Drawing here puts the opaque dark backdrop on the very first frame.
        overlayView.setNeedsDisplay(overlayView.bounds)
        overlayView.displayIfNeeded()
        orderFrontRegardless()
    }

    var uiTestHasFrozenFrame: Bool { overlayView.uiTestHasFrozenFrame }
    func uiTestPickColor(atScreen screenPoint: NSPoint) {
        let windowPoint = convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        overlayView.uiTestPick(at: overlayView.convert(windowPoint, from: nil))
    }
    func uiTestSampleHex(atScreen screenPoint: NSPoint) -> String? {
        let windowPoint = convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        return overlayView.uiTestSample(at: overlayView.convert(windowPoint, from: nil))
    }
}

// MARK: - Overlay NSView

@MainActor
private final class SelectionOverlayView: NSView {

    var selectionHandler: ((CGRect, CGWindowID?) -> Void)?
    var cancelHandler:    (() -> Void)?
    var colorPickHandler: ((String) -> Void)?

    private let mode: SelectionMode
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var isSelecting = false

    // For area mode: track mouse position for crosshair before drag starts
    private var mousePosition: NSPoint?

    // CleanShot-style: the magnifier loupe + crosshair guides only appear while
    // holding Control (when the setting is on). Color-pick always shows the loupe
    // (it IS the eyedropper). Default off keeps selection snappy: nothing heavy is
    // repainted per mouse move, the plain crosshair cursor does the aiming.
    private var controlHeld = false
    private var showsLoupeArtifacts: Bool {
        if mode == .colorPick { return true }
        return !Settings.magnifierRequiresControl || controlHeld
    }

    override func flagsChanged(with event: NSEvent) {
        let held = event.modifierFlags.contains(.control)
        if held != controlHeld {
            controlHeld = held
            if let pos = mousePosition { invalidateCursorArtifacts(at: pos) } else { needsDisplay = true }
        }
        super.flagsChanged(with: event)
    }

    // For window mode
    private var highlightedWindowRect: NSRect?
    // The highlighted window's frame in AppKit screen coordinates (bottom-left,
    // global) plus its CGWindowID, kept alongside the view-space rect so the
    // selection reports the exact window the user is hovering, the screen rect
    // for the legacy crop fallback and the windowID for isolated SCK capture.
    private var highlightedWindowScreenRect: NSRect?
    private var highlightedWindowID: CGWindowID?
    private var trackingArea: NSTrackingArea?
    private var cachedWindows: [(screenRect: NSRect, windowID: CGWindowID)] = []
    private var lastWindowListRefresh: TimeInterval = 0

    private var frozenImage: CGImage?

    func setFrozenImage(_ image: CGImage) {
        frozenImage = image
        needsDisplay = true
    }

    var uiTestHasFrozenFrame: Bool { frozenImage != nil }
    func uiTestPick(at point: NSPoint) {
        if let hex = sampledHex(at: point) { colorPickHandler?(hex) } else { cancelHandler?() }
    }
    func uiTestSample(at point: NSPoint) -> String? { sampledHex(at: point) }

    /// Crops the frozen backdrop to a global selection rect, reusing the loupe's
    /// orientation math (the frozen frame is this screen at native density, view
    /// coords are screen-local). This lets area capture produce the shot from the
    /// dark frozen frame already in hand instead of tearing the overlay down and
    /// re-grabbing the live screen — the re-grab is what reveals the icon-cover
    /// light still and the paused aerial poster (the dark→light flash at print
    /// time). Returns nil if the frame is missing or the rect degenerates, so the
    /// caller can fall back to a live grab.
    func croppedFrozenImage(globalRect: CGRect, screenFrame: CGRect) -> NSImage? {
        guard let frozenImage else { return nil }
        let local = CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: globalRect.minY - screenFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
        let imgScale = CGFloat(frozenImage.width) / max(bounds.width, 1)
        let pxRect = CGRect(
            x: local.minX * imgScale,
            y: (bounds.height - local.maxY) * imgScale,
            width: local.width * imgScale,
            height: local.height * imgScale
        ).integral
        guard pxRect.width >= 1, pxRect.height >= 1,
              let cg = frozenImage.cropping(to: pxRect) else { return nil }
        return NSImage(cgImage: cg, size: local.size)
    }

    init(mode: SelectionMode, frozenImage: CGImage?) {
        self.mode = mode
        self.frozenImage = frozenImage
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        updateTrackingArea()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // O app fica INATIVO durante a seleção (painel não-ativante): NSCursor.push
    // global não vale nesse estado, o cursor vem do cursorUpdate da janela sob
    // o ponteiro. Garante o crosshair sempre que o cursor entra no overlay.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Opaque frozen backdrop FIRST. The overlay used to paint a ~transparent
        // tint (alpha 0.001) and let the LIVE desktop show through. With a video
        // wallpaper (aerial), macOS pauses the wallpaper the instant this
        // full-screen panel covers the desktop and falls back to the still poster
        // frame, which on a dynamic light/dark wallpaper is the LIGHT variant, so
        // the screen appeared to flip dark to light the moment selection started.
        // Painting the frozen screenshot (or a dark fill until it lands) as an
        // opaque base means whatever the paused wallpaper does underneath never
        // shows through. The dim/highlight below now layers over this base.
        drawFrozenBackdrop()

        if mode == .window {
            drawWindowHighlight()
        } else if isSelecting && !currentRect.isEmpty {
            drawActiveSelection()
        } else if mode == .area || mode == .colorPick {
            drawPreDragArtifacts()
        }
    }

    /// Opaque base for the overlay: the frozen screenshot of this display, grabbed
    /// at hotkey time BEFORE the overlay went up (so it is the real dark desktop,
    /// not the paused-wallpaper light still nor the overlay itself). NSImage keeps
    /// the screenshot's natural orientation regardless of the view's flip.
    ///
    /// Fallback when the grab failed (frozenImage nil, rare): a SOLID,
    /// appearance-correct dark fill. NOT the old near-transparent tint (alpha
    /// 0.001) — that re-exposed the live wallpaper, which on a video wallpaper
    /// pauses to a LIGHT poster and brings the flash right back. NOT pure black
    /// either (a dead panel you can't aim through). windowBackgroundColor is dark
    /// in dark mode, light in light mode; fill opacity never affects hit-testing.
    private func drawFrozenBackdrop() {
        if let frozenImage {
            NSImage(cgImage: frozenImage, size: bounds.size)
                .draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
        } else {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath.fill(bounds)
        }
    }

    /// Window mode: dim everything, punch a clean hole over the hovered window so
    /// the frozen backdrop reads through it (even-odd, NOT a clear fill: clearing
    /// would re-expose the live desktop we just covered).
    private func drawWindowHighlight() {
        guard let winRect = highlightedWindowRect else {
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath.fill(bounds)
            return
        }
        let outer = NSBezierPath(rect: bounds)
        let inner = NSBezierPath(rect: winRect)
        outer.append(inner)
        outer.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        outer.fill()
        KritColors.accent.setStroke()
        inner.lineWidth = 2
        inner.stroke()
    }

    /// Area mode during the drag: dim outside the selection (frozen backdrop reads
    /// clean inside), plus border, rule-of-thirds grid, corner handles, size label
    /// and, when active, the magnifier loupe.
    private func drawActiveSelection() {
        let outer = NSBezierPath(rect: bounds)
        let inner = NSBezierPath(rect: currentRect)
        outer.append(inner)
        outer.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        outer.fill()

        // Blue selection border
        KritColors.accent.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        border.stroke()

        drawRuleOfThirdsGrid(in: currentRect)
        drawCornerHandles(for: currentRect)
        drawDimensionLabel(near: currentRect)
        // Loupe during the drag: pixel-precise feedback while sizing the rect,
        // but only when the magnifier is active (Control held, or always-on).
        if showsLoupeArtifacts, let pos = mousePosition {
            drawMagnifierLoupe(at: pos)
        }
    }

    /// Subtle rule-of-thirds guides for premium framing (like CleanShot X), only
    /// once the rect is big enough for them to read.
    private func drawRuleOfThirdsGrid(in rect: NSRect) {
        guard rect.width > 50 && rect.height > 50 else { return }
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let grid = NSBezierPath()
        let w3 = rect.width / 3
        let h3 = rect.height / 3
        grid.move(to: NSPoint(x: rect.minX + w3, y: rect.minY))
        grid.line(to: NSPoint(x: rect.minX + w3, y: rect.maxY))
        grid.move(to: NSPoint(x: rect.minX + w3 * 2, y: rect.minY))
        grid.line(to: NSPoint(x: rect.minX + w3 * 2, y: rect.maxY))
        grid.move(to: NSPoint(x: rect.minX, y: rect.minY + h3))
        grid.line(to: NSPoint(x: rect.maxX, y: rect.minY + h3))
        grid.move(to: NSPoint(x: rect.minX, y: rect.minY + h3 * 2))
        grid.line(to: NSPoint(x: rect.maxX, y: rect.minY + h3 * 2))
        grid.lineWidth = 1.0
        grid.stroke()
    }

    /// Pre-drag (area) and color-pick: the opaque frozen backdrop already fills the
    /// view, so macOS hit-tests it and delivers mouseDown. No scrim: the frozen
    /// screen reads at full brightness until the drag starts, matching the old
    /// live-through feel minus the wallpaper flash.
    private func drawPreDragArtifacts() {
        guard showsLoupeArtifacts, let pos = mousePosition else { return }
        drawCrosshair(at: pos)
        // The hex pill under the loupe already names the pixel; screen coordinates
        // would be noise while picking a color.
        if mode == .area { drawCoordinateLabel(at: pos) }
        drawMagnifierLoupe(at: pos)
    }

    // MARK: - Magnifier Loupe

    private func drawMagnifierLoupe(at point: NSPoint) {
        guard let frozenImage else { return }

        // Magnified region: 24x24 points around the cursor.
        let captureSize: CGFloat = 24

        // The frozen frame covers exactly this screen and view coords are
        // already screen-local (the overlay fills the screen), so no global
        // conversion. The frame comes at the display's native pixel density
        // (2x on Retina); measure the point-to-pixel factor from the buffer
        // itself instead of assuming 1:1 — assuming it sampled the wrong
        // quadrant on Retina and broke entirely on secondary displays.
        let imgScale = CGFloat(frozenImage.width) / max(bounds.width, 1)
        let topLeftY = bounds.height - point.y

        let captureRect = CGRect(
            x: (point.x - captureSize / 2) * imgScale,
            y: (topLeftY - captureSize / 2) * imgScale,
            width: captureSize * imgScale,
            height: captureSize * imgScale
        )

        guard let cgImage = frozenImage.cropping(to: captureRect) else { return }
        let loupeSize: CGFloat = 120
        let offset: CGFloat = 20

        // Position: offset from cursor, flip to other side near edges
        var loupeX = point.x + offset
        var loupeY = point.y + offset
        if loupeX + loupeSize > bounds.maxX - 10 {
            loupeX = point.x - offset - loupeSize
        }
        if loupeY + loupeSize > bounds.maxY - 10 {
            loupeY = point.y - offset - loupeSize
        }

        let loupeRect = NSRect(x: loupeX, y: loupeY, width: loupeSize, height: loupeSize)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        // Clip to circle
        let clipPath = CGPath(ellipseIn: loupeRect, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()

        // Dark background behind the magnified pixels
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fill(loupeRect)

        // Draw magnified image with nearest-neighbor interpolation for crisp pixels
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: loupeRect)

        // Pixel grid overlay
        let pixelSize = loupeSize / captureSize
        if pixelSize > 4 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.setLineWidth(0.5)
            for i in 0...Int(captureSize) {
                let x = loupeRect.minX + CGFloat(i) * pixelSize
                ctx.move(to: CGPoint(x: x, y: loupeRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: loupeRect.maxY))
                let y = loupeRect.minY + CGFloat(i) * pixelSize
                ctx.move(to: CGPoint(x: loupeRect.minX, y: y))
                ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: y))
            }
            ctx.strokePath()
        }

        // Center crosshair
        let cx = loupeRect.midX, cy = loupeRect.midY
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: cx - 6, y: cy))
        ctx.addLine(to: CGPoint(x: cx + 6, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - 6))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 6))
        ctx.strokePath()

        ctx.restoreGState()

        // Circular border (drawn outside the clip)
        let borderPath = NSBezierPath(ovalIn: loupeRect.insetBy(dx: 0.75, dy: 0.75))
        NSColor.white.withAlphaComponent(0.4).setStroke()
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        // Shadow ring for depth
        let shadowPath = NSBezierPath(ovalIn: loupeRect.insetBy(dx: -1, dy: -1))
        NSColor.black.withAlphaComponent(0.3).setStroke()
        shadowPath.lineWidth = 2.0
        shadowPath.stroke()

        // Pixel color hex label below the loupe
        drawColorLabel(for: cgImage, below: loupeRect)
    }

    /// Hex of the frozen-frame pixel under a view-space point (the same frame
    /// the loupe magnifies, so click and loupe always agree). View coords are
    /// screen-local; the buffer is top-left origin at native pixel density.
    private func sampledHex(at point: NSPoint) -> String? {
        guard let frozenImage else { return nil }
        let imgScale = CGFloat(frozenImage.width) / max(bounds.width, 1)
        let x = Int((point.x * imgScale).rounded(.down))
        let y = Int(((bounds.height - point.y) * imgScale).rounded(.down))
        return PixelSampler.hex(in: frozenImage, x: x, y: y)
    }

    private func drawColorLabel(for image: CGImage, below loupeRect: NSRect) {
        guard let hex = PixelSampler.hex(in: image, x: image.width / 2, y: image.height / 2) else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: hex, attributes: attrs)
        let size = str.size()
        let pillX = loupeRect.midX - (size.width + 12) / 2
        let pillY = loupeRect.minY - size.height - 10
        let pillRect = NSRect(x: pillX, y: pillY, width: size.width + 12, height: size.height + 6)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: pillX + 6, y: pillY + 3))
    }

    // MARK: - Corner Handles

    private func drawCornerHandles(for rect: NSRect) {
        let handleLen: CGFloat = 8
        let handleWidth: CGFloat = 2.5
        NSColor.white.setStroke()

        let corners: [(NSPoint, [(CGFloat, CGFloat)])] = [
            (NSPoint(x: rect.minX, y: rect.minY), [(0, handleLen), (handleLen, 0)]),
            (NSPoint(x: rect.maxX, y: rect.minY), [(0, handleLen), (-handleLen, 0)]),
            (NSPoint(x: rect.minX, y: rect.maxY), [(0, -handleLen), (handleLen, 0)]),
            (NSPoint(x: rect.maxX, y: rect.maxY), [(0, -handleLen), (-handleLen, 0)]),
        ]

        for (origin, offsets) in corners {
            let path = NSBezierPath()
            path.lineWidth = handleWidth
            path.lineCapStyle = .round
            for (dx, dy) in offsets {
                path.move(to: origin)
                path.line(to: NSPoint(x: origin.x + dx, y: origin.y + dy))
            }
            path.stroke()
        }
    }

    // MARK: - Dimension Label

    private func drawDimensionLabel(near rect: NSRect) {
        let label = String(format: "%.0f \u{00D7} %.0f", rect.width, rect.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 6)
        let bg = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: origin)
    }

    private func drawCrosshair(at point: NSPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Shadow line (dark, underneath) for contrast on light backgrounds
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.strokePath()

        // Primary line (white, on top)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(0.5)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.strokePath()
    }

    private func drawCoordinateLabel(at point: NSPoint) {
        guard let win = window else { return }
        // Convert view coordinates to screen coordinates for display
        let screenPoint = win.convertToScreen(NSRect(origin: point, size: .zero)).origin
        // Convert to top-left origin (Core Graphics) for user-facing display.
        // CG global coords are anchored to the primary display, use screens[0].
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let displayX = Int(screenPoint.x)
        let displayY = Int(screenHeight - screenPoint.y)

        let label = "\(displayX)\n\(displayY)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let padding: CGFloat = 6
        let offset: CGFloat = 15

        // Position label to bottom-right of cursor, clamped to view bounds
        var labelX = point.x + offset
        var labelY = point.y - offset - size.height - padding
        if labelX + size.width + padding * 2 > bounds.maxX {
            labelX = point.x - offset - size.width - padding * 2
        }
        if labelY < bounds.minY {
            labelY = point.y + offset
        }

        let bgRect = NSRect(x: labelX, y: labelY, width: size.width + padding * 2, height: size.height + padding)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: labelX + padding, y: labelY + padding * 0.5))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Safety net: if the panel isn't key (race on first capture), take key
        // now so the drag events are delivered here. Never activates the app:
        // the user's frontmost app must keep its focus appearance.
        if let win = window, !win.isKeyWindow {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(self)
        }

        if mode == .window {
            // Report the window's frame in SCREEN coordinates (not the view-space
            // highlight rect): the overlay view's origin is the screen origin, so
            // on a secondary display (screen.frame.origin != 0) the raw view rect
            // is offset and the crop lands on the wrong area. The windowID lets
            // the caller capture the window in isolation via SCK.
            if let screenRect = highlightedWindowScreenRect {
                selectionHandler?(screenRect, highlightedWindowID)
            }
            return
        }
        if mode == .colorPick {
            // Sample the frozen frame (what the loupe shows) and finish. A click
            // before the frame lands has nothing to sample; cancel rather than
            // report a wrong color.
            if let hex = sampledHex(at: event.locationInWindow) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                colorPickHandler?(hex)
            } else {
                cancelHandler?()
            }
            return
        }
        let point = AreaSelectionGeometry.clampedPoint(event.locationInWindow, to: bounds)
        startPoint = point
        isSelecting = true
        currentRect = .zero
        mousePosition = point  // keep the loupe anchored at the drag corner
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = startPoint else { return }
        let current = AreaSelectionGeometry.clampedPoint(event.locationInWindow, to: bounds)
        let previousRect = currentRect
        let previousCursor = mousePosition
        mousePosition = current
        currentRect = AreaSelectionGeometry.rect(from: start, to: current, constrainedTo: bounds)
        // The loupe rides the drag corner; invalidate its old/new footprint.
        if let previousCursor { invalidateCursorArtifacts(at: previousCursor) }
        invalidateCursorArtifacts(at: current)

        // First drag frame: pre-drag branch only painted a near-clear tint
        // across the screen, so we need a full-screen redraw to establish the
        // 0.3 dim everywhere and punch out the selection. After that, only
        // the diff between old and new rects (plus margin for border, corner
        // handles, and the dimension label above) actually changed, the rest
        // of the dim region is already correct on the layer's backing store.
        let margin: CGFloat = 32
        if previousRect.isEmpty {
            setNeedsDisplay(bounds)
        } else {
            setNeedsDisplay(previousRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
            setNeedsDisplay(currentRect.insetBy(dx: -margin, dy: -margin).intersection(bounds))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, isSelecting else { return }
        isSelecting = false
        if currentRect.width > 4 && currentRect.height > 4 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            selectionHandler?(convertToScreen(currentRect), nil)
        } else {
            // Tiny click / accidental tap, cancel cleanly; never leave overlay stuck
            cancelHandler?()
        }
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        if AreaSelectionDiag.timeline["firstMouseMoved"] == nil { AreaSelectionDiag.mark("firstMouseMoved") }
        if mode == .window {
            let previous = highlightedWindowRect
            let hit = windowUnder(point: event.locationInWindow)
            highlightedWindowRect = hit?.viewRect
            highlightedWindowScreenRect = hit?.screenRect
            highlightedWindowID = hit?.windowID
            if previous != highlightedWindowRect {
                invalidateWindowHighlight(from: previous, to: highlightedWindowRect)
            }
        } else if (mode == .area || mode == .colorPick) && !isSelecting {
            // Force the crosshair cursor on every move: the selection panel is
            // INACTIVE, so NSCursor.push()/cursorUpdate don't reliably stick and the
            // pointer would stay an arrow. This is the aiming target by default,
            // when the magnifier is hidden.
            NSCursor.crosshair.set()
            // Read Control from the global modifier state (the inactive panel never
            // gets flagsChanged), so the magnifier toggles live while moving.
            let wasShowing = showsLoupeArtifacts
            controlHeld = NSEvent.modifierFlags.contains(.control)
            let isShowing = showsLoupeArtifacts

            // Magnifier hidden: paint NOTHING per move, just track the position, so
            // there is zero per-move redraw and the selection stays snappy.
            guard isShowing || wasShowing else {
                mousePosition = event.locationInWindow
                return
            }
            // Active (or just released): invalidate the artifacts at both the old and
            // new positions: crosshair strips (full-screen lines), the loupe (120px
            // + shadow/border, flips near screen edges), the hex pill and the label.
            if let old = mousePosition {
                invalidateCursorArtifacts(at: old)
            }
            mousePosition = event.locationInWindow
            if isShowing { invalidateCursorArtifacts(at: mousePosition!) }
        } else {
            setNeedsDisplay(bounds)
        }
    }

    private func invalidateWindowHighlight(from oldRect: NSRect?, to newRect: NSRect?) {
        let padding: CGFloat = 8
        if let oldRect {
            setNeedsDisplay(oldRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
        if let newRect {
            setNeedsDisplay(newRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
    }

    /// Repaints the narrow crosshair strips plus a generous box around the
    /// cursor that fully contains the loupe (on either side), the hex color
    /// pill, and the coordinate label. Tuned so no leftover pixels trail the
    /// pointer when the mouse moves fast.
    private func invalidateCursorArtifacts(at point: NSPoint) {
        // Crosshair lines span the whole view; invalidate a thin strip on each axis.
        let strip: CGFloat = 4
        setNeedsDisplay(NSRect(x: 0, y: point.y - strip / 2, width: bounds.width, height: strip))
        setNeedsDisplay(NSRect(x: point.x - strip / 2, y: 0, width: strip, height: bounds.height))

        // Loupe (120) + 20 offset + margin for shadow/border/pill/coord label in any quadrant.
        let halo: CGFloat = 190
        let haloRect = NSRect(
            x: point.x - halo,
            y: point.y - halo,
            width: halo * 2,
            height: halo * 2
        ).intersection(bounds)
        setNeedsDisplay(haloRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            cancelHandler?()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Helpers

    private func convertToScreen(_ rect: NSRect) -> CGRect {
        guard let win = window else { return rect }
        // Convert from view to window to screen
        let winRect = convert(rect, to: nil)
        let screenRect = win.convertToScreen(winRect)
        return screenRect
    }

    /// The frontmost layer-0 window under `point` (view coords): its rect in view
    /// space (for the highlight overlay), its rect in AppKit screen coords (for
    /// the crop fallback), and its CGWindowID (for isolated SCK capture).
    private func windowUnder(point: NSPoint) -> (viewRect: NSRect, screenRect: NSRect, windowID: CGWindowID)? {
        guard let win = window else { return nil }
        let screenPoint = win.convertToScreen(NSRect(origin: point, size: .zero)).origin
        refreshWindowRectsIfNeeded()
        // cachedWindows is ordered front-to-back (CGWindowListCopyWindowInfo
        // returns frontmost first), so the first hit is the topmost window.
        for entry in cachedWindows where entry.screenRect.contains(screenPoint) {
            let viewOrigin = win.convertFromScreen(NSRect(origin: entry.screenRect.origin, size: .zero)).origin
            let viewRect = NSRect(origin: viewOrigin, size: entry.screenRect.size)
            return (viewRect, entry.screenRect, entry.windowID)
        }
        return nil
    }

    private func refreshWindowRectsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowListRefresh > 0.15 else { return }
        lastWindowListRefresh = now
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // CGWindowBounds is global Core Graphics (top-left origin, anchored to the
        // primary display, spanning all monitors). Converting to AppKit global
        // (bottom-left, same anchor) uses the PRIMARY display height for every
        // window regardless of which monitor it sits on.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenFrames = NSScreen.screens.map { $0.frame }
        cachedWindows = windowList.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let windowNumber = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let screenRect = CGRect(
                x: bounds.origin.x,
                y: primaryHeight - bounds.origin.y - bounds.height,
                width: bounds.width,
                height: bounds.height
            )
            // Skip windows that cover an entire display. A window matching a full
            // screen frame (Screen Sharing / screen-mirroring fullscreen mirror,
            // and similar) is never a meaningful single-window target, capturing
            // it is identical to screen/area mode. Without this the picker would
            // grab the mirror on every click ("window shot = the whole screen"),
            // and a full-bleed shot composes with no margin so its shadow has
            // nowhere to fall. The match is tight (2px) and against the full
            // frame, not visibleFrame, so a maximized app window (which leaves
            // the menu bar) stays pickable.
            let coversDisplay = screenFrames.contains { f in
                abs(f.minX - screenRect.minX) < 2 && abs(f.minY - screenRect.minY) < 2 &&
                abs(f.width - screenRect.width) < 2 && abs(f.height - screenRect.height) < 2
            }
            if coversDisplay { return nil }
            return (screenRect, CGWindowID(windowNumber))
        }
    }

}
