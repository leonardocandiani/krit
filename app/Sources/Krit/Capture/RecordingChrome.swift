import AppKit

enum RecordingChrome {
    struct Shadow: Equatable {
        let opacity: Float
        let radius: CGFloat
        let offset: CGSize
    }

    static let preflightShellRadius = ChromeFactory.Radius.dock
    static let hudShellRadius = ChromeFactory.Radius.dock
    static let resultShellRadius = ChromeFactory.Radius.panel
    static let controlRadius = ChromeFactory.Radius.control
    // Keep a readable floor over arbitrary desktop content without turning the
    // material into an opaque dark dashboard.
    static let contrastFloorAlpha: CGFloat = 0.34
    static let sectionDividerAlpha: CGFloat = 0.16
    static let neutralHoverAlpha: CGFloat = 0.12
    static let groupedToggleHoverAlpha: CGFloat = 0.08
    /// Floating chrome over arbitrary screen content, so it takes the same
    /// shadow as a menu: wide and soft. It used to be 0.56, dark enough to read
    /// as a drop-shadow filter painted under a rectangle rather than as a bar
    /// hovering above the desktop, and over pale content it looked like a smudge.
    static let overlayShadow = Shadow(
        opacity: 0.22,
        radius: 28,
        offset: CGSize(width: 0, height: -8)
    )

    static var effectiveContrastFloorAlpha: CGFloat {
        contrastFloorOpacity(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    static func contrastFloorOpacity(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> CGFloat {
        if increaseContrast { return 0.58 }
        if reduceTransparency { return 0.48 }
        return contrastFloorAlpha
    }

    @MainActor
    static func makeSectionDivider(identifier: String) -> NSView {
        let divider = RecordingChromeDivider(frame: .zero)
        divider.identifier = NSUserInterfaceItemIdentifier(identifier)
        return divider
    }
}

@MainActor
private final class RecordingChromeDivider: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(RecordingChrome.sectionDividerAlpha)
            .cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum RecordingControlRole: Equatable {
    case neutral
    case selected
    case primary
    case live
    case destructive
}

enum RecordingButtonPresentation: Equatable {
    case glyph
    case vertical
    case horizontal
}

enum RecordingButtonChromeStyle: Equatable {
    case standalone
    case groupedToggle
}

struct RecordingPreflightLayout {
    let shell = CGRect(x: 0, y: 0, width: 744, height: 72)
    let source = CGRect(x: 8, y: 8, width: 176, height: 56)
    let toggles = [
        CGRect(x: 192, y: 8, width: 52, height: 56),
        CGRect(x: 244, y: 8, width: 52, height: 56),
        CGRect(x: 296, y: 8, width: 52, height: 56),
        CGRect(x: 348, y: 8, width: 52, height: 56),
    ]
    let options = CGRect(x: 408, y: 8, width: 136, height: 56)
    let record = CGRect(x: 552, y: 8, width: 136, height: 56)
    let cancel = CGRect(x: 696, y: 8, width: 40, height: 56)

    var semanticFrames: [CGRect] {
        [source] + toggles + [options, record, cancel]
    }
}

struct RecordingHUDLayout {
    let shell: CGRect
    let liveCluster: CGRect
    let microphoneMeter: CGRect?
    let pause: CGRect
    let stop: CGRect
    let overflow: CGRect

    init(showsMeter: Bool) {
        liveCluster = CGRect(x: 8, y: 8, width: 136, height: 56)
        if showsMeter {
            shell = CGRect(x: 0, y: 0, width: 556, height: 72)
            microphoneMeter = CGRect(x: 152, y: 8, width: 112, height: 56)
            pause = CGRect(x: 272, y: 8, width: 100, height: 56)
            stop = CGRect(x: 380, y: 8, width: 112, height: 56)
            overflow = CGRect(x: 500, y: 8, width: 48, height: 56)
        } else {
            shell = CGRect(x: 0, y: 0, width: 436, height: 72)
            microphoneMeter = nil
            pause = CGRect(x: 152, y: 8, width: 100, height: 56)
            stop = CGRect(x: 260, y: 8, width: 112, height: 56)
            overflow = CGRect(x: 380, y: 8, width: 48, height: 56)
        }
    }

    var semanticFrames: [CGRect] {
        [liveCluster] + [microphoneMeter].compactMap { $0 } + [pause, stop, overflow]
    }
}

struct RecordingResultLayout {
    let shell = CGRect(x: 0, y: 0, width: 696, height: 112)
    let thumbnail = CGRect(x: 12, y: 12, width: 144, height: 88)
    let metadata = CGRect(x: 168, y: 12, width: 216, height: 88)
    let editRecording = CGRect(x: 392, y: 28, width: 136, height: 56)
    let reveal = CGRect(x: 536, y: 28, width: 96, height: 56)
    let overflow = CGRect(x: 640, y: 28, width: 44, height: 56)

    var primaryAction: CGRect { editRecording }

    var semanticFrames: [CGRect] {
        [thumbnail, metadata, editRecording, reveal, overflow]
    }
}

enum RecordingSurfaceKind: Equatable {
    case preflight
    case hud
    case result
}

enum RecordingPresentationTrigger: Equatable {
    case keyboard
    case pointer
    case stateTransition
}

enum RecordingTransition: Equatable {
    case instant
    case fade(duration: TimeInterval)
    case fadeAndScale(duration: TimeInterval, initialScale: CGFloat)
}

enum RecordingMotionPolicy {
    static func entrance(
        for surface: RecordingSurfaceKind,
        trigger: RecordingPresentationTrigger,
        reduceMotion: Bool
    ) -> RecordingTransition {
        guard !reduceMotion else { return .instant }
        if surface == .preflight, trigger == .keyboard { return .instant }
        switch surface {
        case .preflight:
            return .fade(duration: 0.12)
        case .hud:
            return .fadeAndScale(duration: 0.16, initialScale: 0.98)
        case .result:
            return .fadeAndScale(duration: 0.18, initialScale: 0.98)
        }
    }

    static func exit(for surface: RecordingSurfaceKind, reduceMotion: Bool) -> RecordingTransition {
        guard !reduceMotion else { return .instant }
        switch surface {
        case .preflight:
            return .instant
        case .hud:
            return .fade(duration: 0.12)
        case .result:
            return .fade(duration: 0.12)
        }
    }
}

enum RecordingLiveRole: Equatable {
    case live
    case paused
}

struct RecordingHUDStateAppearance: Equatable {
    let stopAlpha: CGFloat
    let stateLabel: String
    let liveRole: RecordingLiveRole
    let pauseAccessibilityLabel: String

    init(paused: Bool) {
        stopAlpha = 1
        stateLabel = paused ? "Paused" : "Recording"
        liveRole = paused ? .paused : .live
        pauseAccessibilityLabel = paused ? "Resume recording" : "Pause recording"
    }
}

@MainActor
class RecordingChromeButton: NSButton {
    private(set) var semanticRole: RecordingControlRole
    let presentation: RecordingButtonPresentation
    private let chromeStyle: RecordingButtonChromeStyle
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false

    init(
        symbol: String,
        title: String,
        role: RecordingControlRole,
        presentation: RecordingButtonPresentation,
        chromeStyle: RecordingButtonChromeStyle = .standalone
    ) {
        semanticRole = role
        self.presentation = presentation
        self.chromeStyle = chromeStyle
        super.init(frame: .zero)

        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.control
        layer?.cornerCurve = .continuous
        imageScaling = .scaleProportionallyDown
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = title

        let pointSize: CGFloat = presentation == .horizontal ? 17 : 18
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)

        switch presentation {
        case .glyph:
            self.title = ""
            imagePosition = .imageOnly
        case .vertical:
            self.title = title
            font = KritType.footnote.nsFont
            imagePosition = .imageAbove
            imageHugsTitle = true
        case .horizontal:
            self.title = title
            font = KritType.bodyEmphasis.nsFont
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateAppearance()
    }

    func setSemanticRole(_ role: RecordingControlRole) {
        semanticRole = role
        updateAppearance()
    }

    func setToggleState(_ isOn: Bool) {
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(isOn ? 1 : 0)
        setSemanticRole(isOn ? .selected : .neutral)
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.97, y: 0.97))
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.setAffineTransform(.identity)
    }

    private func updateAppearance() {
        let background: NSColor
        let foreground: NSColor
        switch semanticRole {
        case .neutral:
            let hoverAlpha = chromeStyle == .groupedToggle
                ? RecordingChrome.groupedToggleHoverAlpha
                : RecordingChrome.neutralHoverAlpha
            background = NSColor.white.withAlphaComponent(isPointerInside ? hoverAlpha : 0)
            foreground = NSColor.white.withAlphaComponent(0.86)
        case .selected:
            let hoverAlpha = chromeStyle == .groupedToggle
                ? RecordingChrome.groupedToggleHoverAlpha + 0.02
                : RecordingChrome.neutralHoverAlpha
            background = NSColor.white.withAlphaComponent(isPointerInside ? hoverAlpha : 0)
            foreground = KritColors.accent
        case .primary:
            background = KritColors.accent.withAlphaComponent(isPointerInside ? 1 : 0.92)
            foreground = .white
        case .live:
            background = NSColor.systemRed.withAlphaComponent(isPointerInside ? 0.92 : 0.78)
            foreground = .white
        case .destructive:
            background = NSColor.systemRed.withAlphaComponent(isPointerInside ? 0.23 : 0.16)
            foreground = .systemRed
        }
        layer?.backgroundColor = background.cgColor
        contentTintColor = foreground
    }
}

@MainActor
final class RecordingLevelMeter: NSView {
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
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Microphone input level")
        setLevel(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.64 + clamped * 0.36
        setAccessibilityValue(Int((smoothedLevel * 100).rounded()))

        let gap = min(4, max(3, bounds.width / 16))
        let barWidth = max(3, (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.16
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.66))
            let height = baseHeight + response * max(0, bounds.height - baseHeight)
            bar.frame = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.16).cgColor
        }
    }
}
