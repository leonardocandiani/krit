import AppKit

// Coral accent: #FF7847 (rgb 255, 120, 71)
// Void background: #07080a (rgb 7, 8, 10)

private let coral = NSColor(calibratedRed: 255/255.0, green: 120/255.0, blue: 71/255.0, alpha: 1)
private let void  = NSColor(calibratedRed: 7/255.0,   green: 8/255.0,   blue: 10/255.0,  alpha: 1)

/// How much accent every neutral carries. Low enough that nobody calls the
/// surface orange, high enough that neighbouring panels stop reading as parts
/// from different apps. This single number is what makes the app feel designed
/// rather than assembled.
private let tintAmount: CGFloat = 0.03

/// Mixes `tintAmount` of coral into a neutral, in sRGB. The AppKit counterpart
/// of `color-mix(in srgb, accent 3%, base)`.
private func tinted(_ base: NSColor, _ amount: CGFloat = tintAmount) -> NSColor {
    guard let a = base.usingColorSpace(.sRGB), let b = coral.usingColorSpace(.sRGB) else { return base }
    return a.blended(withFraction: amount, of: b) ?? base
}

/// A translucent overlay built from the *tinted* foreground rather than from
/// pure black or white: the wash that produces card, hover, input and well.
/// Passing the accent through even these low alphas is what keeps a hover state
/// from looking like dirt on the surface.
private func tintedOverlay(light: CGFloat, dark: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return tinted(.white).withAlphaComponent(dark)
        default:        return tinted(.black).withAlphaComponent(light)
        }
    }
}

/// A solid surface: a neutral grey per theme, both tinted with the same accent.
private func tintedSurface(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return tinted(dark)
        default:        return tinted(light)
        }
    }
}

private func grey(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:    CGFloat(hex & 0xFF) / 255.0,
            alpha: 1)
}

enum KritColors {

    // MARK: - Surfaces by role
    //
    // Named for what they DO, not for where they were first needed. Two panels
    // with the same job in different windows now share one value instead of
    // each picking its own `NSColor(white:alpha:)`. Every value below carries
    // the same 3% of coral, which is what makes them agree.

    /// The window itself: the furthest-back plane.
    static let windowBackground  = tintedSurface(light: grey(0xE8E8EC), dark: grey(0x1C1C1E))
    /// A sidebar or master list, one step forward from the window.
    static let sidebarBackground = tintedSurface(light: .white,          dark: grey(0x242426))
    /// The content pane a sidebar sits next to.
    static let contentBackground = tintedSurface(light: grey(0xF2F2F5), dark: grey(0x18181A))
    /// A raised sheet, popover or panel body.
    static let panelBackground   = tintedSurface(light: grey(0xFAFAFA), dark: grey(0x2A2A2D))

    /// Resting fill of a card or a settings row.
    static let surfaceCard      = tintedOverlay(light: 0.03, dark: 0.05)
    /// The same card under the pointer.
    static let surfaceCardHover = tintedOverlay(light: 0.05, dark: 0.08)
    /// A text field or any control that receives input.
    static let surfaceInput     = tintedOverlay(light: 0.04, dark: 0.06)
    /// A recessed track: slider groove, segmented background, progress trough.
    static let surfaceWell      = tintedOverlay(light: 0.06, dark: 0.10)
    /// The unfilled part of a slider groove. Heavier than `surfaceWell` because
    /// a 4pt track has to stay visible against both a light card and a dark
    /// glass pill, where a 6% wash simply disappears.
    static let trackFill        = NSColor(red: 120/255, green: 120/255, blue: 128/255, alpha: 0.20)
    /// Hover for something already sitting on a filled surface.
    static let surfaceHover     = tintedOverlay(light: 0.07, dark: 0.10)
    /// The pressed state of the above.
    static let surfacePressed   = tintedOverlay(light: 0.10, dark: 0.14)

    // MARK: - Text, five steps
    //
    // Two levels force every secondary string to either shout or vanish. Five
    // is what lets a section label recede without disappearing and a subtitle
    // exist without competing with its title.

    static let textPrimary   = tintedSurface(light: grey(0x1D1D1F), dark: grey(0xF5F5F7))
    static let textStrong    = tintedSurface(light: grey(0x0A0A0C), dark: .white)
    static let textSecondary = tintedSurface(light: grey(0x5A5A5E), dark: grey(0xA9A9AE))
    static let textTertiary  = tintedSurface(light: grey(0x8A8A8E), dark: grey(0x8A8A8E))
    static let textMuted     = tintedSurface(light: grey(0xB0B0B5), dark: grey(0x6A6A6E))

    // MARK: - Lines
    //
    // Always half a point. On Retina that is one physical line, and it is the
    // difference between a border that exists and a border that was drawn.

    static let hairline       = tintedOverlay(light: 0.09, dark: 0.10)
    static let hairlineStrong = tintedOverlay(light: 0.16, dark: 0.18)
    /// A separator inside a group, lighter than the edge around it.
    static let divider        = tintedOverlay(light: 0.07, dark: 0.08)

    /// Ink for a glyph sitting on a WHITE chrome fill, e.g. the selected tool
    /// inside the dark pill. Deliberately not `textPrimary`: that token is
    /// appearance-dynamic, and the pill pins itself to dark, so it would resolve
    /// to the near-white dark-mode ink and vanish against the white disc.
    static let onLightChrome = NSColor(srgbRed: 0x1D/255, green: 0x1D/255, blue: 0x1F/255, alpha: 1)

    /// Width for every hairline in the app. A full point doubles the intended
    /// weight on Retina, which is what makes chrome look heavy-handed.
    static let hairlineWidth: CGFloat = 0.5

    static let overlayTint = tintedOverlay(light: 0.08, dark: 0.06)

    /// Solid fill behind the capture thumbnail in QuickAccessOverlay.
    /// Needs to be opaque enough to read as a proper container when the
    /// image is letterboxed inside the fixed overlay size.
    static let overlayContainerFill = NSColor(name: "overlayContainerFill") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(white: 0.11, alpha: 0.96)
        default:        return NSColor(white: 0.18, alpha: 0.96)
        }
    }

    static let overlayBorder = NSColor(name: "overlayBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.25)
        default:        return NSColor.black.withAlphaComponent(0.12)
        }
    }

    static let cornerButtonBackground = NSColor(name: "cornerButton") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.18)
        default:        return NSColor.black.withAlphaComponent(0.12)
        }
    }

    static let cornerButtonHover = NSColor(name: "cornerButtonHover") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.35)
        default:        return NSColor.black.withAlphaComponent(0.22)
        }
    }

    static let cornerButtonPressed = NSColor(name: "cornerButtonPressed") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.45)
        default:        return NSColor.black.withAlphaComponent(0.30)
        }
    }

    static let pillButtonBackground = NSColor(name: "pillButton") { appearance in
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(opaque ? 0.82 : 0.48)
        default:        return NSColor.black.withAlphaComponent(opaque ? 0.82 : 0.52)
        }
    }

    static let pillButtonHover = NSColor(name: "pillButtonHover") { appearance in
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return coral.withAlphaComponent(opaque ? 0.72 : 0.42)
        default:        return coral.withAlphaComponent(opaque ? 0.76 : 0.46)
        }
    }

    static let pillButtonPressed = NSColor(name: "pillButtonPressed") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return coral.withAlphaComponent(0.76)
        default:        return coral.withAlphaComponent(0.80)
        }
    }

    static let pillButtonText = NSColor(name: "pillButtonText") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.92)
        default:        return NSColor.white.withAlphaComponent(0.94)
        }
    }

    static let progressBackground = tintedOverlay(light: 0.15, dark: 0.15)

    static let pinnedBorder = tintedOverlay(light: 0.08, dark: 0.12)

    static let canvasBackground = NSColor(name: "canvasBackground") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(white: 0.12, alpha: 1.0)
        default:        return NSColor(white: 0.22, alpha: 1.0)
        }
    }

    // Void dark surface (#07080a) for the editor stage top.
    static let editorStageTop = NSColor(name: "editorStageTop") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return void
        default:        return NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        }
    }

    static let editorStageBottom = NSColor(name: "editorStageBottom") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor(calibratedRed: 0.105, green: 0.096, blue: 0.13, alpha: 1)
        default:        return NSColor(calibratedRed: 0.28, green: 0.28, blue: 0.31, alpha: 1)
        }
    }

    static let editorChromeBorder = NSColor(name: "editorChromeBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.10)
        default:        return NSColor.white.withAlphaComponent(0.20)
        }
    }

    static let editorDockBorder = NSColor(name: "editorDockBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.18)
        default:        return NSColor.white.withAlphaComponent(0.28)
        }
    }

    static let editorActionBackground = tintedOverlay(light: 0.10, dark: 0.13)

    /// Neutral selection for structural navigation. Coral stays on the selected
    /// glyph and primary actions instead of becoming a large painted rectangle.
    static let navigationSelectionFill = tintedOverlay(light: 0.08, dark: 0.12)

    static let navigationHoverFill = tintedOverlay(light: 0.045, dark: 0.07)

    /// Subtle inset surface shared by Settings-style cards and compact status
    /// rows. It remains neutral so content hierarchy does not compete with coral.
    static let insetSurface = NSColor(name: "insetSurface") { appearance in
        // Reduce Transparency asks for a surface that reads without relying on
        // what is behind it, so the wash roughly doubles. Both branches still
        // come from the tinted foreground, not from flat black or white.
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return tinted(.white).withAlphaComponent(opaque ? 0.10 : 0.065)
        default:        return tinted(.black).withAlphaComponent(opaque ? 0.07 : 0.035)
        }
    }

    static let insetSurfaceStroke = hairline

    /// Pointer feedback for compact editor tools. These remain neutral so coral
    /// keeps its meaning as a primary action or a committed toggle state.
    static let editorToolHoverFill = surfaceHover

    static let editorToolPressedFill = surfacePressed

    /// Monochrome fill behind the SELECTED tool in the editor's flat tool strip
    /// (CleanShot pattern): a high-contrast neutral pad, NOT the coral accent.
    /// Coral is reserved for the background-panel toggle and the primary Done.
    /// Dark mode: a near-white pad with a dark glyph. Light mode: a dark grey pad
    /// with a white glyph. Inactive tools draw no pad at all (flat glyph only).
    static let toolSelectedFill = NSColor(name: "toolSelectedFill") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.92)
        default:        return NSColor(white: 0.34, alpha: 1.0)
        }
    }

    /// Glyph color of the SELECTED tool, the inverse of `toolSelectedFill` so the
    /// symbol reads against its pad (dark glyph on the light dark-mode pad, white
    /// glyph on the dark light-mode pad).
    static let toolSelectedGlyph = NSColor(name: "toolSelectedGlyph") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.88)
        default:        return NSColor.white
        }
    }

    /// Glyph color of an INACTIVE flat tool: a flat, slightly muted label color,
    /// no pad behind it, matching the bare glyphs in the CleanShot tool strip.
    static let toolInactiveGlyph = NSColor(name: "toolInactiveGlyph") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.82)
        default:        return NSColor.black.withAlphaComponent(0.74)
        }
    }

    static let selectionDim = NSColor(name: "selectionDim") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.45)
        default:        return NSColor.black.withAlphaComponent(0.3)
        }
    }

    static let labelPillBackground = NSColor(name: "labelPill") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.75)
        default:        return NSColor.black.withAlphaComponent(0.65)
        }
    }

    /// KRIT coral accent (#FF7847), used for the default annotation color and primary UI accents.
    static let accent: NSColor = coral
}
