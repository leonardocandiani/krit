import AppKit
import SwiftUI

/// Single semantic type scale for KRIT, mirroring `ChromeFactory.Radius`. Each
/// role vends both an `NSFont` (AppKit) and a SwiftUI `Font` from the same spec,
/// so the whole app speaks one type language instead of scattering
/// `systemFont(ofSize:)` literals across 40-odd call sites.
///
/// Sizes follow macOS chrome conventions (control text 13, secondary 11/12,
/// titles 15-22). Weights bias to `.semibold` for emphasis roles so labels read
/// crisp on glass.
enum KritType {
    case largeTitle
    case title
    case heading
    case bodyEmphasis
    case body
    case callout
    case caption
    case footnote
    case mono
    /// An all-caps group header above a list of settings or presets. Small,
    /// heavy and widely tracked: it has to recede as a block while every letter
    /// stays legible at 11pt.
    case sectionLabel

    var size: CGFloat {
        switch self {
        case .largeTitle: return 22
        case .title: return 17
        case .heading: return 15
        case .bodyEmphasis: return 13
        case .body: return 13
        case .callout: return 12
        case .caption: return 11
        case .footnote: return 10
        case .mono: return 12
        case .sectionLabel: return 11
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .largeTitle, .title, .heading: return .semibold
        // Semibold is the emphasis default, not bold. Bold at 13pt on glass
        // reads as shouting; semibold reads as deliberate.
        case .bodyEmphasis, .sectionLabel: return .semibold
        case .body, .callout, .caption, .footnote, .mono: return .regular
        }
    }

    /// Optical tracking, in points. The sign flips with size: large text closes
    /// up because the default spacing looks loose at display sizes, and small
    /// all-caps opens up because caps set tight turn into a grey smear. Apple
    /// applies this to SF and almost nobody copies it.
    var kern: CGFloat {
        switch self {
        case .largeTitle: return -0.5
        case .title: return -0.4
        case .heading: return -0.2
        case .bodyEmphasis, .body: return -0.1
        case .sectionLabel: return 0.6
        case .callout, .caption, .footnote, .mono: return 0
        }
    }

    private var swiftUIWeight: Font.Weight {
        switch nsWeight {
        case .semibold: return .semibold
        case .bold: return .bold
        case .medium: return .medium
        default: return .regular
        }
    }

    /// AppKit font for this role.
    var nsFont: NSFont {
        if self == .mono { return .monospacedSystemFont(ofSize: size, weight: nsWeight) }
        return .systemFont(ofSize: size, weight: nsWeight)
    }

    /// SwiftUI font for this role.
    var font: Font {
        if self == .mono { return .system(size: size, weight: swiftUIWeight, design: .monospaced) }
        return .system(size: size, weight: swiftUIWeight)
    }

    /// Font plus tracking plus colour in one dictionary, so a label gets the
    /// whole role instead of only its size. Kerning is invisible when applied
    /// one call site at a time, which is exactly why it has to live here.
    func attributes(color: NSColor = KritColors.textPrimary) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: nsFont, .foregroundColor: color]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    /// An attributed string carrying this role. `sectionLabel` upper-cases its
    /// text here so no call site has to remember to.
    func string(_ text: String, color: NSColor = KritColors.textPrimary) -> NSAttributedString {
        let body = self == .sectionLabel ? text.uppercased() : text
        return NSAttributedString(string: body, attributes: attributes(color: color))
    }
}

extension SwiftUI.Text {
    /// Apply a KRIT type role to a SwiftUI Text, tracking included.
    func kritType(_ role: KritType) -> SwiftUI.Text {
        font(role.font).tracking(role.kern)
    }
}

extension NSTextField {
    /// A non-editable label carrying a full type role: font, tracking and colour.
    /// Replaces the `NSTextField(labelWithString:)` + `font =` + `textColor =`
    /// trio that every view was repeating with slightly different values.
    static func kritLabel(_ text: String,
                          _ role: KritType,
                          color: NSColor = KritColors.textPrimary) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: role.string(text, color: color))
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// Restyle an existing label in place, keeping its current text.
    func applyKritType(_ role: KritType, color: NSColor = KritColors.textPrimary) {
        attributedStringValue = role.string(stringValue, color: color)
    }
}
