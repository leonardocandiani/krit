import AppKit
import AVFoundation
import AudioToolbox
import CoreVideo
import CoreMedia
import ScreenCaptureKit

/// Actions the result window (and the video overlay card) invoke back on the
/// engine: GIF export, trim, and re-opening the editor window from the card.
@MainActor
protocol RecordingResultActions: AnyObject {
    func exportGIF(from url: URL)
    /// Exports `range` of `url`. When `convert` is nil it is a plain range trim
    /// (no rescale or audio remux). When `convert` is set, the output is rescaled
    /// to the chosen dimensions, re-encoded at the chosen quality, and its audio
    /// follows the chosen mode (keep / mono downmix / mute).
    func trim(url: URL, range: CMTimeRange, convert: VideoTrimPanel.ConvertOptions?)
    /// Bakes screen-studio-style auto-zoom into a copy of the clip, following the
    /// recorded cursor path. No-ops with a toast when the clip has no cursor data.
    func exportAutoZoom(from url: URL)
    /// Re-presents the RecordingResultWindow (GIF / trim editor) for a finished
    /// recording. The overlay card's "Edit recording" routes here so the result
    /// window's exclusive features stay reachable after it stops being the default.
    func openVideoEditor(url: URL, duration: Double)
}

/// The single ownership record for one recording take. The engine can await
/// permissions and ScreenCaptureKit startup without making a second request look
/// idle, and late callbacks can prove they still belong to the active take.
struct RecordingTakeLifecycle {
    private enum State: Equatable {
        case idle
        case starting(UUID)
        case recording(UUID)
        case finishing(UUID)
    }

    private var state: State = .idle

    var isActive: Bool { state != .idle }

    var activeID: UUID? {
        switch state {
        case .idle: nil
        case .starting(let id), .recording(let id), .finishing(let id): id
        }
    }

    mutating func begin() -> UUID? {
        guard case .idle = state else { return nil }
        let id = UUID()
        state = .starting(id)
        return id
    }

    func isStarting(_ id: UUID) -> Bool {
        if case .starting(id) = state { return true }
        return false
    }

    func isRecording(_ id: UUID) -> Bool {
        if case .recording(id) = state { return true }
        return false
    }

    func isFinishing(_ id: UUID) -> Bool {
        if case .finishing(id) = state { return true }
        return false
    }

    mutating func promoteToRecording(_ id: UUID) -> Bool {
        guard isStarting(id) else { return false }
        state = .recording(id)
        return true
    }

    mutating func beginFinishing(_ id: UUID) -> Bool {
        guard isStarting(id) || isRecording(id) else { return false }
        state = .finishing(id)
        return true
    }

    mutating func complete(_ id: UUID) -> Bool {
        guard isFinishing(id) else { return false }
        state = .idle
        return true
    }
}

private struct PreparedRecording {
    let stream: SCStream
    let output: RecordingStreamOutput
    let timeline: RecordingTimelineWriter
    let url: URL
    let regionRect: CGRect
}

@MainActor
final class RecordingEngine: NSObject, RecordingResultActions {

    /// VideoToolbox's hardware H.264 path on Apple silicon is reliable through
    /// 4096 pixels per edge. Larger capture buffers can select the software
    /// encoder, multiplying memory pressure and startup latency on Retina screens.
    nonisolated static let maxCaptureEdge = 4_096

    private let writerQueue = DispatchQueue(label: "com.krit.recording.writer", qos: .userInitiated)
    // start/stopRunning() block for hundreds of ms (hardware warm-up/teardown);
    // run them off the main actor so the HUD never stalls at start/stop.
    private let sessionQueue = DispatchQueue(label: "com.krit.recording.session", qos: .userInitiated)

    // AVCaptureSession.start/stopRunning are thread-safe but the type is not
    // Sendable; route both through here so the off-main hop lives in one place.
    private func runSessionOffMain(_ session: AVCaptureSession, start: Bool) {
        nonisolated(unsafe) let s = session
        sessionQueue.async { start ? s.startRunning() : s.stopRunning() }
    }
    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var timeline: RecordingTimelineWriter?
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var microphoneDelegate: MicrophoneCaptureDelegate?
    private var cameraBubble: CameraBubbleWindow?
    private var clickKeyOverlay: KeystrokeClickOverlay?
    /// Dims everything outside the recorded area during area recording. Only set
    /// for the displayRect source; window/fullscreen recording has no dim.
    private var dimOverlay: RecordingDimOverlay?
    private var outputURL: URL?
    /// Last finished recording, so the result window (GIF export / trim / reveal)
    /// stays reachable after the user dismisses it.
    private var lastFinishedRecording: (url: URL, duration: Double)?
    var hasLastRecording: Bool {
        guard let last = lastFinishedRecording else { return false }
        return FileManager.default.fileExists(atPath: last.url.path)
    }
    private var recordingScreen: NSScreen?
    /// Source of the active take, kept so a restart can re-arm the same capture.
    private var lastSource: RecordingSource?
    /// True while a discard/restart tears the take down, so finishRecording throws
    /// the file away instead of presenting a card.
    private var isDiscarding = false
    /// True when the discard should be followed by a fresh take of the same source.
    private var restartAfterDiscard = false
    private var takeLifecycle = RecordingTakeLifecycle()
    private var isPaused = false
    private var finishSessionID = UUID()
    private var hud: RecordingHUDWindow?

    // Cursor-path capture (feeds auto-zoom). A timer samples the mouse against the
    // capture region; the clock advances only while not paused so sample times line
    // up with the gated video timeline. Written as a metadata sidecar on finish.
    private var mouseSamples: [RecordedMouseSample] = []
    private var mouseSampleTimer: Timer?
    private var mouseSampleClock: TimeInterval = 0
    private var captureRegionRect: CGRect = .zero
    private var captureRegionSize: CGSize = .zero
    private let mouseSamplesPerSecond = 30

    var active: Bool { takeLifecycle.isActive }

    /// GUI test hook: how many dim panels are live (0 when no dim is showing).
    var uiTestDimPanelCount: Int { dimOverlay?.panelCount ?? 0 }

    /// GUI test hook: outcome of the last finish ("none", "saved:<path>" or
    /// "failed:<reason>"), so the harness sees WHICH branch ran instead of
    /// inferring from a missing card.
    var uiTestLastFinishOutcome = "none"
    var uiTestLastRecordingDuration: Double? { lastFinishedRecording?.duration }
    var uiTestIsPaused: Bool { isPaused }

    func startRecording(rect: CGRect, on screen: NSScreen) async {
        await startRecording(source: .displayRect(rect: rect, screen: screen))
    }

    func startRecording(window: SCWindow, on screen: NSScreen) async {
        await startRecording(source: .window(window, screen: screen))
    }

    private func startRecording(source: RecordingSource) async {
        guard let takeID = takeLifecycle.begin() else {
            ToastWindow.show(message: "Recording already in progress")
            return
        }
        lastSource = source

        uiTestLastFinishOutcome = "none"
        uiTestLastStreamError = ""

        var configuration = RecordingConfiguration.current
        if configuration.recordsMicrophone {
            let canUseMicrophone = await requestMicrophonePermissionIfNeeded()
            guard takeLifecycle.isStarting(takeID) else { return }
            if !canUseMicrophone {
                configuration.recordsMicrophone = false
                ToastWindow.show(message: "Mic unavailable. Recording without it.")
            }
        }
        if configuration.recordsWebcam {
            let canUseWebcam = await requestWebcamPermissionIfNeeded()
            guard takeLifecycle.isStarting(takeID) else { return }
            if !canUseWebcam {
                configuration.recordsWebcam = false
                ToastWindow.show(message: "Camera unavailable. Recording without it.")
            }
        }

        var preparedForCancellation: PreparedRecording?
        do {
            guard takeLifecycle.isStarting(takeID) else { return }
            let hud = RecordingHUDWindow()
            hud.configure(
                systemAudio: configuration.recordsSystemAudio,
                microphone: configuration.recordsMicrophone,
                fps: configuration.fps,
                quality: configuration.quality.displayName
            )
            hud.stopHandler = { [weak self] in self?.stopRecording() }
            hud.togglePauseHandler = { [weak self] _ in self?.togglePause() }
            hud.restartHandler = { [weak self] in self?.restartRecording() }
            hud.discardHandler = { [weak self] in self?.discardRecording() }
            self.hud = hud
            self.recordingScreen = source.screen
            hud.show(on: source.screen)

            // Dim the area outside an area-recording rect (CleanShot-style). Built
            // before the stream filter so its panels can be excluded too. The
            // panels tile the screen minus the rect, so a fullscreen rect produces
            // zero-size panels (no dim), which is the desired behavior.
            var dimWindowNumbers: [CGWindowID] = []
            if case .displayRect(let dimRect, let dimScreen) = source {
                let overlay = RecordingDimOverlay()
                overlay.show(around: dimRect, on: dimScreen)
                dimOverlay = overlay
                dimWindowNumbers = overlay.windowNumbers
            }

            var excludedWindowNumbers = source.usesDisplayFilter ? [CGWindowID(hud.windowNumber)].filter { $0 > 0 } : []
            excludedWindowNumbers.append(contentsOf: dimWindowNumbers)
            let prepared = try await prepareStream(
                source: source,
                configuration: configuration,
                excludingWindowNumbers: excludedWindowNumbers,
                takeID: takeID
            )
            preparedForCancellation = prepared
            guard takeLifecycle.isStarting(takeID) else {
                await discardPreparedRecording(prepared)
                cleanup(takeID: takeID)
                return
            }
            stream = prepared.stream
            streamOutput = prepared.output
            timeline = prepared.timeline
            outputURL = prepared.url
            isPaused = false

            if configuration.recordsMicrophone {
                try startMicrophoneCapture(
                    deviceID: configuration.microphoneDeviceID,
                    timeline: prepared.timeline,
                    takeID: takeID
                )
            }
            guard takeLifecycle.isStarting(takeID) else {
                await discardPreparedRecording(prepared)
                cleanup(takeID: takeID)
                return
            }
            try await prepared.stream.startCapture()
            guard takeLifecycle.promoteToRecording(takeID) else {
                await discardPreparedRecording(prepared)
                cleanup(takeID: takeID)
                return
            }

            captureRegionRect = prepared.regionRect
            captureRegionSize = prepared.regionRect.size
            startMouseSampling(takeID: takeID)

            // The click/keystroke overlay lives INSIDE the captured region so the
            // stream picks it up directly, it is deliberately NOT excluded.
            if configuration.recordsClicks || configuration.recordsKeystrokes {
                let overlay = KeystrokeClickOverlay(
                    regionRect: prepared.regionRect,
                    screen: source.screen,
                    showsClicks: configuration.recordsClicks,
                    showsKeystrokes: configuration.recordsKeystrokes
                )
                overlay.start()
                clickKeyOverlay = overlay
            }

            // The webcam shows as a floating circular bubble on screen, left IN
            // the capture so it is recorded in place (no per-frame composite).
            if configuration.recordsWebcam,
               let bubble = CameraBubbleWindow(deviceID: configuration.webcamDeviceID, screen: source.screen) {
                bubble.start()
                cameraBubble = bubble
            }

            SoundManager.play(.recordStart)
            ToastWindow.show(message: "Recording started")
            preparedForCancellation = nil
        } catch {
            if let preparedForCancellation {
                await discardPreparedRecording(preparedForCancellation)
            }
            let wasCancelled = takeLifecycle.isFinishing(takeID)
            if takeLifecycle.isStarting(takeID) {
                _ = takeLifecycle.beginFinishing(takeID)
            }
            cleanup(takeID: takeID)
            guard !wasCancelled else { return }
            ToastWindow.show(message: "Could not start recording. Check permissions.")
            print("[KRIT] Recording start failed: \(error)")
        }
    }

    /// Stop the in-progress take and throw the file away, no card. Wired to the
    /// HUD trash button, so it performs a real action instead of sitting disabled.
    func discardRecording() {
        guard let takeID = takeLifecycle.activeID, takeLifecycle.isRecording(takeID) else { return }
        isDiscarding = true
        stopRecording()
    }

    /// Discard the current take and immediately start a fresh one of the same
    /// source. Wired to the HUD restart button.
    func restartRecording() {
        guard let takeID = takeLifecycle.activeID,
              takeLifecycle.isRecording(takeID),
              lastSource != nil else { return }
        restartAfterDiscard = true
        discardRecording()
    }

    /// If a discard/restart is in flight, drop the finished file, optionally
    /// re-arm the same source, and return true so finishRecording skips the
    /// normal card-presentation path.
    private func consumeDiscardIfNeeded(url: URL) -> Bool {
        guard isDiscarding else { return false }
        isDiscarding = false
        let shouldRestart = restartAfterDiscard
        restartAfterDiscard = false
        try? FileManager.default.removeItem(at: url)
        ToastWindow.show(message: shouldRestart ? "Restarting\u{2026}" : "Recording discarded", duration: 2.0)
        if shouldRestart, let src = lastSource {
            Task { await startRecording(source: src) }
        }
        return true
    }

    /// Re-presents the result window for the last finished recording so GIF export,
    /// trim and reveal stay reachable after the window was dismissed.
    func reopenResultPanel() {
        guard let last = lastFinishedRecording,
              FileManager.default.fileExists(atPath: last.url.path) else { return }
        RecordingResultWindow.show(
            url: last.url,
            duration: last.duration,
            actions: self,
            on: recordingScreen
        )
    }

    /// Default post-recording destination. With the overlay on (the user's normal
    /// setting), the finished clip shows up as a video card in the quick-access tray,
    /// exactly like a screenshot; the GIF/trim editor stays reachable from the card's
    /// "Edit recording" menu. With the overlay off, fall back to the result window so
    /// the recording is never left without a destination.
    private func presentResult(url: URL, duration: Double) {
        guard Settings.afterCaptureShowOverlay else {
            RecordingResultWindow.show(
                url: url,
                duration: duration,
                actions: self,
                on: recordingScreen
            )
            return
        }
        let screen = recordingScreen
        Task { [weak self] in
            let thumbnail = await Self.firstFrameThumbnail(for: url)
            guard let self else { return }
            QuickAccessOverlay.showVideo(
                url: url,
                duration: duration,
                thumbnail: thumbnail,
                isTemporary: false,
                actions: self,
                screen: screen
            )
        }
    }

    func openVideoEditor(url: URL, duration: Double) {
        // "Edit recording" opens the Snapzy-style video editor (player + timeline +
        // zoom lane + trim), the real editing surface. The exported clip comes back
        // as a fresh card.
        VideoEditorWindowController.show(url: url) { [weak self] outURL, outDuration in
            guard let self else { return }
            self.lastFinishedRecording = (outURL, outDuration)
            self.presentResult(url: outURL, duration: outDuration)
        }
    }

    /// First-frame poster for the overlay card. AVAssetImageGenerator on a fresh
    /// asset, off the main actor; falls back to a generic film icon if the grab
    /// fails (corrupt clip, codec hiccup) so the card always has something to show.
    private static func firstFrameThumbnail(for url: URL) async -> NSImage {
        await RecordingThumbnailProvider.thumbnail(for: url)
    }

    func stopRecording() {
        guard let takeID = takeLifecycle.activeID else { return }
        if takeLifecycle.isStarting(takeID) {
            cancelStartingTake(takeID)
            return
        }
        guard takeLifecycle.isRecording(takeID), takeLifecycle.beginFinishing(takeID) else { return }
        SoundManager.play(.recordStop)
        closeRecordingChrome()

        let streamToStop = stream
        let outputToRemove = streamOutput
        Task {
            var stopError: Error?
            do {
                try await streamToStop?.stopCapture()
            } catch {
                print("[KRIT] Recording stop failed: \(error)")
                stopError = error
            }
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            guard self.takeLifecycle.isFinishing(takeID) else { return }
            self.finishRecording(error: stopError, takeID: takeID)
        }
    }

    func togglePause() {
        guard let takeID = takeLifecycle.activeID, takeLifecycle.isRecording(takeID) else { return }
        guard let paused = timeline?.togglePause() else { return }
        isPaused = paused
        if paused { SoundManager.play(.recordPause) }
        clickKeyOverlay?.setPaused(isPaused)
        hud?.setPaused(isPaused)
    }

    // MARK: - Cursor sampling (auto-zoom source)

    private func startMouseSampling(takeID: UUID) {
        mouseSamples.removeAll()
        mouseSampleClock = 0
        mouseSampleTimer?.invalidate()
        let interval = 1.0 / Double(mouseSamplesPerSecond)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.sampleMouseTick(interval: interval, takeID: takeID) }
        }
        // .common so the timer keeps firing while the cursor is tracking/dragging.
        RunLoop.main.add(timer, forMode: .common)
        mouseSampleTimer = timer
    }

    private func sampleMouseTick(interval: TimeInterval, takeID: UUID) {
        guard takeLifecycle.isRecording(takeID), !isPaused else { return }
        guard captureRegionRect.width > 0, captureRegionRect.height > 0 else { return }
        // NSEvent.mouseLocation is global screen space, bottom-left origin, same as
        // the capture region rect. Normalize, then flip Y to a top-left origin so a
        // sample maps straight onto a video frame.
        let p = NSEvent.mouseLocation
        let rawX = (p.x - captureRegionRect.minX) / captureRegionRect.width
        let rawYBottom = (p.y - captureRegionRect.minY) / captureRegionRect.height
        let inside = rawX >= 0 && rawX <= 1 && rawYBottom >= 0 && rawYBottom <= 1
        let nx = min(max(rawX, 0), 1)
        let nyTop = min(max(1 - rawYBottom, 0), 1)
        mouseSamples.append(RecordedMouseSample(time: mouseSampleClock, normalizedX: nx, normalizedY: nyTop, isInsideCapture: inside))
        mouseSampleClock += interval
    }

    private func stopMouseSampling() {
        mouseSampleTimer?.invalidate()
        mouseSampleTimer = nil
    }

    fileprivate nonisolated func streamDidStopWithError(_ error: Error, takeID: UUID) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.takeLifecycle.isRecording(takeID),
                  self.takeLifecycle.beginFinishing(takeID) else { return }
            let nsError = error as NSError
            self.uiTestLastStreamError = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
            self.closeRecordingChrome()
            self.finishRecording(error: error, takeID: takeID)
        }
    }

    /// GUI test hook: raw domain/code of the last SCStream stop error, so a
    /// "lost the screen stream" failure is diagnosable without console access.
    var uiTestLastStreamError = ""

    private func prepareStream(
        source: RecordingSource,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID],
        takeID: UUID
    ) async throws -> PreparedRecording {
        let preparedSource = try await prepareCaptureSource(source, configuration: configuration, excludingWindowNumbers: excludingWindowNumbers)

        let url = Self.makeOutputURL()
        var prepared = false
        defer {
            if !prepared {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(
                width: preparedSource.pixelWidth,
                height: preparedSource.pixelHeight,
                fps: configuration.fps,
                quality: configuration.quality
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.cannotAddWriterInput }
        writer.add(videoInput)

        var microphoneInput: AVAssetWriterInput?
        if configuration.recordsMicrophone {
            // Always 2 channels: the capture side forces 48k stereo delivery
            // via AVCaptureAudioDataOutput.audioSettings (devices lie about
            // their format; a channel mismatch faults the AAC encoder with
            // -12737, which surfaced as "Recording not saved" with mic on).
            let input = Self.audioInput(channels: 2, bitrate: 192_000)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            microphoneInput = input
        }

        var systemAudioInput: AVAssetWriterInput?
        if configuration.recordsSystemAudio {
            let input = Self.audioInput(channels: 2, bitrate: 192_000)
            guard writer.canAdd(input) else { throw RecordingError.cannotAddWriterInput }
            writer.add(input)
            systemAudioInput = input
        }

        let timeline = RecordingTimelineWriter(
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            microphoneInput: microphoneInput,
            queue: writerQueue,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
        )
        let output = RecordingStreamOutput(
            recordingEngine: self,
            timeline: timeline,
            takeID: takeID
        )
        let stream = SCStream(filter: preparedSource.filter, configuration: preparedSource.streamConfig, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writerQueue)
        if configuration.recordsSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writerQueue)
        }

        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStartWriter }
        prepared = true
        return PreparedRecording(
            stream: stream,
            output: output,
            timeline: timeline,
            url: url,
            regionRect: preparedSource.regionRect
        )
    }

    private func prepareCaptureSource(
        _ source: RecordingSource,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        switch source {
        case .displayRect(let rect, let screen):
            return try await prepareDisplaySource(
                rect: rect,
                on: screen,
                configuration: configuration,
                excludingWindowNumbers: excludingWindowNumbers
            )
        case .window(let window, let screen):
            return try await prepareWindowDisplaySource(
                window: window,
                on: screen,
                configuration: configuration
            )
        }
    }

    private func prepareWindowDisplaySource(
        window: SCWindow,
        on screen: NSScreen,
        configuration: RecordingConfiguration
    ) async throws -> PreparedCaptureSource {
        let snapshot = try await ScreenCaptureCatalog.shared.windows(.allContent)
        let selectedWindow = snapshot.window(id: CGWindowID(window.windowID)) ?? window
        let appKitRect = Self.appKitRect(fromScreenCaptureKitWindowFrame: selectedWindow.frame, on: screen)
        let screenID = ScreenCaptureCatalog.displayID(of: screen)
        guard let display = screenID.flatMap(snapshot.display(id:))
            ?? snapshot.displays.max(by: {
                Self.overlapArea($0.frame, selectedWindow.frame)
                    < Self.overlapArea($1.frame, selectedWindow.frame)
            }) else {
            throw RecordingError.noDisplay
        }

        let filter = SCContentFilter(display: display, including: [selectedWindow])
        return try prepareDisplaySource(
            rect: appKitRect,
            on: screen,
            configuration: configuration,
            filter: filter,
            display: display
        )
    }

    private static func appKitRect(fromScreenCaptureKitWindowFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        let screenID = ScreenCaptureCatalog.displayID(of: screen) ?? CGMainDisplayID()
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: screenID,
            appKitFrame: screen.frame,
            coreGraphicsFrame: CGDisplayBounds(screenID),
            backingScale: max(screen.backingScaleFactor, 1)
        )
        return geometry.appKitRect(fromCoreGraphics: frame)
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        let snapshot = try await ScreenCaptureCatalog.shared.windows(.allContent)
        // Match by display ID only. AppKit rects and SCDisplay frames have
        // opposite Y axes, so intersecting them is not a valid fallback.
        guard let screenID = ScreenCaptureCatalog.displayID(of: screen),
              let display = snapshot.display(id: screenID) else {
            throw RecordingError.noDisplay
        }
        let excludedWindows = excludingWindowNumbers.compactMap { windowNumber in
            snapshot.window(id: windowNumber)
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        return try prepareDisplaySource(
            rect: rect,
            on: screen,
            configuration: configuration,
            filter: filter,
            display: display
        )
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        filter: SCContentFilter,
        display: SCDisplay
    ) throws -> PreparedCaptureSource {
        // Match still capture's proven scale rule. `pointPixelScale` can report
        // 2 on a genuine 1x display, which previously doubled the recording
        // buffer and left the stream content occupying only part of it.
        let geometry = ScreenCaptureDisplayGeometry(
            displayID: display.displayID,
            appKitFrame: screen.frame,
            coreGraphicsFrame: display.frame,
            backingScale: max(screen.backingScaleFactor, 1)
        )
        let region = try geometry.sourceRegion(
            for: rect,
            evenPixelDimensions: true,
            maxEdge: Self.maxCaptureEdge
        )

        let streamConfig = Self.streamConfiguration(
            width: region.pixelWidth,
            height: region.pixelHeight,
            configuration: configuration
        )
        streamConfig.sourceRect = region.sourceRect

        return PreparedCaptureSource(
            filter: filter,
            streamConfig: streamConfig,
            pixelWidth: region.pixelWidth,
            pixelHeight: region.pixelHeight,
            regionRect: rect
        )
    }

    private static func streamConfiguration(width: Int, height: Int, configuration: RecordingConfiguration) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.queueDepth = 8
        streamConfig.showsCursor = configuration.showsCursor
        streamConfig.scalesToFit = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            streamConfig.captureResolution = .best
        }
        if configuration.recordsSystemAudio {
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }
        return streamConfig
    }

    private func finishRecording(error streamError: Error?, takeID: UUID) {
        guard takeLifecycle.isFinishing(takeID) else { return }
        stopMicrophoneCapture()
        stopMouseSampling()
        cameraBubble?.stop()
        cameraBubble = nil
        clickKeyOverlay?.stop()
        clickKeyOverlay = nil
        let sessionID = UUID()
        finishSessionID = sessionID

        guard let timeline, let url = outputURL else {
            cleanup(takeID: takeID)
            showSaveFailure(reason: streamError.map(Self.saveFailureReason) ?? "the recording ended before it could start")
            return
        }
        // Snapshot the cursor path before cleanup clears it, so the success branch
        // can persist the auto-zoom sidecar alongside the completed clip.
        let capturedSamples = mouseSamples
        let capturedRegionSize = captureRegionSize
        let capturedSamplesPerSecond = mouseSamplesPerSecond

        timeline.finish { [weak self] result in
            guard let self,
                  self.finishSessionID == sessionID,
                  self.takeLifecycle.isFinishing(takeID) else { return }
            let timelineDiagnostics = timeline.diagnosticsSummary()
            self.cleanup(takeID: takeID)
            // Discard/restart: drop the file and skip the card entirely.
            if self.consumeDiscardIfNeeded(url: url) { return }
            if let streamError {
                self.showSaveFailure(reason: Self.saveFailureReason(streamError))
                print("[KRIT] Recording stream error: \(streamError)")
                return
            }

            switch result {
            case .completed(let duration):
                ToastWindow.show(message: Self.savedRecordingMessage(for: url), duration: 3.0)
                self.uiTestLastFinishOutcome = "saved:\(url.path)"
                self.lastFinishedRecording = (url, duration)
                if !capturedSamples.isEmpty {
                    RecordingMetadataStore.save(
                        RecordingMetadata(
                            captureSize: capturedRegionSize,
                            samplesPerSecond: capturedSamplesPerSecond,
                            mouseSamples: capturedSamples
                        ),
                        for: url
                    )
                }
                self.presentResult(url: url, duration: duration)

            case .noVideo:
                self.showSaveFailure(reason: "no frames were captured")

            case .timedOut:
                self.showSaveFailure(reason: "the recorder timed out while writing the file")
                print("[KRIT] Recording finish timed out for \(url.path)")

            case .failed(let writerError):
                if self.uiTestLastStreamError.isEmpty {
                    self.uiTestLastStreamError = timelineDiagnostics.isEmpty
                        ? Self.writerDiagnostic(writerError)
                        : timelineDiagnostics
                }
                self.showSaveFailure(reason: Self.saveFailureReason(writerError))
                print("[KRIT] Recording finish failed: \(writerError)")
            }
        }
    }

    /// Single failure toast so a save error is never silent: always names a real,
    /// jargon-free reason in one line. Copy stays under the toast's width.
    private func showSaveFailure(reason: String) {
        uiTestLastFinishOutcome = "failed:\(reason)"
        ToastWindow.show(message: "Recording not saved: \(reason).", duration: 4.0)
    }

    /// Condenses a framework error into a short human reason for the toast. Falls
    /// back to the localized description (already a sentence) when nothing more
    /// specific is recognized.
    private static func saveFailureReason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain || nsError.code == NSFileWriteOutOfSpaceError {
            return "the disk is full or the folder is not writable"
        }
        if nsError.domain == "com.apple.coremedia" || nsError.domain == AVFoundationErrorDomain {
            return "the recorder lost the screen stream"
        }
        let description = nsError.localizedDescription
        return description.isEmpty ? "an unexpected error occurred" : description
    }

    private static func writerDiagnostic(_ error: Error) -> String {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
            .map { " under:\($0.domain)#\($0.code)" } ?? ""
        return "writer:\(nsError.domain)#\(nsError.code)\(underlying): \(nsError.localizedDescription)"
    }

    private func closeRecordingChrome() {
        dimOverlay?.hide()
        dimOverlay = nil
        hud?.closeHUD()
        hud = nil
    }

    /// Stop pressed while permissions, source lookup or SCStream startup is still
    /// pending. The take remains finishing until the owner tears down its own local
    /// resources, so a second start cannot race the late continuation.
    private func cancelStartingTake(_ takeID: UUID) {
        guard takeLifecycle.beginFinishing(takeID) else { return }
        closeRecordingChrome()
        let streamToStop = stream
        let outputToRemove = streamOutput
        Task { [weak self] in
            guard let self else { return }
            try? await streamToStop?.stopCapture()
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            guard self.takeLifecycle.isFinishing(takeID) else { return }
            self.cleanup(takeID: takeID)
        }
    }

    /// Releases a stream prepared by a startup continuation that lost ownership
    /// before it was allowed to install or promote the take.
    private func discardPreparedRecording(_ prepared: PreparedRecording) async {
        try? await prepared.stream.stopCapture()
        try? prepared.stream.removeStreamOutput(prepared.output, type: .screen)
        try? prepared.stream.removeStreamOutput(prepared.output, type: .audio)
        prepared.timeline.cancel()
        try? FileManager.default.removeItem(at: prepared.url)
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startMicrophoneCapture(
        deviceID: String,
        timeline: RecordingTimelineWriter,
        takeID: UUID
    ) throws {
        guard let device = Self.microphoneDevice(for: deviceID) else { throw RecordingError.noMicrophone }
        let session = AVCaptureSession()
        session.beginConfiguration()

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw RecordingError.cannotAddMicrophoneInput }
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        // Force a canonical delivery format (macOS honors audioSettings here).
        // Devices lie: a USB mic can report mono in activeFormat and deliver
        // stereo buffers, and any mismatch with the writer input's channel
        // count faults the AAC encoder (-12737, "Recording not saved"). Fixing
        // capture at 48k stereo float makes the match with the writer's
        // 2-channel input unconditional.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let delegate = MicrophoneCaptureDelegate(
            recordingEngine: self,
            timeline: timeline,
            takeID: takeID
        )
        audioOutput.setSampleBufferDelegate(delegate, queue: writerQueue)
        guard session.canAddOutput(audioOutput) else { throw RecordingError.cannotAddMicrophoneInput }
        session.addOutput(audioOutput)
        session.commitConfiguration()
        runSessionOffMain(session, start: true)

        microphoneSession = session
        microphoneOutput = audioOutput
        microphoneDelegate = delegate
    }

    private func stopMicrophoneCapture() {
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = microphoneSession {
            runSessionOffMain(session, start: false)
        }
        microphoneSession = nil
        microphoneOutput = nil
        microphoneDelegate = nil
    }

    fileprivate func updateMicrophoneLevel(_ level: CGFloat, takeID: UUID) {
        guard takeLifecycle.isRecording(takeID) else { return }
        hud?.updateMicrophoneLevel(level)
    }

    private func requestWebcamPermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - RecordingResultActions (GIF export + trim)

    func exportGIF(from url: URL) {
        let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
        ToastWindow.show(message: "Exporting GIF…")
        Task {
            do {
                let out = try await GIFEncoder.encode(videoURL: url, to: gifURL)
                ToastWindow.show(message: "Saved GIF: \(out.lastPathComponent)", duration: 3.0)
            } catch {
                ToastWindow.show(message: "Could not export GIF.")
                print("[KRIT] GIF export failed: \(error)")
            }
        }
    }

    func trim(url: URL, range: CMTimeRange, convert: VideoTrimPanel.ConvertOptions?) {
        let base = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(base) Trimmed.mp4")
        ToastWindow.show(message: "Trimming…")
        Task { [weak self] in
            let ok: Bool
            if let convert {
                ok = await Self.exportTrimConvert(source: url, range: range, options: convert, to: outURL)
            } else {
                ok = await Self.exportTrimOnly(source: url, range: range, to: outURL)
            }
            guard ok else {
                ToastWindow.show(message: "Could not trim recording.")
                return
            }
            ToastWindow.show(message: "Saved trimmed: \(outURL.lastPathComponent)", duration: 3.0)
            // Route the trimmed clip back through presentResult so it returns as
            // a card (or the result window with the overlay off) instead of being
            // left orphaned on disk, the same way exportAutoZoom does.
            guard let self else { return }
            let seconds = CMTimeGetSeconds(range.duration)
            self.lastFinishedRecording = (outURL, seconds)
            self.presentResult(url: outURL, duration: seconds)
        }
    }

    // MARK: - Trim export pipeline

    /// Plain range trim: exports `range` at the source's native dimensions and
    /// audio, with no rescale or remux. This is the historical "Trim Only" path.
    static func exportTrimOnly(source url: URL, range: CMTimeRange, to outURL: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.timeRange = range
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed, let error = export.error { print("[KRIT] Trim failed: \(error)") }
        return export.status == .completed
    }

    /// Range trim that also honors the convert options: rescales the video to
    /// `options.width` x `options.height`, applies a quality-driven byte budget,
    /// and emits audio per `options.audio`.
    ///
    /// Strategy: the video (and, for `.keep`, its audio) goes through one
    /// `AVAssetExportSession` driven by an `AVMutableVideoComposition` whose
    /// `renderSize` does the real rescale. `.mute` simply omits the audio track.
    /// `.mono` cannot be downmixed by an export session, so phase 1 stays
    /// video-only, phase 2 reader/writer-encodes a genuine 1-channel track, and
    /// phase 3 muxes the two together.
    static func exportTrimConvert(
        source url: URL,
        range: CMTimeRange,
        options: VideoTrimPanel.ConvertOptions,
        to outURL: URL
    ) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let rawFps = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let fps = max(Int(rawFps.rounded()), 1)
        // Even dimensions keep H.264 happy; clamp to a 2px floor.
        let target = CGSize(width: evenClamp(options.width), height: evenClamp(options.height))

        // Phase 1: rescaled video, cut to `range`, plus original audio when keep.
        guard let (comp, compVideo) = await buildTrimComposition(
            asset: asset, videoTrack: videoTrack, range: range, keepAudio: options.audio == .keep
        ) else {
            return false
        }
        let transform = await renderTransform(for: videoTrack, target: target)
        let videoComposition = scalingVideoComposition(
            track: compVideo, transform: transform, target: target, fps: fps, duration: range.duration
        )

        let needsMono = (options.audio == .mono)
        // For mono, phase 1 writes video-only to a temp file; for keep/mute the
        // export already produces the final file.
        let phase1URL = needsMono
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("krit-trim-v-\(UUID().uuidString).mp4")
            : outURL

        let budget = qualityByteBudget(
            target: target, fps: fps, quality: options.quality,
            durationSec: CMTimeGetSeconds(range.duration), includeAudio: options.audio == .keep
        )
        guard await runVideoExport(comp, videoComposition: videoComposition, budget: budget, to: phase1URL) else {
            return false
        }
        if !needsMono { return true }

        // Phase 2 + 3: downmix the source audio to a real 1-channel track and mux
        // it onto the rescaled video.
        return await muxMonoAudio(source: url, range: range, videoOnly: phase1URL, to: outURL)
    }

    /// Composition for the trim: video over `range`, plus the original audio when
    /// `keepAudio`. Returns the composition and its video track so the caller can
    /// hang a scaling video composition on it.
    private static func buildTrimComposition(
        asset: AVURLAsset, videoTrack: AVAssetTrack, range: CMTimeRange, keepAudio: Bool
    ) async -> (AVMutableComposition, AVCompositionTrack)? {
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? compVideo.insertTimeRange(range, of: videoTrack, at: .zero)) != nil else {
            return nil
        }
        if keepAudio,
           let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        }
        return (comp, compVideo)
    }

    /// Orient (preferred transform, identity for screen recordings) then scale the
    /// source into the `target` render box.
    private static func renderTransform(for track: AVAssetTrack, target: CGSize) async -> CGAffineTransform {
        let naturalSize = (try? await track.load(.naturalSize)) ?? target
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let display = naturalSize.applying(preferredTransform)
        let displayWidth = abs(display.width) > 0 ? abs(display.width) : max(naturalSize.width, 1)
        let displayHeight = abs(display.height) > 0 ? abs(display.height) : max(naturalSize.height, 1)
        let scale = CGAffineTransform(scaleX: target.width / displayWidth, y: target.height / displayHeight)
        return preferredTransform.concatenating(scale)
    }

    /// Runs the phase-1 export session that rescales and re-encodes the video.
    private static func runVideoExport(
        _ comp: AVMutableComposition, videoComposition: AVMutableVideoComposition, budget: Int64, to outURL: URL
    ) async -> Bool {
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.fileLengthLimit = budget
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed, let error = export.error { print("[KRIT] Trim+convert video failed: \(error)") }
        return export.status == .completed
    }

    /// Phases 2 + 3 of the mono path: downmix the source audio over `range` to a
    /// real 1-channel track, then mux it onto the rescaled `videoOnly` file. If the
    /// source has no audio, the rescaled video alone becomes the result.
    private static func muxMonoAudio(source url: URL, range: CMTimeRange, videoOnly phase1URL: URL, to outURL: URL) async -> Bool {
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("krit-trim-a-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: phase1URL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard await writeMonoAudio(from: url, range: range, to: audioURL) else {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.moveItem(at: phase1URL, to: outURL)
            return FileManager.default.fileExists(atPath: outURL.path)
        }
        return await mux(videoURL: phase1URL, audioURL: audioURL, to: outURL)
    }

    /// Rounds down to an even value with a 2px floor (H.264 dislikes odd sizes).
    private static func evenClamp(_ value: Int) -> Int { max(2, value - (value % 2)) }

    /// Byte budget fed to `AVAssetExportSession.fileLengthLimit`. Mirrors the
    /// panel's bits-per-pixel-per-frame estimate so a low quality slider yields a
    /// visibly smaller file. The 64 KB floor avoids a budget so tight the export
    /// would fail outright on tiny clips.
    private static func qualityByteBudget(target: CGSize, fps: Int, quality: Double, durationSec: Double, includeAudio: Bool) -> Int64 {
        let bitsPerPixelPerFrame = 0.06 + max(0, min(1, quality)) * 0.20
        let pixels = Double(Int(target.width) * Int(target.height))
        let videoBitsPerSecond = pixels * Double(fps) * bitsPerPixelPerFrame
        let audioBitsPerSecond: Double = includeAudio ? 192_000 : 0
        let bytes = (videoBitsPerSecond + audioBitsPerSecond) * max(durationSec, 0.05) / 8.0
        return Int64(max(bytes, 64_000))
    }

    /// Builds the video composition that rescales the composition's video track to
    /// `target` by applying `transform` (orient + scale) at a `renderSize` of
    /// `target`.
    private static func scalingVideoComposition(
        track: AVCompositionTrack,
        transform: CGAffineTransform,
        target: CGSize,
        fps: Int,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = target
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    /// Reads the source audio over `range` and writes a genuine single-channel AAC
    /// track. The mono channel layout makes the reader DOWNMIX (sum both channels)
    /// rather than drop one. Returns false when the source has no audio.
    nonisolated private static func writeMonoAudio(from url: URL, range: CMTimeRange, to outURL: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: outURL, fileType: .m4a) else {
            return false
        }
        reader.timeRange = range

        var monoLayout = AudioChannelLayout()
        monoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &monoLayout, count: MemoryLayout<AudioChannelLayout>.size)

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData
        ])
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 96_000
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        try? FileManager.default.removeItem(at: outURL)
        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.krit.trim.audio")
        let appended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let pump = MonoAudioPump(
                input: writerInput,
                output: readerOutput,
                rangeStart: range.start,
                continuation: continuation
            )
            writerInput.requestMediaDataWhenReady(on: queue) {
                pump.appendAvailableSamples()
            }
        }
        guard appended else {
            writer.cancelWriting()
            return false
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed && reader.status == .completed
    }

    /// Muxes a video-only file and an audio-only file into one mp4 without
    /// re-encoding either track (passthrough).
    private static func mux(videoURL: URL, audioURL: URL, to outURL: URL) async -> Bool {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
              let videoDuration = try? await videoAsset.load(.duration),
              let audioDuration = try? await audioAsset.load(.duration),
              let compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }
        try? compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        // Clamp audio to the video length so a slightly longer audio tail does not
        // stretch the clip.
        let audioRange = CMTimeRange(start: .zero, duration: min(audioDuration, videoDuration))
        try? compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed, let error = export.error { print("[KRIT] Trim+convert mux failed: \(error)") }
        return export.status == .completed
    }

    func exportAutoZoom(from url: URL) {
        guard let metadata = RecordingMetadataStore.load(for: url), metadata.mouseSamples.count >= 2 else {
            ToastWindow.show(message: "No cursor data to auto-zoom this clip.")
            return
        }
        let base = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(base) Auto-Zoom.mp4")
        ToastWindow.show(message: "Rendering auto-zoom…")
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            guard seconds > 0.05 else {
                ToastWindow.show(message: "Could not auto-zoom recording.")
                return
            }
            // One auto segment over the whole clip: a constant 2x camera that
            // follows the recorded cursor. Smart per-activity segments come later.
            let segment = ZoomSegment(startTime: 0, duration: seconds, zoomLevel: 2.0, zoomType: .auto)
            let path = AutoFocusEngine.buildPath(from: metadata, segment: segment)
            do {
                try await ZoomComposer.export(url: url, to: outURL, segments: [segment], autoFocusPaths: [segment.id: path])
                guard let self else { return }
                ToastWindow.show(message: "Saved auto-zoom: \(outURL.lastPathComponent)", duration: 3.0)
                self.lastFinishedRecording = (outURL, seconds)
                self.presentResult(url: outURL, duration: seconds)
            } catch {
                ToastWindow.show(message: "Could not auto-zoom recording.")
                print("[KRIT] Auto-zoom export failed: \(error)")
            }
        }
    }

    private func cleanup(takeID: UUID) {
        guard takeLifecycle.isFinishing(takeID) else { return }
        stopMicrophoneCapture()
        stopMouseSampling()
        mouseSamples.removeAll()
        captureRegionRect = .zero
        captureRegionSize = .zero
        cameraBubble?.stop()
        cameraBubble = nil
        clickKeyOverlay?.stop()
        clickKeyOverlay = nil
        dimOverlay?.hide()
        dimOverlay = nil
        stream = nil
        streamOutput = nil
        timeline?.cancel()
        timeline = nil
        outputURL = nil
        isPaused = false
        closeRecordingChrome()
        finishSessionID = UUID()
        _ = takeLifecycle.complete(takeID)
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: width, height: height, fps: fps, quality: quality),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    private static func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func bitrate(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> Int {
        let pixels = Double(max(width, 1) * max(height, 1))
        let raw = pixels * Double(max(fps, 1)) * quality.bitsPerPixelPerFrame
        return min(max(Int(raw.rounded()), quality.minimumBitrate), quality.maximumBitrate)
    }

    /// Shifts an AUDIO sample buffer to a new presentation time by applying the
    /// PTS delta to EVERY timing entry, preserving per-sample durations. SCK
    /// system-audio buffers carry many samples; rewriting them with a single
    /// uniform timing entry (the video-style copy below) corrupts the timing and
    /// the writer faults with kCMSampleBufferError_ArrayTooSmall (-12737), which
    /// surfaced as "Recording not saved" whenever audio capture was enabled.
    nonisolated private static func audioCopy(sampleBuffer: CMSampleBuffer, shiftedTo newPresentationTime: CMTime) -> CMSampleBuffer? {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard originalPTS.isValid, newPresentationTime.isValid else { return nil }
        let delta = CMTimeSubtract(newPresentationTime, originalPTS)

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in 0..<infos.count {
            if infos[i].presentationTimeStamp.isValid {
                infos[i].presentationTimeStamp = CMTimeAdd(infos[i].presentationTimeStamp, delta)
            }
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeAdd(infos[i].decodeTimeStamp, delta)
            }
        }
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: infos.count,
            sampleTimingArray: &infos,
            sampleBufferOut: &copied
        )
        guard status == noErr else { return nil }
        return copied
    }

    /// AVFoundation invokes `requestMediaDataWhenReady` serially on the queue
    /// supplied by the caller. These reader and writer objects are therefore
    /// confined to that one queue, never shared with the main actor.
    private final class MonoAudioPump: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let output: AVAssetReaderTrackOutput
        private let rangeStart: CMTime
        private var isFinished = false
        private let continuation: CheckedContinuation<Bool, Never>

        init(
            input: AVAssetWriterInput,
            output: AVAssetReaderTrackOutput,
            rangeStart: CMTime,
            continuation: CheckedContinuation<Bool, Never>
        ) {
            self.input = input
            self.output = output
            self.rangeStart = rangeStart
            self.continuation = continuation
        }

        func appendAvailableSamples() {
            guard !isFinished else { return }
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    finish(success: true)
                    return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let shifted = RecordingEngine.audioCopy(
                    sampleBuffer: sample,
                    shiftedTo: CMTimeSubtract(pts, rangeStart)
                ) ?? sample
                guard input.append(shifted) else {
                    finish(success: false)
                    return
                }
            }
        }

        private func finish(success: Bool) {
            guard !isFinished else { return }
            isFinished = true
            if success { input.markAsFinished() }
            continuation.resume(returning: success)
        }
    }

    fileprivate nonisolated static func frameStatus(from rawValue: Any) -> SCFrameStatus? {
        if let status = rawValue as? SCFrameStatus { return status }
        if let raw = rawValue as? Int { return SCFrameStatus(rawValue: raw) }
        if let raw = rawValue as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) }
        return nil
    }

    private static func microphoneDevice(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    fileprivate nonisolated static func microphoneLevel(from sampleBuffer: CMSampleBuffer) -> CGFloat {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return 0
        }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData,
              bufferList.mBuffers.mDataByteSize > 0 else {
            return 0
        }

        let sampleCount: Int
        let sumSquares: Double
        if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let value = Double(sample)
                return partial + value * value
            }
        } else if streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamDescription.mBitsPerChannel == 64 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Double>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: sampleCount)
            sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        } else if streamDescription.mBitsPerChannel == 16 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int16.max)
                return partial + normalized * normalized
            }
        } else if streamDescription.mBitsPerChannel == 32 {
            sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: sampleCount)
            sumSquares = samples.reduce(0) { partial, sample in
                let normalized = Double(sample) / Double(Int32.max)
                return partial + normalized * normalized
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(max(rms, 0.000_001))
        return CGFloat(max(0, min(1, (decibels + 55) / 45)))
    }

    private static func makeOutputURL() -> URL {
        let directory = URL(fileURLWithPath: Settings.autoSaveLocation, isDirectory: true)
        let baseName = ImageExporter.timestampedName
        var url = directory.appendingPathComponent("\(baseName).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName) \(suffix).mp4")
            suffix += 1
        }
        return url
    }

    private static func savedRecordingMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        return "Saved to \(destination): \(url.lastPathComponent)"
    }

    private enum RecordingSource {
        case displayRect(rect: CGRect, screen: NSScreen)
        case window(SCWindow, screen: NSScreen)

        var screen: NSScreen {
            switch self {
            case .displayRect(_, let screen), .window(_, let screen): screen
            }
        }

        var usesDisplayFilter: Bool {
            switch self {
            case .displayRect, .window: true
            }
        }
    }

    private struct PreparedCaptureSource {
        let filter: SCContentFilter
        let streamConfig: SCStreamConfiguration
        let pixelWidth: Int
        let pixelHeight: Int
        /// AppKit (bottom-left) region rect used to position the click/key overlay.
        let regionRect: CGRect
    }

    private enum RecordingError: Error {
        case noDisplay
        case noMicrophone
        case cannotAddWriterInput
        case cannotStartWriter
        case cannotAddMicrophoneInput
    }
}

private struct RecordingConfiguration {
    var fps: Int
    var quality: RecordingQuality
    var showsCursor: Bool
    var recordsSystemAudio: Bool
    var recordsMicrophone: Bool
    var microphoneDeviceID: String
    var recordsWebcam: Bool
    var webcamDeviceID: String
    var recordsClicks: Bool
    var recordsKeystrokes: Bool

    static var current: RecordingConfiguration {
        RecordingConfiguration(
            fps: Settings.recordingFPS,
            quality: RecordingQuality(rawValue: Settings.recordingQuality) ?? .high,
            showsCursor: Settings.recordingShowsCursor,
            recordsSystemAudio: Settings.recordingSystemAudio,
            recordsMicrophone: Settings.recordingMicrophone,
            microphoneDeviceID: Settings.recordingMicrophoneDeviceID,
            recordsWebcam: Settings.recordingWebcam,
            webcamDeviceID: Settings.recordingWebcamDeviceID,
            recordsClicks: Settings.recordingShowsClicks,
            recordsKeystrokes: Settings.recordingShowsKeystrokes
        )
    }
}

enum RecordingQuality: String {
    case balanced
    case high
    case max

    var displayName: String {
        switch self {
        case .balanced: "Balanced"
        case .high: "High"
        case .max: "Max"
        }
    }

    var bitsPerPixelPerFrame: Double {
        switch self {
        case .balanced: 0.12
        case .high: 0.22
        case .max: 0.32
        }
    }

    var minimumBitrate: Int {
        switch self {
        case .balanced: 6_000_000
        case .high: 12_000_000
        case .max: 20_000_000
        }
    }

    var maximumBitrate: Int {
        switch self {
        case .balanced: 40_000_000
        case .high: 80_000_000
        case .max: 120_000_000
        }
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    private weak var recordingEngine: RecordingEngine?
    private let timeline: RecordingTimelineWriter
    private let takeID: UUID

    init(
        recordingEngine: RecordingEngine,
        timeline: RecordingTimelineWriter,
        takeID: UUID
    ) {
        self.recordingEngine = recordingEngine
        self.timeline = timeline
        self.takeID = takeID
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[SCStreamFrameInfo.status],
                  RecordingEngine.frameStatus(from: rawStatus) == .complete else {
                return
            }
            timeline.append(sampleBuffer, from: .video)
        case .audio:
            timeline.append(sampleBuffer, from: .systemAudio)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordingEngine?.streamDidStopWithError(error, takeID: takeID)
    }
}

private final class MicrophoneCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private weak var recordingEngine: RecordingEngine?
    private let timeline: RecordingTimelineWriter
    private let takeID: UUID
    private var lastMeterUpdate = 0.0

    init(
        recordingEngine: RecordingEngine,
        timeline: RecordingTimelineWriter,
        takeID: UUID
    ) {
        self.recordingEngine = recordingEngine
        self.timeline = timeline
        self.takeID = takeID
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        timeline.append(sampleBuffer, from: .microphone)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeterUpdate >= (1.0 / 30.0) else { return }
        lastMeterUpdate = now
        let level = RecordingEngine.microphoneLevel(from: sampleBuffer)
        Task { @MainActor [weak recordingEngine] in
            recordingEngine?.updateMicrophoneLevel(level, takeID: takeID)
        }
    }
}
