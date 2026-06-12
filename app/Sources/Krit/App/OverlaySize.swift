import Foundation

/// Size of the Quick Access overlay card. Backed by a String raw value so it can
/// persist in UserDefaults and drive a Preferences picker (see `Settings.overlaySize`).
enum OverlaySize: String, CaseIterable {
    case small
    case medium
    case large

    /// Base width of the overlay card in points for each size.
    var width: CGFloat {
        switch self {
        case .small:  return 180
        case .medium: return 240
        case .large:  return 320
        }
    }

    /// Multiplier applied to the medium baseline, for scaling fonts/insets/etc.
    var scale: CGFloat {
        switch self {
        case .small:  return 0.75
        case .medium: return 1.0
        case .large:  return 1.33
        }
    }

    var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
}
