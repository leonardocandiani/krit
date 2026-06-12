import AppKit
import AVFoundation
import CoreVideo
import CoreMedia
import ScreenCaptureKit

/// Actions the result window (and the video overlay card) invoke back on the
/// engine: GIF export, trim, and re-opening the editor window from the card.
@MainActor
protocol RecordingResultActions: AnyObject {
    func exportGIF(from url: URL)
    func trim(url: URL, range: CMTimeRange)
    /// Re-presents the RecordingResultWindow (GIF / trim editor) for a finished
    /// recording. The overlay card's "Edit recording" routes here so the result
    /// window's exclusive features stay reachable after it stops being the default.
    func reopenResultWindow(url: URL, duration: Double)
}

@MainActor
final class RecordingEngine: NSObject, RecordingResultActions {

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
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
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
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    /// Source-clock PTS of the most recently appended video frame. Used to anchor
    /// the pause gap at the pause toggle, not at the first frame seen while paused.
    private var lastAppendedSourceTime: CMTime?
    private var lastCompleteSampleBuffer: CMSampleBuffer?
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    // Each audio source carries its own clock (system audio rides the SCStream
    // clock, the mic rides its AVCaptureSession host clock), so neither can be
    // retimed against the video's first PTS. Anchor each track on its own first
    // sample and map it onto the session time the video had reached by then; this
    // keeps every track monotonic from .zero up, which the writer requires.
    private var systemAudioAnchor: AudioTrackAnchor?
    private var microphoneAnchor: AudioTrackAnchor?
    private var lastSystemAudioOutputTime: CMTime?
    private var lastMicrophoneOutputTime: CMTime?
    private var recordingStartedAt: CFTimeInterval = 0
    private var isRecording = false
    private var isFinishing = false
    private var isPaused = false
    // Total accumulated paused time in source timescale; subtracted from every
    // relative PTS (video + both audio tracks) so the output has no frozen gap.
    private var pausedDuration: CMTime = .zero
    private var pauseStartedSourceTime: CMTime?
    private var finishSessionID = UUID()
    private var finishTimeoutWorkItem: DispatchWorkItem?
    private var hud: RecordingHUDWindow?
    private var configuration = RecordingConfiguration.current

    var active: Bool { isRecording || isFinishing }

    /// GUI test hook: how many dim panels are live (0 when no dim is showing).
    var uiTestDimPanelCount: Int { dimOverlay?.panelCount ?? 0 }

    /// GUI test hook: outcome of the last finish ("none", "saved:<path>" or
    /// "failed:<reason>"), so the harness sees WHICH branch ran instead of
    /// inferring from a missing card.
    var uiTestLastFinishOutcome = "none"

    func startRecording(rect: CGRect, on screen: NSScreen) async {
        await startRecording(source: .displayRect(rect: rect, screen: screen))
    }

    func startRecording(window: SCWindow, on screen: NSScreen) async {
        await startRecording(source: .window(window, screen: screen))
    }

    private func startRecording(source: RecordingSource) async {
        guard !active else {
            ToastWindow.show(message: "Recording already in progress")
            return
        }

        uiTestLastFinishOutcome = "none"
        uiTestLastStreamError = ""

        var configuration = RecordingConfiguration.current
        if configuration.recordsMicrophone {
            let canUseMicrophone = await requestMicrophonePermissionIfNeeded()
            if !canUseMicrophone {
                configuration.recordsMicrophone = false
                ToastWindow.show(message: "Mic unavailable. Recording without it.")
            }
        }
        if configuration.recordsWebcam {
            let canUseWebcam = await requestWebcamPermissionIfNeeded()
            if !canUseWebcam {
                configuration.recordsWebcam = false
                ToastWindow.show(message: "Camera unavailable. Recording without it.")
            }
        }

        do {
            let hud = RecordingHUDWindow()
            hud.configure(
                systemAudio: configuration.recordsSystemAudio,
                microphone: configuration.recordsMicrophone,
                fps: configuration.fps,
                quality: configuration.quality.displayName
            )
            hud.stopHandler = { [weak self] in self?.stopRecording() }
            hud.togglePauseHandler = { [weak self] _ in self?.togglePause() }
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
                excludingWindowNumbers: excludedWindowNumbers
            )
            stream = prepared.stream
            streamOutput = prepared.output
            assetWriter = prepared.writer
            videoInput = prepared.videoInput
            systemAudioInput = prepared.systemAudioInput
            microphoneInput = prepared.microphoneInput
            outputURL = prepared.url
            self.configuration = configuration
            resetTimingState()
            isFinishing = false
            isRecording = false
            isPaused = false
            pausedDuration = .zero
            pauseStartedSourceTime = nil
            isRecording = true
            recordingStartedAt = CACurrentMediaTime()

            if configuration.recordsMicrophone {
                try startMicrophoneCapture(deviceID: configuration.microphoneDeviceID)
            }
            try await prepared.stream.startCapture()

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
        } catch {
            if let stream {
                try? await stream.stopCapture()
            }
            cleanup()
            ToastWindow.show(message: "Could not start recording. Check permissions.")
            print("[KRIT] Recording start failed: \(error)")
        }
    }

    /// Re-presents the result window for the last finished recording so GIF export,
    /// trim and reveal stay reachable after the window was dismissed.
    func reopenLastResult() {
        guard let last = lastFinishedRecording,
              FileManager.default.fileExists(atPath: last.url.path) else { return }
        RecordingResultWindow.show(url: last.url, duration: last.duration, actions: self)
    }

    /// Default post-recording destination. With the overlay on (the user's normal
    /// setting), the finished clip shows up as a video card in the quick-access tray,
    /// exactly like a screenshot; the GIF/trim editor stays reachable from the card's
    /// "Edit recording" menu. With the overlay off, fall back to the result window so
    /// the recording is never left without a destination.
    private func presentResult(url: URL, duration: Double) {
        guard Settings.afterCaptureShowOverlay else {
            RecordingResultWindow.show(url: url, duration: duration, actions: self)
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

    func reopenResultWindow(url: URL, duration: Double) {
        RecordingResultWindow.show(url: url, duration: duration, actions: self)
    }

    /// First-frame poster for the overlay card. AVAssetImageGenerator on a fresh
    /// asset, off the main actor; falls back to a generic film icon if the grab
    /// fails (corrupt clip, codec hiccup) so the card always has something to show.
    private static func firstFrameThumbnail(for url: URL) async -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        let fallback = NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage()
        return fallback
    }

    func stopRecording() {
        guard isRecording, !isFinishing else { return }
        SoundManager.play(.recordStop)
        beginFinishing()

        let streamToStop = stream
        let outputToRemove = streamOutput
        Task {
            do {
                try await streamToStop?.stopCapture()
            } catch {
                print("[KRIT] Recording stop failed: \(error)")
            }
            if let streamToStop, let outputToRemove {
                try? streamToStop.removeStreamOutput(outputToRemove, type: .screen)
                try? streamToStop.removeStreamOutput(outputToRemove, type: .audio)
            }
            finishRecording(error: nil)
        }
    }

    func togglePause() {
        guard isRecording, !isFinishing else { return }
        // No-op until the session has its first frame; pausing before any frame
        // would have nothing to gate and no source clock to measure the gap from.
        guard firstPresentationTime != nil else { return }
        isPaused.toggle()
        // Anchor the pause gap at the toggle (last appended frame's source PTS),
        // not at the first frame seen while paused, otherwise pausedDuration
        // under-counts by up to ~2 frame intervals and A/V drifts forward.
        if isPaused {
            pauseStartedSourceTime = lastAppendedSourceTime
            SoundManager.play(.recordPause)
        }
        clickKeyOverlay?.setPaused(isPaused)
        hud?.setPaused(isPaused)
    }

    fileprivate nonisolated func streamDidStopWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording, !self.isFinishing else { return }
            let nsError = error as NSError
            self.uiTestLastStreamError = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
            self.beginFinishing()
            self.finishRecording(error: error)
        }
    }

    /// GUI test hook: raw domain/code of the last SCStream stop error, so a
    /// "lost the screen stream" failure is diagnosable without console access.
    var uiTestLastStreamError = ""

    fileprivate nonisolated func processScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status],
              Self.frameStatus(from: rawStatus) == .complete else {
            return
        }

        Task { @MainActor [weak self] in
            self?.appendCompleteFrame(sampleBuffer)
        }
    }

    fileprivate nonisolated func processSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.appendAudioSample(sampleBuffer, to: .system)
        }
    }

    fileprivate nonisolated func processMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let level = Self.microphoneLevel(from: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.hud?.updateMicrophoneLevel(level)
            self?.appendAudioSample(sampleBuffer, to: .microphone)
        }
    }

    private func prepareStream(
        source: RecordingSource,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> (
        stream: SCStream,
        output: RecordingStreamOutput,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?,
        url: URL,
        regionRect: CGRect
    ) {
        let preparedSource = try await prepareCaptureSource(source, configuration: configuration, excludingWindowNumbers: excludingWindowNumbers)

        let output = RecordingStreamOutput(recordingEngine: self)
        let stream = SCStream(filter: preparedSource.filter, configuration: preparedSource.streamConfig, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writerQueue)
        if configuration.recordsSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writerQueue)
        }

        let url = Self.makeOutputURL()
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

        guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStartWriter }

        return (stream, output, writer, videoInput, systemAudioInput, microphoneInput, url, preparedSource.regionRect)
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let selectedWindow = content.windows.first { $0.windowID == window.windowID } ?? window
        let appKitRect = Self.appKitRect(fromScreenCaptureKitWindowFrame: selectedWindow.frame, on: screen)
        guard let display = content.displays.first(where: { $0.frame.intersects(selectedWindow.frame) }) ?? content.displays.first else {
            throw RecordingError.noDisplay
        }

        let filter = SCContentFilter(display: display, including: [selectedWindow])
        return prepareDisplaySource(
            rect: appKitRect,
            on: screen,
            configuration: configuration,
            filter: filter
        )
    }

    private static func appKitRect(fromScreenCaptureKitWindowFrame frame: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: frame.minX,
            y: screen.frame.origin.y + screen.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> PreparedCaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Casar por displayID: rect é AppKit (y pra cima), SCDisplay.frame é
        // CoreGraphics (y pra baixo); a interseção falha num segundo monitor.
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == screenID })
            ?? content.displays.first(where: { $0.frame.intersects(rect) })
            ?? content.displays.first else {
            throw RecordingError.noDisplay
        }
        let excludedWindows = excludingWindowNumbers.compactMap { windowNumber in
            content.windows.first { CGWindowID($0.windowID) == windowNumber }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        return prepareDisplaySource(
            rect: rect,
            on: screen,
            configuration: configuration,
            filter: filter
        )
    }

    private func prepareDisplaySource(
        rect: CGRect,
        on screen: NSScreen,
        configuration: RecordingConfiguration,
        filter: SCContentFilter
    ) -> PreparedCaptureSource {
        let scale = Self.pixelScale(for: filter, fallbackScreen: screen)
        let originX = floor((rect.origin.x - screen.frame.origin.x) * scale) / scale
        let originY = floor((rect.origin.y - screen.frame.origin.y) * scale) / scale
        let width = ceil(rect.width * scale) / scale
        let height = ceil(rect.height * scale) / scale
        let sourceRect = CGRect(
            x: originX,
            y: screen.frame.height - originY - height,
            width: width,
            height: height
        )

        let pixelWidth = max(2, Self.evenCeil(Int(ceil(width * scale))))
        let pixelHeight = max(2, Self.evenCeil(Int(ceil(height * scale))))
        let streamConfig = Self.streamConfiguration(width: pixelWidth, height: pixelHeight, configuration: configuration)
        streamConfig.sourceRect = sourceRect

        return PreparedCaptureSource(filter: filter, streamConfig: streamConfig, pixelWidth: pixelWidth, pixelHeight: pixelHeight, regionRect: rect)
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

    private func appendCompleteFrame(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, let writer = assetWriter, let input = videoInput else { return }

        let sourcePresentationTime = sampleBuffer.presentationTimeStamp

        // Paused: keep the latest frame for the final static-frame logic, but do
        // not append. The pause-start was anchored at the toggle (togglePause);
        // fall back to the first paused frame only if the toggle had no prior
        // appended frame to anchor on.
        if isPaused {
            lastCompleteSampleBuffer = sampleBuffer
            if pauseStartedSourceTime == nil { pauseStartedSourceTime = sourcePresentationTime }
            return
        }
        if let pauseStart = pauseStartedSourceTime {
            pausedDuration = CMTimeAdd(pausedDuration, CMTimeSubtract(sourcePresentationTime, pauseStart))
            pauseStartedSourceTime = nil
        }

        if firstPresentationTime == nil {
            firstPresentationTime = sourcePresentationTime
            writer.startSession(atSourceTime: .zero)
            flushPendingAudioSamples()
        }

        guard let firstPresentationTime else { return }
        let relativePresentationTime = CMTimeSubtract(CMTimeSubtract(sourcePresentationTime, firstPresentationTime), pausedDuration)
        guard relativePresentationTime >= .zero else { return }
        guard input.isReadyForMoreMediaData else { return }

        guard let retimed = Self.copy(sampleBuffer: sampleBuffer, presentationTime: relativePresentationTime, duration: frameDuration) else { return }

        if input.append(retimed) {
            lastPresentationTime = relativePresentationTime
            lastAppendedSourceTime = sourcePresentationTime
            lastCompleteSampleBuffer = sampleBuffer
        } else if let error = writer.error {
            print("[KRIT] Asset writer append failed: \(error)")
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer, to target: AudioTarget) {
        guard !isFinishing else { return }
        // Drop audio while paused so there is no silent gap to fill.
        guard !isPaused else { return }
        // Hold audio until the writer session is open. The session starts on the
        // first video frame; audio that arrives earlier (common with system audio
        // and the mic) has no session to land in yet.
        guard firstPresentationTime != nil else {
            switch target {
            case .system: pendingSystemAudioSamples.append(sampleBuffer)
            case .microphone: pendingMicrophoneSamples.append(sampleBuffer)
            }
            return
        }
        appendReadyAudioSample(sampleBuffer, to: target)
    }

    private func flushPendingAudioSamples() {
        // Anchor each track on its OLDEST buffered sample so the run starts at the
        // session time the track was actually live, then append in arrival order.
        pendingSystemAudioSamples.forEach { appendReadyAudioSample($0, to: .system) }
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.forEach { appendReadyAudioSample($0, to: .microphone) }
        pendingMicrophoneSamples.removeAll()
    }

    private func appendReadyAudioSample(_ sampleBuffer: CMSampleBuffer, to target: AudioTarget) {
        let input: AVAssetWriterInput? = switch target {
        case .system: systemAudioInput
        case .microphone: microphoneInput
        }
        guard let input, input.isReadyForMoreMediaData,
              let presentationTime = sessionTimeForAudio(sampleBuffer, target: target) else { return }
        // The writer rejects (and faults on) a non-monotonic PTS. Two tracks share
        // one clock domain only inside themselves, so dedupe per track: skip any
        // sample whose mapped time does not advance past the last one appended.
        switch target {
        case .system:
            if let last = lastSystemAudioOutputTime, presentationTime <= last { return }
        case .microphone:
            if let last = lastMicrophoneOutputTime, presentationTime <= last { return }
        }
        // Probe de formato: taxa/canais/frames/entradas de timing do buffer real,
        // pra flagrar renegociação de formato ou shape estranho de buffer.
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            var entries: CMItemCount = 0
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entries)
            let sig = "\(Int(asbd.mSampleRate))x\(asbd.mChannelsPerFrame)n\(CMSampleBufferGetNumSamples(sampleBuffer))t\(entries)"
            let key = "fmt-\(target):"
            if !uiTestLastStreamError.contains("\(key)\(sig)") {
                uiTestLastStreamError += " \(key)\(sig)@\(String(format: "%.2f", presentationTime.seconds))"
            }
        }
        guard let retimed = Self.audioCopy(sampleBuffer: sampleBuffer, shiftedTo: presentationTime) else {
            uiTestLastStreamError += " audioCopyFailed-\(target)"
            return
        }
        guard input.append(retimed) else {
            if let error = assetWriter?.error {
                let ns = error as NSError
                let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " under:\($0.domain)#\($0.code)" } ?? ""
                uiTestLastStreamError += " append-\(target):\(ns.domain)#\(ns.code)\(underlying) pts:\(String(format: "%.4f", presentationTime.seconds))"
                print("[KRIT] Audio append failed (\(target)): \(error)")
            }
            return
        }
        if assetWriter?.status == .failed, !uiTestLastStreamError.contains("firstFail") {
            uiTestLastStreamError += " firstFail-after-\(target) pts:\(String(format: "%.4f", presentationTime.seconds))"
        }
        switch target {
        case .system: lastSystemAudioOutputTime = presentationTime
        case .microphone: lastMicrophoneOutputTime = presentationTime
        }
    }

    /// Maps an audio sample from its own clock onto the writer session timeline.
    /// The first sample of each track defines the anchor: its source PTS pairs with
    /// the session time the video had already reached, so the track lines up with
    /// the video without assuming a shared clock (the mic never shares one). Pause
    /// gaps are folded in via `pausedDuration`, same as video.
    private func sessionTimeForAudio(_ sampleBuffer: CMSampleBuffer, target: AudioTarget) -> CMTime? {
        guard firstPresentationTime != nil else { return nil }
        let sourceTime = sampleBuffer.presentationTimeStamp
        guard sourceTime.isValid else { return nil }

        let anchor: AudioTrackAnchor
        switch target {
        case .system:
            if let existing = systemAudioAnchor {
                anchor = existing
            } else {
                let created = AudioTrackAnchor(sourceTime: sourceTime, sessionTime: currentVideoSessionTime, pausedAtAnchor: pausedDuration)
                systemAudioAnchor = created
                anchor = created
            }
        case .microphone:
            if let existing = microphoneAnchor {
                anchor = existing
            } else {
                let created = AudioTrackAnchor(sourceTime: sourceTime, sessionTime: currentVideoSessionTime, pausedAtAnchor: pausedDuration)
                microphoneAnchor = created
                anchor = created
            }
        }

        let elapsedInTrack = CMTimeSubtract(sourceTime, anchor.sourceTime)
        let pauseSinceAnchor = CMTimeSubtract(pausedDuration, anchor.pausedAtAnchor)
        let mapped = CMTimeSubtract(CMTimeAdd(anchor.sessionTime, elapsedInTrack), pauseSinceAnchor)
        return mapped >= .zero ? mapped : .zero
    }

    /// Session time the most recent video frame reached (already pause-adjusted),
    /// or .zero before the first frame. Audio anchors hang off this so a track that
    /// goes live mid-recording starts at the right offset, not back at .zero.
    private var currentVideoSessionTime: CMTime {
        lastPresentationTime ?? .zero
    }

    private func finishRecording(error: Error?) {
        guard isFinishing else { return }
        stopMicrophoneCapture()
        cameraBubble?.stop()
        cameraBubble = nil
        clickKeyOverlay?.stop()
        clickKeyOverlay = nil
        let sessionID = UUID()
        finishSessionID = sessionID

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendFinalStaticFrameIfNeeded()

            guard let writer = self.assetWriter,
                  let videoInput = self.videoInput,
                  let url = self.outputURL else {
                self.cleanup()
                self.showSaveFailure(reason: error.map(Self.saveFailureReason) ?? "the recording ended before it could start")
                return
            }

            // No video frame ever opened the writer session, so finishWriting would
            // fault. Report the real reason instead of a generic save failure.
            guard self.firstPresentationTime != nil else {
                writer.cancelWriting()
                self.cleanup()
                self.showSaveFailure(reason: error.map(Self.saveFailureReason) ?? "no frames were captured")
                return
            }

            videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.microphoneInput?.markAsFinished()

            let writerBox = AssetWriterBox(writer)
            self.scheduleFinishTimeout(sessionID: sessionID, url: url)
            // Recorded media duration for the trim range, captured before cleanup
            // resets the timing state.
            let recordedDuration = CMTimeGetSeconds(self.lastPresentationTime ?? .zero)
            writer.finishWriting { [weak self] in
                let writerStatus = writerBox.writer.status
                let writerError = writerBox.writer.error
                DispatchQueue.main.async {
                    guard let self, self.finishSessionID == sessionID else { return }
                    self.cancelFinishTimeout()
                    self.cleanup()
                    if let error {
                        self.showSaveFailure(reason: Self.saveFailureReason(error))
                        print("[KRIT] Recording stream error: \(error)")
                    } else if writerStatus == .completed, writerError == nil {
                        ToastWindow.show(message: Self.savedRecordingMessage(for: url), duration: 3.0)
                        // Surface GIF export + trim (C1/C3) now that the MP4 exists.
                        self.uiTestLastFinishOutcome = "saved:\(url.path)"
                        self.lastFinishedRecording = (url, recordedDuration)
                        self.presentResult(url: url, duration: recordedDuration)
                    } else {
                        // Do not clobber a more specific probe (failed append)
                        // already stashed by the audio path.
                        if let writerError, self.uiTestLastStreamError.isEmpty {
                            let ns = writerError as NSError
                            let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " under:\($0.domain)#\($0.code)" } ?? ""
                            self.uiTestLastStreamError = "writer:\(ns.domain)#\(ns.code)\(underlying): \(ns.localizedDescription)"
                        }
                        self.showSaveFailure(reason: writerError.map(Self.saveFailureReason) ?? "the video file could not be written")
                        if let writerError { print("[KRIT] Recording finish failed: \(writerError)") }
                    }
                }
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

    private func beginFinishing() {
        isRecording = false
        isFinishing = true
        dimOverlay?.hide()
        dimOverlay = nil
        hud?.closeHUD()
        hud = nil
    }

    private func scheduleFinishTimeout(sessionID: UUID, url: URL) {
        cancelFinishTimeout()

        let timeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.finishSessionID == sessionID else { return }
                self.assetWriter?.cancelWriting()
                self.cleanup()
                self.showSaveFailure(reason: "the recorder timed out while writing the file")
                print("[KRIT] Recording finish timed out for \(url.path)")
            }
        }
        finishTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func cancelFinishTimeout() {
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
    }

    private func appendFinalStaticFrameIfNeeded() {
        guard let input = videoInput,
              input.isReadyForMoreMediaData,
              let lastSampleBuffer = lastCompleteSampleBuffer,
              let last = lastPresentationTime else { return }
        // Hold the last frame for exactly one extra frame interval in MEDIA time.
        // Deriving this from wall-clock (CACurrentMediaTime - recordingStartedAt)
        // would re-add the full paused duration as a frozen tail (C2 regression).
        let finalPresentationTime = CMTimeAdd(last, frameDuration)
        guard let retimed = Self.copy(sampleBuffer: lastSampleBuffer, presentationTime: finalPresentationTime, duration: frameDuration) else { return }
        _ = input.append(retimed)
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

    private func startMicrophoneCapture(deviceID: String) throws {
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
        let delegate = MicrophoneCaptureDelegate(recordingEngine: self)
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
        if let session = microphoneSession {
            runSessionOffMain(session, start: false)
        }
        microphoneSession = nil
        microphoneOutput = nil
        microphoneDelegate = nil
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

    func trim(url: URL, range: CMTimeRange) {
        let base = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(base) Trimmed.mp4")
        ToastWindow.show(message: "Trimming…")
        Task {
            let asset = AVURLAsset(url: url)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                ToastWindow.show(message: "Could not trim recording.")
                return
            }
            try? FileManager.default.removeItem(at: outURL)
            export.outputURL = outURL
            export.outputFileType = .mp4
            export.timeRange = range
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { continuation.resume() }
            }
            if export.status == .completed {
                ToastWindow.show(message: "Saved trimmed: \(outURL.lastPathComponent)", duration: 3.0)
            } else {
                ToastWindow.show(message: "Could not trim recording.")
                if let error = export.error { print("[KRIT] Trim failed: \(error)") }
            }
        }
    }

    private func cleanup() {
        cancelFinishTimeout()
        stopMicrophoneCapture()
        cameraBubble?.stop()
        cameraBubble = nil
        clickKeyOverlay?.stop()
        clickKeyOverlay = nil
        dimOverlay?.hide()
        dimOverlay = nil
        stream = nil
        streamOutput = nil
        assetWriter = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        outputURL = nil
        resetTimingState()
        recordingStartedAt = 0
        isRecording = false
        isFinishing = false
        hud?.closeHUD()
        hud = nil
        finishSessionID = UUID()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    private func resetTimingState() {
        firstPresentationTime = nil
        lastPresentationTime = nil
        lastAppendedSourceTime = nil
        lastCompleteSampleBuffer = nil
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.removeAll()
        systemAudioAnchor = nil
        microphoneAnchor = nil
        lastSystemAudioOutputTime = nil
        lastMicrophoneOutputTime = nil
    }

    private var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
    }

    private static func videoSettings(width: Int, height: Int, fps: Int, quality: RecordingQuality) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: width, height: height, fps: fps, quality: quality),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoQualityKey: 1.0,
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
    private static func audioCopy(sampleBuffer: CMSampleBuffer, shiftedTo newPresentationTime: CMTime) -> CMSampleBuffer? {
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

    private static func copy(sampleBuffer: CMSampleBuffer, presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration.isValid ? duration : .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        )
        guard status == noErr else { return nil }
        return copied
    }

    nonisolated private static func frameStatus(from rawValue: Any) -> SCFrameStatus? {
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

    nonisolated private static func microphoneLevel(from sampleBuffer: CMSampleBuffer) -> CGFloat {
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

    private static func pixelScale(for filter: SCContentFilter, fallbackScreen screen: NSScreen) -> CGFloat {
        let fallbackScale = max(screen.backingScaleFactor, 1)
        if #available(macOS 14.0, *) {
            return max(CGFloat(filter.pointPixelScale), fallbackScale)
        }
        return fallbackScale
    }

    private static func evenCeil(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
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

    private enum AudioTarget {
        case system
        case microphone
    }

    /// Pairs an audio track's own first-sample PTS with the video session time at
    /// that instant, so the track can be mapped onto the writer timeline without
    /// sharing a clock with the video.
    private struct AudioTrackAnchor {
        let sourceTime: CMTime
        let sessionTime: CMTime
        let pausedAtAnchor: CMTime
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

private enum RecordingQuality: String {
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

private final class AssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    private weak var recordingEngine: RecordingEngine?

    init(recordingEngine: RecordingEngine) {
        self.recordingEngine = recordingEngine
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            recordingEngine?.processScreenSampleBuffer(sampleBuffer)
        case .audio:
            recordingEngine?.processSystemAudioSampleBuffer(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordingEngine?.streamDidStopWithError(error)
    }
}

private final class MicrophoneCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private weak var recordingEngine: RecordingEngine?

    init(recordingEngine: RecordingEngine) {
        self.recordingEngine = recordingEngine
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordingEngine?.processMicrophoneSampleBuffer(sampleBuffer)
    }
}
