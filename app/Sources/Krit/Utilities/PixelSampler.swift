import AppKit

/// Reads single pixels out of CGImages as "#RRGGBB" in sRGB. Shared by the
/// screen eyedropper (selection overlay loupe and pick) and the editor's
/// eyedropper tool.
enum PixelSampler {
    /// Renders the target pixel into a 1×1 8-bit sRGB context instead of
    /// poking raw bytes: source images arrive as BGRA/RGBA, 8 or 16 bits per
    /// channel (lockFocus on wide-gamut displays), in the display's color
    /// space; CG normalizes all of that and the hex comes out as the color
    /// would be specified in CSS. `y` counts rows from the TOP of the image.
    static func hex(in image: CGImage, x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        // Offset the draw so the wanted pixel lands on the context's single
        // cell (CG rects are bottom-left; y is top-down image rows).
        ctx.draw(image, in: CGRect(
            x: -CGFloat(x),
            y: -CGFloat(image.height - 1 - y),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }
}
