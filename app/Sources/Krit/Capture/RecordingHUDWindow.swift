import AppKit

@MainActor
final class RecordingHUDWindow: NSWindow {

    var stopHandler: (() -> Void)?
    /// Fired when the pause button toggles; argument is the new paused state.
    var togglePauseHandler: ((Bool) -> Void)?
    /// Fired when restart is tapped. Optional: the button is present to match the
    /// CleanShot HUD; setting a handler enables it, otherwise it stays disabled
    /// (dimmed, no hit) rather than faking an action the engine does not expose.
    var restartHandler: (() -> Void)? { didSet { restartButton.isEnabled = restartHandler != nil } }
    /// Fired when discard (trash) is tapped. Same wired-but-optional contract as
    /// `restartHandler`.
    var discardHandler: (() -> Void)? { didSet { trashButton.isEnabled = discardHandler != nil } }

    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let detailLabel = NSTextField(labelWithString: "Recording")
    private let microphoneLevelMeter = RecordingHUDLevelMeter()
    private let stopButton = RecordingHUDStopButton()
    private let pauseButton = RecordingHUDPauseButton()
    private let restartButton = RecordingHUDGlyphButton(symbol: "arrow.counterclockwise", tint: .white)
    private let trashButton = RecordingHUDGlyphButton(symbol: "trash", tint: .white)
    private let divider = NSView()
    private var startedAt = Date()
    private var timer: Timer?
    private var isPaused = false
    // Wall-clock paused time so the HUD timer never advances during a pause and
    // stays in lockstep with the gated output.
    private var pausedAccumulator: TimeInterval = 0
    private var pauseStartedAt: Date?

    // Live recording tint: the stop square, the timer and the level meter all read
    // red while recording (CleanShot HUD), matching the r63 reference.
    private static let liveRed = NSColor.systemRed

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 244, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        sharingType = .none

        let hudRadius = ChromeFactory.Radius.panel
        let root = RecordingHUDContentView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = hudRadius
        root.layer?.cornerCurve = .continuous
        // Shadow lives on the outer host layer; glass handles its own rim light.
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = 0.72
        root.layer?.shadowRadius = 30
        root.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = root

        // Single glass backing at the HUD's corner radius (panel scale). The
        // controls stack flat above it: flat-on-one-glass is the correct pattern,
        // glass-on-glass is not.
        let glassBacking = ChromeFactory.backing(frame: root.bounds, cornerRadius: hudRadius)
        root.addSubview(glassBacking)

        // Left group: red stop square + red timer (the recording indicator).
        stopButton.title = ""
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.toolTip = "Stop recording"
        stopButton.frame = NSRect(x: 8, y: 7, width: 30, height: 30)
        root.addSubview(stopButton)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = Self.liveRed
        timeLabel.frame = NSRect(x: 42, y: 13, width: 42, height: 18)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        root.addSubview(timeLabel)

        // Mic level meter sits right after the timer when a microphone is armed;
        // hidden otherwise so the HUD stays as lean as r63 for silent captures.
        microphoneLevelMeter.frame = NSRect(x: 86, y: 11, width: 22, height: 22)
        microphoneLevelMeter.isHidden = true
        root.addSubview(microphoneLevelMeter)

        // Hidden carrier for the audio/fps summary; surfaced as the stop button's
        // tooltip via configure(), not as visible chrome (keeps the pill clean).
        detailLabel.isHidden = true
        root.addSubview(detailLabel)

        // Vertical divider between the indicator group and the control group.
        divider.frame = NSRect(x: 92, y: 12, width: 1, height: 20)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        root.addSubview(divider)

        // Right group: pause · restart · trash.
        pauseButton.title = ""
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        pauseButton.toolTip = "Pause recording"
        pauseButton.frame = NSRect(x: 104, y: 7, width: 30, height: 30)
        root.addSubview(pauseButton)

        restartButton.target = self
        restartButton.action = #selector(restartTapped)
        restartButton.toolTip = "Restart recording"
        restartButton.isEnabled = false
        restartButton.frame = NSRect(x: 140, y: 7, width: 30, height: 30)
        root.addSubview(restartButton)

        trashButton.target = self
        trashButton.action = #selector(discardTapped)
        trashButton.toolTip = "Discard recording"
        trashButton.isEnabled = false
        trashButton.frame = NSRect(x: 176, y: 7, width: 30, height: 30)
        root.addSubview(trashButton)
    }

    override var canBecomeKey: Bool { false }

    func configure(systemAudio: Bool, microphone: Bool, fps: Int, quality: String) {
        let audio = if systemAudio && microphone {
            "sys+mic"
        } else if systemAudio {
            "system"
        } else if microphone {
            "mic"
        } else {
            "no audio"
        }
        detailLabel.stringValue = "\(audio) · \(fps) fps"
        // The audio/fps/quality summary rides as the stop button's tooltip so the
        // pill stays clean while the info is still discoverable on hover.
        stopButton.toolTip = "Stop recording · \(quality.capitalized) quality · \(audio) · \(fps) fps"
        microphoneLevelMeter.isHidden = !microphone
        layoutControls(showsMeter: microphone)
    }

    /// Slides the divider and the control group right when the mic meter is shown,
    /// so the meter has room without overlapping the controls. Resizes the window
    /// to keep it centered on screen.
    private func layoutControls(showsMeter: Bool) {
        let controlsStartX: CGFloat = showsMeter ? 116 : 104
        let dividerX: CGFloat = showsMeter ? 112 : 92
        divider.frame.origin.x = dividerX
        let gap: CGFloat = 36
        pauseButton.frame.origin.x = controlsStartX
        restartButton.frame.origin.x = controlsStartX + gap
        trashButton.frame.origin.x = controlsStartX + gap * 2
        let newWidth = trashButton.frame.maxX + 8
        if abs(frame.width - newWidth) > 0.5 {
            let center = NSPoint(x: frame.midX, y: frame.midY)
            var newFrame = frame
            newFrame.size.width = newWidth
            newFrame.origin.x = center.x - newWidth / 2
            setFrame(newFrame, display: true)
            contentView?.frame = NSRect(origin: .zero, size: newFrame.size)
        }
    }

    func updateMicrophoneLevel(_ level: CGFloat) {
        microphoneLevelMeter.setLevel(level)
    }

    func show(on screen: NSScreen) {
        startedAt = Date()
        updateTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateTime() }
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(x: visibleFrame.midX - frame.width / 2, y: visibleFrame.maxY - frame.height - 18)
        setFrameOrigin(pixelAligned(origin, scale: screen.backingScaleFactor))
        orderFrontRegardless()
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    func closeHUD() {
        timer?.invalidate()
        timer = nil
        microphoneLevelMeter.setLevel(0)
        orderOut(nil)
    }

    private func updateTime() {
        // Subtract accumulated paused time plus any currently-open pause so the
        // displayed timer matches the recorded (gated) duration.
        let openPause = pauseStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) - pausedAccumulator - openPause))
        // m:ss like the r63 reference (single-digit minutes, no leading zero).
        timeLabel.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    /// Reflects the paused state in the chrome: swaps the button glyph, dims the
    /// timer and stop square so the pause is unmistakable.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseStartedAt = Date()
        } else if let started = pauseStartedAt {
            pausedAccumulator += Date().timeIntervalSince(started)
            pauseStartedAt = nil
        }
        pauseButton.setPaused(paused)
        pauseButton.toolTip = paused ? "Resume recording" : "Pause recording"
        timeLabel.alphaValue = paused ? 0.45 : 1
        stopButton.alphaValue = paused ? 0.6 : 1
        updateTime()
    }

    @objc private func pauseTapped() {
        togglePauseHandler?(!isPaused)
    }

    @objc private func stopTapped() {
        stopHandler?()
    }

    @objc private func restartTapped() {
        restartHandler?()
    }

    @objc private func discardTapped() {
        discardHandler?()
    }
}

@MainActor
private final class RecordingHUDContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class RecordingHUDPauseButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let pauseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        contentTintColor = .white
        setPaused(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPaused(_ paused: Bool) {
        let name = paused ? "play.fill" : "pause.fill"
        image = NSImage(systemSymbolName: name, accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(pauseConfig)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
}

/// A flat glyph control for the HUD's restart / trash actions: a borderless SF
/// Symbol with a subtle hover pad, no fill at rest, matching the bare icons in
/// the r63 reference. Disabled (dimmed, no hit) until a handler is wired.
@MainActor
private final class RecordingHUDGlyphButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = tint
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        super.updateLayer()
        alphaValue = isEnabled ? 1 : 0.4
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class RecordingHUDStopButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        // Red filled stop square: the live recording indicator in r63.
        contentTintColor = .systemRed
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop recording")?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
}

@MainActor
private final class RecordingHUDLevelMeter: NSView {

    private let bars: [NSView]
    private var smoothedLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in NSView(frame: .zero) }
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.4
            bar.layer?.cornerCurve = .continuous
            addSubview(bar)
        }
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLevel(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.64 + clamped * 0.36
        let gap: CGFloat = 3
        let barWidth: CGFloat = 3
        let baseHeight: CGFloat = 4
        for (index, bar) in bars.enumerated() {
            let threshold = CGFloat(index) * 0.16
            let response = max(0, min(1, (smoothedLevel - threshold) / 0.66))
            let height = baseHeight + response * (bounds.height - baseHeight)
            let x = CGFloat(index) * (barWidth + gap)
            bar.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            bar.layer?.backgroundColor = response > 0.08
                ? NSColor.systemGreen.withAlphaComponent(0.58 + response * 0.42).cgColor
                : NSColor.white.withAlphaComponent(0.16).cgColor
        }
    }
}
