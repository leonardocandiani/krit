import AppKit
import AVFoundation

enum RecordingThumbnailProvider {
    static func thumbnail(for url: URL) async -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: 0, preferredTimescale: 600)

        if let cgImage = try? await generator.image(at: time).image {
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        let fallback = NSImage(systemSymbolName: "film", accessibilityDescription: "Video thumbnail")
            ?? NSImage(size: NSSize(width: 64, height: 64))
        fallback.size = NSSize(width: 64, height: 64)
        return fallback
    }
}
