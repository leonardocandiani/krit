import AppKit

// MARK: - HSB / RGB / hex model

/// The picker's single source of truth, kept in HSB because the 2D square and the
/// hue slider both operate in that space. RGB and hex are derived views of it, so
/// editing any field round-trips through here and the whole panel stays in sync.
struct PickerColor: Equatable {
    var hue: CGFloat        // 0...1
    var saturation: CGFloat // 0...1
    var brightness: CGFloat // 0...1
    var alpha: CGFloat      // 0...1

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        self.hue = hue.clamped01
        self.saturation = saturation.clamped01
        self.brightness = brightness.clamped01
        self.alpha = alpha.clamped01
    }

    init(_ color: NSColor) {
        // Convert through sRGB first so hueComponent and friends are defined;
        // device / named colors crash if you read HSB without a known space.
        let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? .black
        self.hue = rgb.hueComponent.clamped01
        self.saturation = rgb.saturationComponent.clamped01
        self.brightness = rgb.brightnessComponent.clamped01
        self.alpha = rgb.alphaComponent.clamped01
    }

    var nsColor: NSColor {
        let c = rgb
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    /// Opaque variant for swatch fills, where alpha would only muddy the reading
    /// against the dark glass.
    var opaqueColor: NSColor {
        let c = rgb
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// 8-bit RGB, the values shown in the R/G/B fields.
    var rgb255: (r: Int, g: Int, b: Int) {
        let c = rgb
        return (Int(round(c.r * 255)), Int(round(c.g * 255)), Int(round(c.b * 255)))
    }

    var hexString: String {
        let (r, g, b) = rgb255
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// 0...100 integer used by the Alpha field (CleanShot shows alpha as a percent).
    var alphaPercent: Int { Int(round(alpha * 100)) }

    private var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        let s = color.usingColorSpace(.sRGB) ?? color
        return (s.redComponent, s.greenComponent, s.blueComponent)
    }

    static func from(r: Int, g: Int, b: Int, alphaPercent: Int) -> PickerColor {
        let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        var c = PickerColor(color)
        c.alpha = (CGFloat(alphaPercent) / 100).clamped01
        return c
    }

    /// Parses "#2C7FFB", "2C7FFB" or the 3-digit shorthand. Returns nil on junk so
    /// the field can reject bad input instead of snapping to black.
    static func from(hex raw: String) -> PickerColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return PickerColor(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - Saturation x Brightness square

/// The classic 2D gradient: hue fixed, x = saturation, y = brightness. A ring
/// indicator marks the current S/B; dragging anywhere moves it and reports the new
/// S/B back through `onChange`. Hue comes from the owner so the square recolors
/// when the hue slider moves.
@MainActor
final class SaturationBrightnessView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1 { didSet { needsDisplay = true } }
    var brightness: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Called continuously while dragging with the new (saturation, brightness).
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let radius: CGFloat = 8
        NSGraphicsContext.current?.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        clip.addClip()

        // Base hue at full saturation/brightness, then the white wash left->right
        // (drops saturation) and the black wash top->bottom (drops brightness).
        NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        rect.fill()

        let white = NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 1, alpha: 0))
        white?.draw(in: rect, angle: 0)
        let black = NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 1))
        black?.draw(in: rect, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Indicator ring at the current S/B position.
        let px = rect.minX + saturation * rect.width
        let py = rect.minY + brightness * rect.height
        let ringRadius: CGFloat = 7
        let ringRect = NSRect(x: px - ringRadius, y: py - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 2.5
        NSColor.white.setStroke()
        ring.stroke()
        let inner = NSBezierPath(ovalIn: ringRect.insetBy(dx: 0.6, dy: 0.6))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        inner.stroke()
    }

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = ((p.x - bounds.minX) / bounds.width).clamped01
        let b = ((p.y - bounds.minY) / bounds.height).clamped01
        saturation = s
        brightness = b
        onChange?(s, b)
    }
}

// MARK: - Hue slider

/// Horizontal rainbow track with a draggable knob. Reports hue 0...1 back through
/// `onChange`. Drawn custom (not NSSlider) so the rainbow fill and the round knob
/// match the CleanShot look instead of a system slider.
@MainActor
final class HueSliderView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let trackHeight: CGFloat = 10
        let track = NSRect(x: bounds.minX, y: bounds.midY - trackHeight / 2, width: bounds.width, height: trackHeight)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).addClip()

        // Rainbow: evenly spaced hue stops; NSGradient distributes them uniformly
        // across the track, which is exactly a uniform hue ramp.
        let stops = (0...12).map { NSColor(calibratedHue: CGFloat($0) / 12, saturation: 1, brightness: 1, alpha: 1) }
        let gradient = NSGradient(colors: stops)
        gradient?.draw(in: track, angle: 0)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Knob centered on the current hue.
        let kx = bounds.minX + hue * bounds.width
        let knobRadius: CGFloat = 8
        let knob = NSRect(x: kx - knobRadius, y: bounds.midY - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        let knobPath = NSBezierPath(ovalIn: knob)
        NSColor.white.setFill()
        knobPath.fill()
        knobPath.lineWidth = 1
        NSColor.black.withAlphaComponent(0.25).setStroke()
        knobPath.stroke()
    }

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = ((p.x - bounds.minX) / bounds.width).clamped01
        hue = h
        onChange?(h)
    }
}

// MARK: - My Colors swatch column

/// Bridges a dragging swatch back to its owning panel. Kept tiny on purpose: the
/// button only reports intent (start drag, drag moved, drop, context actions) and
/// the panel owns all reordering, removal and persistence.
@MainActor
protocol SwatchButtonDelegate: AnyObject {
    func swatchDragBegan(_ button: SwatchButton)
    func swatchDragMoved(_ button: SwatchButton, to pointInRoot: NSPoint)
    func swatchDragEnded(_ button: SwatchButton, at pointInRoot: NSPoint)
    func swatchRequestedRemove(_ button: SwatchButton)
    func swatchRequestedMoveToTop(_ button: SwatchButton)
}

/// One saved swatch in the left column. Draws a rounded color chip; the selected
/// one gets a white ring. A plain click selects (the panel turns it into the active
/// picker color); pressing and moving past a small threshold starts a manual drag
/// for reordering or removal. Right-click opens a context menu with Remove / Move
/// to Top. Hovering shows the hex in a tooltip.
@MainActor
final class SwatchButton: NSButton {
    let pickerColor: PickerColor
    var isSelectedSwatch = false { didSet { needsDisplay = true } }
    weak var dragDelegate: SwatchButtonDelegate?

    /// Movement past this many points before the drag takes over, so a normal click
    /// still selects without accidentally starting a reorder.
    private static let dragThreshold: CGFloat = 4

    private var mouseDownInWindow: NSPoint = .zero
    private var isDragging = false

    init(color: PickerColor, target: AnyObject?, action: Selector?) {
        self.pickerColor = color
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "#\(color.hexString)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let chip = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
        pickerColor.opaqueColor.setFill()
        path.fill()
        // Faint rim so very dark/light swatches still read against the popover
        // material in BOTH appearances (a fixed white rim vanished in light mode).
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        if isSelectedSwatch {
            // Accent ring, the native macOS selected-swatch treatment, visible on
            // light and dark popover materials alike.
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    // MARK: Manual drag tracking

    // Custom tracking instead of NSDraggingSession: the panel reorders inside an
    // NSStackView and needs to detect a drop outside the column to remove, which a
    // pasteboard drag does not surface cleanly.
    override func mouseDown(with event: NSEvent) {
        mouseDownInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        if !isDragging {
            let dx = p.x - mouseDownInWindow.x
            let dy = p.y - mouseDownInWindow.y
            guard (dx * dx + dy * dy) >= Self.dragThreshold * Self.dragThreshold else { return }
            isDragging = true
            dragDelegate?.swatchDragBegan(self)
        }
        if let root = window?.contentView {
            dragDelegate?.swatchDragMoved(self, to: root.convert(p, from: nil))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            if let root = window?.contentView {
                dragDelegate?.swatchDragEnded(self, at: root.convert(event.locationInWindow, from: nil))
            }
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            // No drag happened: treat it as a normal click and fire the action.
            sendAction(action, to: target)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove Color", action: #selector(contextRemove), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        let moveTop = NSMenuItem(title: "Move to Top", action: #selector(contextMoveToTop), keyEquivalent: "")
        moveTop.target = self
        menu.addItem(moveTop)
        return menu
    }

    @objc private func contextRemove() { dragDelegate?.swatchRequestedRemove(self) }
    @objc private func contextMoveToTop() { dragDelegate?.swatchRequestedMoveToTop(self) }
}

// MARK: - Color well button (header)

/// The header color control in its closed state (r65): a filled swatch circle of
/// the current annotation color with a small chevron beside it. Clicking opens the
/// ColorPickerPanel in a popover anchored to this button. Custom-drawn so the
/// swatch reads as a real color chip, not a system NSColorWell.
@MainActor
final class ColorWellButton: NSButton {
    private(set) var currentColor: NSColor

    init(color: NSColor, target: AnyObject?, action: Selector?) {
        self.currentColor = color
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    /// Updates the displayed swatch without firing the action (external sync).
    func setColor(_ color: NSColor) {
        currentColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Swatch circle on the left, chevron glyph on the right.
        let diameter: CGFloat = 18
        let swatchRect = NSRect(x: 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        let swatch = NSBezierPath(ovalIn: swatchRect)
        currentColor.setFill()
        swatch.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        swatch.lineWidth = 1
        swatch.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        guard let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let tinted = chevron.tintedColorWell(with: KritColors.toolInactiveGlyph)
        let size = tinted.size
        let origin = NSPoint(x: swatchRect.maxX + 3, y: bounds.midY - size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private extension NSImage {
    /// Flat-color render of an SF Symbol for the chevron glyph. Named distinctly
    /// from the controller's own `tinted(with:)` to avoid a redeclaration.
    func tintedColorWell(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Palette persistence

/// A palette slot keyed by what the colors are used for. Today only the annotation
/// stroke palette exists; `fill` and `textBackground` are reserved so the column can
/// be reused for other annotation properties without another storage rewrite.
enum ColorPaletteRole: String {
    case annotationStroke
    case annotationFill
    case textBackground
}

/// Reads and writes the "My Colors" palette per role, as hex strings in
/// UserDefaults. The stroke role keeps the original key ("colorPickerMyColors") so
/// existing users need zero migration; other roles get a namespaced key.
enum ColorPaletteStore {
    /// The original key, kept as the stroke role's storage for backward compat.
    private static let strokeKey = "colorPickerMyColors"

    /// Grayscale ramp on top descending into saturated colors, matching the
    /// CleanShot starter column. Used as the seed when a role has nothing stored.
    static let defaultPalette: [String] = [
        "FFFFFF", "B4B6B9", "808080", "4D4D4D", "000000",
        "FF7847", "FF3B30", "FF9500", "FFCC00", "34C759",
        "00C7BE", "2C7FFB", "5856D6", "AF52DE", "FF2D55",
    ]

    private static func key(for role: ColorPaletteRole) -> String {
        switch role {
        case .annotationStroke: return strokeKey
        default: return "\(strokeKey).\(role.rawValue)"
        }
    }

    static func load(role: ColorPaletteRole = .annotationStroke) -> [PickerColor] {
        let stored = UserDefaults.standard.array(forKey: key(for: role)) as? [String]
        let hexes = stored ?? defaultPalette
        return hexes.compactMap { PickerColor.from(hex: $0) }
    }

    static func save(_ colors: [PickerColor], role: ColorPaletteRole = .annotationStroke) {
        UserDefaults.standard.set(colors.map { $0.hexString }, forKey: key(for: role))
    }
}

// MARK: - Color picker panel

/// CleanShot-style embedded color picker shown in an NSPopover from the editor's
/// color well. The left column is the persisted "My Colors" palette; the center
/// holds the S/B square, hue slider, result swatch, hex + R/G/B/Alpha fields and
/// an eyedropper; the footer adds the current color to My Colors. Everything edits
/// one `PickerColor`, so any control updates all the others.
@MainActor
final class ColorPickerPanel: NSViewController, NSTextFieldDelegate {

    /// Fired whenever the panel settles on a new color (drag, field commit, swatch
    /// tap, eyedropper). The owner forwards this to the annotation canvas.
    var onColorChanged: ((NSColor) -> Void)?

    private var color: PickerColor {
        didSet { syncControls() }
    }

    private let sbView = SaturationBrightnessView()
    private let hueSlider = HueSliderView()
    private let resultSwatch = NSView()
    private let hexField = NSTextField()
    private let rField = NSTextField()
    private let gField = NSTextField()
    private let bField = NSTextField()
    private let alphaField = NSTextField()
    private let swatchLabel = NSTextField(labelWithString: "")
    private let swatchColumn = NSStackView()
    private var swatchButtons: [SwatchButton] = []
    private let scroll = NSScrollView()

    /// Which palette this panel edits. The header color well only drives stroke
    /// today; the slot is here so the same panel can serve other roles later.
    private let role: ColorPaletteRole = .annotationStroke

    // Drag-reorder state.
    private let insertionIndicator = NSView()
    private var draggingButton: SwatchButton?
    private var dragInsertionIndex: Int?

    private static let panelWidth: CGFloat = 332
    private static let panelHeight: CGFloat = 226
    private static let swatchColumnWidth: CGFloat = 26
    private static let contentLeft: CGFloat = 14 + swatchColumnWidth + 14

    init(initialColor: NSColor) {
        self.color = PickerColor(initialColor)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        root.wantsLayer = true
        view = root

        buildSwatchColumn(in: root)
        buildEditor(in: root)
        syncControls()
    }

    // MARK: Build

    private func buildSwatchColumn(in root: NSView) {
        // Hover/selection readout above the column: "Grayscale 20  #B4B6B9".
        swatchLabel.font = .systemFont(ofSize: 10, weight: .medium)
        swatchLabel.textColor = NSColor.secondaryLabelColor
        swatchLabel.lineBreakMode = .byTruncatingTail
        swatchLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(swatchLabel)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        swatchColumn.orientation = .vertical
        swatchColumn.alignment = .centerX
        swatchColumn.spacing = 6
        swatchColumn.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = swatchColumn

        // Thin accent bar shown between swatches while dragging to mark the drop
        // target. Hidden until a drag is in progress.
        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = KritColors.accent.cgColor
        insertionIndicator.layer?.cornerRadius = 1
        insertionIndicator.isHidden = true
        root.addSubview(insertionIndicator)

        NSLayoutConstraint.activate([
            swatchLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            swatchLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            swatchLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: swatchLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalToConstant: Self.swatchColumnWidth),

            swatchColumn.topAnchor.constraint(equalTo: scroll.topAnchor),
            swatchColumn.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        reloadSwatches()
    }

    private func buildEditor(in root: NSView) {
        // S/B square.
        sbView.translatesAutoresizingMaskIntoConstraints = false
        sbView.onChange = { [weak self] s, b in
            guard let self else { return }
            var c = self.color
            c.saturation = s
            c.brightness = b
            self.color = c
            self.fireChange()
        }
        root.addSubview(sbView)

        // Hue slider under the square.
        hueSlider.translatesAutoresizingMaskIntoConstraints = false
        hueSlider.onChange = { [weak self] h in
            guard let self else { return }
            var c = self.color
            c.hue = h
            self.color = c
            self.fireChange()
        }
        root.addSubview(hueSlider)

        // Large result swatch to the right of the square.
        resultSwatch.wantsLayer = true
        resultSwatch.layer?.cornerRadius = 8
        resultSwatch.layer?.borderWidth = 1
        resultSwatch.layer?.borderColor = NSColor.separatorColor.cgColor
        resultSwatch.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resultSwatch)

        // Hex field + eyedropper row.
        configureField(hexField, width: 74)
        hexField.placeholderString = "Hex"
        root.addSubview(hexField)

        let eyedropper = NSButton(
            image: NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Pick from screen") ?? NSImage(),
            target: self,
            action: #selector(eyedropperTapped)
        )
        eyedropper.isBordered = false
        eyedropper.bezelStyle = .regularSquare
        eyedropper.imagePosition = .imageOnly
        eyedropper.contentTintColor = NSColor.secondaryLabelColor
        eyedropper.toolTip = "Pick color from screen"
        eyedropper.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(eyedropper)

        // R / G / B / Alpha numeric fields, each with a tiny caption.
        let rgbaRow = NSStackView(views: [
            labeledField(rField, caption: "R"),
            labeledField(gField, caption: "G"),
            labeledField(bField, caption: "B"),
            labeledField(alphaField, caption: "A"),
        ])
        rgbaRow.orientation = .horizontal
        rgbaRow.spacing = 6
        rgbaRow.alignment = .top
        rgbaRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rgbaRow)

        // Footer: Add to My Colors (coral filled, where CleanShot uses blue).
        let addButton = NSButton(title: "+ Add to My Colors", target: self, action: #selector(addToMyColors))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.contentTintColor = .white
        addButton.bezelColor = KritColors.accent
        addButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(addButton)

        NSLayoutConstraint.activate([
            sbView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            sbView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.contentLeft),
            sbView.widthAnchor.constraint(equalToConstant: 150),
            sbView.heightAnchor.constraint(equalToConstant: 108),

            resultSwatch.topAnchor.constraint(equalTo: sbView.topAnchor),
            resultSwatch.leadingAnchor.constraint(equalTo: sbView.trailingAnchor, constant: 12),
            resultSwatch.widthAnchor.constraint(equalToConstant: 44),
            resultSwatch.heightAnchor.constraint(equalToConstant: 44),

            hexField.topAnchor.constraint(equalTo: resultSwatch.bottomAnchor, constant: 10),
            hexField.leadingAnchor.constraint(equalTo: resultSwatch.leadingAnchor),

            eyedropper.centerYAnchor.constraint(equalTo: hexField.centerYAnchor),
            eyedropper.leadingAnchor.constraint(equalTo: hexField.trailingAnchor, constant: 4),
            eyedropper.widthAnchor.constraint(equalToConstant: 22),
            eyedropper.heightAnchor.constraint(equalToConstant: 22),

            hueSlider.topAnchor.constraint(equalTo: sbView.bottomAnchor, constant: 12),
            hueSlider.leadingAnchor.constraint(equalTo: sbView.leadingAnchor),
            hueSlider.trailingAnchor.constraint(equalTo: sbView.trailingAnchor),
            hueSlider.heightAnchor.constraint(equalToConstant: 18),

            rgbaRow.topAnchor.constraint(equalTo: hueSlider.bottomAnchor, constant: 12),
            rgbaRow.leadingAnchor.constraint(equalTo: sbView.leadingAnchor),

            addButton.topAnchor.constraint(equalTo: rgbaRow.bottomAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: sbView.leadingAnchor),
            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            addButton.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])
    }

    private func configureField(_ field: NSTextField, width: CGFloat) {
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    /// A small numeric field with a caption underneath (R / G / B / A).
    private func labeledField(_ field: NSTextField, caption: String) -> NSView {
        configureField(field, width: 34)
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = NSColor.tertiaryLabelColor
        label.alignment = .center
        let stack = NSStackView(views: [field, label])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .centerX
        return stack
    }

    // MARK: My Colors persistence

    private func reloadSwatches() {
        swatchButtons.forEach { $0.removeFromSuperview() }
        swatchButtons.removeAll()
        for c in ColorPaletteStore.load(role: role) {
            swatchColumn.addArrangedSubview(makeSwatch(c))
        }
        markSelectedSwatch()
    }

    private func makeSwatch(_ c: PickerColor) -> SwatchButton {
        let button = SwatchButton(color: c, target: self, action: #selector(swatchTapped(_:)))
        button.dragDelegate = self
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        swatchButtons.append(button)
        return button
    }

    // MARK: Sync

    /// Pushes the model into every control. Fields with first responder are left
    /// alone so re-setting their string doesn't move the user's caret mid-edit.
    private func syncControls() {
        guard isViewLoaded else { return }
        sbView.hue = color.hue
        sbView.saturation = color.saturation
        sbView.brightness = color.brightness
        hueSlider.hue = color.hue
        resultSwatch.layer?.backgroundColor = color.nsColor.cgColor

        let (r, g, b) = color.rgb255
        setFieldIfNotEditing(hexField, color.hexString)
        setFieldIfNotEditing(rField, "\(r)")
        setFieldIfNotEditing(gField, "\(g)")
        setFieldIfNotEditing(bField, "\(b)")
        setFieldIfNotEditing(alphaField, "\(color.alphaPercent)")
        markSelectedSwatch()
    }

    private func setFieldIfNotEditing(_ field: NSTextField, _ value: String) {
        // Only the field with first responder is being edited; every other field
        // mirrors the model.
        if field.currentEditor() != nil { return }
        field.stringValue = value
    }

    private func markSelectedSwatch() {
        let hex = color.hexString
        for button in swatchButtons {
            button.isSelectedSwatch = button.pickerColor.hexString == hex
        }
    }

    private func fireChange() {
        onColorChanged?(color.nsColor)
    }

    // MARK: Actions

    @objc private func swatchTapped(_ sender: SwatchButton) {
        var c = sender.pickerColor
        c.alpha = color.alpha
        color = c
        swatchLabel.stringValue = "\(swatchName(for: c))  #\(c.hexString)"
        fireChange()
    }

    @objc private func addToMyColors() {
        var colors = ColorPaletteStore.load(role: role)
        let hex = color.hexString
        // Move-to-front dedupe so re-adding promotes instead of duplicating.
        colors.removeAll { $0.hexString == hex }
        colors.insert(PickerColor(color.opaqueColor), at: 0)
        ColorPaletteStore.save(colors, role: role)
        reloadSwatches()
    }

    @objc private func eyedropperTapped() {
        // NSColorSampler's handler is typed nonisolated, so hop back to the main
        // actor before touching the panel's state.
        NSColorSampler().show { picked in
            guard let picked else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var c = PickerColor(picked)
                c.alpha = self.color.alpha
                self.color = c
                self.fireChange()
            }
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        commitFields(from: obj.object as? NSTextField)
    }

    private func commitFields(from edited: NSTextField?) {
        if edited === hexField {
            if let parsed = PickerColor.from(hex: hexField.stringValue) {
                var c = parsed
                c.alpha = color.alpha
                color = c
                fireChange()
            } else {
                // Reject junk: snap the field back to the current model.
                syncControls()
            }
            return
        }
        if edited === rField || edited === gField || edited === bField || edited === alphaField {
            let r = clampInt(rField.stringValue, max: 255)
            let g = clampInt(gField.stringValue, max: 255)
            let b = clampInt(bField.stringValue, max: 255)
            let a = clampInt(alphaField.stringValue, max: 100)
            color = PickerColor.from(r: r, g: g, b: b, alphaPercent: a)
            fireChange()
        }
    }

    private func clampInt(_ string: String, max: Int) -> Int {
        let value = Int(string.trimmingCharacters(in: .whitespaces)) ?? 0
        return Swift.min(max, Swift.max(0, value))
    }

    /// Human label for the readout above the column. The grayscale steps get a
    /// "Grayscale NN" name like CleanShot; everything else falls back to "Color"
    /// so the label is never empty.
    private func swatchName(for c: PickerColor) -> String {
        if c.saturation < 0.04 {
            return "Grayscale \(Int(round(c.brightness * 100)))"
        }
        return "Color"
    }

    // MARK: Reorder / remove persistence

    /// Persists the current on-screen swatch order to the active role.
    fileprivate func persistCurrentOrder() {
        ColorPaletteStore.save(swatchButtons.map { $0.pickerColor }, role: role)
    }

    /// Removes one swatch with a fade, rebuilds the column, persists.
    fileprivate func removeSwatch(_ button: SwatchButton) {
        guard swatchButtons.contains(where: { $0 === button }) else { return }
        var colors = swatchButtons.map { $0.pickerColor }
        colors.removeAll { $0.hexString == button.pickerColor.hexString }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            button.animator().alphaValue = 0
        }, completionHandler: {
            // The completion handler is typed nonisolated, so hop back to the main
            // actor before touching the panel's state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                ColorPaletteStore.save(colors, role: self.role)
                self.reloadSwatches()
            }
        })
    }

    /// Moves one swatch to the top of the column, persists.
    fileprivate func moveSwatchToTop(_ button: SwatchButton) {
        var colors = swatchButtons.map { $0.pickerColor }
        let hex = button.pickerColor.hexString
        guard let idx = colors.firstIndex(where: { $0.hexString == hex }), idx != 0 else { return }
        let moved = colors.remove(at: idx)
        colors.insert(moved, at: 0)
        ColorPaletteStore.save(colors, role: role)
        reloadSwatches()
    }
}

// MARK: - Swatch drag reordering

extension ColorPickerPanel: SwatchButtonDelegate {

    /// True when the point sits inside the swatch column's horizontal band. Dropping
    /// outside it removes the swatch, matching the macOS "drag out to delete" idiom.
    private func pointInsideColumn(_ pointInRoot: NSPoint) -> Bool {
        let columnFrame = scroll.frame.insetBy(dx: -10, dy: 0)
        return columnFrame.minX <= pointInRoot.x && pointInRoot.x <= columnFrame.maxX
    }

    /// Insertion index for a drop at this point, based on each button's vertical
    /// midpoint. The column is bottom-origin (not flipped), so a higher Y means a
    /// lower index.
    private func insertionIndex(for pointInRoot: NSPoint) -> Int {
        guard let root = view.window?.contentView else { return swatchButtons.count }
        for (i, button) in swatchButtons.enumerated() {
            let frame = button.convert(button.bounds, to: root)
            if pointInRoot.y > frame.midY { return i }
        }
        return swatchButtons.count
    }

    func swatchDragBegan(_ button: SwatchButton) {
        draggingButton = button
        // Lift the swatch: slight scale-up and a soft shadow while it travels.
        button.layer?.zPosition = 1
        button.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        if let layer = button.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.setAffineTransform(CGAffineTransform(scaleX: 1.15, y: 1.15))
        }
    }

    func swatchDragMoved(_ button: SwatchButton, to pointInRoot: NSPoint) {
        guard draggingButton === button else { return }
        if pointInsideColumn(pointInRoot) {
            let index = insertionIndex(for: pointInRoot)
            dragInsertionIndex = index
            showInsertionIndicator(at: index)
        } else {
            // Outside the column: signal a pending removal, no insertion marker.
            dragInsertionIndex = nil
            insertionIndicator.isHidden = true
            button.alphaValue = 0.5
        }
    }

    func swatchDragEnded(_ button: SwatchButton, at pointInRoot: NSPoint) {
        defer { resetDragState(button) }
        guard draggingButton === button else { return }

        if !pointInsideColumn(pointInRoot) {
            removeSwatch(button)
            return
        }

        let target = insertionIndex(for: pointInRoot)
        reorder(button, to: target)
    }

    func swatchRequestedRemove(_ button: SwatchButton) {
        removeSwatch(button)
    }

    func swatchRequestedMoveToTop(_ button: SwatchButton) {
        moveSwatchToTop(button)
    }

    // MARK: Drag helpers

    private func reorder(_ button: SwatchButton, to target: Int) {
        guard let from = swatchButtons.firstIndex(where: { $0 === button }) else { return }
        // The arranged-subview index shifts down by one when moving forward, since
        // removing the source slides everything after it back.
        var to = target
        if to > from { to -= 1 }
        to = Swift.min(Swift.max(0, to), swatchButtons.count - 1)
        guard to != from else { return }

        let moved = swatchButtons.remove(at: from)
        swatchButtons.insert(moved, at: to)
        swatchColumn.removeArrangedSubview(button)
        swatchColumn.insertArrangedSubview(button, at: to)
        persistCurrentOrder()
    }

    private func showInsertionIndicator(at index: Int) {
        guard let root = view.window?.contentView else { return }
        let width = Self.swatchColumnWidth
        let x = scroll.frame.minX
        let y: CGFloat
        if swatchButtons.isEmpty {
            y = scroll.frame.maxY - 1
        } else if index >= swatchButtons.count {
            // Below the last swatch.
            let last = swatchButtons[swatchButtons.count - 1].convert(swatchButtons[swatchButtons.count - 1].bounds, to: root)
            y = last.minY - 4
        } else {
            // Above the swatch currently at this index.
            let frame = swatchButtons[index].convert(swatchButtons[index].bounds, to: root)
            y = frame.maxY + 2
        }
        insertionIndicator.frame = NSRect(x: x, y: y, width: width, height: 2)
        insertionIndicator.isHidden = false
    }

    private func resetDragState(_ button: SwatchButton) {
        insertionIndicator.isHidden = true
        button.shadow = nil
        button.layer?.zPosition = 0
        button.layer?.setAffineTransform(.identity)
        button.alphaValue = 1
        draggingButton = nil
        dragInsertionIndex = nil
    }
}

