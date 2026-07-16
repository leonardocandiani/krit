import AppKit

@MainActor
final class RecordingHUDWindow: NSWindow {

    var stopHandler: (() -> Void)?
    /// Fired when the pause button toggles; argument is the new paused state.
    var togglePauseHandler: ((Bool) -> Void)?
    /// Restart and discard live in More so Stop remains the one dominant action.
    /// Items stay visible but disabled until their matching engine action exists.
    var restartHandler: (() -> Void)?
    var discardHandler: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let stateLabel = NSTextField(labelWithString: "Recording")
    private let liveCluster = NSView()
    private let liveDot = NSView()
    private let microphoneCluster = NSView()
    private let microphoneLevelMeter = RecordingLevelMeter()
    private let microphoneLabel = NSTextField(labelWithString: "Mic")
    private let sectionDividers = (0..<4).map {
        RecordingChrome.makeSectionDivider(identifier: "recording.hud.section-divider.\($0)")
    }
    private let stopButton = RecordingChromeButton(
        symbol: "stop.fill",
        title: "Stop",
        role: .live,
        presentation: .horizontal
    )
    private let pauseButton = RecordingHUDPauseButton()
    private let overflowButton = RecordingChromeButton(
        symbol: "ellipsis",
        title: "More",
        role: .neutral,
        presentation: .glyph
    )
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
        let layout = RecordingHUDLayout(showsMeter: false)
        super.init(
            contentRect: layout.shell,
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

        let root = RecordingHUDContentView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = RecordingChrome.hudShellRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.shadowColor = NSColor.black.cgColor
        root.layer?.shadowOpacity = RecordingChrome.overlayShadow.opacity
        root.layer?.shadowRadius = RecordingChrome.overlayShadow.radius
        root.layer?.shadowOffset = RecordingChrome.overlayShadow.offset
        contentView = root

        let glassBacking = ChromeFactory.backing(
            frame: root.bounds,
            cornerRadius: RecordingChrome.hudShellRadius,
            variant: .regular
        )
        root.addSubview(glassBacking)

        let scrim = RecordingHUDScrim(frame: root.bounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(RecordingChrome.effectiveContrastFloorAlpha)
            .cgColor
        scrim.layer?.cornerRadius = RecordingChrome.hudShellRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.autoresizingMask = [.width, .height]
        root.addSubview(scrim)

        liveCluster.frame = layout.liveCluster
        liveCluster.identifier = NSUserInterfaceItemIdentifier("recording.hud.live")
        liveCluster.wantsLayer = true
        liveCluster.layer?.cornerRadius = ChromeFactory.Radius.card
        liveCluster.layer?.cornerCurve = .continuous
        liveCluster.layer?.backgroundColor = NSColor.clear.cgColor
        liveCluster.setAccessibilityElement(true)
        liveCluster.setAccessibilityRole(.group)
        liveCluster.setAccessibilityLabel("Recording 00:00")
        root.addSubview(liveCluster)

        liveDot.frame = NSRect(x: 16, y: 20, width: 16, height: 16)
        liveDot.wantsLayer = true
        liveDot.layer?.cornerRadius = 8
        liveDot.layer?.backgroundColor = Self.liveRed.cgColor
        liveCluster.addSubview(liveDot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: KritType.title.size, weight: .semibold)
        timeLabel.textColor = Self.liveRed
        timeLabel.frame = NSRect(x: 44, y: 24, width: 80, height: 22)
        liveCluster.addSubview(timeLabel)

        stateLabel.font = KritType.footnote.nsFont
        stateLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        stateLabel.frame = NSRect(x: 44, y: 8, width: 80, height: 14)
        liveCluster.addSubview(stateLabel)

        microphoneCluster.wantsLayer = true
        microphoneCluster.layer?.cornerRadius = ChromeFactory.Radius.card
        microphoneCluster.layer?.cornerCurve = .continuous
        microphoneCluster.layer?.backgroundColor = NSColor.clear.cgColor
        microphoneCluster.identifier = NSUserInterfaceItemIdentifier("recording.hud.microphone-meter")
        microphoneCluster.setAccessibilityElement(true)
        microphoneCluster.setAccessibilityRole(.group)
        microphoneCluster.setAccessibilityLabel("Microphone input")
        root.addSubview(microphoneCluster)

        microphoneLevelMeter.frame = NSRect(x: 16, y: 18, width: 48, height: 20)
        microphoneCluster.addSubview(microphoneLevelMeter)
        microphoneLabel.font = KritType.caption.nsFont
        microphoneLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        microphoneLabel.frame = NSRect(x: 72, y: 19, width: 28, height: 18)
        microphoneCluster.addSubview(microphoneLabel)
        microphoneCluster.isHidden = true

        pauseButton.identifier = NSUserInterfaceItemIdentifier("recording.hud.pause")
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        root.addSubview(pauseButton)

        stopButton.identifier = NSUserInterfaceItemIdentifier("recording.hud.stop")
        stopButton.setAccessibilityLabel("Stop recording")
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        root.addSubview(stopButton)

        overflowButton.identifier = NSUserInterfaceItemIdentifier("recording.hud.overflow")
        overflowButton.setAccessibilityLabel("More recording actions")
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped)
        root.addSubview(overflowButton)

        for divider in sectionDividers {
            root.addSubview(divider)
        }

        apply(layout: layout)
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
        stopButton.toolTip = "Stop recording · \(quality.capitalized) quality · \(audio) · \(fps) fps"
        microphoneCluster.isHidden = !microphone
        layoutControls(showsMeter: microphone)
    }

    private func layoutControls(showsMeter: Bool) {
        let layout = RecordingHUDLayout(showsMeter: showsMeter)
        if abs(frame.width - layout.shell.width) > 0.5 {
            let center = NSPoint(x: frame.midX, y: frame.midY)
            var newFrame = frame
            newFrame.size = layout.shell.size
            newFrame.origin.x = center.x - layout.shell.width / 2
            newFrame.origin.y = center.y - layout.shell.height / 2
            setFrame(newFrame, display: true)
        }
        apply(layout: layout)
    }

    private func apply(layout: RecordingHUDLayout) {
        liveCluster.frame = layout.liveCluster
        microphoneCluster.frame = layout.microphoneMeter ?? .zero
        let hasMeter = layout.microphoneMeter != nil
        microphoneLevelMeter.frame = NSRect(
            x: hasMeter ? 16 : 12,
            y: 18,
            width: hasMeter ? 48 : 24,
            height: 20
        )
        microphoneLabel.frame = NSRect(
            x: hasMeter ? 72 : 44,
            y: 19,
            width: 28,
            height: 18
        )
        pauseButton.frame = layout.pause
        stopButton.frame = layout.stop
        overflowButton.frame = layout.overflow

        var regions = [layout.liveCluster]
        if let microphoneMeter = layout.microphoneMeter {
            regions.append(microphoneMeter)
        }
        regions += [layout.pause, layout.stop, layout.overflow]
        for (index, divider) in sectionDividers.enumerated() {
            guard index < regions.count - 1 else {
                divider.isHidden = true
                continue
            }
            let x = (regions[index].maxX + regions[index + 1].minX) / 2
            divider.frame = NSRect(x: x - 0.5, y: 20, width: 1, height: 32)
            divider.isHidden = false
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
        present(
            transition: RecordingMotionPolicy.entrance(
                for: .hud,
                trigger: .stateTransition,
                reduceMotion: Motion.reduced
            )
        )
    }

    private func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    func closeHUD() {
        timer?.invalidate()
        timer = nil
        microphoneLevelMeter.setLevel(0)
        let transition = RecordingMotionPolicy.exit(for: .hud, reduceMotion: Motion.reduced)
        guard case .fade(let duration) = transition else {
            orderOut(nil)
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1   // reset so the next show() starts opaque-ready
        })
    }

    private func present(transition: RecordingTransition) {
        orderFrontRegardless()
        switch transition {
        case .instant:
            alphaValue = 1
        case .fade(let duration):
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        case .fadeAndScale(let duration, let initialScale):
            alphaValue = 0
            if let layer = contentView?.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = initialScale
                scale.toValue = 1
                scale.duration = duration
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(scale, forKey: "recordingHUDEntranceScale")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    private func updateTime() {
        // Subtract accumulated paused time plus any currently-open pause so the
        // displayed timer matches the recorded (gated) duration.
        let openPause = pauseStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) - pausedAccumulator - openPause))
        timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        liveCluster.setAccessibilityLabel("\(stateLabel.stringValue) \(timeLabel.stringValue)")
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseStartedAt = Date()
        } else if let started = pauseStartedAt {
            pausedAccumulator += Date().timeIntervalSince(started)
            pauseStartedAt = nil
        }
        let appearance = RecordingHUDStateAppearance(paused: paused)
        pauseButton.setPaused(paused)
        pauseButton.toolTip = appearance.pauseAccessibilityLabel
        stateLabel.stringValue = appearance.stateLabel
        stopButton.alphaValue = appearance.stopAlpha
        timeLabel.textColor = paused ? NSColor.white.withAlphaComponent(0.72) : Self.liveRed
        liveCluster.layer?.borderWidth = paused ? 1 : 0
        liveCluster.layer?.borderColor = NSColor.white
            .withAlphaComponent(paused ? 0.20 : 0)
            .cgColor
        liveDot.layer?.backgroundColor = paused
            ? NSColor.white.withAlphaComponent(0.36).cgColor
            : Self.liveRed.cgColor
        updateTime()
        // A paused transition changes multiple layer-backed controls at once.
        // Commit one complete paint before returning so the WindowServer never
        // presents a partial HUD frame while the recording remains paused.
        contentView?.needsDisplay = true
        displayIfNeeded()
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

    @objc private func overflowTapped() {
        let menu = makeOverflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height), in: overflowButton)
    }

    func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        let restart = NSMenuItem(
            title: "Restart Recording",
            action: #selector(restartTapped),
            keyEquivalent: ""
        )
        restart.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        restart.target = self
        restart.isEnabled = restartHandler != nil
        menu.addItem(restart)
        menu.addItem(.separator())

        let discard = NSMenuItem(
            title: "Discard Recording",
            action: #selector(discardTapped),
            keyEquivalent: ""
        )
        discard.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        discard.target = self
        discard.isEnabled = discardHandler != nil
        menu.addItem(discard)
        return menu
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

/// Purely visual contrast scrim: it never intercepts events, so it can sit above
/// the glass without stealing clicks from the controls or the window-background drag.
@MainActor
private final class RecordingHUDScrim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class RecordingHUDPauseButton: RecordingChromeButton {
    private let pauseConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    init() {
        super.init(
            symbol: "pause.fill",
            title: "Pause",
            role: .neutral,
            presentation: .horizontal
        )
        setPaused(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPaused(_ paused: Bool) {
        let name = paused ? "play.fill" : "pause.fill"
        title = paused ? "Resume" : "Pause"
        image = NSImage(systemSymbolName: name, accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(pauseConfig)
        setAccessibilityLabel(paused ? "Resume recording" : "Pause recording")
        toolTip = paused ? "Resume recording" : "Pause recording"
    }
}
