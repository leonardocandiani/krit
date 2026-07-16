import AppKit

/// The action a user picks from the All-in-One options panel. The controller
/// only reports intent plus the final adjusted rect; the engine owns the real
/// capture/record routing.
@MainActor
enum AllInOneAction: CaseIterable, Equatable {
    case capture
    case record
    case window
    case fullscreen
    case scrolling
    case ocr

    var accessibilityIdentifier: String {
        "all-in-one.\(rawValue)"
    }

    var accessibilityLabel: String {
        switch self {
        case .capture: "Capture"
        case .record: "Record"
        case .window: "Window"
        case .fullscreen: "Fullscreen"
        case .scrolling: "Scrolling"
        case .ocr: "OCR"
        }
    }

    var symbol: String {
        switch self {
        case .capture: "camera.viewfinder"
        case .record: "record.circle"
        case .window: "macwindow"
        case .fullscreen: "rectangle.on.rectangle"
        case .scrolling: "scroll"
        case .ocr: "text.viewfinder"
        }
    }

    /// The default receives the first keyboard focus, so its visual hierarchy
    /// must make the result of pressing Return or Space obvious.
    var isPrimary: Bool { self == .capture }

    /// The dock groups capture output, target selection, and specialized tools.
    /// A boundary follows the second action in the first two groups.
    var endsDockGroup: Bool {
        self == .record || self == .fullscreen
    }

    private var rawValue: String {
        switch self {
        case .capture: "capture"
        case .record: "record"
        case .window: "window"
        case .fullscreen: "fullscreen"
        case .scrolling: "scrolling"
        case .ocr: "ocr"
        }
    }
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
    private var isInvalidated = false
    private var didInvokeAction = false
    private var pendingAction: DispatchWorkItem?

    /// `initialRect` is in AppKit global screen coordinates, already validated by
    /// the caller to sit inside `screen`.
    init(screen: NSScreen, initialRect: CGRect, onAction: @escaping ActionHandler, onCancel: @escaping CancelHandler) {
        self.screen = screen
        self.initialRect = initialRect
        self.onAction = onAction
        self.onCancel = onCancel
    }

    func prepareAndShow(engine: CaptureEngine) async {
        // Grab the frozen backdrop BEFORE activating/raising anything, mirroring the
        // area path: the grab must catch the live dark desktop, never a paused
        // wallpaper still nor our own overlay.
        let image = await engine.captureRectToImage(screen.frame, on: screen)
        // A newer capture command can dismiss this controller while the async
        // backdrop grab is in flight. Do not recreate its windows once that newer
        // intent owns the screen.
        guard !isInvalidated else { return }
        var imgRect = NSRect(origin: .zero, size: screen.frame.size)
        let frozen = image?.cgImage(forProposedRect: &imgRect, context: nil, hints: nil)

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

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
        overlay.onEditingFinished = { [weak self] in self?.focusPanel() }
        overlay.show()
        overlayWindow = overlay

        let panel = AllInOnePanelWindow { [weak self] action in
            self?.finish(action: action)
        }
        panelWindow = panel
        panel.showAnchored(below: localRect, on: screen)

        focusPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.focusPanel() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }   // Escape
            return event
        }
    }

    private func focusPanel() {
        guard let panel = panelWindow, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.focusFirstOption()
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
        guard !didFinish, !isInvalidated else { return }
        didFinish = true
        let rect = currentGlobalRect
        tearDown()
        // Small delay mirrors AreaSelectionWindow.finish so the overlay is gone
        // before the capture/record path runs (no overlay pixels in the grab).
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.pendingAction = nil
            self.didInvokeAction = true
            self.onAction(action, rect, self.screen)
        }
        pendingAction = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func cancel() {
        guard !isInvalidated, !didInvokeAction else { return }
        isInvalidated = true
        pendingAction?.cancel()
        pendingAction = nil
        tearDown()
        onCancel()
    }

    /// GUI test hooks: the floating panel window (for glass snapshots) and a
    /// cancel path so the harness can close the surface without key events.
    var uiTestPanelWindow: NSWindow? { panelWindow }
    var uiTestInitialRect: CGRect { initialRect }
    var uiTestScreenFrame: CGRect { screen.frame }
    func uiTestCancel() { cancel() }

    /// A newer capture intent owns the screen. Dismiss this interactive session
    /// synchronously so its frozen overlay cannot leak into the replacement.
    func dismissForReplacement() { cancel() }

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
    var onEditingFinished: (() -> Void)?

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
        // Opaque when the frozen backdrop is in hand: a clear panel would let the
        // layer-backed first frame composite the live (paused→light) wallpaper
        // through, the dark→light flash. Same fix as the area overlay.
        let hasFrozenBackdrop = frozenImage != nil
        isOpaque = hasFrozenBackdrop
        backgroundColor = hasFrozenBackdrop ? .black : .clear
        level = .screenSaver
        sharingType = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.onRectChanged = { [weak self] rect in self?.onRectChanged?(rect) }
        overlayView.onCancel = { [weak self] in self?.onCancel?() }
        overlayView.onEditingFinished = { [weak self] in self?.onEditingFinished?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        // Force the opaque backdrop onto the first composited frame; a layer-backed
        // view defers its first draw otherwise, leaving a clear gap the paused
        // aerial flashes light through. Same as the area overlay's show().
        overlayView.setNeedsDisplay(overlayView.bounds)
        overlayView.displayIfNeeded()
        orderFrontRegardless()
    }
}

// MARK: - Overlay view (editable rect with handles)

@MainActor
private final class AllInOneOverlayView: NSView {

    var onRectChanged: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onEditingFinished: (() -> Void)?

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
        } else {
            // No frozen grab: a solid dark base, never a clear panel that would let
            // the live (paused→light) wallpaper flash through.
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath.fill(bounds)
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
        onEditingFinished?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Escape
    }
}

// MARK: - Options panel

@MainActor
final class AllInOnePanelWindow: NSPanel {

    private static let buttonWidth: CGFloat = 76
    private static let buttonHeight: CGFloat = 60
    private static let intraGroupSpacing: CGFloat = 2
    private static let groupGap: CGFloat = 18
    private static let inset: CGFloat = 10
    private static let gapBelowSelection: CGFloat = 14

    private let onPick: (AllInOneAction) -> Void
    private let options = AllInOneAction.allCases
    private(set) var optionButtons: [NSButton] = []

    init(onPick: @escaping (AllInOneAction) -> Void) {
        self.onPick = onPick
        let boundaryCount = AllInOneAction.allCases.filter { $0.endsDockGroup }.count
        let regularGapCount = AllInOneAction.allCases.count - 1 - boundaryCount
        let width = Self.inset * 2
            + CGFloat(AllInOneAction.allCases.count) * Self.buttonWidth
            + CGFloat(regularGapCount) * Self.intraGroupSpacing
            + CGFloat(boundaryCount) * Self.groupGap
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
        sharingType = .none
        hasShadow = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

        // The panel is one dock, not six competing cards. Individual actions stay
        // transparent at rest; the single shell owns the glass/fallback treatment.
        let dockContent = NSView(frame: root.bounds)

        var x = Self.inset
        for (index, action) in options.enumerated() {
            let button = AllInOneOptionButton(
                action: action,
                symbol: action.symbol,
                isPrimary: action.isPrimary
            )
            button.onClick = { [weak self] in self?.onPick(action) }
            button.frame = NSRect(x: x, y: Self.inset, width: Self.buttonWidth, height: Self.buttonHeight)
            dockContent.addSubview(button)
            optionButtons.append(button)

            guard index < options.count - 1 else { continue }
            if action.endsDockGroup {
                let divider = NSView(frame: NSRect(
                    x: x + Self.buttonWidth + (Self.groupGap - 1) / 2,
                    y: 18,
                    width: 1,
                    height: frame.height - 36
                ))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
                dockContent.addSubview(divider)
            }
            x += Self.buttonWidth + (action.endsDockGroup ? Self.groupGap : Self.intraGroupSpacing)
        }

        let dock: NSView
        if #available(macOS 26.0, *), !ChromeFactory.forceFallback {
            dock = ChromeFactory.make(content: dockContent, cornerRadius: ChromeFactory.Radius.dock)
        } else {
            dock = Self.makeFallbackDock(content: dockContent)
        }
        dock.frame = root.bounds
        dock.autoresizingMask = [.width, .height]
        root.addSubview(dock)

        connectKeyViewLoop()
        initialFirstResponder = optionButtons.first
    }

    /// The panel floats over a separate full-screen selection window. A
    /// behind-window visual effect can resolve to black in that arrangement, so
    /// the fallback is one stable translucent shell rather than six fragile blurs.
    private static func makeFallbackDock(content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let dock = NSView()
        dock.wantsLayer = true
        dock.layer?.cornerRadius = ChromeFactory.Radius.dock
        dock.layer?.cornerCurve = .continuous
        dock.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dock.layer?.borderWidth = 1
        dock.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        dock.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            content.topAnchor.constraint(equalTo: dock.topAnchor),
            content.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
        ])
        return dock
    }

    /// Anchors the panel under `localRect` (overlay-local coords) on `screen`,
    /// converting to global. Falls back to the screen bottom if it would clip.
    func showAnchored(below localRect: CGRect, on screen: NSScreen) {
        reanchor(below: localRect, on: screen)
        orderFrontRegardless()
        focusFirstOption()
    }

    func focusFirstOption() {
        guard let first = optionButtons.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(first)
    }

    func moveFocus(from button: NSButton, backwards: Bool) {
        guard let currentIndex = optionButtons.firstIndex(where: { $0 === button }) else { return }
        let offset = backwards ? optionButtons.count - 1 : 1
        makeFirstResponder(optionButtons[(currentIndex + offset) % optionButtons.count])
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

    private func connectKeyViewLoop() {
        guard !optionButtons.isEmpty else { return }
        for index in optionButtons.indices {
            optionButtons[index].nextKeyView = optionButtons[(index + 1) % optionButtons.count]
        }
    }
}

/// One action inside the unified dock. It is a real `NSButton`, so AppKit gives
/// it key-loop and VoiceOver activation semantics while the custom subviews keep
/// the compact icon-over-label presentation used by the capture flow.
@MainActor
private final class AllInOneOptionButton: NSButton {

    var onClick: (() -> Void)?
    private let icon: NSImageView
    private let label: NSTextField
    private let isPrimary: Bool
    private var trackingArea: NSTrackingArea?
    private var pointerIsInside = false

    init(action: AllInOneAction, symbol: String, isPrimary: Bool) {
        icon = NSImageView()
        label = NSTextField(labelWithString: action.accessibilityLabel)
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        // The dock positions its direct actions with explicit frames. Letting
        // NSGlassEffectView derive constraints here collapses them to intrinsic
        // label width and zero height after its first layout pass.
        translatesAutoresizingMaskIntoConstraints = true
        isBordered = false
        title = ""
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.control
        layer?.cornerCurve = .continuous
        target = self
        self.action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(action.accessibilityIdentifier)
        setAccessibilityLabel(action.accessibilityLabel)
        toolTip = action.accessibilityLabel

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action.accessibilityLabel)?.withSymbolConfiguration(iconConfig)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
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
        applyInteraction(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        refreshInteraction()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        refreshInteraction()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { refreshInteraction() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            applyInteraction(pointerIsInside ? .hovered : .idle)
        }
        return accepted
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty || modifiers == .shift else { break }
            if let panel = window as? AllInOnePanelWindow {
                panel.moveFocus(from: self, backwards: modifiers.contains(.shift))
                return
            }
        case 36, 49, 76: // Return, Space, keypad Enter
            performClick(nil)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        applyInteraction(.pressed)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        refreshInteraction()
    }

    @objc private func activate() {
        onClick?()
    }

    private enum Interaction {
        case idle
        case focused
        case hovered
        case pressed
    }

    private func refreshInteraction() {
        if pointerIsInside {
            applyInteraction(.hovered)
        } else if window?.firstResponder === self {
            applyInteraction(.focused)
        } else {
            applyInteraction(.idle)
        }
    }

    private func applyInteraction(_ interaction: Interaction) {
        let washAlpha: CGFloat
        let borderAlpha: CGFloat
        let isPressed: Bool
        switch interaction {
        case .idle:
            icon.contentTintColor = isPrimary ? KritColors.accent : NSColor.white.withAlphaComponent(0.82)
            label.textColor = isPrimary ? KritColors.accent.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.80)
            washAlpha = isPrimary ? 0.10 : 0
            borderAlpha = isPrimary ? 0.16 : 0
            isPressed = false
        case .focused:
            icon.contentTintColor = KritColors.accent
            label.textColor = .white
            washAlpha = 0.18
            borderAlpha = 0.58
            isPressed = false
        case .hovered:
            icon.contentTintColor = KritColors.accent
            label.textColor = .white
            washAlpha = 0.16
            borderAlpha = 0
            isPressed = false
        case .pressed:
            icon.contentTintColor = KritColors.accent
            label.textColor = .white
            washAlpha = 0.30
            borderAlpha = 0.72
            isPressed = true
        }
        layer?.backgroundColor = KritColors.accent.withAlphaComponent(washAlpha).cgColor
        layer?.borderWidth = borderAlpha > 0 ? 1 : 0
        layer?.borderColor = KritColors.accent.withAlphaComponent(borderAlpha).cgColor
        layer?.transform = isPressed ? CATransform3DMakeScale(0.98, 0.98, 1) : CATransform3DIdentity
    }
}
