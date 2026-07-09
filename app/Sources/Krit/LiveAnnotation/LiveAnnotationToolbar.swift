import AppKit

/// The floating control strip for Live Screen Annotation: tool picker, color
/// swatches, line-width presets, undo/redo, visibility toggle, clear, capture
/// and close. Visual language follows `AllInOnePanelWindow` (translucent HUD
/// chrome, `.screenSaver`-adjacent level, draggable) but with a single backing
/// surface instead of a per-button glass cluster — the morphing glass cluster
/// is a polish pass for a later integration, not load-bearing for the feature.
@MainActor
final class LiveAnnotationToolbarWindow: NSPanel {

    private static let tools: [AnnotationTool] = [
        .freehand, .highlighter, .arrow, .line, .rectangle, .ellipse, .text, .numberedStep
    ]
    private static let colors: [NSColor] = [
        KritColors.accent, .systemRed, .systemYellow, .systemGreen, .systemBlue, .white
    ]
    private static let widths: [(title: String, value: CGFloat, tooltip: String)] = [
        ("S", 3, "Small"), ("M", 6, "Medium"), ("L", 11, "Large")
    ]

    var onToolSelected: ((AnnotationTool) -> Void)?
    var onColorSelected: ((NSColor) -> Void)?
    var onWidthSelected: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onClearAll: (() -> Void)?
    var onCaptureRequested: (() -> Void)?
    var onClose: (() -> Void)?

    private var toolButtons: [(AnnotationTool, LiveAnnotationChromeButton)] = []
    private var swatchButtons: [(NSColor, LiveAnnotationSwatchButton)] = []
    private var widthButtons: [(CGFloat, LiveAnnotationChromeButton)] = []
    private var undoButton: LiveAnnotationChromeButton!
    private var redoButton: LiveAnnotationChromeButton!
    private var eyeButton: LiveAnnotationChromeButton!

    init() {
        let initialRect = NSRect(x: 0, y: 0, width: 10, height: 10)
        let mask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        super.init(contentRect: initialRect, styleMask: mask, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        // One level above the annotation overlay (which sits at .screenSaver),
        // so the toolbar chrome is never occluded by the ink surface below it.
        // MUST come after isFloatingPanel — that setter resets the level (see
        // the overlay window's comment for the bug this caused).
        level = .screenSaver + 1
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Chrome, not content: never appears in a screen share or a KRIT
        // recording, unlike the annotation overlay it controls (see that
        // window's comment for why THAT one omits sharingType).
        sharingType = .none
        buildContent()
    }

    override var canBecomeKey: Bool { false }

    // MARK: - Content

    private func buildContent() {
        let arranged = buildButtons()
        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        // HUD blur matching ChromeFactory's pre-macOS-26 fallback material, so
        // the toolbar reads consistently with the rest of KRIT's floating
        // chrome without pulling in the full glass-cluster machinery.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = ChromeFactory.Radius.dock
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        blur.layoutSubtreeIfNeeded()
        let fitting = blur.fittingSize
        blur.frame = NSRect(origin: .zero, size: fitting)
        contentView = blur
        setContentSize(fitting)

        updateActiveTool(.arrow)
        updateActiveColor(KritColors.accent)
        updateActiveWidth(Self.widths[1].value)
        setUndoRedoEnabled(canUndo: false, canRedo: false)
    }

    private func buildButtons() -> [NSView] {
        var arranged: [NSView] = []
        arranged += buildToolButtons()
        arranged.append(makeDivider())
        arranged += buildSwatchButtons()
        arranged.append(makeDivider())
        arranged += buildWidthButtons()
        arranged.append(makeDivider())
        arranged += buildUndoRedoButtons()
        arranged.append(makeDivider())
        arranged += buildActionButtons()
        return arranged
    }

    private func buildToolButtons() -> [NSView] {
        Self.tools.map { tool in
            let button = LiveAnnotationChromeButton(symbolName: tool.icon, tooltip: tool.tooltip)
            button.onClick = { [weak self] in self?.selectTool(tool) }
            button.setAccessibilityIdentifier("annotation.tool.\(tool.rawValue)")
            toolButtons.append((tool, button))
            return button
        }
    }

    private func buildSwatchButtons() -> [NSView] {
        Self.colors.enumerated().map { index, color in
            let swatch = LiveAnnotationSwatchButton(color: color)
            swatch.onClick = { [weak self] in self?.selectColor(color) }
            swatch.setAccessibilityIdentifier("annotation.color.\(index)")
            swatchButtons.append((color, swatch))
            return swatch
        }
    }

    private func buildWidthButtons() -> [NSView] {
        Self.widths.map { preset in
            let button = LiveAnnotationChromeButton(title: preset.title, tooltip: preset.tooltip)
            button.onClick = { [weak self] in self?.selectWidth(preset.value) }
            button.setAccessibilityIdentifier("annotation.width.\(preset.title.lowercased())")
            widthButtons.append((preset.value, button))
            return button
        }
    }

    private func buildUndoRedoButtons() -> [NSView] {
        undoButton = LiveAnnotationChromeButton(symbolName: "arrow.uturn.backward", tooltip: "Undo (\u{2318}Z)")
        undoButton.onClick = { [weak self] in self?.onUndo?() }
        undoButton.setAccessibilityIdentifier("annotation.undo")
        redoButton = LiveAnnotationChromeButton(symbolName: "arrow.uturn.forward", tooltip: "Redo (\u{21E7}\u{2318}Z)")
        redoButton.onClick = { [weak self] in self?.onRedo?() }
        redoButton.setAccessibilityIdentifier("annotation.redo")
        return [undoButton, redoButton]
    }

    private func buildActionButtons() -> [NSView] {
        eyeButton = LiveAnnotationChromeButton(symbolName: "eye", tooltip: "Hide annotations")
        eyeButton.onClick = { [weak self] in self?.onToggleVisibility?() }
        eyeButton.setAccessibilityIdentifier("annotation.eye")

        let trashButton = LiveAnnotationChromeButton(symbolName: "trash", tooltip: "Clear all")
        trashButton.onClick = { [weak self] in self?.onClearAll?() }
        trashButton.setAccessibilityIdentifier("annotation.trash")

        let cameraButton = LiveAnnotationChromeButton(symbolName: "camera", tooltip: "Capture")
        cameraButton.onClick = { [weak self] in self?.onCaptureRequested?() }
        cameraButton.setAccessibilityIdentifier("annotation.camera")

        let closeButton = LiveAnnotationChromeButton(symbolName: "xmark", tooltip: "Close (keeps your drawing for next time)")
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.setAccessibilityIdentifier("annotation.close")

        return [eyeButton, trashButton, cameraButton, closeButton]
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 22),
        ])
        return divider
    }

    // MARK: - Selection state

    private func selectTool(_ tool: AnnotationTool) {
        updateActiveTool(tool)
        onToolSelected?(tool)
    }

    private func updateActiveTool(_ tool: AnnotationTool) {
        for (t, button) in toolButtons { button.isSelected = (t == tool) }
    }

    private func selectColor(_ color: NSColor) {
        updateActiveColor(color)
        onColorSelected?(color)
    }

    private func updateActiveColor(_ color: NSColor) {
        for (c, button) in swatchButtons { button.isSelected = (c == color) }
    }

    private func selectWidth(_ width: CGFloat) {
        updateActiveWidth(width)
        onWidthSelected?(width)
    }

    private func updateActiveWidth(_ width: CGFloat) {
        for (w, button) in widthButtons { button.isSelected = (w == width) }
    }

    /// Syncs the button highlights to a tool/color/width chosen outside the
    /// toolbar (the controller restoring the last-used values from
    /// `Settings` on a fresh `engage()`), so the chrome doesn't show the
    /// hardcoded arrow/accent/medium defaults from `buildContent()` while the
    /// surface view underneath is actually using something else. Call once,
    /// right after `init()`.
    func syncInitialSelection(tool: AnnotationTool, color: NSColor, width: CGFloat) {
        updateActiveTool(tool)
        updateActiveColor(color)
        updateActiveWidth(width)
    }

    /// Reflects undo/redo availability (called from the surface view's
    /// `onUndoStateChanged`), so the buttons dim instead of no-op silently.
    func setUndoRedoEnabled(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    /// Swaps the eye glyph to reflect the current visibility state.
    func setInkVisible(_ visible: Bool) {
        eyeButton.setSymbol(visible ? "eye" : "eye.slash", tooltip: visible ? "Hide annotations" : "Show annotations")
    }

    // MARK: - Placement

    /// Anchors bottom-center of the anchor screen's visible frame, clear of
    /// the Dock/menu bar. The user can drag it anywhere afterward
    /// (`isMovableByWindowBackground`).
    func showAnchored(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }
}

// MARK: - Buttons

/// One icon-or-text control in the toolbar: flat by default, a pad fill when
/// selected (matching `KritColors.toolSelectedFill/Glyph`, the same "selected
/// tool" language the screenshot editor's own tool strip uses), dimmed and
/// inert when disabled. Handles its own click instead of routing through
/// NSButtonCell, mirroring `AllInOneOptionButton` in AllInOneController.
@MainActor
private final class LiveAnnotationChromeButton: NSView {

    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    var isEnabled = true { didSet { updateAppearance() } }

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let usesImage: Bool

    convenience init(symbolName: String, tooltip: String) {
        self.init(tooltip: tooltip, usesImage: true)
        setSymbol(symbolName, tooltip: tooltip)
    }

    convenience init(title: String, tooltip: String) {
        self.init(tooltip: tooltip, usesImage: false)
        label.stringValue = title
    }

    private init(tooltip: String, usesImage: Bool) {
        self.usesImage = usesImage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        toolTip = tooltip

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content: NSView = usesImage ? imageView : label
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, tooltip: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        toolTip = tooltip
    }

    // Real accessibility, not just automation plumbing: role/label/press make this
    // a proper AX button (VoiceOver included), not just a plain NSView a screen
    // reader skips over. `ui-click` (UIIntrospection) drives the exact same path.
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected ? KritColors.toolSelectedFill.cgColor : .clear
        let glyphColor = isSelected ? KritColors.toolSelectedGlyph : KritColors.toolInactiveGlyph
        imageView.contentTintColor = glyphColor
        label.textColor = glyphColor
        alphaValue = isEnabled ? 1 : 0.35
    }

    // The toolbar panel is a non-activating panel that never becomes key
    // (canBecomeKey = false), so without this a click on a button in the
    // not-key window is swallowed just to focus the window and never reaches
    // mouseDown — the same override AllInOneOptionButton needs for the identical
    // window shape.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Unlike AllInOne's toolbar, this panel is isMovableByWindowBackground, and
    // a non-opaque custom NSView answers mouseDownCanMoveWindow = true — so a
    // click on a button would start a window drag and never reach mouseDown.
    // Dragging stays available on the backing blur and the dividers.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
}

/// A round color chip; the selected swatch gets a bright ring.
@MainActor
private final class LiveAnnotationSwatchButton: NSView {

    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        toolTip = color.accessibilityName
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (isSelected ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).cgColor
    }

    // See LiveAnnotationChromeButton: the not-key toolbar panel needs its
    // buttons to accept the first click, or the swatch never registers.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // See LiveAnnotationChromeButton: without this, the movable-by-background
    // panel turns the click into a window drag before mouseDown can fire.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onClick?() }

    // See LiveAnnotationChromeButton's identical overrides.
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
