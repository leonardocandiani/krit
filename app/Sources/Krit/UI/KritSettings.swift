import SwiftUI

/// The settings vocabulary: a group, a row, and the glyph tile that identifies
/// it. SwiftUI's `.formStyle(.grouped)` paints its own background and its own
/// row metrics, which means the app's tokens never reach the surface the user
/// actually looks at. These draw the same structure with KRIT's values, so a
/// settings screen finally looks like the rest of the app.
///
/// Structure, borrowed wholesale from the macOS Settings grammar:
///
///     SECTION LABEL           <- 11pt semibold, +0.6 tracking, tertiary
///     ┌───────────────────┐
///     │ [icon] Title    ◯ │   <- 44pt row, control trailing
///     │        Subtitle    │
///     ├───────────────────┤   <- divider, inset past the tile
///     │ [icon] Title    ◯ │
///     └───────────────────┘   <- one card per group, not one per row

// MARK: - Group

/// A titled card holding a run of rows. The label sits outside the card and the
/// rows share a single rounded surface, which is what makes a group read as one
/// object instead of a stack of separate pills.
struct KritSettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .kritType(.sectionLabel)
                    .foregroundStyle(Color.kritTextTertiary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) { content }
                .kritCardSurface(radius: ChromeFactory.Radius.card)
        }
    }
}

// MARK: - Row

/// One setting: glyph tile, title, optional subtitle, and a trailing control.
///
/// The tile colour is categorical the way System Settings uses it, which is
/// what separates it from the decorative pastel icon tile: full-strength fill,
/// white glyph, and the same colour every time that row appears.
struct KritSettingsRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    init(_ title: String,
         symbol: String,
         tint: Color,
         subtitle: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            KritGlyphTile(symbol: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .kritType(.body)
                    .foregroundStyle(Color.kritTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .kritType(.caption)
                        .foregroundStyle(Color.kritTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control
                .labelsHidden()
                // Outside a `Form`, SwiftUI renders `Toggle` as a checkbox on
                // macOS. Every settings row wants the switch, and asking for it
                // here means no call site has to remember.
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A setting whose value is a range: title and live readout on one line, the
/// slider on its own below. Splitting them means the number stays put while the
/// thumb moves, instead of the row reflowing on every drag.
struct KritSliderRow: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let readout: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                KritGlyphTile(symbol: symbol, tint: tint)
                Text(title)
                    .kritType(.body)
                    .foregroundStyle(Color.kritTextPrimary)
                Spacer(minLength: 8)
                Text(readout)
                    .kritType(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.kritTextTertiary)
            }

            slider
                .controlSize(.small)

            if let caption {
                Text(caption)
                    .kritType(.caption)
                    .foregroundStyle(Color.kritTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}

/// An inline advisory inside a group: something the user needs to act on before
/// the setting above it does anything. Tinted, but never the accent, so it does
/// not read as a control.
struct KritSettingsNote: View {
    let text: String
    let symbol: String
    let tint: Color

    init(_ text: String, symbol: String, tint: Color) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .kritType(.caption)
                .foregroundStyle(Color.kritTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Separator between rows in the same group. Inset past the tile so the rule
/// starts where the text does, the way grouped lists have always done it.
struct KritRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.kritDivider)
            .frame(height: KritColors.hairlineWidth)
            .padding(.leading, 44)
    }
}

// MARK: - Glyph tile

/// The filled rounded square behind a settings glyph.
struct KritGlyphTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: KritColors.hairlineWidth)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Page

/// The scrolling body of a settings tab: groups stacked on the content surface,
/// with the width and rhythm shared by every tab.
struct KritSettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }
}
