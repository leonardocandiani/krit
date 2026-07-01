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
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .largeTitle, .title, .heading, .bodyEmphasis: return .semibold
        case .body, .callout, .caption, .footnote, .mono: return .regular
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
}

extension SwiftUI.Text {
    /// Apply a KRIT type role to a SwiftUI Text.
    func kritType(_ role: KritType) -> SwiftUI.Text { font(role.font) }
}
