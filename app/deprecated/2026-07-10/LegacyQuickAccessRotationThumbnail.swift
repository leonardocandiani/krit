import AppKit

// Deprecated on 2026-07-10.
//
// Rotation persistence moved into HistoryManager and HistoryDiskStore so raw and
// presented representations cannot diverge. Thumbnail generation now uses the
// capture artifact boundary. This helper is retained only as migration history
// and is outside the Swift package target.

enum LegacyQuickAccessRotationThumbnail {
    static func downsampled(_ cg: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cg }
        let scale = maxDimension / longest
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}
