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
    static var kritNavigationSelection: Color { Color(KritColors.navigationSelectionFill) }
    static var kritNavigationHover: Color { Color(KritColors.navigationHoverFill) }
    static var kritInsetSurface: Color { Color(KritColors.insetSurface) }
    static var kritInsetSurfaceStroke: Color { Color(KritColors.insetSurfaceStroke) }

    // MARK: - Surfaces by role
    //
    // The SwiftUI face of the tinted neutrals. Every one of these carries 3% of
    // coral, which is what stops a hosted island from drifting to a system grey
    // that belongs to no one.

    static var kritWindow: Color { Color(KritColors.windowBackground) }
    static var kritSidebar: Color { Color(KritColors.sidebarBackground) }
    static var kritContent: Color { Color(KritColors.contentBackground) }
    static var kritPanel: Color { Color(KritColors.panelBackground) }

    static var kritCard: Color { Color(KritColors.surfaceCard) }
    static var kritCardHover: Color { Color(KritColors.surfaceCardHover) }
    static var kritInput: Color { Color(KritColors.surfaceInput) }
    static var kritWell: Color { Color(KritColors.surfaceWell) }
    static var kritHover: Color { Color(KritColors.surfaceHover) }
    static var kritPressed: Color { Color(KritColors.surfacePressed) }

    // MARK: - Text, five steps

    static var kritTextPrimary: Color { Color(KritColors.textPrimary) }
    static var kritTextStrong: Color { Color(KritColors.textStrong) }
    static var kritTextSecondary: Color { Color(KritColors.textSecondary) }
    static var kritTextTertiary: Color { Color(KritColors.textTertiary) }
    static var kritTextMuted: Color { Color(KritColors.textMuted) }

    // MARK: - Lines

    static var kritHairline: Color { Color(KritColors.hairline) }
    static var kritHairlineStrong: Color { Color(KritColors.hairlineStrong) }
    static var kritDivider: Color { Color(KritColors.divider) }
}

extension View {
    /// A card surface: tinted fill, hairline rim, continuous corner. The one
    /// place that decides what "a card" looks like, so two panels doing the
    /// same job stop being drawn two different ways.
    func kritCardSurface(radius: CGFloat = ChromeFactory.Radius.card,
                         fill: Color = .kritCard) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.kritHairline, lineWidth: KritColors.hairlineWidth)
        )
    }
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
