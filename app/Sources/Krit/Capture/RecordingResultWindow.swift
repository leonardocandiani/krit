import AppKit

/// Post-recording result panel (C1/C3). After an MP4 finishes, this surfaces the
/// actions the engine implements, Export GIF and Trim, plus Reveal in Finder,
/// so both acceptance criteria are reachable from the UI.
@MainActor
final class RecordingResultWindow: NSWindow, NSWindowDelegate {

    private static var current: RecordingResultWindow?

    private let url: URL
    private let durationSeconds: Double
    private weak var actions: RecordingResultActions?

    /// Shows the result panel for a finished `url`. `actions` is the engine, which
    /// runs the GIF export / trim. `duration` bounds the trim range.
    static func show(url: URL, duration: Double, actions: RecordingResultActions) {
        current?.close()
        let window = RecordingResultWindow(url: url, duration: duration, actions: actions)
        current = window
        window.present()
    }

    private init(url: URL, duration: Double, actions: RecordingResultActions) {
        self.url = url
        self.durationSeconds = max(duration, 0)
        self.actions = actions

        let width: CGFloat = 420
        let height: CGFloat = 168
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        delegate = self
        center()
        buildContent(width: width, height: height)
    }

    private func buildContent(width: CGFloat, height: CGFloat) {
        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        contentView = background

        let glass = ChromeFactory.backing(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            cornerRadius: ChromeFactory.Radius.panel
        )
        background.addSubview(glass)

        let iconWrap = NSView(frame: NSRect(x: 24, y: height - 76, width: 42, height: 42))
        iconWrap.wantsLayer = true
        iconWrap.layer?.cornerRadius = 13
        iconWrap.layer?.cornerCurve = .continuous
        iconWrap.layer?.backgroundColor = KritColors.accent.withAlphaComponent(0.12).cgColor
        iconWrap.layer?.borderWidth = 1
        iconWrap.layer?.borderColor = KritColors.accent.withAlphaComponent(0.28).cgColor
        background.addSubview(iconWrap)

        let icon = NSImageView(frame: NSRect(x: 9, y: 9, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        icon.contentTintColor = KritColors.accent
        iconWrap.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: "Recording saved")
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.frame = NSRect(x: 78, y: height - 62, width: width - 102, height: 24)
        background.addSubview(titleLabel)

        let detailLabel = NSTextField(labelWithString: url.lastPathComponent)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.frame = NSRect(x: 78, y: height - 84, width: width - 102, height: 18)
        background.addSubview(detailLabel)

        let buttonY: CGFloat = 20
        var x: CGFloat = 24
        let gap: CGFloat = 8

        let gifButton = NSButton(title: "Export GIF", target: self, action: #selector(exportGIFTapped))
        gifButton.bezelStyle = .rounded
        gifButton.frame = NSRect(x: x, y: buttonY, width: 100, height: 32)
        background.addSubview(gifButton)
        x += 100 + gap

        let trimButton = NSButton(title: "Trim\u{2026}", target: self, action: #selector(trimTapped))
        trimButton.bezelStyle = .rounded
        trimButton.frame = NSRect(x: x, y: buttonY, width: 70, height: 32)
        background.addSubview(trimButton)

        let revealButton = NSButton(title: "Reveal", target: self, action: #selector(revealTapped))
        revealButton.bezelStyle = .rounded
        revealButton.frame = NSRect(x: width - 188, y: buttonY, width: 80, height: 32)
        background.addSubview(revealButton)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        // Primary action of this window: pin the default-button bezel to the brand
        // coral so the chrome stays on one accent (QRCodeResultWindow pattern).
        doneButton.bezelColor = KritColors.accent
        doneButton.frame = NSRect(x: width - 100, y: buttonY, width: 76, height: 32)
        background.addSubview(doneButton)
    }

    private func present() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
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

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func doneTapped() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: self)
    }
}
