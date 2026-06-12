import Foundation

/// How the editor opens a window capture. Window shots are the only captures that
/// auto-apply a background (user rule); this picks which one. Backed by a String
/// raw value so it persists in UserDefaults and drives a Preferences picker
/// (see `Settings.windowCaptureBackground`).
enum WindowCaptureBackground: String, CaseIterable {
    /// Compose with the current desktop wallpaper, centered with shadow (default).
    case systemWallpaper
    /// Apply the saved default template, else a seeded enabled background.
    case savedTemplate
    /// Open raw, like an ordinary screenshot.
    case none

    var displayName: String {
        switch self {
        case .systemWallpaper: return "System wallpaper"
        case .savedTemplate:   return "Saved template"
        case .none:            return "None"
        }
    }
}
