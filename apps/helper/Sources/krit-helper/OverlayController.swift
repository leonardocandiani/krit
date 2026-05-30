import AppKit

/// Coordinates the region-selection overlays (one window per display).
///
/// On start, CaptureEngine must have already called `freezeAllDisplays()`.
/// Each NSScreen gets a borderless window with a `SelectionView` that draws
/// the freeze-frame, the dimming overlay, and the selection rectangle.
@MainActor
final class OverlayController: NSObject {

    private let engine: CaptureEngine
    private var windows: [NSWindow] = []
    private var isShowing = false

    /// Called when a region capture completes (with the PNG URL).
    var onComplete: ((URL) -> Void)?
    /// Called when the selection is cancelled (Esc or click without drag).
    var onCancelled: (() -> Void)?

    init(engine: CaptureEngine) {
        self.engine = engine
        super.init()
    }

    var active: Bool { isShowing }

    /// Freezes the displays and shows the selection overlays.
    func beginRegionCapture() {
        guard !isShowing else { return }
        isShowing = true

        Task { @MainActor in
            do {
                try await engine.freezeAllDisplays()
                presentOverlays()
            } catch {
                FileHandle.standardError.write(Data("KRIT: failed to freeze screen: \(error)\n".utf8))
                isShowing = false
                onCancelled?()
            }
        }
    }

    private func presentOverlays() {
        // Activate the app so the overlays can receive keyboard/mouse events.
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.engine = engine
            view.screen = screen
            view.onFinish = { [weak self] globalRect in
                self?.finish(with: globalRect)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()

            windows.append(window)
        }

        // Ensure the first overlay has keyboard focus (for Esc).
        windows.first?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(with globalRect: CGRect) {
        closeAll()
        do {
            let url = try engine.crop(globalRect: globalRect)
            onComplete?(url)
        } catch {
            FileHandle.standardError.write(Data("KRIT: crop failed: \(error)\n".utf8))
            onCancelled?()
        }
    }

    func cancel() {
        guard isShowing else { return }
        engine.clearFreezes()
        closeAll()
        onCancelled?()
    }

    private func closeAll() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        isShowing = false
        NSCursor.arrow.set()
    }
}

// MARK: - SelectionView

/// View that draws the freeze-frame of a display and the dragged selection rectangle.
///
/// Internal coordinates: bottom-left origin, points (standard AppKit, isFlipped=false).
@MainActor
final class SelectionView: NSView {

    weak var engine: CaptureEngine?
    weak var screen: NSScreen?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// Selection rectangle in view-local coordinates (points, bottom-left).
    private var selectionRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Freeze-frame as background (covers the entire display).
        if let screen = screen,
           let displayID = displayID(for: screen),
           let freeze = engine?.freezes[displayID] {
            ctx.draw(freeze.image, in: bounds)
        } else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(bounds)
        }

        // 2. Dim overlay on top.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.fill(bounds)

        guard let sel = selectionRect, sel.width >= 1, sel.height >= 1 else { return }

        // 3. Redraw the selected area WITHOUT dimming (clipped from the freeze).
        if let screen = screen,
           let displayID = displayID(for: screen),
           let freeze = engine?.freezes[displayID] {
            ctx.saveGState()
            ctx.clip(to: sel)
            ctx.draw(freeze.image, in: bounds)
            ctx.restoreGState()
        }

        // 4. Selection border.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))

        // 5. Pixel dimensions near the cursor.
        drawDimensions(for: sel, in: ctx)
    }

    private func drawDimensions(for sel: CGRect, in ctx: CGContext) {
        let scale = screen?.backingScaleFactor ?? 1.0
        let wPx = Int((sel.width * scale).rounded())
        let hPx = Int((sel.height * scale).rounded())
        let label = "\(wPx) x \(hPx)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.size()
        let pad: CGFloat = 6

        // Position the badge just below the bottom edge of the rect (above if it doesn't fit).
        var badgeOrigin = CGPoint(x: sel.minX, y: sel.minY - textSize.height - pad * 2 - 4)
        if badgeOrigin.y < 4 {
            badgeOrigin.y = sel.maxY + 4
        }
        let badgeRect = CGRect(
            x: badgeOrigin.x,
            y: badgeOrigin.y,
            width: textSize.width + pad * 2,
            height: textSize.height + pad
        )

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        str.draw(at: CGPoint(x: badgeRect.minX + pad, y: badgeRect.minY + pad / 2))
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let sel = selectionRect, sel.width >= 1, sel.height >= 1 else {
            // Click without drag: cancel.
            onCancel?()
            return
        }
        onFinish?(localToGlobal(sel))
    }

    // MARK: Keyboard events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Coordinate conversions

    /// Converts a view-local rect (points, bottom-left) to AppKit global coordinates
    /// (points, bottom-left) by adding the screen frame origin.
    private func localToGlobal(_ rect: CGRect) -> CGRect {
        let origin = screen?.frame.origin ?? .zero
        return CGRect(x: rect.origin.x + origin.x,
                      y: rect.origin.y + origin.y,
                      width: rect.width, height: rect.height)
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
