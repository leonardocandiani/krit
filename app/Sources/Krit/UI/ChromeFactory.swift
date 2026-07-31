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
    /// One ruler, not two. These used to be their own scale (panel 16, card 12,
    /// control 11), which is why a window built here and a window built from
    /// KritMetrics read as two different apps sitting next to each other: the
    /// eye catches a 4pt difference in corner radius long before it can name it.
    /// Every surface now derives from the same numbers, so restyling one screen
    /// no longer means the rest drift out of step.
    enum Radius {
        /// The recording bars are floating chrome, the same class of surface as
        /// a floating panel, so they take the same corner.
        static let dock: CGFloat = KritMetrics.Radius.panel
        static let panel: CGFloat = KritMetrics.Radius.panel
        static let card: CGFloat = KritMetrics.Radius.card
        static let control: CGFloat = KritMetrics.Radius.cell
        /// Kept tight: pills are short, and a pill rounder than its own height
        /// stops being a pill.
        static let pill: CGFloat = 6
    }

    /// Debug switch to exercise the pre-macOS 26 blur fallback on a modern
    /// machine (set KRIT_FORCE_GLASS_FALLBACK=1). Lets the Intel/older-macOS
    /// rendering be reproduced and snapshotted without that hardware.
    static var forceFallback: Bool { ProcessInfo.processInfo.environment["KRIT_FORCE_GLASS_FALLBACK"] == "1" }

    /// Wraps `content` in a glass (or blur) capsule with the given radius.
    /// The returned view owns `content`; size the returned view, not content.
    ///
    /// `alwaysDark` pins the capsule to the dark appearance in both themes. Use
    /// it for chrome that floats over *user content* rather than over the app:
    /// a screenshot can be any colour, so a capsule that follows the system
    /// theme would be white-on-white half the time. Pinning it dark also fixes
    /// the controls inside, which then know their glyphs must be light.
    @MainActor
    static func make(content: NSView, cornerRadius: CGFloat, variant: Variant = .regular, tint: NSColor? = nil, alwaysDark: Bool = false) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let capsule: NSView
        // Real glass samples what is behind it, so it cannot be held dark: over a
        // light screenshot it turns white and takes the light glyphs inside it
        // with it. Chrome that must stay dark uses the HUD material instead,
        // which is the same translucent dark the reference app draws.
        if alwaysDark {
            let blur = makeBlur(cornerRadius: cornerRadius, variant: variant, tint: tint)
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                content.topAnchor.constraint(equalTo: blur.topAnchor),
                content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            return blur
        }
        if #available(macOS 26.0, *), !forceFallback {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            if let tint { glass.tintColor = tint }
            capsule = glass
        } else {
            let blur = makeBlur(cornerRadius: cornerRadius, variant: variant, tint: tint)
            blur.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                content.topAnchor.constraint(equalTo: blur.topAnchor),
                content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            capsule = blur
        }
        // Set on the capsule, which the content inherits: setting it on the
        // content alone leaves the material itself following the system theme.
        if alwaysDark { capsule.appearance = NSAppearance(named: .darkAqua) }
        return capsule
    }

    /// A standalone glass (or blur) backing view meant to sit *behind* controls,
    /// e.g. as the back layer of a borderless window. Sized to `frame` and set
    /// to autoresize; the caller stacks its own controls above it.
    @MainActor
    static func backing(frame: NSRect, cornerRadius: CGFloat, variant: Variant = .regular, tint: NSColor? = nil) -> NSView {
        if #available(macOS 26.0, *), !forceFallback {
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
        if #available(macOS 26.0, *), !forceFallback {
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

    /// A clear backing that sits over rich content in the same window must blur
    /// that content, not the desktop behind the window. Regular floating chrome
    /// remains a behind-window material.
    static func fallbackBlendingMode(for variant: Variant) -> NSVisualEffectView.BlendingMode {
        switch variant {
        case .regular:
            .behindWindow
        case .clear:
            .withinWindow
        }
    }

    // MARK: - Fallback (pre-macOS 26)

    @MainActor
    private static func makeBlur(cornerRadius: CGFloat, variant: Variant, tint: NSColor?) -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = variant == .clear ? .fullScreenUI : .hudWindow
        blur.blendingMode = fallbackBlendingMode(for: variant)
        blur.state = .active
        blur.wantsLayer = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        // The hairline is fallback-only, real glass self-rims. It also doubles
        // as the accessibility contrast edge. Only a rounded, floating shape gets
        // the rim: an edge-to-edge panel (cornerRadius 0) would draw it as a stray
        // white border framing the whole surface, so skip it there.
        if cornerRadius > 0 {
            let ws = NSWorkspace.shared
            let highContrast = ws.accessibilityDisplayShouldIncreaseContrast
            let lessTransparent = ws.accessibilityDisplayShouldReduceTransparency
            let borderAlpha: CGFloat = highContrast ? 0.55 : (lessTransparent ? 0.30 : 0.18)
            // Half a point is one physical line on Retina. A full point draws
            // the rim at double the intended weight, which is what makes the
            // fallback look heavier than real glass. Increase Contrast is the
            // one case that deliberately asks for a visible edge.
            blur.layer?.borderWidth = highContrast ? 1.5 : KritColors.hairlineWidth
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        }

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
