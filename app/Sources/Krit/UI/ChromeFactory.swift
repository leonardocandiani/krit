import AppKit

/// Single gate for Liquid Glass adoption across KRIT. Every floating surface
/// (toolbars, HUDs, overlays, panels, popovers) asks here for its backing so
/// the whole app speaks one glass language and follows Apple's documented
/// Liquid Glass standards:
///
///  - Regular variant by default; Clear only for media-rich backdrops the
///    caller dims itself.
///  - Glass stays untinted; tint is reserved for the single primary action.
///  - No hairline on real glass (it draws its own rim light). The 1px border
///    ships only on the pre-26 blur fallback.
///  - Accessibility: Reduce Transparency / Increase Contrast raise opacity and
///    add a contrast border on the fallback. macOS 26 glass adapts on its own.
///
/// macOS 26+ gets real glass (NSGlassEffectView); earlier systems fall back to
/// the HUD material that shipped with KRIT v0.1. Deployment target stays 13.
enum ChromeFactory {

    /// Apple's two Liquid Glass variants.
    enum Variant {
        /// Adapts to any content with its own legibility treatment. The default
        /// for chrome that floats over unknown content.
        case regular
        /// More transparent, for media-rich backdrops the caller already dims.
        case clear
    }

    /// Corner-radius scale shared by every glass surface, so radii stay
    /// consistent and concentric across the app.
    enum Radius {
        static let dock: CGFloat = 18
        static let panel: CGFloat = 16
        static let card: CGFloat = 12
        static let control: CGFloat = 11
        static let pill: CGFloat = 6
    }

    /// Wraps `content` in a glass (or blur) capsule with the given radius.
    /// The returned view owns `content`; size the returned view, not content.
    @MainActor
    static func make(content: NSView, cornerRadius: CGFloat, variant: Variant = .regular, tint: NSColor? = nil) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            if let tint { glass.tintColor = tint }
            return glass
        }
        let blur = makeBlur(cornerRadius: cornerRadius, variant: variant, tint: tint)
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    /// A standalone glass (or blur) backing view meant to sit *behind* controls,
    /// e.g. as the back layer of a borderless window. Sized to `frame` and set
    /// to autoresize; the caller stacks its own controls above it.
    @MainActor
    static func backing(frame: NSRect, cornerRadius: CGFloat, variant: Variant = .regular, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = cornerRadius
            if let tint { glass.tintColor = tint }
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        let blur = makeBlur(cornerRadius: cornerRadius, variant: variant, tint: tint)
        blur.frame = frame
        blur.autoresizingMask = [.width, .height]
        return blur
    }

    /// Groups nearby glass shapes so they merge/morph correctly. Glass cannot
    /// sample glass: any two glass views closer than ~40pt should share a
    /// container. On the fallback path there is no clustering to do.
    @MainActor
    static func makeCluster(content: NSView, spacing: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.contentView = content
            container.spacing = spacing
            return container
        }
        return content
    }

    /// Concentric inner radius for a control inset by `inset` inside a container
    /// of `outerRadius`, Apple's nested-corner rule keeps shapes parallel.
    static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 2)
    }

    // MARK: - Fallback (pre-macOS 26)

    @MainActor
    private static func makeBlur(cornerRadius: CGFloat, variant: Variant, tint: NSColor?) -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = variant == .clear ? .fullScreenUI : .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        // The hairline is fallback-only, real glass self-rims. It also doubles
        // as the accessibility contrast edge.
        let ws = NSWorkspace.shared
        let highContrast = ws.accessibilityDisplayShouldIncreaseContrast
        let lessTransparent = ws.accessibilityDisplayShouldReduceTransparency
        let borderAlpha: CGFloat = highContrast ? 0.55 : (lessTransparent ? 0.30 : 0.18)
        blur.layer?.borderWidth = highContrast ? 1.5 : 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor

        if let tint {
            // Tinted fallback: lay the accent wash over the blur at low alpha so
            // the primary action still reads as tinted without real glass.
            let wash = CALayer()
            wash.frame = blur.bounds
            wash.backgroundColor = tint.withAlphaComponent(0.22).cgColor
            wash.cornerRadius = cornerRadius
            wash.cornerCurve = .continuous
            wash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            blur.layer?.addSublayer(wash)
        }
        return blur
    }
}
