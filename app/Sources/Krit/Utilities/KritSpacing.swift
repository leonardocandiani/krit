import CoreGraphics

/// 4pt spacing grid shared across KRIT chrome, so padding and gaps stay on a
/// consistent rhythm instead of ad-hoc per-view numbers. Promoted from the
/// `BackgroundSidebar`'s local `Style` enum to an app-wide token.
enum KritSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
}
