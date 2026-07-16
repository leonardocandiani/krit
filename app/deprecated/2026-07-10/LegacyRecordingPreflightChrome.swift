import AppKit

// Deprecated on 2026-07-10.
//
// The recording continuum replaced this preflight chrome with
// RecordingChromeButton and RecordingLevelMeter. These implementations had no
// remaining instantiations and stay here only as migration history. This folder
// is intentionally outside the Swift package target.

@MainActor
private final class LegacyRecordingActionButton: NSButton {
    private let symbol: String
    private let buttonTint: NSColor
    private let isPrimary: Bool

    init(symbol: String, title: String, tint: NSColor = KritColors.accent, isPrimary: Bool = false) {
        self.symbol = symbol
        self.buttonTint = tint
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        self.title = ""
        toolTip = title
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = idleBackground
        contentTintColor = buttonTint
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var idleBackground: CGColor {
        isPrimary
            ? buttonTint.withAlphaComponent(0.20).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = buttonTint.withAlphaComponent(isPrimary ? 0.30 : 0.16).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = idleBackground
    }
}

@MainActor
private final class LegacyRecordingAudioLevelMeter: NSView {
    private let bars: [NSView]
    private var smoothedLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in NSView(frame: .zero) }
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.cornerCurve = .continuous
            addSubview(bar)
        }
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.62 + clamped * 0.38
        let gap: CGFloat = 3
        let barWidth: CGFloat = 3
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.17
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.65))
            let height = baseHeight + response * (bounds.height - baseHeight)
            let x = CGFloat(index) * (barWidth + gap)
            bar.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.18).cgColor
        }
    }
}

/*
Removed from RecordingControlsWindow after the dock preflight became fixed-height:

private static let expandedHeight: CGFloat = 72
private let microphoneContainer = NSView()
private let cameraContainer = NSView()

private func resizeForDeviceState() { ... }
private static var isExpanded: Bool { false }
private static func windowHeight(expanded: Bool) -> CGFloat { barHeight + chromeInset * 2 }
private func label(_:size:weight:color:) -> NSTextField { ... }
private func keyHint(_:) -> NSView { ... }
private func segmentContainer(frame:) -> NSView { ... }
private func styleDeviceContainer(_:frame:) { ... }
private func divider(x:height:) -> NSView { ... }

All callers had been removed before this archival move. The active implementation
uses RecordingChromeButton, RecordingLevelMeter, and the fixed RecordingPreflightLayout.
*/
