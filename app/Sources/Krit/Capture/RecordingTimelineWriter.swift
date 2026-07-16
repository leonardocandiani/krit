import AVFoundation
import CoreMedia

/// Owns the media timeline for one screen recording. ScreenCaptureKit and
/// AVCapture deliver samples on the same serial queue, so every PTS decision,
/// media append, and finish operation stays off the MainActor and in arrival order.
final class RecordingTimelineWriter: @unchecked Sendable {
    enum Track: String {
        case video
        case systemAudio
        case microphone
    }

    enum FinishResult {
        case completed(duration: TimeInterval)
        case noVideo
        case failed(Error)
        case timedOut
    }

    private struct AudioTrackAnchor {
        let sourceTime: CMTime
        let sessionTime: CMTime
        let pausedAtAnchor: CMTime
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let queue: DispatchQueue
    private let frameDuration: CMTime
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueID = UUID()

    private var isAcceptingSamples = true
    private var isFinishing = false
    private var didFinish = false
    private var isPaused = false
    private var awaitingResumeVideo = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var lastObservedVideoSourceTime: CMTime?
    /// The most recent frame accepted by the writer. A paused frame is deliberately
    /// not eligible here because finish extends the visible timeline with this image.
    private var lastCompleteSampleBuffer: CMSampleBuffer?
    private var pausedDuration: CMTime = .zero
    private var pauseStartedSourceTime: CMTime?
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    private var systemAudioAnchor: AudioTrackAnchor?
    private var microphoneAnchor: AudioTrackAnchor?
    private var lastSystemAudioOutputTime: CMTime?
    private var lastMicrophoneOutputTime: CMTime?
    private var diagnosticEntries: [String] = []
    private var suppressedDiagnosticCount = 0
    private var finishCompletion: (@MainActor (FinishResult) -> Void)?
    private var finishTimeout: DispatchWorkItem?

    private static let maximumPreRollDuration = CMTime(value: 1, timescale: 2)
    private static let maximumPreRollBuffers = 128
    private static let maximumDiagnosticEntries = 12

    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?,
        queue: DispatchQueue,
        frameDuration: CMTime
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        self.queue = queue
        self.frameDuration = frameDuration
        queue.setSpecific(key: queueKey, value: queueID)
    }

    /// Must be invoked by the media callback queue. No sample crosses to the
    /// MainActor, which keeps capture cadence independent from AppKit work.
    func append(_ sampleBuffer: CMSampleBuffer, from track: Track) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isAcceptingSamples, !isFinishing,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch track {
        case .video:
            appendVideo(sampleBuffer)
        case .systemAudio, .microphone:
            appendAudio(sampleBuffer, to: track)
        }
    }

    /// A pause command is ordered after all callbacks already accepted by the
    /// queue. This is a rare control hop, unlike the per-frame hot path.
    func togglePause() -> Bool? {
        syncOnQueue {
            guard !isFinishing, firstPresentationTime != nil else { return nil }
            isPaused.toggle()
            if isPaused {
                if pauseStartedSourceTime == nil {
                    pauseStartedSourceTime = lastObservedVideoSourceTime
                }
                awaitingResumeVideo = false
            } else {
                // Video is the timeline master. Audio arriving first after resume
                // must wait until the next video frame has folded the pause gap.
                awaitingResumeVideo = true
            }
            return isPaused
        }
    }

    func finish(
        timeout: TimeInterval = 10,
        completion: @escaping @MainActor (FinishResult) -> Void
    ) {
        queue.async { [self] in
            guard !isFinishing, !didFinish else { return }
            isFinishing = true
            isAcceptingSamples = false
            finishCompletion = completion

            guard lastPresentationTime != nil else {
                writer.cancelWriting()
                complete(.noVideo)
                return
            }

            appendFinalStaticFrameIfNeeded()
            videoInput.markAsFinished()
            systemAudioInput?.markAsFinished()
            microphoneInput?.markAsFinished()

            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self, !self.didFinish else { return }
                if self.writer.status == .completed, self.writer.error == nil {
                    self.complete(.completed(duration: CMTimeGetSeconds(self.lastPresentationTime ?? .zero)))
                } else if self.writer.status == .failed {
                    self.complete(.failed(self.writer.error ?? RecordingTimelineError.writerDidNotComplete))
                } else {
                    self.writer.cancelWriting()
                    self.complete(.timedOut)
                }
            }
            finishTimeout = timeoutWork
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard !self.didFinish else { return }
                    if self.writer.status == .completed, self.writer.error == nil {
                        self.complete(.completed(duration: CMTimeGetSeconds(self.lastPresentationTime ?? .zero)))
                    } else {
                        self.complete(.failed(self.writer.error ?? RecordingTimelineError.writerDidNotComplete))
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !didFinish else { return }
            isAcceptingSamples = false
            isFinishing = true
            finishTimeout?.cancel()
            writer.cancelWriting()
            didFinish = true
            finishCompletion = nil
            clearPendingSamples()
        }
    }

    func diagnosticsSummary() -> String {
        syncOnQueue {
            guard !diagnosticEntries.isEmpty else { return "" }
            let summary = diagnosticEntries.joined(separator: " | ")
            guard suppressedDiagnosticCount > 0 else { return summary }
            return "\(summary) | +\(suppressedDiagnosticCount) more"
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let sourcePresentationTime = sampleBuffer.presentationTimeStamp
        guard sourcePresentationTime.isValid else { return }
        lastObservedVideoSourceTime = sourcePresentationTime

        if isPaused {
            if pauseStartedSourceTime == nil { pauseStartedSourceTime = sourcePresentationTime }
            return
        }

        if let pauseStart = pauseStartedSourceTime {
            pausedDuration = CMTimeAdd(pausedDuration, CMTimeSubtract(sourcePresentationTime, pauseStart))
            pauseStartedSourceTime = nil
        }
        awaitingResumeVideo = false

        if firstPresentationTime == nil {
            firstPresentationTime = sourcePresentationTime
            writer.startSession(atSourceTime: .zero)
            flushPendingAudioSamples()
        }

        guard let firstPresentationTime else { return }
        let presentationTime = CMTimeSubtract(
            CMTimeSubtract(sourcePresentationTime, firstPresentationTime),
            pausedDuration
        )
        if let lastPresentationTime, presentationTime <= lastPresentationTime {
            appendDiagnostic("video PTS did not advance")
            return
        }
        guard presentationTime >= .zero, videoInput.isReadyForMoreMediaData,
              let retimed = copyVideo(sampleBuffer, presentationTime: presentationTime, duration: frameDuration) else { return }

        if videoInput.append(retimed) {
            lastPresentationTime = presentationTime
            lastCompleteSampleBuffer = sampleBuffer
        } else if let error = writer.error {
            appendDiagnostic("video append failed: \(error.localizedDescription)")
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to track: Track) {
        guard !isPaused, !awaitingResumeVideo else { return }
        guard firstPresentationTime != nil else {
            switch track {
            case .systemAudio:
                pendingSystemAudioSamples.append(sampleBuffer)
                trimPreRoll(&pendingSystemAudioSamples)
            case .microphone:
                pendingMicrophoneSamples.append(sampleBuffer)
                trimPreRoll(&pendingMicrophoneSamples)
            case .video:
                return
            }
            return
        }
        appendReadyAudio(sampleBuffer, to: track)
    }

    private func flushPendingAudioSamples() {
        pendingSystemAudioSamples.forEach { appendReadyAudio($0, to: .systemAudio) }
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.forEach { appendReadyAudio($0, to: .microphone) }
        pendingMicrophoneSamples.removeAll()
    }

    private func trimPreRoll(_ samples: inout [CMSampleBuffer]) {
        while samples.count > Self.maximumPreRollBuffers {
            samples.removeFirst()
        }
        guard let newest = samples.last?.presentationTimeStamp, newest.isValid else { return }
        while let oldest = samples.first?.presentationTimeStamp,
              oldest.isValid,
              CMTimeCompare(CMTimeSubtract(newest, oldest), Self.maximumPreRollDuration) > 0 {
            samples.removeFirst()
        }
    }

    private func appendReadyAudio(_ sampleBuffer: CMSampleBuffer, to track: Track) {
        let input: AVAssetWriterInput? = switch track {
        case .systemAudio: systemAudioInput
        case .microphone: microphoneInput
        case .video: nil
        }
        guard let input, input.isReadyForMoreMediaData,
              let presentationTime = sessionTime(for: sampleBuffer, track: track) else { return }

        switch track {
        case .systemAudio:
            if let lastSystemAudioOutputTime, presentationTime <= lastSystemAudioOutputTime { return }
        case .microphone:
            if let lastMicrophoneOutputTime, presentationTime <= lastMicrophoneOutputTime { return }
        case .video:
            return
        }

        guard let retimed = copyAudio(sampleBuffer, presentationTime: presentationTime) else {
            appendDiagnostic("audio timing copy failed: \(track.rawValue)")
            return
        }
        guard input.append(retimed) else {
            if let error = writer.error {
                appendDiagnostic("audio append failed \(track.rawValue): \(error.localizedDescription)")
            }
            return
        }

        switch track {
        case .systemAudio: lastSystemAudioOutputTime = presentationTime
        case .microphone: lastMicrophoneOutputTime = presentationTime
        case .video: break
        }
    }

    private func sessionTime(for sampleBuffer: CMSampleBuffer, track: Track) -> CMTime? {
        guard firstPresentationTime != nil else { return nil }
        let sourceTime = sampleBuffer.presentationTimeStamp
        guard sourceTime.isValid else { return nil }

        let anchor: AudioTrackAnchor
        switch track {
        case .systemAudio:
            if let systemAudioAnchor {
                anchor = systemAudioAnchor
            } else {
                let created = AudioTrackAnchor(
                    sourceTime: sourceTime,
                    sessionTime: currentVideoSessionTime,
                    pausedAtAnchor: pausedDuration
                )
                systemAudioAnchor = created
                anchor = created
            }
        case .microphone:
            if let microphoneAnchor {
                anchor = microphoneAnchor
            } else {
                let created = AudioTrackAnchor(
                    sourceTime: sourceTime,
                    sessionTime: currentVideoSessionTime,
                    pausedAtAnchor: pausedDuration
                )
                microphoneAnchor = created
                anchor = created
            }
        case .video:
            return nil
        }

        let elapsed = CMTimeSubtract(sourceTime, anchor.sourceTime)
        let pauseSinceAnchor = CMTimeSubtract(pausedDuration, anchor.pausedAtAnchor)
        let mapped = CMTimeSubtract(CMTimeAdd(anchor.sessionTime, elapsed), pauseSinceAnchor)
        return mapped >= .zero ? mapped : .zero
    }

    private var currentVideoSessionTime: CMTime {
        lastPresentationTime ?? .zero
    }

    private func appendFinalStaticFrameIfNeeded() {
        guard videoInput.isReadyForMoreMediaData,
              let lastCompleteSampleBuffer,
              let lastPresentationTime else { return }
        let finalPresentationTime = CMTimeAdd(lastPresentationTime, frameDuration)
        guard let retimed = copyVideo(
            lastCompleteSampleBuffer,
            presentationTime: finalPresentationTime,
            duration: frameDuration
        ) else { return }
        if videoInput.append(retimed) {
            self.lastPresentationTime = finalPresentationTime
        }
    }

    private func complete(_ result: FinishResult) {
        guard !didFinish else { return }
        didFinish = true
        finishTimeout?.cancel()
        finishTimeout = nil
        clearPendingSamples()
        let completion = finishCompletion
        finishCompletion = nil
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func clearPendingSamples() {
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.removeAll()
    }

    private func appendDiagnostic(_ value: String) {
        guard diagnosticEntries.count < Self.maximumDiagnosticEntries else {
            suppressedDiagnosticCount += 1
            return
        }
        diagnosticEntries.append(value)
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueID {
            return body()
        }
        return queue.sync(execute: body)
    }

    private func copyVideo(
        _ sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
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
        return status == noErr ? copied : nil
    }

    private func copyAudio(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard originalPTS.isValid, presentationTime.isValid else { return nil }
        let delta = CMTimeSubtract(presentationTime, originalPTS)

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        )
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        ) == noErr else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, delta)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, delta)
            }
        }
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copied
        )
        return status == noErr ? copied : nil
    }
}

private enum RecordingTimelineError: LocalizedError {
    case writerDidNotComplete

    var errorDescription: String? {
        "The media writer did not complete the recording."
    }
}
