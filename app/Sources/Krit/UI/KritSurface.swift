import AppKit
import SwiftUI

/// A restrained transition between fixed chrome and scrolling content. It
/// communicates depth without drawing another hard bar across the window.
struct KritEdgeDissolve: View {
    enum Direction {
        case down
        case up
    }

    let direction: Direction

    init(_ direction: Direction = .down) {
        self.direction = direction
    }

    var body: some View {
        LinearGradient(
            colors: [Color.primary.opacity(0.07), Color.primary.opacity(0)],
            startPoint: direction == .down ? .top : .bottom,
            endPoint: direction == .down ? .bottom : .top
        )
        .frame(height: 10)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Status is expressed by one semantic dot and plain text. A whole coloured
/// capsule gives routine state too much visual authority in a settings pane.
struct KritStatusLabel: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: KritSpacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .kritType(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

/// Neutral inset card for small groups that need containment without a nested
/// material or another branded tile.
struct KritInsetCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(KritSpacing.l)
            .background(
                RoundedRectangle(cornerRadius: ChromeFactory.Radius.card, style: .continuous)
                    .fill(Color.kritInsetSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChromeFactory.Radius.card, style: .continuous)
                    .stroke(Color.kritInsetSurfaceStroke, lineWidth: 1)
            )
    }
}

/// AppKit counterpart used by native onboarding and editor chrome.
final class KritEdgeDissolveView: NSView {
    enum Direction {
        case down
        case up
    }

    private let direction: Direction

    init(frame frameRect: NSRect, direction: Direction = .down) {
        self.direction = direction
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let strong = NSColor.labelColor.withAlphaComponent(0.08)
        let clear = NSColor.labelColor.withAlphaComponent(0)
        let gradient = direction == .down
            ? NSGradient(starting: strong, ending: clear)
            : NSGradient(starting: clear, ending: strong)
        gradient?.draw(in: bounds, angle: 90)
    }
}
