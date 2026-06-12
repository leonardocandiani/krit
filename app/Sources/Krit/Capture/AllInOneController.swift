import AppKit

/// The action a user picks from the All-in-One options panel. The controller
/// only reports intent plus the final adjusted rect; the engine owns the real
/// capture/record routing.
@MainActor
enum AllInOneAction {
    case capture
    case record
    case window
    case fullscreen
    case scrolling
    case ocr
}

/// CleanShot-style All-in-One: a single overlay on the target screen shows the
/// last selection already drawn with resize handles (or a centered default the
/// first time), and a floating glass panel of options anchored under it. The
/// user can resize/move the rect, then pick Capture, Record, Window, Fullscreen,
/// Scrolling, or OCR. This is a self-contained path with its own callback so the
/// existing area/window selection flows stay untouched.
@MainActor
final class AllInOneController: NSObject {

    /// (action, adjusted rect in AppKit global screen coords, screen). For Window
    /// and Fullscreen the rect is the current selection but the engine ignores it.
    typealias ActionHandler = (AllInOneAction, CGRect, NSScreen) -> Void
    typealias CancelHandler = () -> Void

    private let screen: NSScreen
    private let initialRect: CGRect
    private let onAction: ActionHandler
    private let onCancel: CancelHandler

    private var overlayWindow: AllInOneOverlayWindow?
    private var panelWindow: AllInOnePanelWindow?
    private var keyMonitor: Any?
    private var didFinish = false

    /// `initialRect` is in AppKit global screen coordinates, already validated by
    /// the caller to sit inside `screen`.
    init(screen: NSScreen, initialRect: CGRect, onAction: @escaping ActionHandler, onCancel: @escaping CancelHandler) {
        self.screen = screen
        self.initialRect = initialRect
        self.onAction = onAction
        self.onCancel = onCancel
    }

    func prepareAndShow(engine: CaptureEngine) async {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let image = await engine.captureRectToImage(screen.frame, on: screen)
        var imgRect = NSRect(origin: .zero, size: screen.frame.size)
        let frozen = image?.cgImage(forProposedRect: &imgRect, context: nil, hints: nil)

        // Overlay rect is in the overlay view's local space (origin at the
        // screen's bottom-left), so shift the global rect by the screen origin.
        let localRect = CGRect(
            x: initialRect.origin.x - screen.frame.origin.x,
            y: initialRect.origin.y - screen.frame.origin.y,
            width: initialRect.width,
            height: initialRect.height
        )

        let overlay = AllInOneOverlayWindow(screen: screen, initialRect: localRect, frozenImage: frozen)
        overlay.onRectChanged = { [weak self] rect in self?.repositionPanel(localRect: rect) }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.show()
        overlayWindow = overlay

        let panel = AllInOnePanelWindow { [weak self] action in
            self?.finish(action: action)
        }
        panelWindow = panel
        panel.showAnchored(below: localRect, on: screen)

        focusOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusOverlay() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.focusOverlay() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }   // Escape
            return event
        }
    }

    private func focusOverlay() {
        guard let overlay = overlayWindow, overlay.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
        overlay.makeMain()
        overlay.focusContent()
    }

    private func repositionPanel(localRect: CGRect) {
        panelWindow?.reanchor(below: localRect, on: screen)
    }

    /// Current selection in AppKit global screen coordinates.
    private var currentGlobalRect: CGRect {
        let local = overlayWindow?.selectionRect ?? CGRect(
            x: initialRect.origin.x - screen.frame.origin.x,
            y: initialRect.origin.y - screen.frame.origin.y,
            width: initialRect.width,
            height: initialRect.height
        )
        return CGRect(
            x: local.origin.x + screen.frame.origin.x,
            y: local.origin.y + screen.frame.origin.y,
            width: local.width,
            height: local.height
        )
    }

    private func finish(action: AllInOneAction) {
        guard !didFinish else { return }
        didFinish = true
        let rect = currentGlobalRect
        tearDown()
        // Small delay mirrors AreaSelectionWindow.finish so the overlay is gone
        // before the capture/record path runs (no overlay pixels in the grab).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.onAction(action, rect, self.screen)
        }
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        tearDown()
        onCancel()
    }

    /// GUI test hooks: the floating panel window (for glass snapshots) and a
    /// cancel path so the harness can close the surface without key events.
    var uiTestPanelWindow: NSWindow? { panelWindow }
    func uiTestCancel() { cancel() }

    private func tearDown() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        panelWindow?.orderOut(nil)
        panelWindow = nil
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }
}

// MARK: - Overlay window

@MainActor
private final class AllInOneOverlayWindow: NSWindow {

    var onRectChanged: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let overlayView: AllInOneOverlayView

    var selectionRect: CGRect { overlayView.selectionRect }

    init(screen: NSScreen, initialRect: CGRect, frozenImage: CGImage?) {
        overlayView = AllInOneOverlayView(initialRect: initialRect, frozenImage: frozenImage)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.onRectChanged = { [weak self] rect in self?.onRectChanged?(rect) }
        overlayView.onCancel = { [weak self] in self?.onCancel?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() { orderFrontRegardless() }
    func focusContent() { makeFirstResponder(overlayView) }
}

// MARK: - Overlay view (editable rect with handles)

@MainActor
private final class AllInOneOverlayView: NSView {

    var onRectChanged: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var selectionRect: CGRect
    private let frozenImage: CGImage?

    private let handleSize: CGFloat = 10
    private let minSize: CGFloat = 40

    private enum DragMode {
        case none
        case move(grabOffset: CGSize)
        case resize(Handle, anchor: CGPoint)
    }

    /// The eight resize handles, named by compass position in AppKit space
    /// (bottom-left origin), so `n` is the top edge.
    private enum Handle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w
    }

    private var dragMode: DragMode = .none

    init(initialRect: CGRect, frozenImage: CGImage?) {
        self.selectionRect = initialRect
        self.frozenImage = frozenImage
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Frozen screenshot under the dim so the selection reads against the real
        // content (matches AreaSelectionWindow's frozen-image approach).
        if let frozenImage {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.draw(frozenImage, in: bounds)
                ctx.restoreGState()
            }
        }

        // Dim everywhere except inside the selection.
        let outer = NSBezierPath(rect: bounds)
        let inner = NSBezierPath(rect: selectionRect)
        outer.append(inner)
        outer.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        outer.fill()

        guard !selectionRect.isEmpty else { return }

        KritColors.accent.setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 1.5
        border.stroke()

        drawDimensionLabel()
        drawHandles()
    }

    private func drawHandles() {
        for handle in Handle.allCases {
            let center = point(for: handle, in: selectionRect)
            let rect = NSRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            let path = NSBezierPath(ovalIn: rect)
            NSColor.white.setFill()
            path.fill()
            KritColors.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawDimensionLabel() {
        let label = String(format: "%.0f \u{00D7} %.0f", selectionRect.width, selectionRect.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let origin = NSPoint(x: selectionRect.midX - size.width / 2, y: selectionRect.maxY + 8)
        let bg = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        str.draw(at: origin)
    }

    private func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .nw: return CGPoint(x: rect.minX, y: rect.maxY)
        case .n:  return CGPoint(x: rect.midX, y: rect.maxY)
        case .ne: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .e:  return CGPoint(x: rect.maxX, y: rect.midY)
        case .se: return CGPoint(x: rect.maxX, y: rect.minY)
        case .s:  return CGPoint(x: rect.midX, y: rect.minY)
        case .sw: return CGPoint(x: rect.minX, y: rect.minY)
        case .w:  return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// The fixed corner/edge opposite the dragged handle, used as the resize anchor.
    private func anchorPoint(for handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .nw: return CGPoint(x: rect.maxX, y: rect.minY)
        case .ne: return CGPoint(x: rect.minX, y: rect.minY)
        case .se: return CGPoint(x: rect.minX, y: rect.maxY)
        case .sw: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .n:  return CGPoint(x: rect.minX, y: rect.minY)
        case .s:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .e:  return CGPoint(x: rect.minX, y: rect.minY)
        case .w:  return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    private func handle(at point: NSPoint) -> Handle? {
        let hitPadding: CGFloat = 9
        for handle in Handle.allCases {
            let center = self.point(for: handle, in: selectionRect)
            let rect = NSRect(
                x: center.x - handleSize / 2 - hitPadding,
                y: center.y - handleSize / 2 - hitPadding,
                width: handleSize + hitPadding * 2,
                height: handleSize + hitPadding * 2
            )
            if rect.contains(point) { return handle }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if let win = window, !win.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(self)
        }

        let p = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: p) {
            dragMode = .resize(handle, anchor: anchorPoint(for: handle, in: selectionRect))
        } else if selectionRect.contains(p) {
            dragMode = .move(grabOffset: CGSize(width: p.x - selectionRect.minX, height: p.y - selectionRect.minY))
        } else {
            // Click outside starts a fresh rect drag from this point.
            dragMode = .resize(.ne, anchor: p)
            selectionRect = CGRect(origin: p, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .none:
            return
        case .move(let grabOffset):
            var origin = NSPoint(x: p.x - grabOffset.width, y: p.y - grabOffset.height)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - selectionRect.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - selectionRect.height)
            selectionRect.origin = origin
        case .resize(_, let anchor):
            let clamped = NSPoint(
                x: min(max(p.x, bounds.minX), bounds.maxX),
                y: min(max(p.y, bounds.minY), bounds.maxY)
            )
            selectionRect = CGRect(
                x: min(anchor.x, clamped.x),
                y: min(anchor.y, clamped.y),
                width: abs(clamped.x - anchor.x),
                height: abs(clamped.y - anchor.y)
            )
        }
        needsDisplay = true
        onRectChanged?(selectionRect)
    }

    override func mouseUp(with event: NSEvent) {
        // Enforce a sane minimum so a tiny accidental drag never produces an
        // unusable selection; clamp inside the screen bounds.
        if !selectionRect.isEmpty {
            var rect = selectionRect
            rect.size.width = max(rect.width, minSize)
            rect.size.height = max(rect.height, minSize)
            rect.origin.x = min(rect.origin.x, bounds.maxX - rect.width)
            rect.origin.y = min(rect.origin.y, bounds.maxY - rect.height)
            rect.origin.x = max(rect.origin.x, bounds.minX)
            rect.origin.y = max(rect.origin.y, bounds.minY)
            selectionRect = rect
        }
        dragMode = .none
        needsDisplay = true
        onRectChanged?(selectionRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Escape
    }
}

// MARK: - Options panel

@MainActor
private final class AllInOnePanelWindow: NSWindow {

    private static let buttonWidth: CGFloat = 76
    private static let buttonHeight: CGFloat = 60
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 10
    private static let gapBelowSelection: CGFloat = 14

    private let onPick: (AllInOneAction) -> Void

    private struct Option {
        let action: AllInOneAction
        let title: String
        let symbol: String
    }

    private let options: [Option] = [
        Option(action: .capture, title: "Capture", symbol: "camera.viewfinder"),
        Option(action: .record, title: "Record", symbol: "record.circle"),
        Option(action: .window, title: "Window", symbol: "macwindow"),
        Option(action: .fullscreen, title: "Fullscreen", symbol: "rectangle.on.rectangle"),
        Option(action: .scrolling, title: "Scrolling", symbol: "scroll"),
        Option(action: .ocr, title: "OCR", symbol: "text.viewfinder"),
    ]

    init(onPick: @escaping (AllInOneAction) -> Void) {
        self.onPick = onPick
        let width = Self.inset * 2 + CGFloat(6) * Self.buttonWidth + CGFloat(5) * Self.spacing
        let height = Self.inset * 2 + Self.buttonHeight
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver + 1   // sits above the overlay
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        buildContent()
    }

    override var canBecomeKey: Bool { false }

    private func buildContent() {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = ChromeFactory.Radius.dock
        root.layer?.cornerCurve = .continuous
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.6
        root.layer?.shadowRadius = 26
        root.layer?.shadowOffset = CGSize(width: 0, height: -10)
        contentView = root

        // Each option is its own glass shape grouped in one glass cluster, so on
        // macOS 26 the six shapes merge into a single panel when it appears and the
        // hovered shape lifts/morphs out of the group. The cluster (one merged
        // glass system) is the single glass surface for this window. Inner radius
        // is concentric with the dock: 18 outer, inset 10 -> 8. There is no backing
        // under them (glass over glass is forbidden); on the pre-26 fallback each
        // button carries its own blur and the cluster is a plain passthrough.
        let buttonRadius = ChromeFactory.concentricRadius(outer: ChromeFactory.Radius.dock, inset: Self.inset)
        let clusterContent = NSView(frame: root.bounds)

        var x = Self.inset
        for option in options {
            let button = AllInOneOptionButton(symbol: option.symbol, title: option.title)
            button.onClick = { [weak self] in self?.onPick(option.action) }
            let shape = ChromeFactory.make(content: button, cornerRadius: buttonRadius)
            shape.frame = NSRect(x: x, y: Self.inset, width: Self.buttonWidth, height: Self.buttonHeight)
            button.glassShape = shape
            clusterContent.addSubview(shape)
            x += Self.buttonWidth + Self.spacing
        }

        let cluster = ChromeFactory.makeCluster(content: clusterContent, spacing: Self.spacing)
        cluster.frame = root.bounds
        cluster.autoresizingMask = [.width, .height]
        root.addSubview(cluster)
    }

    /// Anchors the panel under `localRect` (overlay-local coords) on `screen`,
    /// converting to global. Falls back to the screen bottom if it would clip.
    func showAnchored(below localRect: CGRect, on screen: NSScreen) {
        reanchor(below: localRect, on: screen)
        orderFrontRegardless()
    }

    func reanchor(below localRect: CGRect, on screen: NSScreen) {
        let globalRectMinX = localRect.minX + screen.frame.origin.x
        let globalRectMidX = localRect.midX + screen.frame.origin.x
        let globalRectMinY = localRect.minY + screen.frame.origin.y
        let globalRectMaxY = localRect.maxY + screen.frame.origin.y

        let visible = screen.visibleFrame
        var x = globalRectMidX - frame.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)

        // Prefer below the selection; if it would drop off the bottom, place it
        // above; if neither fits, pin to the screen bottom.
        var y = globalRectMinY - Self.gapBelowSelection - frame.height
        if y < visible.minY + 8 {
            let above = globalRectMaxY + Self.gapBelowSelection
            if above + frame.height <= visible.maxY - 8 {
                y = above
            } else {
                y = visible.minY + 24
            }
        }
        _ = globalRectMinX
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// One option as the content of a glass shape. The shape (its `glassShape`
/// wrapper) is the visible glass; this view draws the icon + label and toggles
/// the shape's accent tint to mark the moment's primary action on hover/press.
@MainActor
private final class AllInOneOptionButton: NSView {

    var onClick: (() -> Void)?
    /// The glass wrapper the controller hands back after `ChromeFactory.make`.
    /// Hover/press tint it; on the fallback path tinting falls back to a wash.
    weak var glassShape: NSView?

    private var trackingArea: NSTrackingArea?
    /// Pre-26 accent wash, lazily added on first hover (real glass tints itself).
    private var fallbackWash: CALayer?

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(iconConfig)
        icon.contentTintColor = KritColors.accent
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.86)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { applyTint(KritColors.accent.withAlphaComponent(0.55), washAlpha: 0.16) }
    override func mouseExited(with event: NSEvent) { applyTint(nil, washAlpha: 0) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        applyTint(KritColors.accent, washAlpha: 0.30)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }

    override func mouseUp(with event: NSEvent) {
        applyTint(nil, washAlpha: 0)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    /// Real glass takes the live tint; the pre-26 blur gets an accent wash over
    /// the content so the hovered/pressed shape still reads as the primary action.
    private func applyTint(_ tint: NSColor?, washAlpha: CGFloat) {
        if #available(macOS 26.0, *), let glass = glassShape as? NSGlassEffectView {
            glass.tintColor = tint
            return
        }
        wantsLayer = true
        if fallbackWash == nil {
            let wash = CALayer()
            wash.frame = bounds
            wash.cornerCurve = .continuous
            wash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.insertSublayer(wash, at: 0)
            fallbackWash = wash
        }
        fallbackWash?.backgroundColor = (tint ?? .clear).withAlphaComponent(washAlpha).cgColor
    }
}
