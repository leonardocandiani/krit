import AppKit
import AVFoundation
import CoreMedia

/// The CleanShot-style "Trim & Convert" body (C3). A scrub timeline of frame
/// thumbnails with two coral trim handles on top, Dimensions / Width / Height on
/// the left, Quality / Audio on the right, an estimated size readout, and the
/// Cancel / Trim Only / Trim & Convert actions at the foot.
///
/// What is wired to the engine today: the TRIM range. `RecordingEngine.trim`
/// takes a `CMTimeRange` and exports that span, so dragging the handles changes
/// what gets written. Dimensions, Quality and the Audio mode are surfaced and
/// drive the live size estimate, and they are handed back in `ConvertOptions`,
/// but the engine's export path does not rescale or remux audio yet, so those
/// fields are wired-but-pending: the controls are real and report their values,
/// the convert step applies them only once the engine grows a scaling/audio
/// export. This is called out where the values leave the panel so nothing here
/// pretends to do more than it does.
@MainActor
final class VideoTrimPanel: NSView {

    /// What the panel asks the engine to do when an action button is pressed.
    enum Action {
        /// Export only the selected span, no re-encode of dimensions/audio.
        case trimOnly(range: CMTimeRange)
        /// Export the selected span and apply the convert options. The range is
        /// always honored; the rest of `options` is wired-but-pending on the
        /// engine (see the type doc).
        case trimAndConvert(range: CMTimeRange, options: ConvertOptions)
    }

    /// Convert parameters chosen in the panel. Carried back to the caller so the
    /// engine can apply them when its export path supports scaling/audio.
    struct ConvertOptions {
        var width: Int
        var height: Int
        /// 0...1, Low to High.
        var quality: Double
        var audio: AudioMode
    }

    enum AudioMode {
        case keep
        case mono
        case mute
    }

    private let assetURL: URL
    private let duration: Double
    private let nativeWidth: Int
    private let nativeHeight: Int
    private let onAction: (Action) -> Void
    private let onCancel: () -> Void

    // Trim state, in seconds, clamped to [0, duration].
    private var trimStart: Double = 0
    private var trimEnd: Double

    // Convert state.
    private var targetWidth: Int
    private var targetHeight: Int
    private var quality: Double = 0.7
    private var audioMode: AudioMode = .keep

    // Controls kept for live updates.
    private let timeline = TrimTimelineView()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let qualitySlider = NSSlider()
    private let dimensionsPopup = NSPopUpButton()
    private let estimateLabel = NSTextField(labelWithString: "")

    /// Scale options offered in the Dimensions popup. Original plus a few common
    /// downscales, matching the CleanShot menu.
    private let scaleChoices: [(label: String, factor: Double)] = [
        ("Original", 1.0),
        ("75%", 0.75),
        ("50%", 0.5),
        ("25%", 0.25),
    ]

    init(
        url: URL,
        duration: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        onAction: @escaping (Action) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.assetURL = url
        self.duration = max(duration, 0.01)
        self.nativeWidth = max(pixelWidth, 2)
        self.nativeHeight = max(pixelHeight, 2)
        self.trimEnd = max(duration, 0.01)
        self.targetWidth = max(pixelWidth, 2)
        self.targetHeight = max(pixelHeight, 2)
        self.onAction = onAction
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        build()
        loadThumbnails()
        refreshEstimate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func build() {
        wantsLayer = true

        buildTimeline()
        let body = buildBody()
        addSubview(body)
        buildFooter()
    }

    private func buildTimeline() {
        // The scrub strip spans the full width at the top, on its own dark trough,
        // with a play button on the left and the two trim handles riding the
        // thumbnail rail.
        let trough = NSView(frame: NSRect(x: 0, y: bounds.height - 92, width: bounds.width, height: 92))
        trough.wantsLayer = true
        trough.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        trough.autoresizingMask = [.width, .minYMargin]
        addSubview(trough)

        let play = TimelinePlayButton(frame: NSRect(x: 16, y: bounds.height - 64, width: 36, height: 36))
        play.target = self
        play.action = #selector(playTapped)
        play.autoresizingMask = [.minYMargin]
        addSubview(play)

        timeline.frame = NSRect(x: 64, y: bounds.height - 84, width: bounds.width - 80, height: 72)
        timeline.autoresizingMask = [.width, .minYMargin]
        timeline.onTrimChanged = { [weak self] startFraction, endFraction in
            guard let self else { return }
            self.trimStart = startFraction * self.duration
            self.trimEnd = endFraction * self.duration
            self.refreshEstimate()
        }
        addSubview(timeline)
    }

    private func buildBody() -> NSView {
        let body = NSView(frame: NSRect(x: 0, y: 56, width: bounds.width, height: bounds.height - 92 - 56))
        body.autoresizingMask = [.width, .height]

        // Left column: Dimensions popup + Width / Height fields.
        let leftX: CGFloat = 24
        let labelWidth: CGFloat = 84
        let fieldX = leftX + labelWidth + 8
        var rowY = body.bounds.height - 40

        addRowLabel("Dimensions:", to: body, x: leftX, y: rowY, width: labelWidth)
        for choice in scaleChoices {
            let title = choice.factor == 1.0
                ? "\(nativeWidth) x \(nativeHeight) (Original)"
                : "\(Int((Double(nativeWidth) * choice.factor).rounded())) x \(Int((Double(nativeHeight) * choice.factor).rounded())) (\(choice.label))"
            dimensionsPopup.addItem(withTitle: title)
        }
        dimensionsPopup.frame = NSRect(x: fieldX, y: rowY - 4, width: 196, height: 26)
        dimensionsPopup.target = self
        dimensionsPopup.action = #selector(dimensionsPopupChanged)
        body.addSubview(dimensionsPopup)

        rowY -= 40
        addRowLabel("Width:", to: body, x: leftX, y: rowY, width: labelWidth)
        configureNumberField(widthField, value: targetWidth, x: fieldX, y: rowY - 2, on: body, action: #selector(widthEdited))

        rowY -= 36
        addRowLabel("Height:", to: body, x: leftX, y: rowY, width: labelWidth)
        configureNumberField(heightField, value: targetHeight, x: fieldX, y: rowY - 2, on: body, action: #selector(heightEdited))

        // Right column: Quality slider + Audio radios.
        let rightX = body.bounds.width / 2 + 8
        let rightLabelWidth: CGFloat = 64
        var rightRowY = body.bounds.height - 40

        addRowLabel("Quality:", to: body, x: rightX, y: rightRowY, width: rightLabelWidth)
        let low = makeCaption("Low")
        low.frame = NSRect(x: rightX + rightLabelWidth + 6, y: rightRowY + 1, width: 30, height: 16)
        body.addSubview(low)
        qualitySlider.minValue = 0
        qualitySlider.maxValue = 1
        qualitySlider.doubleValue = quality
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.frame = NSRect(x: rightX + rightLabelWidth + 38, y: rightRowY - 2, width: body.bounds.width - (rightX + rightLabelWidth + 38) - 56, height: 22)
        qualitySlider.autoresizingMask = [.width]
        body.addSubview(qualitySlider)
        let high = makeCaption("High")
        high.frame = NSRect(x: body.bounds.width - 50, y: rightRowY + 1, width: 36, height: 16)
        high.autoresizingMask = [.minXMargin]
        body.addSubview(high)

        rightRowY -= 40
        addRowLabel("Audio:", to: body, x: rightX, y: rightRowY, width: rightLabelWidth)
        let audioOptions: [(String, AudioMode)] = [
            ("Don't change", .keep),
            ("Convert to mono", .mono),
            ("Mute", .mute),
        ]
        var radioY = rightRowY + 2
        for (index, option) in audioOptions.enumerated() {
            let radio = NSButton(radioButtonWithTitle: option.0, target: self, action: #selector(audioChanged(_:)))
            radio.tag = index
            radio.state = option.1 == audioMode ? .on : .off
            radio.frame = NSRect(x: rightX + rightLabelWidth + 6, y: radioY, width: 200, height: 20)
            body.addSubview(radio)
            radioY -= 24
        }

        return body
    }

    private func buildFooter() {
        estimateLabel.font = .systemFont(ofSize: 12)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.frame = NSRect(x: 100, y: 18, width: 220, height: 18)
        addSubview(estimateLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 16, y: 14, width: 78, height: 30)
        addSubview(cancel)

        let convert = NSButton(title: "Trim & Convert", target: self, action: #selector(trimAndConvertTapped))
        convert.bezelStyle = .rounded
        convert.keyEquivalent = "\r"
        // Primary action of the panel: pin the default bezel to the brand coral
        // (the CleanShot blue maps to KRIT's accent).
        convert.bezelColor = KritColors.accent
        convert.frame = NSRect(x: bounds.width - 16 - 130, y: 14, width: 130, height: 30)
        convert.autoresizingMask = [.minXMargin]
        addSubview(convert)

        let trimOnly = NSButton(title: "Trim Only", target: self, action: #selector(trimOnlyTapped))
        trimOnly.bezelStyle = .rounded
        trimOnly.frame = NSRect(x: bounds.width - 16 - 130 - 8 - 92, y: 14, width: 92, height: 30)
        trimOnly.autoresizingMask = [.minXMargin]
        addSubview(trimOnly)
    }

    private func addRowLabel(_ text: String, to view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.frame = NSRect(x: x, y: y, width: width, height: 18)
        view.addSubview(label)
    }

    private func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureNumberField(_ field: NSTextField, value: Int, x: CGFloat, y: CGFloat, on view: NSView, action: Selector) {
        field.stringValue = "\(value)"
        field.alignment = .left
        field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: x, y: y, width: 92, height: 24)
        field.target = self
        field.action = action
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 2
        field.formatter = formatter
        view.addSubview(field)
    }

    // MARK: - Thumbnails

    private func loadThumbnails() {
        let asset = AVURLAsset(url: assetURL)
        let count = 12
        let aspect = Double(nativeWidth) / Double(max(nativeHeight, 1))
        let stripHeight = 72.0
        let maxWidth = Int((stripHeight * aspect).rounded())
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: Int(stripHeight))
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        let times: [NSValue] = (0..<count).map { index in
            let fraction = (Double(index) + 0.5) / Double(count)
            return NSValue(time: CMTime(seconds: fraction * duration, preferredTimescale: 600))
        }

        // Generate off the main actor; the strip fills in once all frames arrive.
        nonisolated(unsafe) let gen = generator
        DispatchQueue.global(qos: .userInitiated).async {
            var collected = [Int: NSImage]()
            for (index, value) in times.enumerated() {
                if let cgImage = try? gen.copyCGImage(at: value.timeValue, actualTime: nil) {
                    collected[index] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
            let ordered = (0..<count).compactMap { collected[$0] }
            DispatchQueue.main.async { [weak self] in
                self?.timeline.setThumbnails(ordered)
            }
        }
    }

    // MARK: - Actions

    @objc private func playTapped() {
        // Preview play of the trimmed span lives in the editor's video card (r60);
        // here the button steps the scrub head, which the timeline owns.
        timeline.togglePlayhead()
    }

    @objc private func dimensionsPopupChanged() {
        let index = dimensionsPopup.indexOfSelectedItem
        guard scaleChoices.indices.contains(index) else { return }
        let factor = scaleChoices[index].factor
        targetWidth = max(2, Int((Double(nativeWidth) * factor).rounded()))
        targetHeight = max(2, Int((Double(nativeHeight) * factor).rounded()))
        widthField.stringValue = "\(targetWidth)"
        heightField.stringValue = "\(targetHeight)"
        refreshEstimate()
    }

    @objc private func widthEdited() {
        let value = max(2, widthField.integerValue)
        targetWidth = value
        // Keep the native aspect ratio: derive height from width.
        targetHeight = max(2, Int((Double(value) * Double(nativeHeight) / Double(nativeWidth)).rounded()))
        heightField.stringValue = "\(targetHeight)"
        syncDimensionsPopupToCustom()
        refreshEstimate()
    }

    @objc private func heightEdited() {
        let value = max(2, heightField.integerValue)
        targetHeight = value
        targetWidth = max(2, Int((Double(value) * Double(nativeWidth) / Double(nativeHeight)).rounded()))
        widthField.stringValue = "\(targetWidth)"
        syncDimensionsPopupToCustom()
        refreshEstimate()
    }

    private func syncDimensionsPopupToCustom() {
        // A manual width/height that matches no preset deselects the popup choices.
        let matchIndex = scaleChoices.firstIndex { choice in
            Int((Double(nativeWidth) * choice.factor).rounded()) == targetWidth
        }
        if let matchIndex {
            dimensionsPopup.selectItem(at: matchIndex)
        } else {
            dimensionsPopup.selectItem(at: -1)
        }
    }

    @objc private func qualityChanged() {
        quality = qualitySlider.doubleValue
        refreshEstimate()
    }

    @objc private func audioChanged(_ sender: NSButton) {
        switch sender.tag {
        case 1: audioMode = .mono
        case 2: audioMode = .mute
        default: audioMode = .keep
        }
        refreshEstimate()
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    @objc private func trimOnlyTapped() {
        guard let range = currentRange() else { return }
        onAction(.trimOnly(range: range))
    }

    @objc private func trimAndConvertTapped() {
        guard let range = currentRange() else { return }
        let options = ConvertOptions(
            width: targetWidth,
            height: targetHeight,
            quality: quality,
            audio: audioMode
        )
        onAction(.trimAndConvert(range: range, options: options))
    }

    private func currentRange() -> CMTimeRange? {
        let start = max(0, min(trimStart, duration))
        let end = max(start, min(trimEnd, duration))
        guard end - start > 0.05 else {
            ToastWindow.show(message: "Trim selection is too short.")
            return nil
        }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    // MARK: - Size estimate

    private func refreshEstimate() {
        let selected = max(0.05, trimEnd - trimStart)
        // Bitrate model mirrors RecordingEngine.bitrate: bits-per-pixel-per-frame
        // scaled by the quality slider, at a nominal 30 fps. Audio adds a flat
        // 192 kbps unless muted (96 kbps for mono). This is a display estimate,
        // not the encoder's exact rate.
        let bitsPerPixelPerFrame = 0.06 + quality * 0.20
        let fps = 30.0
        let pixels = Double(targetWidth * targetHeight)
        let videoBitsPerSecond = pixels * fps * bitsPerPixelPerFrame
        let audioBitsPerSecond: Double = switch audioMode {
        case .keep: 192_000
        case .mono: 96_000
        case .mute: 0
        }
        let totalBytes = (videoBitsPerSecond + audioBitsPerSecond) * selected / 8
        estimateLabel.stringValue = "Estimated file size: ~\(Self.formatBytes(totalBytes))"
    }

    private static func formatBytes(_ bytes: Double) -> String {
        let mb = bytes / (1024 * 1024)
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        let kb = bytes / 1024
        return String(format: "%.0f KB", max(kb, 1))
    }
}

// MARK: - Play button

@MainActor
private final class TimelinePlayButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        contentTintColor = .white
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?.withSymbolConfiguration(config)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Timeline / trim handles

/// The thumbnail rail with two coral handles bounding the kept span. Frames
/// outside the selection are dimmed; the kept window carries a coral border.
@MainActor
private final class TrimTimelineView: NSView {

    var onTrimChanged: ((_ startFraction: Double, _ endFraction: Double) -> Void)?

    private var thumbnails: [NSImage] = []
    private let railInset: CGFloat = 0
    private let handleWidth: CGFloat = 10
    private var startFraction: Double = 0
    private var endFraction: Double = 1
    private var playheadFraction: Double = 0
    private var showsPlayhead = false

    private enum DragTarget { case start, end, none }
    private var dragTarget: DragTarget = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setThumbnails(_ images: [NSImage]) {
        thumbnails = images
        needsDisplay = true
    }

    func togglePlayhead() {
        showsPlayhead.toggle()
        if showsPlayhead { playheadFraction = startFraction }
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rail = railRect()

        // 1. Thumbnail strip, tiled evenly across the rail.
        if thumbnails.isEmpty {
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4).fill()
        } else {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4).addClip()
            let cellWidth = rail.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let cell = NSRect(x: rail.minX + CGFloat(index) * cellWidth, y: rail.minY, width: ceil(cellWidth) + 1, height: rail.height)
                image.draw(in: cell, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let selRect = selectionRect()

        // 2. Dim the frames outside the kept window.
        NSColor(white: 0.06, alpha: 0.62).setFill()
        let leftDim = NSRect(x: rail.minX, y: rail.minY, width: selRect.minX - rail.minX, height: rail.height)
        let rightDim = NSRect(x: selRect.maxX, y: rail.minY, width: rail.maxX - selRect.maxX, height: rail.height)
        leftDim.fill()
        rightDim.fill()

        // 3. Coral border around the kept window.
        KritColors.accent.setStroke()
        let border = NSBezierPath(rect: selRect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        // 4. The two handles.
        drawHandle(at: selRect.minX)
        drawHandle(at: selRect.maxX - handleWidth)

        // 5. Optional playhead line while previewing.
        if showsPlayhead {
            let x = rail.minX + CGFloat(playheadFraction) * rail.width
            NSColor.white.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: rail.minY))
            line.line(to: NSPoint(x: x, y: rail.maxY))
            line.lineWidth = 2
            line.stroke()
        }
    }

    private func drawHandle(at x: CGFloat) {
        let rail = railRect()
        let handle = NSRect(x: x, y: rail.minY - 2, width: handleWidth, height: rail.height + 4)
        KritColors.accent.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
        // A pair of grip notches so the handle reads as draggable.
        NSColor(white: 1, alpha: 0.8).setStroke()
        let notch = NSBezierPath()
        let cx = handle.midX
        for dy in [-3.0, 3.0] {
            notch.move(to: NSPoint(x: cx, y: handle.midY + dy - 3))
            notch.line(to: NSPoint(x: cx, y: handle.midY + dy + 3))
        }
        notch.lineWidth = 1
        notch.stroke()
    }

    private func railRect() -> NSRect {
        bounds.insetBy(dx: railInset, dy: 6)
    }

    private func selectionRect() -> NSRect {
        let rail = railRect()
        let minX = rail.minX + CGFloat(startFraction) * rail.width
        let maxX = rail.minX + CGFloat(endFraction) * rail.width
        return NSRect(x: minX, y: rail.minY, width: max(maxX - minX, handleWidth * 2), height: rail.height)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let sel = selectionRect()
        let startHandle = NSRect(x: sel.minX - 6, y: bounds.minY, width: handleWidth + 12, height: bounds.height)
        let endHandle = NSRect(x: sel.maxX - handleWidth - 6, y: bounds.minY, width: handleWidth + 12, height: bounds.height)
        if startHandle.contains(point) {
            dragTarget = .start
        } else if endHandle.contains(point) {
            dragTarget = .end
        } else {
            dragTarget = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragTarget != .none else { return }
        let rail = railRect()
        let point = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, (point.x - rail.minX) / rail.width))
        let minSpan = 0.02
        switch dragTarget {
        case .start:
            startFraction = min(fraction, endFraction - minSpan)
        case .end:
            endFraction = max(fraction, startFraction + minSpan)
        case .none:
            break
        }
        needsDisplay = true
        onTrimChanged?(startFraction, endFraction)
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = .none
    }
}

// MARK: - Hosting window

/// Glass sheet-style window that hosts the `VideoTrimPanel` (C3). Reads the
/// asset's native pixel size to seed the Dimensions fields, then routes the
/// panel's actions back to the engine. Trim Only and Trim & Convert both export
/// the selected span via `RecordingResultActions.trim`; the convert options ride
/// along for when the engine's export path can apply scaling/audio.
@MainActor
final class VideoTrimWindow: NSWindow, NSWindowDelegate {

    private static var current: VideoTrimWindow?
    private weak var actions: RecordingResultActions?
    private let url: URL
    private let durationSeconds: Double
    private let stage: NSView

    static func show(url: URL, duration: Double, actions: RecordingResultActions) {
        current?.close()
        let window = VideoTrimWindow(url: url, duration: duration, actions: actions)
        current = window
        window.present()
    }

    private init(url: URL, duration: Double, actions: RecordingResultActions) {
        self.url = url
        self.durationSeconds = duration
        self.actions = actions

        let width: CGFloat = 600
        let height: CGFloat = 320
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.stage = root
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

        root.wantsLayer = true
        contentView = root

        let glass = ChromeFactory.backing(
            frame: root.bounds,
            cornerRadius: ChromeFactory.Radius.panel
        )
        root.addSubview(glass)

        // The native pixel size seeds the Dimensions fields. Loaded async (the
        // modern AVAsset path the GIF encoder also uses) so the deprecated
        // synchronous track read is avoided; the panel mounts as soon as it
        // resolves, which is immediate for a local file.
        Task { [weak self] in
            let size = await Self.pixelSize(of: url)
            guard let self else { return }
            self.mountPanel(pixelWidth: size.0, pixelHeight: size.1)
        }
    }

    private func mountPanel(pixelWidth: Int, pixelHeight: Int) {
        let panel = VideoTrimPanel(
            url: url,
            duration: durationSeconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            onAction: { [weak self] action in self?.handle(action) },
            onCancel: { [weak self] in self?.close() }
        )
        panel.frame = stage.bounds
        panel.autoresizingMask = [.width, .height]
        stage.addSubview(panel)
    }

    private func present() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func handle(_ action: VideoTrimPanel.Action) {
        switch action {
        case .trimOnly(let range):
            actions?.trim(url: url, range: range)
        case .trimAndConvert(let range, _):
            // Only the range reaches the engine today; the convert options are
            // wired-but-pending (see VideoTrimPanel's type doc). The trim still
            // runs so the action is never a no-op.
            actions?.trim(url: url, range: range)
        }
        close()
    }

    /// Native pixel dimensions of the recording, read from its video track. Falls
    /// back to a sane 1920x1080 if the track can't be read so the fields are never
    /// empty.
    private static func pixelSize(of url: URL) async -> (Int, Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (1920, 1080)
        }
        let size = naturalSize.applying(transform)
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())
        guard width >= 2, height >= 2 else { return (1920, 1080) }
        return (width, height)
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: self)
    }
}
