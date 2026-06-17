import AVFoundation
import CoreImage
import Foundation

/// Bakes the auto-zoom camera path into an exported video. An
/// `AVMutableVideoComposition` driven by a custom compositor that, per frame,
/// resolves the `CameraState` (AutoFocusEngine) and crops+scales the frame to that
/// zoom. Ported from Snapzy's ZoomCompositor, trimmed to the zoom effect; the
/// background/corner-radius treatment (reusing ScreenshotBackgroundComposer) is a
/// later layer on top of this.
enum ZoomComposer {
    enum ComposerError: Error { case noVideoTrack, exportFailed }

    static func makeVideoComposition(
        for asset: AVAsset,
        segments: [ZoomSegment],
        autoFocusPaths: [UUID: [AutoFocusCameraSample]],
        transitionDuration: TimeInterval = ZoomCalculator.defaultTransitionDuration
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ComposerError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? nominalFPS : 30
        let duration = try await asset.load(.duration)

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

        let instruction = ZoomCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            zooms: segments,
            autoFocusPaths: autoFocusPaths,
            trackID: track.trackID,
            transitionDuration: transitionDuration
        )
        comp.instructions = [instruction]
        comp.customVideoCompositorClass = ZoomVideoCompositor.self
        return comp
    }

    /// Export `url` to `outURL` with the zoom composition applied.
    static func export(
        url: URL,
        to outURL: URL,
        segments: [ZoomSegment],
        autoFocusPaths: [UUID: [AutoFocusCameraSample]],
        transitionDuration: TimeInterval = ZoomCalculator.defaultTransitionDuration
    ) async throws {
        let asset = AVURLAsset(url: url)
        let videoComposition = try await makeVideoComposition(
            for: asset,
            segments: segments,
            autoFocusPaths: autoFocusPaths,
            transitionDuration: transitionDuration
        )
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposerError.exportFailed
        }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? ComposerError.exportFailed
        }
    }
}

/// Carries the zoom plan to the compositor for the whole clip.
final class ZoomCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let zooms: [ZoomSegment]
    let autoFocusPaths: [UUID: [AutoFocusCameraSample]]
    let trackID: CMPersistentTrackID
    let transitionDuration: TimeInterval

    var enablePostProcessing: Bool { true }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    init(
        timeRange: CMTimeRange,
        zooms: [ZoomSegment],
        autoFocusPaths: [UUID: [AutoFocusCameraSample]],
        trackID: CMPersistentTrackID,
        transitionDuration: TimeInterval
    ) {
        self.timeRange = timeRange
        self.zooms = zooms
        self.autoFocusPaths = autoFocusPaths
        self.trackID = trackID
        self.transitionDuration = transitionDuration
        super.init()
    }
}

/// Per-frame zoom: crop to the resolved camera rect and scale back to full frame.
final class ZoomVideoCompositor: NSObject, AVVideoCompositing {
    private let minRenderableZoom: CGFloat = 1.0001

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
    var supportsWideColorSourceFrames: Bool { false }
    var supportsHDRSourceFrames: Bool { false }

    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "com.krit.zoomcompositor")

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in self?.process(request) }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func process(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ZoomCompositionInstruction,
              let sourceBuffer = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finish(with: ZoomComposer.ComposerError.exportFailed)
            return
        }

        let time = CMTimeGetSeconds(request.compositionTime)
        let camera = AutoFocusEngine.resolvedCameraState(
            at: time,
            segments: instruction.zooms,
            autoFocusPaths: instruction.autoFocusPaths,
            transitionDuration: instruction.transitionDuration
        )

        guard camera.zoomLevel > minRenderableZoom,
              let output = applyZoom(to: sourceBuffer, camera: camera) else {
            request.finish(withComposedVideoFrame: sourceBuffer)
            return
        }
        request.finish(withComposedVideoFrame: output)
    }

    private func applyZoom(to sourceBuffer: CVPixelBuffer, camera: CameraState) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: sourceBuffer)
        let extent = image.extent
        let crop = ZoomCalculator.calculateCropRect(
            center: camera.center,
            zoomLevel: camera.zoomLevel,
            frameSize: extent.size
        )
        guard crop.width > 0, crop.height > 0 else { return nil }
        let scaleX = extent.width / crop.width
        let scaleY = extent.height / crop.height
        let zoomed = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let renderContext, let output = renderContext.newPixelBuffer() else { return nil }
        ciContext.render(zoomed, to: output)
        return output
    }
}
