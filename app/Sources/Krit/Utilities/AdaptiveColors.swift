import AppKit

// Coral accent: #FF7847 (rgb 255, 120, 71)
// Void background: #07080a (rgb 7, 8, 10)

private let coral = NSColor(calibratedRed: 255/255.0, green: 120/255.0, blue: 71/255.0, alpha: 1)
private let void  = NSColor(calibratedRed: 7/255.0,   green: 8/255.0,   blue: 10/255.0,  alpha: 1)

enum KritColors {

    static let overlayTint = NSColor(name: "overlayTint") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.06)
        default:        return NSColor.black.withAlphaComponent(0.08)
        }
    }

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
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.92)
        default:        return NSColor.white.withAlphaComponent(0.95)
        }
    }

    static let pillButtonHover = NSColor(name: "pillButtonHover") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white
        default:        return NSColor.white
        }
    }

    static let pillButtonPressed = NSColor(name: "pillButtonPressed") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.75)
        default:        return NSColor.white.withAlphaComponent(0.75)
        }
    }

    static let pillButtonText = NSColor(name: "pillButtonText") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.black.withAlphaComponent(0.85)
        default:        return NSColor.black.withAlphaComponent(0.85)
        }
    }

    static let progressBackground = NSColor(name: "progressBg") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.15)
        default:        return NSColor.black.withAlphaComponent(0.15)
        }
    }

    static let pinnedBorder = NSColor(name: "pinnedBorder") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.12)
        default:        return NSColor.black.withAlphaComponent(0.08)
        }
    }

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

    static let editorActionBackground = NSColor(name: "editorActionBackground") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: return NSColor.white.withAlphaComponent(0.13)
        default:        return NSColor.black.withAlphaComponent(0.10)
        }
    }

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
