import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Off-main GIF encoder for finished recordings. Reads an MP4 with
/// AVAssetImageGenerator, downsamples the frame rate, downscales to a max
/// dimension, and writes an animated GIF via ImageIO. The 256-color palette
/// quantization is performed by ImageIO itself when the destination UTType is
/// `com.compuserve.gif` (no hand-rolled octree needed). Audio is dropped.
enum GIFEncoder {

    enum GIFEncoderError: Error {
        case noVideoTrack
        case noFrames
        case finalizeFailed
    }

    /// Encodes `videoURL` into an animated GIF at `gifURL`.
    /// - maxDimension: largest side in px; frames downscale to fit (aspect kept).
    /// - targetFPS: GIF frame rate (browsers clamp delays below ~0.06s).
    /// - progress: 0...1, called on whatever actor the caller bounces it to.
    @discardableResult
    static func encode(
        videoURL: URL,
        to gifURL: URL,
        maxDimension: CGFloat = 800,
        targetFPS: Int = 15,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFEncoderError.noVideoTrack
        }

        let sourceFPS = max(Double(try await track.load(.nominalFrameRate)), 1)
        let fps = max(targetFPS, 1)
        let totalSeconds = max(CMTimeGetSeconds(duration), 0)
        guard totalSeconds > 0 else { throw GIFEncoderError.noFrames }

        // Frame-rate downsample: one sample every `spacing` seconds. Capped so a
        // long recording never produces a multi-thousand-frame GIF, but when the
        // clip would exceed the cap at 1/fps, widen the spacing so the GIF still
        // spans the WHOLE recording (slower, never truncated to the first 40s).
        let frameCap = 600
        let spacing = max(1.0 / Double(fps), totalSeconds / Double(frameCap))
        var times: [CMTime] = []
        var t = 0.0
        while t < totalSeconds, times.count < frameCap {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += spacing
        }
        guard !times.isEmpty else { throw GIFEncoderError.noFrames }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: spacing / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: spacing / 2, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

        let gifType = UTType.gif.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            gifType,
            times.count,
            nil
        ) else {
            throw GIFEncoderError.finalizeFailed
        }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProps as CFDictionary)

        // Per-frame delay floored at 0.06s (browsers clamp anything lower).
        let delay = max(spacing, 0.06)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay
            ]
        ]

        var written = 0
        var failed = 0
        // images(for:) is the async sequence available on macOS 13+; it yields
        // each requested time with its CGImage, off the main actor.
        for await result in generator.images(for: times) {
            switch result {
            case let .success(_, image, _):
                let scaled = downscale(image, maxDimension: maxDimension)
                CGImageDestinationAddImage(destination, scaled, frameProps as CFDictionary)
                written += 1
                progress?(Double(written) / Double(times.count))
            case let .failure(_, error):
                failed += 1
                print("[KRIT] GIF frame generation failed: \(error)")
            @unknown default:
                failed += 1
            }
        }

        guard written > 0 else { throw GIFEncoderError.noFrames }
        // Bail rather than finalize a half-empty GIF: if more than ~25% of frames
        // failed the result would be visibly broken yet still "succeed".
        guard failed * 4 <= written else { throw GIFEncoderError.noFrames }
        guard CGImageDestinationFinalize(destination) else { throw GIFEncoderError.finalizeFailed }
        return gifURL
    }

    /// Downscale preserving aspect, snapping to even dimensions. The generator's
    /// maximumSize already bounds the box; this guarantees a clean even-pixel
    /// raster so encoders never pad an odd row.
    private static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1, maxDimension / max(w, h))
        let targetW = max(2, evenDown(Int((w * scale).rounded())))
        let targetH = max(2, evenDown(Int((h * scale).rounded())))
        if targetW == image.width, targetH == image.height { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return context.makeImage() ?? image
    }

    private static func evenDown(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value - 1
    }
}
