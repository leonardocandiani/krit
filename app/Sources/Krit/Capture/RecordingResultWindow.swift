import AppKit

/// Post-recording result panel (C1/C3). After an MP4 finishes, this surfaces the
/// actions the engine implements, Export GIF and Trim, plus Reveal in Finder,
/// so both acceptance criteria are reachable from the UI.
@MainActor
final class RecordingResultWindow: NSWindow, NSWindowDelegate {

    private static var current: RecordingResultWindow?

    private let url: URL
    private let durationSeconds: Double
    private weak var anchorScreen: NSScreen?
    private weak var actions: RecordingResultActions?
    private let posterImageView = NSImageView()
    private var keyMonitor: Any?
    private var thumbnailTask: Task<Void, Never>?

    /// Shows the result panel for a finished `url`. `actions` is the engine, which
    /// runs the GIF export / trim. `duration` bounds the trim range.
    static func show(
        url: URL,
        duration: Double,
        actions: RecordingResultActions,
        on screen: NSScreen? = nil
    ) {
        current?.close()
        let window = RecordingResultWindow(
            url: url,
            duration: duration,
            actions: actions,
            screen: screen
        )
        current = window
        window.present()
    }

    static func uiTestMake(
        url: URL,
        duration: Double,
        actions: RecordingResultActions
    ) -> RecordingResultWindow {
        RecordingResultWindow(url: url, duration: duration, actions: actions, screen: nil)
    }

    private init(
        url: URL,
        duration: Double,
        actions: RecordingResultActions,
        screen: NSScreen?
    ) {
        self.url = url
        self.durationSeconds = max(duration, 0)
        self.actions = actions
        anchorScreen = screen

        let layout = RecordingResultLayout()
        super.init(
            contentRect: layout.shell,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none
        delegate = self
        // A borderless result panel is still a user-facing surface. It must keep
        // the accessory app active when another persistent window closes.
        NSApp.addActivationPersistentWindow(self)
        buildContent(layout: layout)
        installKeyMonitor()
        loadThumbnail()
    }

    override var canBecomeKey: Bool { true }

    private func buildContent(layout: RecordingResultLayout) {
        let background = RecordingResultContentView(frame: layout.shell)
        background.wantsLayer = true
        background.layer?.cornerRadius = RecordingChrome.resultShellRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.shadowColor = NSColor.black.cgColor
        background.layer?.shadowOpacity = RecordingChrome.overlayShadow.opacity
        background.layer?.shadowRadius = RecordingChrome.overlayShadow.radius
        background.layer?.shadowOffset = RecordingChrome.overlayShadow.offset
        contentView = background
        isMovableByWindowBackground = true

        let glass = ChromeFactory.backing(
            frame: layout.shell,
            cornerRadius: RecordingChrome.resultShellRadius
        )
        background.addSubview(glass)

        let contrastFloor = RecordingResultScrim(frame: layout.shell)
        contrastFloor.wantsLayer = true
        contrastFloor.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(RecordingChrome.effectiveContrastFloorAlpha * 0.78)
            .cgColor
        contrastFloor.layer?.cornerRadius = RecordingChrome.resultShellRadius
        contrastFloor.layer?.cornerCurve = .continuous
        background.addSubview(contrastFloor)

        let posterContainer = NSView(frame: layout.thumbnail)
        posterContainer.identifier = NSUserInterfaceItemIdentifier("recording.result.thumbnail")
        posterContainer.wantsLayer = true
        posterContainer.layer?.cornerRadius = ChromeFactory.Radius.card
        posterContainer.layer?.cornerCurve = .continuous
        posterContainer.layer?.masksToBounds = true
        posterContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        posterContainer.layer?.borderWidth = 1
        posterContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        background.addSubview(posterContainer)

        posterImageView.frame = posterContainer.bounds.insetBy(dx: 4, dy: 4)
        posterImageView.autoresizingMask = [.width, .height]
        posterImageView.imageScaling = .scaleProportionallyUpOrDown
        posterImageView.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Recording preview")
        posterImageView.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        posterContainer.addSubview(posterImageView)
        addDurationBadge(to: posterContainer)

        let metadata = NSView(frame: layout.metadata)
        metadata.identifier = NSUserInterfaceItemIdentifier("recording.result.metadata")
        metadata.setAccessibilityElement(true)
        metadata.setAccessibilityRole(.group)
        metadata.setAccessibilityLabel("Recording saved: \(url.lastPathComponent), \(formattedDuration)")
        background.addSubview(metadata)

        let divider = NSView(frame: NSRect(x: 0, y: 8, width: 1, height: 72))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        metadata.addSubview(divider)

        let check = NSImageView(frame: NSRect(x: 20, y: 54, width: 20, height: 20))
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .bold))
        check.contentTintColor = KritColors.accent
        metadata.addSubview(check)

        let titleLabel = NSTextField(labelWithString: "Recording saved")
        titleLabel.font = KritType.heading.nsFont
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        titleLabel.frame = NSRect(x: 52, y: 54, width: 156, height: 22)
        metadata.addSubview(titleLabel)

        let fileLabel = NSTextField(labelWithString: url.lastPathComponent)
        fileLabel.font = KritType.caption.nsFont
        fileLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.frame = NSRect(x: 20, y: 32, width: 180, height: 18)
        metadata.addSubview(fileLabel)

        let clock = NSImageView(frame: NSRect(x: 20, y: 12, width: 16, height: 16))
        clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        clock.contentTintColor = NSColor.white.withAlphaComponent(0.52)
        metadata.addSubview(clock)

        let durationLabel = NSTextField(labelWithString: formattedDuration)
        durationLabel.font = KritType.caption.nsFont
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        durationLabel.frame = NSRect(x: 44, y: 11, width: 72, height: 18)
        metadata.addSubview(durationLabel)

        let editButton = RecordingChromeButton(
            symbol: "pencil.and.outline",
            title: "Edit Recording",
            role: .primary,
            presentation: .horizontal
        )
        editButton.identifier = NSUserInterfaceItemIdentifier("recording.result.edit")
        editButton.frame = layout.editRecording
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.keyEquivalent = "\r"
        background.addSubview(editButton)

        let revealButton = RecordingChromeButton(
            symbol: "folder",
            title: "Reveal",
            role: .neutral,
            presentation: .horizontal
        )
        revealButton.identifier = NSUserInterfaceItemIdentifier("recording.result.reveal")
        revealButton.frame = layout.reveal
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        background.addSubview(revealButton)

        let overflowButton = RecordingChromeButton(
            symbol: "ellipsis",
            title: "More",
            role: .neutral,
            presentation: .glyph
        )
        overflowButton.identifier = NSUserInterfaceItemIdentifier("recording.result.overflow")
        overflowButton.setAccessibilityLabel("More recording actions")
        overflowButton.frame = layout.overflow
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped(_:))
        background.addSubview(overflowButton)
    }

    private var formattedDuration: String {
        let seconds = Int(durationSeconds.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func addDurationBadge(to poster: NSView) {
        let label = NSTextField(labelWithString: formattedDuration)
        label.font = KritType.caption.nsFont
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        label.layer?.cornerRadius = ChromeFactory.Radius.pill
        label.layer?.cornerCurve = .continuous
        label.frame = NSRect(x: poster.bounds.width - 58, y: 8, width: 48, height: 22)
        poster.addSubview(label)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    private func loadThumbnail() {
        let url = url
        thumbnailTask = Task { [weak self] in
            let image = await RecordingThumbnailProvider.thumbnail(for: url)
            guard !Task.isCancelled, let self else { return }
            posterImageView.contentTintColor = nil
            posterImageView.image = image
        }
    }

    private func present() {
        positionAtAnchor()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let transition = RecordingMotionPolicy.entrance(
            for: .result,
            trigger: .stateTransition,
            reduceMotion: Motion.reduced
        )
        switch transition {
        case .instant:
            alphaValue = 1
            makeKeyAndOrderFront(nil)
        case .fade(let duration):
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        case .fadeAndScale(let duration, let initialScale):
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            if let layer = contentView?.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = initialScale
                scale.toValue = 1
                scale.duration = duration
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(scale, forKey: "recordingResultEntranceScale")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    private func positionAtAnchor() {
        guard let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            center()
            return
        }
        let visible = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 18
        )
        setFrameOrigin(
            NSPoint(
                x: (origin.x * scale).rounded() / scale,
                y: (origin.y * scale).rounded() / scale
            )
        )
    }

    @objc private func exportGIFTapped() {
        actions?.exportGIF(from: url)
    }

    @objc private func trimTapped() {
        // The rich Trim & Convert panel (timeline + dimensions + quality + audio)
        // replaces the old start/end NSAlert. It routes the chosen range back to
        // the engine through the same `actions.trim`.
        guard let actions else { return }
        VideoTrimWindow.show(url: url, duration: durationSeconds, actions: actions)
    }

    @objc private func editTapped() {
        // The Snapzy-style video editor (player + timeline + zoom lane). Reachable
        // here so a recording finished with the overlay off still has a path to the
        // full editor, not just GIF/trim.
        actions?.openVideoEditor(url: url, duration: durationSeconds)
    }

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func overflowTapped(_ sender: NSButton) {
        let menu = NSMenu()

        let exportGIF = NSMenuItem(
            title: "Export GIF",
            action: #selector(exportGIFTapped),
            keyEquivalent: ""
        )
        exportGIF.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        exportGIF.target = self
        menu.addItem(exportGIF)

        let trim = NSMenuItem(title: "Trim", action: #selector(trimTapped), keyEquivalent: "")
        trim.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        trim.target = self
        menu.addItem(trim)

        menu.addItem(.separator())
        let copyPath = NSMenuItem(
            title: "Copy Path",
            action: #selector(copyPathTapped),
            keyEquivalent: ""
        )
        copyPath.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyPath.target = self
        menu.addItem(copyPath)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func copyPathTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func doneTapped() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.removeActivationPersistentWindow(self)
        thumbnailTask?.cancel()
        thumbnailTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if Self.current === self { Self.current = nil }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: self)
    }
}

@MainActor
private final class RecordingResultContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class RecordingResultScrim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
