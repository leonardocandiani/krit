import AppKit
import SwiftUI

/// SwiftUI bridge to the app's design tokens. KRIT is an AppKit app with a few
/// SwiftUI islands (preferences, video editor, what's new); every hosted island
/// runs through `.kritTheme()` so it speaks one visual language instead of
/// drifting to the system blue. AppKit owns the source tokens (`KritColors`,
/// `KritType`); this only exposes them to SwiftUI and tints the control accent.
///
/// The colors stay computed (not stored) so the underlying dynamic `NSColor`
/// keeps adapting to light/dark at render time.
extension Color {
    /// KRIT coral accent (#FF7847), the single brand/primary color.
    static var kritAccent: Color { Color(KritColors.accent) }
    static var kritCanvas: Color { Color(KritColors.canvasBackground) }
    static var kritEditorStageTop: Color { Color(KritColors.editorStageTop) }
    static var kritEditorStageBottom: Color { Color(KritColors.editorStageBottom) }
    static var kritEditorChromeBorder: Color { Color(KritColors.editorChromeBorder) }
    static var kritEditorActionBackground: Color { Color(KritColors.editorActionBackground) }
}

/// Applies the KRIT visual language to a hosted SwiftUI tree: coral as the
/// control accent so toggles, sliders, focus rings and selection match the
/// brand instead of the system blue. Apply at the root of every
/// `NSHostingController`/`NSHostingView`.
private struct KritThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(.kritAccent)
    }
}

extension View {
    /// Wrap a hosted SwiftUI tree so it inherits KRIT's coral accent and tokens.
    func kritTheme() -> some View { modifier(KritThemeModifier()) }
}
