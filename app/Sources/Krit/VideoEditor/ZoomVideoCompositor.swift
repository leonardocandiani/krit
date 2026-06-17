import AVFoundation
import CoreImage
import Foundation
import ImageIO

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
        transitionDuration: TimeInterval = ZoomCalculator.defaultTransitionDuration,
        background: VideoBackgroundOptions = .disabled
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ComposerError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? nominalFPS : 30
        let duration = try await asset.load(.duration)

        let natW = abs(naturalSize.width), natH = abs(naturalSize.height)
        let pad = background.isEnabled ? (background.paddingFraction * natW).rounded() : 0

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: natW + 2 * pad, height: natH + 2 * pad)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

        let instruction = ZoomCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            zooms: segments,
            autoFocusPaths: autoFocusPaths,
            trackID: track.trackID,
            transitionDuration: transitionDuration,
            background: background
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
        transitionDuration: TimeInterval = ZoomCalculator.defaultTransitionDuration,
        timeRange: CMTimeRange? = nil,
        background: VideoBackgroundOptions = .disabled
    ) async throws {
        let asset = AVURLAsset(url: url)
        let videoComposition = try await makeVideoComposition(
            for: asset,
            segments: segments,
            autoFocusPaths: autoFocusPaths,
            transitionDuration: transitionDuration,
            background: background
        )
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposerError.exportFailed
        }
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        // Trim, when requested. Zoom segment times are asset-relative, so they keep
        // aligning even with the output trimmed to a sub-range.
        if let timeRange { export.timeRange = timeRange }

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
    let background: VideoBackgroundOptions

    var enablePostProcessing: Bool { true }
    var containsTweening: Bool { true }
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    init(
        timeRange: CMTimeRange,
        zooms: [ZoomSegment],
        autoFocusPaths: [UUID: [AutoFocusCameraSample]],
        trackID: CMPersistentTrackID,
        transitionDuration: TimeInterval,
        background: VideoBackgroundOptions = .disabled
    ) {
        self.timeRange = timeRange
        self.zooms = zooms
        self.autoFocusPaths = autoFocusPaths
        self.trackID = trackID
        self.transitionDuration = transitionDuration
        self.background = background
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

    // Cached per export instance (render size + background params are constant).
    private var cachedBackdrop: CIImage?
    private var cachedMask: CIImage?

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

        let source = CIImage(cvPixelBuffer: sourceBuffer)
        let zoomed = camera.zoomLevel > minRenderableZoom ? applyZoom(to: source, camera: camera) : source

        if instruction.background.isEnabled, let output = composeBackground(zoomed, background: instruction.background) {
            request.finish(withComposedVideoFrame: output)
            return
        }

        // Zoom-only (or passthrough) path.
        guard camera.zoomLevel > minRenderableZoom,
              let renderContext, let output = renderContext.newPixelBuffer() else {
            request.finish(withComposedVideoFrame: sourceBuffer)
            return
        }
        ciContext.render(zoomed, to: output)
        request.finish(withComposedVideoFrame: output)
    }

    private func applyZoom(to image: CIImage, camera: CameraState) -> CIImage {
        let extent = image.extent
        let crop = ZoomCalculator.calculateCropRect(center: camera.center, zoomLevel: camera.zoomLevel, frameSize: extent.size)
        guard crop.width > 0, crop.height > 0 else { return image }
        let scaleX = extent.width / crop.width
        let scaleY = extent.height / crop.height
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    /// Place the (rounded) video on the gradient backdrop with padding, baked into
    /// a render-size buffer. Snapzy's signature look.
    private func composeBackground(_ video: CIImage, background bg: VideoBackgroundOptions) -> CVPixelBuffer? {
        guard let renderContext, let output = renderContext.newPixelBuffer() else { return nil }
        let renderSize = renderContext.size
        let extent = video.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let padX = (renderSize.width - extent.width) / 2
        let padY = (renderSize.height - extent.height) / 2

        let backdrop = backdropImage(bg, size: renderSize)
        let radius = bg.cornerFraction * min(extent.width, extent.height)
        let rounded = roundCorners(video, radius: radius) ?? video
        let placed = rounded.transformed(by: CGAffineTransform(translationX: padX, y: padY))
        let composite = placed.composited(over: backdrop).cropped(to: CGRect(origin: .zero, size: renderSize))
        ciContext.render(composite, to: output)
        return output
    }

    /// Gradient or wallpaper backdrop at render size (cached per export).
    private func backdropImage(_ bg: VideoBackgroundOptions, size: CGSize) -> CIImage {
        if let cachedBackdrop { return cachedBackdrop }
        let image: CIImage
        switch bg.kind {
        case .wallpaper: image = wallpaperImage(bg, size: size)
        case .gradient:  image = gradientImage(start: bg.startHex, end: bg.endHex, size: size)
        }
        cachedBackdrop = image
        return image
    }

    private func gradientImage(start: String, end: String, size: CGSize) -> CIImage {
        let c0 = ciColor(start), c1 = ciColor(end)
        guard let f = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: c0).cropped(to: CGRect(origin: .zero, size: size))
        }
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: 0, y: size.height), forKey: "inputPoint1")
        f.setValue(c0, forKey: "inputColor0")
        f.setValue(c1, forKey: "inputColor1")
        return (f.outputImage ?? CIImage(color: c0)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Wallpaper scaled aspect-fill to the render size, centered.
    private func wallpaperImage(_ bg: VideoBackgroundOptions, size: CGSize) -> CIImage {
        guard let data = bg.wallpaperData,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return gradientImage(start: bg.startHex, end: bg.endHex, size: size)
        }
        let idx = min(max(bg.wallpaperIndex, 0), max(CGImageSourceGetCount(src) - 1, 0))
        guard let cg = CGImageSourceCreateImageAtIndex(src, idx, nil) else {
            return gradientImage(start: bg.startHex, end: bg.endHex, size: size)
        }
        let base = CIImage(cgImage: cg)
        let ext = base.extent
        guard ext.width > 0, ext.height > 0 else {
            return gradientImage(start: bg.startHex, end: bg.endHex, size: size)
        }
        let scale = max(size.width / ext.width, size.height / ext.height)
        let scaled = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tx = (size.width - ext.width * scale) / 2
        let ty = (size.height - ext.height * scale) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Clip the video to a rounded rect via an alpha mask (CoreGraphics, cached).
    private func roundCorners(_ image: CIImage, radius: CGFloat) -> CIImage? {
        guard radius > 0.5 else { return image }
        let extent = image.extent
        if cachedMask == nil {
            let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
            if let cg = ctx.makeImage() { cachedMask = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y)) }
        }
        guard let mask = cachedMask, let blend = CIFilter(name: "CIBlendWithAlphaMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage
    }

    private func ciColor(_ hex: String) -> CIColor {
        let ns = ScreenshotBackgroundComposer.color(from: hex).usingColorSpace(.sRGB) ?? .black
        return CIColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: 1)
    }
}
