import CoreGraphics

/// Cheap signal for screenshot-based UI gates. Window capture can return a
/// correctly-sized opaque black bitmap when Screen Recording is unavailable;
/// file size alone cannot distinguish that failure from a rendered window.
enum ScreenshotVisualQuality {
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        let width = 48
        let height = 48
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var darkest = 255
        var lightest = 0
        var opaquePixels = 0
        var luminanceBins = Set<Int>()

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 16 else { continue }
            opaquePixels += 1

            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let luminance = (54 * red + 183 * green + 19 * blue) >> 8
            darkest = min(darkest, luminance)
            lightest = max(lightest, luminance)
            luminanceBins.insert(luminance / 8)
        }

        let enoughCoverage = opaquePixels >= (width * height) / 4
        let enoughContrast = lightest >= 24 && lightest - darkest >= 12
        return enoughCoverage && enoughContrast && luminanceBins.count >= 4
    }
}
