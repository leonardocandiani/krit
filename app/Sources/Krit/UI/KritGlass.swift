import AppKit

/// The reference app's glass, rebuilt in AppKit layer by layer.
///
/// Its glass is never one effect. Every floating surface there is a stack:
///
///     backdrop-filter: blur(30px) saturate(150%)
///     background:      rgba(28,28,30,.32)
///     box-shadow:      inset 0 1px 0.5px rgba(255,255,255,0.30),   ← top highlight
///                      inset 0 0 0 0.5px rgba(255,255,255,0.14),   ← inner rim
///                      0 2px 6px rgba(0,0,0,0.10),                 ← contact shadow
///                      0 10px 26px rgba(0,0,0,0.16)                ← lift shadow
///
/// A plain `NSVisualEffectView` gives you the first line and nothing else, which
/// is why chrome built on it reads as "a blurred rectangle" rather than as
/// glass. The highlight along the top edge is what sells it: it is the specular
/// line you get on a real pane, and it is the piece most often left out.
///
/// The two shadows do different jobs and cannot be collapsed into one. The tight
/// one anchors the surface to what is under it; the wide one lifts it away.
@MainActor
final class KritGlassBacking: NSView {

    /// The recipes the reference uses, kept as named cases so a caller picks a
    /// role rather than typing blur radii.
    enum Style {
        /// Floating bar over content: the dark pill. `blur(30) saturate(150%)`.
        case bar
        /// A panel that hosts controls: nearly opaque. `blur(24) saturate(100%)`.
        case panel
        /// Menus and popovers. `blur(28) saturate(100%)`.
        case menu

        var blurRadius: CGFloat {
            switch self {
            case .bar: 30
            case .panel: 24
            case .menu: 28
            }
        }

        var saturation: CGFloat {
            switch self {
            case .bar: 1.5
            case .panel, .menu: 1.0
            }
        }

        /// Whether the surface holds itself dark regardless of the system theme.
        /// The bar floats over user content, which can be any colour.
        var isAlwaysDark: Bool { self == .bar }

        /// The panel's fill is opaque in the reference (`--bg-customize-panel`
        /// is plain `#ffffff`), so its blur never actually shows. It is a solid
        /// surface with a three-layer shadow, and painting it translucent buries
        /// its own section captions in whatever is behind the window.
        var isOpaque: Bool { self == .panel }

        /// `0 2px 6px` then `0 10px 26px` for a bar; a panel sits closer.
        var shadows: [(opacity: Float, radius: CGFloat, y: CGFloat)] {
            switch self {
            case .bar:
                [(0.10, 6, -2), (0.16, 26, -10)]
            case .panel:
                [(0.08, 0.5, 0), (0.04, 3, -1), (0.06, 24, -8)]
            case .menu:
                [(0.10, 6, -2), (0.22, 28, -8)]
            }
        }
    }

    private let style: Style
    private let material = NSVisualEffectView()
    private let highlight = CAGradientLayer()
    /// Solid surface, used instead of the material when the style is opaque.
    private let fill = CALayer()
    /// One layer per shadow. CALayer draws a single shadow, and the stacked
    /// shadows are not decoration: see the class comment.
    private var shadowLayers: [CALayer] = []

    var cornerRadius: CGFloat {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    init(style: Style, cornerRadius: CGFloat) {
        self.style = style
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        if style.isAlwaysDark { appearance = NSAppearance(named: .darkAqua) }

        for spec in style.shadows {
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = spec.opacity
            shadow.shadowRadius = spec.radius
            shadow.shadowOffset = CGSize(width: 0, height: spec.y)
            shadow.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(shadow)
            shadowLayers.append(shadow)
        }

        material.material = style == .bar ? .hudWindow : .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.isHidden = style.isOpaque
        material.wantsLayer = true
        material.layer?.masksToBounds = true
        material.layer?.cornerCurve = .continuous
        // Saturation is the half of the recipe AppKit has no property for. The
        // reference pushes it to 150% on bars so colours behind the glass stay
        // recognisable instead of washing out.
        if style.saturation != 1,
           let filter = CIFilter(name: "CIColorControls",
                                 parameters: [kCIInputSaturationKey: style.saturation]) {
            material.layer?.backgroundFilters = [filter]
        }
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        // Opaque surfaces get a solid fill in place of the material, plus the
        // reference's faint outer hairline instead of the glass rim. "Opaque" is
        // the default, not a guarantee: the user can dial the fill down until
        // the desktop reads through it (Settings > Editor > Chrome opacity).
        if style.isOpaque {
            fill.cornerCurve = .continuous
            fill.masksToBounds = true
            fill.borderWidth = KritColors.hairlineWidth
            layer?.addSublayer(fill)
            material.isHidden = false
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(chromeOpacityChanged),
                name: Settings.editorChromeOpacityChanged,
                object: nil
            )
        }

        // Inner rim: `inset 0 0 0 0.5px rgba(255,255,255,0.14)`.
        material.layer?.borderWidth = KritColors.hairlineWidth
        material.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // Top specular line: `inset 0 1px 0.5px rgba(255,255,255,0.30)`. Drawn as
        // a short gradient rather than a hard 1pt bar so it reads as a curved
        // edge catching light instead of a drawn border.
        highlight.colors = [
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0)
        highlight.isHidden = style.isOpaque
        material.layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The content this glass wraps.
    ///
    /// Hosted by whichever layer is actually visible: the material for glass,
    /// the view itself when the fill is opaque. Parenting content to a hidden
    /// material would hide the content with it.
    func setContent(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView = style.isOpaque ? self : material
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        material.layer?.cornerRadius = cornerRadius
        fill.frame = bounds
        fill.cornerRadius = cornerRadius

        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        for shadow in shadowLayers {
            shadow.frame = bounds
            shadow.cornerRadius = cornerRadius
            shadow.shadowPath = path
        }

        // 3pt of falloff: enough to read as a lit edge at every pill height we
        // use, short enough that it never becomes a gradient down the surface.
        highlight.frame = NSRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 3)
    }

    override func updateLayer() {
        material.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // Resolved here, not at init: a dynamic NSColor turned into a cgColor
        // once keeps whichever theme was current at that moment.
        //
        // The fill carries the user's opacity, and the vibrant material sits
        // behind it: as the fill thins out, what shows through is the blurred
        // desktop rather than a flat hole.
        let opacity = style.isOpaque ? CGFloat(Settings.editorChromeOpacity) : 1
        fill.backgroundColor = KritColors.sidebarBackground.withAlphaComponent(opacity).cgColor
        fill.borderColor = KritColors.hairline.cgColor
    }

    @objc private func chromeOpacityChanged() {
        needsDisplay = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
