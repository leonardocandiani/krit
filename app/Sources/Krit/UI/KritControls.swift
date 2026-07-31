import AppKit

/// AppKit ports of the reference app's controls, at its measured values rather
/// than at an approximation of them. Every number here was read out of the
/// shipped CSS/JS, and the comments keep the original declaration next to the
/// port so a future change can be checked against the source instead of taste.

// MARK: - Slider

/// Slider with a 4pt track and a 17×12 capsule knob.
///
/// Reference:
///     track: height 4, radius 2, accent up to the value, rgba(120,120,128,.2) after
///     thumb: 17×12, radius 6, white, 0 0 0 .5px rgba(0,0,0,.18), 0 1px 3px rgba(0,0,0,.22)
///     hover: scale(1.35) · active: scale(1.5) · transition .12s
///
/// The knob being a horizontal capsule instead of the system circle is most of
/// what makes their sliders read as theirs.
final class KritSliderCell: NSSliderCell {

    private static let trackHeight: CGFloat = 4
    private static let knobSize = NSSize(width: 17, height: 12)

    /// Grows the knob under the pointer, the way the reference scales its thumb.
    var knobScale: CGFloat = 1

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX,
                         y: rect.midY - Self.trackHeight / 2,
                         width: rect.width,
                         height: Self.trackHeight)
        let radius = Self.trackHeight / 2

        KritColors.trackFill.setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        // Filled portion. Clamped so a slider at its minimum draws nothing
        // rather than a stray dot of accent under the knob.
        let range = maxValue - minValue
        guard range > 0 else { return }
        let fraction = CGFloat((doubleValue - minValue) / range)
        guard fraction > 0 else { return }

        let filled = NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height)
        KritColors.accent.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let size = NSSize(width: Self.knobSize.width * knobScale,
                          height: Self.knobSize.height * knobScale)
        let rect = NSRect(x: knobRect.midX - size.width / 2,
                          y: knobRect.midY - size.height / 2,
                          width: size.width,
                          height: size.height)
        let radius = Self.knobSize.height / 2 * knobScale

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The hairline rim keeps the white knob from dissolving into a light
        // track; it is the `0 0 0 .5px` in the reference shadow stack.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = KritColors.hairlineWidth
        path.stroke()
    }

    override var knobThickness: CGFloat { Self.knobSize.height }
}

/// A slider wearing `KritSliderCell`, with the pointer scaling wired up.
final class KritSlider: NSSlider {

    // Without this, dragging the knob drags the WINDOW: the editor's window is
    // non-opaque (for the see-through stage), and AppKit lets a non-opaque
    // window be dragged by any subview that does not opt out.
    override var mouseDownCanMoveWindow: Bool { false }

    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = makeCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = makeCell()
    }

    private func makeCell() -> KritSliderCell {
        let cell = KritSliderCell()
        cell.sliderType = .linear
        cell.isContinuous = true
        cell.controlSize = .regular
        return cell
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setKnobScale(1.35) }
    override func mouseExited(with event: NSEvent) { setKnobScale(1) }

    override func mouseDown(with event: NSEvent) {
        setKnobScale(1.5)
        super.mouseDown(with: event)
        setKnobScale(bounds.contains(convert(event.locationInWindow, from: nil)) ? 1.35 : 1)
    }

    private func setKnobScale(_ scale: CGFloat) {
        guard let cell = cell as? KritSliderCell, cell.knobScale != scale else { return }
        cell.knobScale = Motion.reduced ? 1 : scale
        needsDisplay = true
    }
}

// MARK: - Colour swatch

/// A round colour swatch with the reference's two-ring selected state.
///
/// Reference:
///     idle:     inset 0 0 0 0.5px rgba(0,0,0,.10), 0 1px 2px rgba(0,0,0,.08)
///     selected: inset 0 0 0 1.5px var(--bg-card), inset 0 0 0 3px <accent>
///
/// The inner ring is the *surface* colour, not a gap in the fill: it reads as
/// the swatch shrinking away from an accent ring drawn around it, which is what
/// keeps a white swatch legible as selected.
final class KritSwatchButton: NSButton {

    override var mouseDownCanMoveWindow: Bool { false }

    var color: NSColor = .white { didSet { needsDisplay = true } }
    var isSelectedSwatch = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        color.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        if isSelectedSwatch {
            // Ring order matters: the surface-coloured ring is drawn first and
            // the accent ring outside it, so the two never blend into one thick
            // border on a light swatch.
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            KritColors.panelBackground.setStroke()
            inner.lineWidth = 1.5
            inner.stroke()

            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 2.25, dy: 2.25))
            KritColors.accent.setStroke()
            outer.lineWidth = 1.5
            outer.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.10).setStroke()
            circle.lineWidth = KritColors.hairlineWidth
            circle.stroke()
        }
    }
}

// MARK: - Selectable row

/// A full-width row that can be selected, in the app's own accent.
///
/// Exists because AppKit's push-on/push-off bezels paint their ON state in the
/// SYSTEM accent, which on a default Mac is blue: the one colour this app never
/// chose. Selection has to look like every other selected thing in the editor.
final class SelectableRowButton: NSButton {

    override var mouseDownCanMoveWindow: Bool { false }

    private var hovered = false

    override var state: NSControl.StateValue {
        didSet {
            guard state != oldValue else { return }
            restyle()
        }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = title
        setButtonType(.pushOnPushOff)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = KritMetrics.Radius.cell
        layer?.cornerCurve = .continuous
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func restyle() {
        let selected = state == .on
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? KritColors.accent : KritColors.textPrimary,
            .kern: -0.1,
        ])
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let selected = state == .on
        let fill: NSColor = selected
            ? KritColors.accent.withAlphaComponent(0.16)
            : (hovered ? KritColors.surfaceCardHover : KritColors.surfaceCard)
        layer?.backgroundColor = fill.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Badge

/// A status pill: a wash of one hue behind ink of the same hue.
///
/// Deliberately borderless. A badge that needs an outline to be visible is
/// competing with the row it labels; the tinted fill already separates it.
final class KritBadge: NSView {

    private let label = NSTextField(labelWithString: "")
    private let hue: NSColor

    init(text: String, hue: NSColor = KritColors.accent) {
        self.hue = hue
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = KritMetrics.Badge.radius
        layer?.cornerCurve = .continuous

        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: KritMetrics.Badge.fontSize, weight: .bold),
            .foregroundColor: hue,
            .kern: 0.3,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let insets = KritMetrics.Badge.insets
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: KritMetrics.Badge.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hue.withAlphaComponent(KritMetrics.Badge.fillAlpha).cgColor
    }
}

// MARK: - Glass pill button

/// A circular control that lives inside a dark glass pill.
///
/// Reference:
///     idle    transparent
///     hover   rgba(255,255,255,.16)
///     on      #fff with the glyph inverted to the text colour
///     brand   the accent, glyph white
///
/// On glass there is no bezel: the shape only appears when you reach for it,
/// which is why the hover wash is the whole design and not a nicety.
final class GlassPillButton: NSButton {

    /// How the button reads at rest.
    enum Emphasis {
        /// One of many; shows itself on hover.
        case plain
        /// The selected member of a group: solid white, glyph inverted.
        case selected
        /// The one action the pill exists for: accent-filled.
        case brand
    }

    var emphasis: Emphasis = .plain {
        didSet {
            guard emphasis != oldValue else { return }
            applyEmphasis()
        }
    }

    private var hovered = false
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        applyEmphasis()
    }

    override func layout() {
        super.layout()
        // Capsule at any size: the pill's controls are circles, and a fixed
        // radius would turn a wider control (the zoom read-out) into a lozenge
        // with the wrong corners.
        layer?.cornerRadius = bounds.height / 2
    }

    private func applyEmphasis() {
        switch emphasis {
        case .plain:
            layer?.backgroundColor = hovered
                ? NSColor.white.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
            contentTintColor = .white
        case .selected:
            layer?.backgroundColor = NSColor.white.cgColor
            contentTintColor = KritColors.textPrimary
        case .brand:
            layer?.backgroundColor = KritColors.accent.cgColor
            contentTintColor = .white
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        guard emphasis == .plain else { return }
        crossfadeBackground(to: NSColor.white.withAlphaComponent(0.16), duration: 0.16)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        guard emphasis == .plain else { return }
        crossfadeBackground(to: .clear, duration: 0.16)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Row button

/// A list row in the reference's menu voice: 7×9 padding, 7pt radius, 13/500
/// text, and a card-hover wash that crossfades in over 0.12s.
final class KritRowButton: NSView {

    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let action: () -> Void
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        var leading: NSLayoutXAxisAnchor = leadingAnchor
        var inset: CGFloat = 9

        if let symbol {
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            glyph.contentTintColor = KritColors.textSecondary
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 15),
            ])
            leading = glyph.trailingAnchor
            inset = 9
        }

        label.attributedStringValue = KritType.body.string(title, color: KritColors.textPrimary)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        crossfadeBackground(to: KritColors.surfaceCardHover, duration: 0.12)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        crossfadeBackground(to: .clear, duration: 0.12)
    }

    override func mouseDown(with event: NSEvent) { action() }
}
