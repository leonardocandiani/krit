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

    init(mode: SelectionMode, completion: @escaping Completion) {
        self.mode = mode
        self.completion = completion
    }

    private var keyMonitor: Any?

    func prepareAndShow(engine: CaptureEngine) async {
        AreaSelectionDiag.mark("prepareEntry")
        // NUNCA ativar o KRIT aqui: o overlay é um painel não-ativante que vira
        // key sozinho. Ativar o app desativava o app do usuário no instante do
        // atalho, mudando seleção de texto/realce/aparência de foco exatamente
        // no estado que ele queria fotografar (o bug "tira de seleção onde estou").

        // Overlays go up IMMEDIATELY so the selection is usable the instant the
        // hotkey fires. The frozen frames (loupe sampling + legacy crop source)
        // arrive asynchronously below; the loupe simply stays hidden until its
        // frame lands. The old order (full-screen grab per display, serial, at
        // the user's supersampling scale) held the whole UI back for seconds.
        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(screen: screen, mode: mode, frozenImage: nil)
            overlay.selectionHandler = { [weak self] rect, windowID in self?.finish(rect: rect, screen: screen, windowID: windowID) }
            overlay.cancelHandler = { [weak self] in self?.cancel() }
            overlay.colorPickHandler = { [weak self] hex in self?.finishColorPick(hex) }
            overlay.show()
            overlays.append(overlay)
        }
        for (overlay, screen) in zip(overlays, NSScreen.screens) {
            Task { [weak overlay] in
                // Native 1x: this frame is for the loupe and fallback crop, the
                // real capture re-grabs at the configured quality on release.
                let image = await engine.captureRectToImage(screen.frame, on: screen, nativeScale: true)
                var rect = NSRect(origin: .zero, size: screen.frame.size)
                guard let frozenCG = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                await MainActor.run { overlay?.setFrozenImage(frozenCG) }
            }
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
        NSCursor.pop()
        tearDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.completion(rect, screen, windowID)
        }
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
    func uiTestPickColor(atScreen screenPoint: NSPoint) {
        let overlay = overlays.first(where: { $0.frame.contains(screenPoint) }) ?? overlays.first
        overlay?.uiTestPickColor(atScreen: screenPoint)
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
        NSCursor.pop()
        tearDown()
        onColorPicked?(hex)
    }

    func cancel() {
        NSCursor.pop()
        tearDown()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        completion(nil, screen, nil)
    }

    private func tearDown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        // Sem restore de activation policy: este fluxo nunca escala o policy
        // (painel não-ativante), então restaurar aqui só atropelaria outro fluxo
        // que esteja legitimamente em .accessory (Preferences abertas, etc).
    }
}

// MARK: - Overlay NSWindow

/// Timeline diagnostics for the hotkey-to-selection path (UI tests read it).
enum AreaSelectionDiag {
    nonisolated(unsafe) static var timeline: [String: CFTimeInterval] = [:]
    static func mark(_ name: String) { timeline[name] = CACurrentMediaTime() }
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
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
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

    func show() {
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
        if mode == .window {
            // Window mode: dimmed background with cut-out for highlighted window
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath.fill(bounds)
            if let winRect = highlightedWindowRect {
                NSColor.clear.setFill()
                let path = NSBezierPath(rect: winRect)
                path.fill()
                KritColors.accent.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        } else if isSelecting && !currentRect.isEmpty {
            // Area mode, during drag: dim outside selection, clear inside
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

            // Subtle rule-of-thirds grid for premium framing (like CleanShot X)
            if currentRect.width > 50 && currentRect.height > 50 {
                NSColor.white.withAlphaComponent(0.25).setStroke()
                let grid = NSBezierPath()
                let w3 = currentRect.width / 3
                let h3 = currentRect.height / 3
                grid.move(to: NSPoint(x: currentRect.minX + w3, y: currentRect.minY))
                grid.line(to: NSPoint(x: currentRect.minX + w3, y: currentRect.maxY))
                grid.move(to: NSPoint(x: currentRect.minX + w3 * 2, y: currentRect.minY))
                grid.line(to: NSPoint(x: currentRect.minX + w3 * 2, y: currentRect.maxY))
                grid.move(to: NSPoint(x: currentRect.minX, y: currentRect.minY + h3))
                grid.line(to: NSPoint(x: currentRect.maxX, y: currentRect.minY + h3))
                grid.move(to: NSPoint(x: currentRect.minX, y: currentRect.minY + h3 * 2))
                grid.line(to: NSPoint(x: currentRect.maxX, y: currentRect.minY + h3 * 2))
                grid.lineWidth = 1.0
                grid.stroke()
            }

            drawCornerHandles(for: currentRect)
            drawDimensionLabel(near: currentRect)
            // Keep the loupe live during the drag, it samples the in-memory
            // frozen image (zero per-frame capture cost), so the user gets
            // pixel-precise feedback exactly when sizing the rect, which is the
            // moment it matters most. Anchored at the active drag corner.
            if let pos = mousePosition {
                drawMagnifierLoupe(at: pos)
            }
        } else if mode == .area || mode == .colorPick {
            // Pre-drag (area) and color-pick: near-invisible tint so macOS
            // hit-tests this region and delivers mouseDown. Fully clear windows
            // pass clicks through.
            NSColor.black.withAlphaComponent(0.001).setFill()
            NSBezierPath.fill(bounds)
            if let pos = mousePosition {
                drawCrosshair(at: pos)
                // The hex pill under the loupe already names the pixel; screen
                // coordinates would be noise while picking a color.
                if mode == .area { drawCoordinateLabel(at: pos) }
                drawMagnifierLoupe(at: pos)
            }
        }
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
        startPoint = event.locationInWindow
        isSelecting = true
        currentRect = .zero
        mousePosition = event.locationInWindow  // keep the loupe anchored at the drag corner
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = startPoint else { return }
        let current = event.locationInWindow
        let previousRect = currentRect
        let previousCursor = mousePosition
        mousePosition = current
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
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
            // Invalidate every artifact we paint around the cursor at both
            // the previous and new positions: crosshair strips (full-screen
            // lines), the loupe (120px + shadow/border, flips left or right
            // and up or down near screen edges), the hex color pill below
            // the loupe, and the coordinate label offset from the cursor.
            if let old = mousePosition {
                invalidateCursorArtifacts(at: old)
            }
            mousePosition = event.locationInWindow
            invalidateCursorArtifacts(at: mousePosition!)
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
            return (screenRect, CGWindowID(windowNumber))
        }
    }

}
