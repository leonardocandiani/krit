import AppKit

/// CleanShot-style text style picker: a popover with a grid of preset swatches,
/// each rendered as a REAL attributed-string preview ("Ag") in its own style
/// (regular, bold, italic, bold+italic, backplate chip, outlined). Clicking a
/// swatch applies that preset to the selected text, or sets it as the default for
/// the next text when nothing is selected. The active preset is ringed in accent.
@MainActor
final class TextStylePanel: NSViewController {

    /// Fired with the chosen preset when the user taps a swatch.
    var onSelectPreset: ((TextStylePreset) -> Void)?

    /// The preset to ring as active. Set before presenting so the popover opens
    /// reflecting the current text's style.
    var activePreset: TextStylePreset = .regular {
        didSet { refreshSelection() }
    }

    private var swatches: [TextStylePreset: TextStyleSwatchButton] = [:]

    private let columns = 2
    private let swatchSize = NSSize(width: 116, height: 64)
    private let gridSpacing: CGFloat = 8
    private let edgeInset: CGFloat = 12

    override func loadView() {
        let presets = TextStylePreset.allCases
        let rows = Int(ceil(Double(presets.count) / Double(columns)))
        let width = edgeInset * 2 + CGFloat(columns) * swatchSize.width + CGFloat(columns - 1) * gridSpacing
        let height = edgeInset * 2 + CGFloat(rows) * swatchSize.height + CGFloat(rows - 1) * gridSpacing

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        for (index, preset) in presets.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = edgeInset + CGFloat(col) * (swatchSize.width + gridSpacing)
            // Top-down layout in the non-flipped popover space.
            let y = height - edgeInset - swatchSize.height - CGFloat(row) * (swatchSize.height + gridSpacing)

            let button = TextStyleSwatchButton(preset: preset)
            button.frame = NSRect(x: x, y: y, width: swatchSize.width, height: swatchSize.height)
            button.toolTip = preset.title
            button.target = self
            button.action = #selector(swatchTapped(_:))
            container.addSubview(button)
            swatches[preset] = button
        }

        view = container
        refreshSelection()
    }

    private func refreshSelection() {
        for (preset, button) in swatches {
            button.isActive = (preset == activePreset)
        }
    }

    @objc private func swatchTapped(_ sender: TextStyleSwatchButton) {
        activePreset = sender.preset
        onSelectPreset?(sender.preset)
    }
}

/// A single style swatch: draws the preset's preview glyphs the way the canvas
/// would render that style, so the picker is WYSIWYG instead of an icon legend.
@MainActor
final class TextStyleSwatchButton: NSButton {

    let preset: TextStylePreset

    var isActive = false {
        didSet { needsDisplay = true }
    }

    /// The glyphs shown in every swatch; "Ag" carries an ascender and a descender
    /// so weight, italic and the outline ring all read clearly.
    private let sample = "Ag"
    private let previewSize: CGFloat = 26

    init(preset: TextStylePreset) {
        self.preset = preset
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 8

        // Card background, lighter when active so the selection reads at a glance.
        let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                  : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).setFill()
        card.fill()

        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if isActive {
            KritColors.accent.setStroke()
            border.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            border.lineWidth = 1
        }
        border.stroke()

        drawPreview(in: rect)
    }

    /// Renders the sample glyphs in the preset's exact style: weight + italic on
    /// the font, a backplate chip behind them for the backplate preset, and a dark
    /// outline ring for the outlined preset. Mirrors `TextAnnotation.draw`.
    private func drawPreview(in rect: NSRect) {
        let base = NSFont.systemFont(ofSize: previewSize, weight: preset.weight)
        let font: NSFont = preset.italic
            ? (NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: previewSize) ?? base)
            : base

        let glyphColor: NSColor = preset.backplate == .pill ? .white : KritColors.accent

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: glyphColor,
        ]
        if preset.outline {
            attrs[.strokeColor] = NSColor.black.withAlphaComponent(0.9)
            attrs[.strokeWidth] = -6.0
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 3
            attrs[.shadow] = shadow
        }

        let text = sample as NSString
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = NSPoint(x: rect.midX - textSize.width / 2,
                                 y: rect.midY - textSize.height / 2)

        if preset.backplate == .pill {
            let padX = previewSize * 0.35
            let padY = previewSize * 0.18
            let plate = NSRect(x: textOrigin.x - padX, y: textOrigin.y - padY,
                               width: textSize.width + padX * 2, height: textSize.height + padY * 2)
            let plateRadius = min(plate.height / 2, previewSize * 0.55)
            let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)
            KritColors.accent.setFill()
            platePath.fill()
        }

        text.draw(at: textOrigin, withAttributes: attrs)
    }
}
