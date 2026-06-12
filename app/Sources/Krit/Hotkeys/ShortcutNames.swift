import Foundation
import KeyboardShortcuts

/// Strongly-typed names for every global capture shortcut, each seeded with the
/// default KRIT used to hardcode. Defaults double as the "Restore Defaults"
/// target: `KeyboardShortcuts.reset(_:)` reads `defaultShortcut` from here.
extension KeyboardShortcuts.Name {
    static let captureArea         = Self("captureArea",         default: .init(.four,  modifiers: [.command, .shift]))
    static let captureWindow       = Self("captureWindow",       default: .init(.five,  modifiers: [.command, .shift]))
    static let captureFullscreen   = Self("captureFullscreen",   default: .init(.three, modifiers: [.command, .shift]))
    static let capturePreviousArea = Self("capturePreviousArea", default: .init(.seven, modifiers: [.command, .shift]))
    static let allInOne            = Self("allInOne",            default: .init(.a,     modifiers: [.command, .shift]))
    static let recordScreen        = Self("recordScreen",        default: .init(.six,   modifiers: [.command, .shift]))
    static let ocrCapture          = Self("ocrCapture",          default: .init(.o,     modifiers: [.command, .shift]))
    static let scrollingCapture    = Self("scrollingCapture",    default: .init(.s,     modifiers: [.command, .shift]))
    static let captureHistory      = Self("captureHistory",      default: .init(.h,     modifiers: [.command, .shift]))
    static let snapAndPaste        = Self("snapAndPaste",        default: .init(.p,     modifiers: [.command, .shift]))
    // No default binding: the eyedropper is opt-in so it never collides with a
    // system or app shortcut out of the box. Bind it in Preferences > Shortcuts.
    static let pickColor           = Self("pickColor")

    /// Every rebindable shortcut, in Preferences display order. Used to build the
    /// recorder rows and to reset them all at once. Per-preset shortcuts are
    /// dynamic (see `snapPreset(id:)`) and intentionally excluded here.
    static let allCapture: [KeyboardShortcuts.Name] = [
        .captureArea, .captureWindow, .captureFullscreen, .capturePreviousArea,
        .allInOne, .snapAndPaste, .recordScreen,
        .ocrCapture, .scrollingCapture, .pickColor, .captureHistory,
    ]

    /// Dynamic, per-preset global shortcut. The name encodes the preset id so the
    /// binding persists across launches and survives preset renames (only delete
    /// drops it). Registered/unregistered by HotkeyManager.registerPresets.
    static func snapPreset(id: UUID) -> KeyboardShortcuts.Name {
        Self("snapPreset-\(id.uuidString)")
    }
}
