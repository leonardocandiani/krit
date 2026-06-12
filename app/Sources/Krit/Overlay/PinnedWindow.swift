import AppKit

/// A floating screenshot window that stays on top of everything.
/// Can be resized, dragged, and dismissed on hover.
@MainActor
final class PinnedWindow: NSWindow {

    private static var pinned: [PinnedWindow] = []

    static func pin(image: NSImage) {
        let win = PinnedWindow(image: image)
        win.show()
        pinned.append(win)
    }

    static func closeAll() {
        pinned.forEach { $0.orderOut(nil) }
        pinned.removeAll()
    }

    private let imageView: DraggablePinnedImageView
    private var closeButton: NSButton?
    private var resizeGrip: NSImageView?
    private var isHovered = false
    /// The window's natural pinned size (100% zoom), captured at init. Zoom
    /// presets scale relative to this so 100% always returns to the original.
    private var naturalPinnedSize: NSSize = .zero
    /// When locked, the pin cannot be moved, resized, or zoomed, so it stays put
    /// as a reference. Mirrored into isMovableByWindowBackground and styleMask.
    private var isLocked = false

    // Place-on-the-side: while the user drags the pin near a screen edge, a hint
    // strip appears on that edge; releasing there snaps the window flush against
    // it. The candidate edge is tracked during the drag and consumed on mouse-up.
    private var snapHint: SnapHintWindow?
    private var snapCandidateEdge: ScreenEdge?
    private var snapMouseUpMonitor: Any?
    /// How close (in points) the pin's edge must get to a screen edge before the
    /// place-on-the-side hint arms.
    private let snapThreshold: CGFloat = 36

    init(image: NSImage) {
        let size = constrainedSize(for: image.size)
        let draggableImage = DraggablePinnedImageView(frame: NSRect(origin: .zero, size: size))
        imageView = draggableImage

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        naturalPinnedSize = size
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true

        // Force proportional resize so the layer border always perfectly fits the image!
        // aspectRatio handles the proportional clamp on the native .resizable border drag,
        // so there is no custom edge-drag path that would need a separate clamp.
        self.aspectRatio = size

        // Clamp resize so the pin stays usable (it can no longer shrink to nothing) and
        // never grows past the visible screen. Both bounds keep the image aspect ratio so
        // the proportional border drag stays consistent.
        contentMinSize = pinnedMinSize(for: size)
        contentMaxSize = pinnedMaxSize(for: size)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = KritColors.pinnedBorder.cgColor
        imageView.autoresizingMask = [.width, .height]

        draggableImage.onHoverStateChanged = { [weak self] hovered in
            self?.isHovered = hovered
            if hovered {
                self?.showCloseButton()
            } else {
                self?.hideCloseButton()
            }
        }

        contentView = imageView
        center()
        delegate = self
    }

    func show() {
        orderFrontRegardless()
        SoundManager.play(.pin)
    }

    // MARK: - Hover (shows close button)

    private func showCloseButton() {
        guard closeButton == nil, let content = contentView else { return }
        let btn = NSButton(frame: NSRect(x: content.bounds.width - 24, y: content.bounds.height - 24, width: 20, height: 20))
        btn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.target = self
        btn.action = #selector(closeTapped)
        btn.alphaValue = 0
        // Stick to top-right corner during live window resize.
        btn.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(btn)
        closeButton = btn

        let grip = NSImageView(frame: NSRect(x: content.bounds.width - 20, y: 4, width: 16, height: 16))
        grip.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize")
        grip.contentTintColor = .white.withAlphaComponent(0.6)
        grip.alphaValue = 0
        // Stick to bottom-right corner during live window resize.
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(grip)
        resizeGrip = grip

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 1
            grip.animator().alphaValue = 1
        }
    }

    private func hideCloseButton() {
        guard let btn = closeButton else { return }
        let grip = resizeGrip
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            btn.animator().alphaValue = 0
            grip?.animator().alphaValue = 0
        }, completionHandler: {
            btn.removeFromSuperview()
            grip?.removeFromSuperview()
        })
        closeButton = nil
        resizeGrip = nil
    }

    @objc private func closeTapped() {
        PinnedWindow.pinned.removeAll { $0 === self }
        orderOut(nil)
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    // MARK: - Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(buildContextMenu(), with: event, for: view)
    }

    /// The CleanShot-style rich menu for a pinned window. Items without a real
    /// backend (Upload to Cloud) are present but disabled so the surface matches
    /// the reference without faking behaviour.
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        addItem(to: menu, title: "Close", action: #selector(closeTapped), key: "w")
        addItem(to: menu, title: "Open Annotation Tool", action: #selector(editPinnedImage), key: "e")
        addItem(to: menu, title: "Copy to Clipboard", action: #selector(copyPinnedImage), key: "c")
        // Upload to Cloud has no backend in KRIT; keep the row for parity but
        // leave it disabled so it never pretends to upload. Wire a target/action
        // here once a cloud destination exists.
        let upload = NSMenuItem(title: "Upload to Cloud", action: nil, keyEquivalent: "u")
        upload.keyEquivalentModifierMask = [.command]
        upload.isEnabled = false
        menu.addItem(upload)
        addItem(to: menu, title: "Extract text", action: #selector(extractText), key: "")
        addItem(to: menu, title: "Save As…", action: #selector(savePinnedImage), key: "s")

        menu.addItem(.separator())

        let lock = addItem(to: menu, title: "Lock", action: #selector(toggleLock), key: "l")
        lock.state = isLocked ? .on : .off

        menu.addItem(makeZoomMenuItem())
        menu.addItem(makeOpacityMenuItem())

        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        item.target = self
        menu.addItem(item)
        return item
    }

    /// Zoom submenu: presets that rescale the window around its center, keeping
    /// the image aspect ratio. 100% is the window's natural pinned size.
    private func makeZoomMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [50, 100, 200] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(percent) / 100.0
            item.isEnabled = !isLocked
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// Opacity submenu (F4): presets that set the whole window's alphaValue.
    private func makeOpacityMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [20, 50, 100] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Double(percent) / 100.0
            item.state = abs(alphaValue - CGFloat(percent) / 100.0) < 0.001 ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        alphaValue = CGFloat(value)
    }

    /// Rescales the pinned window to `factor` of its natural pinned size around
    /// its current center, clamped to the same min/max bounds the resize border
    /// uses so a preset can never collapse or overflow the screen.
    @objc private func setZoom(_ sender: NSMenuItem) {
        guard !isLocked, let factor = sender.representedObject as? Double else { return }
        let base = naturalPinnedSize
        var target = NSSize(width: base.width * CGFloat(factor), height: base.height * CGFloat(factor))
        target = clampToBounds(target)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let origin = NSPoint(x: center.x - target.width / 2, y: center.y - target.height / 2)
        setFrame(NSRect(origin: origin, size: target), display: true, animate: true)
    }

    /// Clamp a candidate size into the window's content min/max, preserving the
    /// image aspect ratio (both bounds already keep it), so zoom presets stay in
    /// the same envelope as the live resize border.
    private func clampToBounds(_ size: NSSize) -> NSSize {
        var clamped = size
        if clamped.width < contentMinSize.width || clamped.height < contentMinSize.height {
            clamped = contentMinSize
        }
        if clamped.width > contentMaxSize.width || clamped.height > contentMaxSize.height {
            clamped = contentMaxSize
        }
        return clamped
    }

    /// Toggles Lock: a locked pin can no longer be moved, resized, or zoomed, so
    /// it stays put as a reference. Stored so the menu can show the checkmark.
    @objc private func toggleLock() {
        isLocked.toggle()
        isMovableByWindowBackground = !isLocked
        styleMask = isLocked ? [.borderless] : [.borderless, .resizable]
    }

    /// Runs OCR on the pinned image and copies the recognized text to the
    /// clipboard, the same Extract text path the editor offers.
    @objc private func extractText() {
        guard let image = imageView.image else { return }
        Task { @MainActor in
            let text = await OCREngine.recognizeText(in: image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ToastWindow.show(message: "No text found")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmed, forType: .string)
            ToastWindow.show(message: "✓ Text copied")
        }
    }

    @objc private func copyPinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.copyToClipboard(image: image)
        ToastWindow.show(message: "✓ Copied to clipboard")
    }

    @objc private func savePinnedImage() {
        guard let image = imageView.image else { return }
        ImageExporter.saveWithPanel(image: image, suggestedName: ImageExporter.timestampedName, presentingWindow: self) { result in
            if result.didSave {
                ToastWindow.show(message: "✓ Saved screenshot")
            }
        }
    }

    @objc private func editPinnedImage() {
        guard let image = imageView.image else { return }
        AnnotationWindowController.open(image: image)
        closeTapped()
    }

    @objc private func closeAllPins() { PinnedWindow.closeAll() }

    // MARK: - Place on the side (snap to edge)

    /// A live drag near a screen edge arms the place-on-the-side hint. The window
    /// move is driven natively by isMovableByWindowBackground, so there is no
    /// drag callback; windowDidMove is the per-frame hook. The edge with the
    /// nearest gap inside the threshold wins; releasing there snaps the pin flush.
    fileprivate func handleWindowDidMove() {
        guard !isLocked, let screen = screen ?? NSScreen.main else {
            clearSnapHint()
            return
        }
        let visible = screen.visibleFrame
        let edge = nearestSnapEdge(in: visible)
        if let edge {
            snapCandidateEdge = edge
            showSnapHint(for: edge, in: visible)
            armSnapMouseUpMonitor()
        } else {
            clearSnapHint()
        }
    }

    /// The screen edge the window is hovering closest to within the snap
    /// threshold, or nil when it is not near any edge.
    private func nearestSnapEdge(in visible: NSRect) -> ScreenEdge? {
        let f = frame
        let gaps: [(ScreenEdge, CGFloat)] = [
            (.left, f.minX - visible.minX),
            (.right, visible.maxX - f.maxX),
            (.top, visible.maxY - f.maxY),
            (.bottom, f.minY - visible.minY),
        ]
        let within = gaps.filter { $0.1 <= snapThreshold }
        return within.min(by: { abs($0.1) < abs($1.1) })?.0
    }

    /// Shows (or retargets) the edge hint strip on `edge` of the visible frame.
    private func showSnapHint(for edge: ScreenEdge, in visible: NSRect) {
        let hint: SnapHintWindow
        if let existing = snapHint {
            hint = existing
        } else {
            hint = SnapHintWindow()
            snapHint = hint
        }
        hint.present(for: edge, in: visible)
    }

    /// Watches for the drag release so the pin can snap to the armed edge. One
    /// monitor at a time; torn down when the hint clears.
    private func armSnapMouseUpMonitor() {
        guard snapMouseUpMonitor == nil else { return }
        snapMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.commitSnapIfNeeded()
            return event
        }
    }

    /// On release, if an edge is armed, slide the pin flush against it, then
    /// clear the hint and monitor.
    private func commitSnapIfNeeded() {
        defer { clearSnapHint() }
        guard !isLocked, let edge = snapCandidateEdge,
              let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = frame.origin
        switch edge {
        case .left:   origin.x = visible.minX
        case .right:  origin.x = visible.maxX - frame.width
        case .top:    origin.y = visible.maxY - frame.height
        case .bottom: origin.y = visible.minY
        }
        setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: true)
    }

    /// Tears down the hint strip and the release monitor. Idempotent.
    private func clearSnapHint() {
        snapCandidateEdge = nil
        snapHint?.dismiss()
        snapHint = nil
        if let monitor = snapMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            snapMouseUpMonitor = nil
        }
    }
}

/// Which screen edge a pinned window is being placed against.
enum ScreenEdge {
    case left, right, top, bottom

    /// Hint text shown in the edge strip, mirroring CleanShot's "Place on the …".
    var hintText: String {
        switch self {
        case .left:   return "Place on the left  ←"
        case .right:  return "Place on the right  →"
        case .top:    return "Place on the top  ↑"
        case .bottom: return "Place on the bottom  ↓"
        }
    }
}

/// A translucent coral strip shown along a screen edge while the user drags a
/// pinned window toward it, labelling the place-on-the-side target.
@MainActor
private final class SnapHintWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = KritColors.accent.withAlphaComponent(0.22).cgColor
        container.layer?.borderColor = KritColors.accent.withAlphaComponent(0.9).cgColor
        container.layer?.borderWidth = 2

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        contentView = container
    }

    /// Positions the strip along `edge` of `visible` and fills in its label.
    func present(for edge: ScreenEdge, in visible: NSRect) {
        label.stringValue = edge.hintText
        let thickness: CGFloat = 64
        let rect: NSRect
        switch edge {
        case .left:
            rect = NSRect(x: visible.minX, y: visible.minY, width: thickness, height: visible.height)
        case .right:
            rect = NSRect(x: visible.maxX - thickness, y: visible.minY, width: thickness, height: visible.height)
        case .top:
            rect = NSRect(x: visible.minX, y: visible.maxY - thickness, width: visible.width, height: thickness)
        case .bottom:
            rect = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: thickness)
        }
        setFrame(rect, display: true)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

extension PinnedWindow: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        handleWindowDidMove()
    }
}

// NSImageView consumes mouseDown for its own drag-and-drop, which blocks
// isMovableByWindowBackground. This subclass lets the window handle plain drags,
// and starts a file drag-out (F2b) only on Option-drag so window-move never regresses.
@MainActor
private final class DraggablePinnedImageView: NSImageView, NSDraggingSource {
    var onHoverStateChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var optionDragArmed = false
    private var activeDragFileURL: URL?

    // Plain drag still moves the window; Option-drag exports the file instead, so
    // we only opt out of window-move when Option is held at mouse-down.
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverStateChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        optionDragArmed = event.modifierFlags.contains(.option)
        dragOrigin = optionDragArmed ? event.locationInWindow : nil
        // Plain drag: defer to the window (don't call super, which would start the
        // image view's own drag and block isMovableByWindowBackground).
    }

    override func mouseDragged(with event: NSEvent) {
        guard optionDragArmed, let origin = dragOrigin, let image else { return }
        let current = event.locationInWindow
        guard abs(current.x - origin.x) > 3 || abs(current.y - origin.y) > 3 else { return }
        dragOrigin = nil

        guard let png = ImageExporter.pngData(from: image),
              let fileURL = DragFileVault.makeFile(data: png) else { return }
        activeDragFileURL = fileURL

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let url = self.activeDragFileURL else { return }
            self.activeDragFileURL = nil
            DragFileVault.scheduleCleanup(url)
        }
    }
}

// Constrain initial size to something reasonable
private func constrainedSize(for size: NSSize) -> NSSize {
    let maxDim: CGFloat = 480
    let scale = min(1.0, min(maxDim / size.width, maxDim / size.height))
    return NSSize(width: size.width * scale, height: size.height * scale)
}

// Smallest the pin may shrink to: 120pt on the longer side, but never below 60pt on the
// shorter side (very wide or tall shots would otherwise collapse one axis to a sliver).
// Scaled up if the 60pt floor is hit so the aspect ratio is preserved.
@MainActor
private func pinnedMinSize(for size: NSSize) -> NSSize {
    guard size.width > 0, size.height > 0 else { return NSSize(width: 120, height: 120) }
    let longSide: CGFloat = 120
    let shortFloor: CGFloat = 60
    let aspect = size.width / size.height

    var minSize = aspect >= 1
        ? NSSize(width: longSide, height: longSide / aspect)
        : NSSize(width: longSide * aspect, height: longSide)

    let shorter = min(minSize.width, minSize.height)
    if shorter < shortFloor {
        let bump = shortFloor / shorter
        minSize = NSSize(width: minSize.width * bump, height: minSize.height * bump)
    }
    return minSize
}

// Largest the pin may grow to: bounded by the visible screen (minus a small margin), with
// the aspect ratio preserved. Falls back generously if no screen is available.
@MainActor
private func pinnedMaxSize(for size: NSSize) -> NSSize {
    guard size.width > 0, size.height > 0 else { return NSSize(width: 4000, height: 4000) }
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 4000, height: 4000)
    let margin: CGFloat = 40
    let maxW = max(120, visible.width - margin)
    let maxH = max(120, visible.height - margin)

    // Fit the image rect inside the visible bounds, preserving aspect ratio. The limiting
    // axis wins, so neither dimension ever exceeds the screen.
    let scale = min(maxW / size.width, maxH / size.height)
    return NSSize(width: size.width * scale, height: size.height * scale)
}
