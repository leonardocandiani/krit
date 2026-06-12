import AppKit

/// Floating affordance shown at the bottom of the canvas after a Smart Redact
/// pass, so applying the suggested boxes is discoverable instead of a hidden
/// Enter shortcut. Two modes:
///
///  - `.findings(count:)`: a count label plus a primary "Redact all" capsule
///    (coral, the moment's primary action) and a neutral "Cancel". The buttons
///    drive the exact same paths as the Enter/Esc shortcuts, which stay live.
///  - `.empty`: a single "No sensitive content found" line that dismisses
///    itself, so a zero-finding pass never reads as silence.
///
/// The banner is a plain NSView hosted as an NSScrollView floating subview, so it
/// keeps a fixed on-screen size while the canvas underneath zooms and scrolls
/// (the clip view magnifies; this chrome must not). Styled with the app's glass
/// language via ChromeFactory.
@MainActor
final class SmartRedactBanner: NSView {

    enum Mode {
        case findings(count: Int)
        case empty
    }

    var onRedactAll: (() -> Void)?
    var onCancel: (() -> Void)?

    private let glass: NSView
    private let label = NSTextField(labelWithString: "")
    private let redactButton = CapsuleButton()
    private let cancelButton = CapsuleButton()

    private let horizontalPadding: CGFloat = 16
    private let interItemSpacing: CGFloat = 12
    private let buttonSpacing: CGFloat = 8
    private let bannerHeight: CGFloat = 48

    init(mode: Mode) {
        glass = ChromeFactory.backing(
            frame: .zero,
            cornerRadius: ChromeFactory.Radius.panel
        )
        super.init(frame: .zero)
        wantsLayer = true
        // The drop shadow lifts the bar off the artwork; the glass clips itself.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        glass.wantsLayer = true
        glass.layer?.cornerRadius = ChromeFactory.Radius.panel
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        addSubview(glass)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white

        redactButton.title = "Redact all"
        redactButton.style = .primary
        redactButton.target = self
        redactButton.action = #selector(redactAllTapped)

        cancelButton.title = "Cancel"
        cancelButton.style = .neutral
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        configure(for: mode)
        layoutBanner()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-targets an existing banner at a new pass result without rebuilding the
    /// view, so a second Smart Redact run just updates the count/copy in place.
    func update(mode: Mode) {
        configure(for: mode)
        layoutBanner()
    }

    private func configure(for mode: Mode) {
        switch mode {
        case .findings(let count):
            let noun = count == 1 ? "item" : "items"
            label.stringValue = "\(count) sensitive \(noun) found"
            redactButton.isHidden = false
            cancelButton.isHidden = false
            if redactButton.superview == nil { glass.addSubview(redactButton) }
            if cancelButton.superview == nil { glass.addSubview(cancelButton) }
        case .empty:
            label.stringValue = "No sensitive content found"
            redactButton.isHidden = true
            cancelButton.isHidden = true
        }
        if label.superview == nil { glass.addSubview(label) }
    }

    /// Lays out the bar to its intrinsic width and returns its size, so the
    /// canvas can center it horizontally over the viewport.
    @discardableResult
    func layoutBanner() -> NSSize {
        label.sizeToFit()
        redactButton.sizeToFit()
        cancelButton.sizeToFit()

        var width = horizontalPadding + label.frame.width
        if !redactButton.isHidden {
            width += interItemSpacing + cancelButton.frame.width + buttonSpacing + redactButton.frame.width
        }
        width += horizontalPadding

        frame.size = NSSize(width: ceil(width), height: bannerHeight)
        glass.frame = bounds

        let labelY = (bannerHeight - label.frame.height) / 2
        label.frame.origin = CGPoint(x: horizontalPadding, y: labelY)

        if !redactButton.isHidden {
            let buttonY = (bannerHeight - redactButton.frame.height) / 2
            let redactX = bounds.maxX - horizontalPadding - redactButton.frame.width
            redactButton.frame.origin = CGPoint(x: redactX, y: buttonY)
            let cancelX = redactX - buttonSpacing - cancelButton.frame.width
            cancelButton.frame.origin = CGPoint(x: cancelX, y: (bannerHeight - cancelButton.frame.height) / 2)
        }
        return frame.size
    }

    @objc private func redactAllTapped() { onRedactAll?() }
    @objc private func cancelTapped() { onCancel?() }
}

/// A small pill button matching the app's chrome: a coral fill for the primary
/// action, a translucent neutral fill otherwise. Drawn via its layer so it reads
/// the same on the glass backing across macOS versions.
@MainActor
private final class CapsuleButton: NSButton {

    enum Style { case primary, neutral }

    var style: Style = .neutral { didSet { applyStyle() } }

    private let horizontalInset: CGFloat = 14
    private let pillHeight: CGFloat = 28
    private var trackingAreaRef: NSTrackingArea?
    private var hovering = false { didSet { applyStyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = pillHeight / 2
        layer?.cornerCurve = .continuous
        focusRingType = .none
        setButtonType(.momentaryChange)
        applyStyle()
    }

    override var title: String {
        didSet { restyleTitle() }
    }

    private func restyleTitle() {
        let color: NSColor = style == .primary ? .white : NSColor.white.withAlphaComponent(0.92)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    private func applyStyle() {
        switch style {
        case .primary:
            let base = KritColors.accent
            let fill = hovering ? (base.blended(withFraction: 0.12, of: .white) ?? base) : base
            layer?.backgroundColor = fill.cgColor
        case .neutral:
            let alpha: CGFloat = hovering ? 0.26 : 0.16
            layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
        restyleTitle()
    }

    override func sizeToFit() {
        super.sizeToFit()
        let textWidth = attributedTitle.length > 0 ? attributedTitle.size().width : 0
        frame.size = NSSize(width: ceil(textWidth) + horizontalInset * 2, height: pillHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
