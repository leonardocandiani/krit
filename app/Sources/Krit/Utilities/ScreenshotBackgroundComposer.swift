import AppKit
import CoreImage

// 9-position grid used to place the screenshot inside an aspect-ratio canvas.
enum BackgroundAlignment: String, Codable, CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    // Unit anchor in [0,1] with (0,0) bottom-left, (1,1) top-right (Core Graphics coords).
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 1)
        case .top: return CGPoint(x: 0.5, y: 1)
        case .topRight: return CGPoint(x: 1, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 0)
        case .bottom: return CGPoint(x: 0.5, y: 0)
        case .bottomRight: return CGPoint(x: 1, y: 0)
        }
    }
}

enum BackgroundAspectPreset: String, Codable, CaseIterable {
    case ratio16x9
    case ratio4x3
    case ratio1x1
    case ratio5x4
    case ratio9x16

    var displayName: String {
        switch self {
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio1x1: return "1:1"
        case .ratio5x4: return "5:4"
        case .ratio9x16: return "9:16"
        }
    }

    // width / height
    var ratio: CGFloat {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio1x1: return 1.0
        case .ratio5x4: return 5.0 / 4.0
        case .ratio9x16: return 9.0 / 16.0
        }
    }
}

struct ScreenshotBackgroundOptions: Equatable, Codable {
    enum Style: String, Codable {
        case solid
        case gradient
        case image
        case blurredImage
    }

    var isEnabled: Bool
    var style: Style
    var presetName: String
    var colorHex: String
    var gradientStartHex: String
    var gradientEndHex: String
    var accentHexes: [String]
    var customImageData: Data?
    var customImageName: String?
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: CGFloat
    // Multiplier layered on top of `shadow` so the sidebar can tune drop-shadow weight
    // independently. Default 1 reproduces the legacy look.
    var shadowStrength: CGFloat = 1
    // Inner margin that shrinks the screenshot inside its padded slot, leaving room
    // around the shadow frame. 0 keeps the legacy layout.
    var inset: CGFloat = 0
    // Gaussian radius used by the .blurredImage style. The sidebar's "Blurred"
    // tiles map light/medium/strong onto 10/22/40. Defaulted so the memberwise
    // init and every existing call site keep compiling unchanged.
    var blurIntensity: CGFloat = 18
    var alignment: BackgroundAlignment = .center
    var aspectPreset: BackgroundAspectPreset? = nil
    // True when the .image background means "the desktop wallpaper", not a fixed
    // picture: applying it resolves the wallpaper of the screen it lands on NOW
    // instead of replaying whatever customImageData was embedded when the options
    // were saved (a template created at home must not paint the home wallpaper
    // at work). Optional so templates saved before this field decode unchanged.
    var tracksDesktopWallpaper: Bool? = nil

    /// A copy with the desktop-tracking wallpaper resolved against `screen`.
    /// No-op for fixed backgrounds; keeps the embedded image as a fallback when
    /// the live wallpaper cannot be read.
    @MainActor
    func resolvingDesktopWallpaper(for screen: NSScreen?) -> ScreenshotBackgroundOptions {
        guard tracksDesktopWallpaper == true else { return self }
        var resolved = self
        if let data = SystemWallpaperSource.currentDesktopBackgroundData(for: screen) {
            resolved.customImageData = data
            resolved.customImageName = "Current wallpaper"
        }
        return resolved
    }

    // Curated mesh-gradient palettes. Each is a deep-to-bright base plus a few
    // harmonious bloom accents (analogous or one tasteful complement), tuned so
    // the screen-blended blooms glow without muddying. One source of truth: the
    // sidebar gradient grid and the editor popover both read this list.
    static let imagePresets: [ScreenshotBackgroundImagePreset] = [
        // Warm: deep plum base lifting into coral. The brand default.
        .init(name: "Sunset Coral",  startHex: "#1f0a22", endHex: "#ff8f6b", accentHexes: ["#ff6f8f", "#ffab6b", "#c0507f"]),
        // Cool aurora: midnight indigo with teal and violet light from above.
        .init(name: "Aurora",        startHex: "#0a1030", endHex: "#4f8fe0", accentHexes: ["#2ee6c0", "#8f5cff", "#3f7cff"]),
        // Deep ocean blue, a calm corporate-clean duotone.
        .init(name: "Mariner",       startHex: "#061a3a", endHex: "#4f9fe6", accentHexes: ["#27c8e0", "#3a7eff", "#7fd0ff"]),
        // Cool teal/green glass, fresh without going neon.
        .init(name: "Mint Glass",    startHex: "#04231f", endHex: "#5fe0bb", accentHexes: ["#34d6b6", "#b6ffe0", "#2aa890"]),
        // Warm amber dusk, golden light over a deep umber base (no mud).
        .init(name: "Golden Hour",   startHex: "#2a1206", endHex: "#f0a84a", accentHexes: ["#ff7e4a", "#ffd98f", "#e0606a"]),
        // Soft lavender haze, pastel violet with a pink kiss.
        .init(name: "Lavender Haze", startHex: "#1a1236", endHex: "#cfa8ff", accentHexes: ["#b48fff", "#ffb0e0", "#8f6fe0"]),
        // Rose quartz, warm pink with a peach undertone.
        .init(name: "Rose Quartz",   startHex: "#2a0e22", endHex: "#ffb6c8", accentHexes: ["#ff86a8", "#ffd0c0", "#d96f97"]),
        // Graphite mono, cool charcoal lifting into pewter, fully neutral.
        .init(name: "Graphite",      startHex: "#0c0e14", endHex: "#3e4658", accentHexes: ["#5a6480", "#aab4cc", "#46506a"]),
        // Bright sky/ice cyan, crisp and airy.
        .init(name: "Tahoe Ice",     startHex: "#052836", endHex: "#7fd6ec", accentHexes: ["#3fb6d6", "#cdf2ff", "#4f9fd0"]),
        // Warm peach, soft coral-to-cream sunrise.
        .init(name: "Peach Fizz",    startHex: "#2a0f10", endHex: "#ffb89a", accentHexes: ["#ff8a6a", "#ffd6b8", "#e07a5f"]),
        // Ultraviolet, refined magenta/purple instead of harsh neon.
        .init(name: "Ultraviolet",   startHex: "#150428", endHex: "#a86bff", accentHexes: ["#7a4fff", "#ff7ad6", "#8f5fe0"]),
        // Emerald, deep forest base into a clean jade.
        .init(name: "Emerald",       startHex: "#042a1e", endHex: "#3fb886", accentHexes: ["#26d6b0", "#b6e85c", "#2fae7a"]),
        // Sandstone, warm terracotta over a deep clay base.
        .init(name: "Sandstone",     startHex: "#231210", endHex: "#d99a6e", accentHexes: ["#e0b35c", "#d97a6a", "#f0d2b0"]),
        // Cobalt dream, electric blue with a soft periwinkle lift.
        .init(name: "Cobalt Dream",  startHex: "#06112e", endHex: "#5a72f0", accentHexes: ["#3f5fff", "#9a7cff", "#aebcff"]),
        // Flamingo, warm pink-coral duotone with a hint of gold.
        .init(name: "Flamingo",      startHex: "#28091f", endHex: "#ff9ab0", accentHexes: ["#ff6f97", "#ffba8a", "#d96f8f"]),
        // Nightfall, near-black indigo with a faint blue glow. Dramatic, clean.
        .init(name: "Nightfall",     startHex: "#06070f", endHex: "#28335c", accentHexes: ["#3f4a86", "#5a6fc0", "#2a3360"]),
        // Sage, muted desaturated green, calm and editorial.
        .init(name: "Sage",          startHex: "#141d16", endHex: "#a8c2a0", accentHexes: ["#7fa078", "#d2e0c8", "#6a8a66"]),
        // Mono cream, near-white warm paper for light layouts.
        .init(name: "Mono Cream",    startHex: "#faf7f2", endHex: "#e6dfd2", accentHexes: ["#efe7d8", "#f5f0e8", "#ddd2c0"])
    ]

    static let editorDefault = ScreenshotBackgroundOptions(
        isEnabled: false,
        style: .gradient,
        // Default to the brand "Sunset Coral" palette so enabling a background
        // (or switching to the image style) always lands on a real, polished preset.
        presetName: imagePresets[0].name,
        colorHex: "#f4eadb",
        gradientStartHex: imagePresets[0].startHex,
        gradientEndHex: imagePresets[0].endHex,
        accentHexes: imagePresets[0].accentHexes,
        customImageData: nil,
        customImageName: nil,
        padding: 72,
        cornerRadius: 18,
        // Tuned so the print lifts off the background with real depth out of the
        // box, no slider needed. Pairs with the canvas-proportional drawShadow.
        shadow: 0.55
    )
}

struct ScreenshotBackgroundImagePreset: Equatable {
    let name: String
    let startHex: String
    let endHex: String
    let accentHexes: [String]
}

enum ScreenshotBackgroundComposer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Point-size of the composed canvas for `image` under `options`, honoring
    /// inset, padding and the aspect preset exactly as `composeIfNeeded` does.
    /// The editor sizes its canvas frame from this so the flattened export never
    /// stretches the art or knocks annotations out of registration (E1/E2).
    static func outputPointSize(for imageSize: NSSize, options: ScreenshotBackgroundOptions) -> NSSize {
        guard options.isEnabled, imageSize.width > 0, imageSize.height > 0 else { return imageSize }
        let padding = clamped(options.padding, min: 0, max: 240)
        // Inset does NOT change the canvas: the padded frame is derived from the
        // ORIGINAL size and stays put while the shot floats smaller inside it.
        // (It used to shrink both, the whole composition imploded as you dragged.)
        let paddedSize = NSSize(
            width: imageSize.width + padding * 2,
            height: imageSize.height + padding * 2
        )
        return canvasSize(for: paddedSize, aspectPreset: options.aspectPreset)
    }

    /// Aspect-preserving inset: the shot shrinks uniformly (its SHORT side loses
    /// `inset` per edge) and never distorts. The old per-axis subtraction changed
    /// the aspect ratio (600×400 at inset 100 became 400×200, visibly stretched).
    private static func insetShotSize(source: NSSize, inset: CGFloat) -> NSSize {
        let minDim = Swift.min(source.width, source.height)
        guard minDim > 0, inset > 0 else { return source }
        let s = Swift.max(0.2, (minDim - 2 * inset) / minDim)
        return NSSize(width: source.width * s, height: source.height * s)
    }

    /// Uniform ring thickness (in render/canvas space) for the inset frame. The
    /// `inset` is expressed in source points; we map it into the space the shrunk
    /// shot actually occupies so the colored border has the same visual weight the
    /// user dialed in, regardless of the export scale or aspect.
    private static func insetBorderWidth(inset: CGFloat, imageRect: CGRect, imagePointSize: NSSize) -> CGFloat {
        guard inset > 0 else { return 0 }
        let shotMin = Swift.min(imagePointSize.width, imagePointSize.height)
        guard shotMin > 0 else { return 0 }
        let renderMin = Swift.min(imageRect.width, imageRect.height)
        return inset * (renderMin / shotMin)
    }

    static func composeIfNeeded(_ image: NSImage, options: ScreenshotBackgroundOptions) -> NSImage {
        guard options.isEnabled else { return image }
        guard let source = image.bestCGImage else { return image }

        let sourcePointSize = image.size
        guard sourcePointSize.width > 0, sourcePointSize.height > 0 else { return image }

        let scale = max(
            CGFloat(source.width) / sourcePointSize.width,
            CGFloat(source.height) / sourcePointSize.height,
            1
        )
        let padding = clamped(options.padding, min: 0, max: 240)
        let inset = clamped(options.inset, min: 0, max: 240)

        // Aspect-preserving inset: the shot floats smaller inside a STABLE padded
        // frame derived from the original size (same math as outputPointSize).
        let imagePointSize = insetShotSize(source: sourcePointSize, inset: inset)
        let paddedSize = NSSize(
            width: sourcePointSize.width + padding * 2,
            height: sourcePointSize.height + padding * 2
        )

        // Canvas size: either the padded box, or the smallest aspect-ratio rect that
        // contains it when an aspect preset is selected.
        let outputPointSize = canvasSize(for: paddedSize, aspectPreset: options.aspectPreset)

        let pixelWidth = max(1, Int(ceil(outputPointSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(outputPointSize.height * scale)))

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)

        let outputRect = CGRect(origin: .zero, size: outputPointSize)
        // Pass the screenshot so the .blurredImage style can use it as its blur
        // source when no wallpaper is chosen (CleanShot's default print-blur look).
        drawBackground(in: context, rect: outputRect, options: options, sourceImage: source)

        // Single source of slot geometry: the exact rect the screenshot is drawn
        // into, computed in bottom-left CG space (this context is NOT flipped) and
        // pixel-snapped at the render scale. `imageSlotRect` returns the SAME rect
        // in flipped (top-left) canvas points so blur/pixelate and the editor map
        // their regions against where the art actually landed, one math, two
        // consumers, no drift with inset/alignment/aspect.
        let imageRect = slotRect(
            imagePointSize: imagePointSize,
            padding: padding,
            canvasSize: outputPointSize,
            alignment: options.alignment,
            snapScale: scale,
            flipped: false
        )
        // Corners scale down with the inset shrink so a small floating shot keeps
        // proportional rounding instead of cookie-cutter corners.
        let shrink = imagePointSize.width / Swift.max(sourcePointSize.width, 1)
        let radius = cornerRadius(for: imageRect, options: options, shrink: shrink)

        // Inset border (CleanShot): the revealed ring around the shrunk shot is a
        // frame painted with the print's dominant color, sharing the OUTER slot
        // corner radius. The shot floats centered inside it. The whole card (frame
        // + shot) is what casts the shadow, so the border reads as part of the print.
        let border = insetBorderWidth(
            inset: inset, imageRect: imageRect, imagePointSize: imagePointSize
        )
        let outerRect = border > 0
            ? imageRect.insetBy(dx: -border, dy: -border)
            : imageRect
        let outerRadius = border > 0
            ? cornerRadius(for: outerRect, options: options, shrink: 1)
            : radius

        let shadowIntensity = clamped(options.shadow, min: 0, max: 1) * clamped(options.shadowStrength, min: 0, max: 3)
        drawShadow(in: context, container: outputRect, rect: outerRect, radius: outerRadius, intensity: shadowIntensity)

        if border > 0 {
            // Fill the outer rounded rect with the dominant color, then the shot is
            // clipped to its own rounded rect on top, leaving the colored ring.
            let frameColor = medianBorderColor(of: source) ?? fallbackColor
            context.saveGState()
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.addPath(roundedPath(for: outerRect, radius: outerRadius))
            context.setFillColor(frameColor.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.addPath(roundedPath(for: imageRect, radius: radius))
        context.clip()
        context.draw(source, in: imageRect)
        context.restoreGState()
        // Hairline goes on the OUTER edge of the framed card (or the shot itself when
        // there is no inset frame) so the whole unit gets the crisp rim.
        drawEdgeStroke(in: context, rect: outerRect, radius: outerRadius, scale: scale)

        guard let composed = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: composed)
        rep.size = outputPointSize
        let output = NSImage(size: outputPointSize)
        output.addRepresentation(rep)
        return output
    }

    static func previewImage(options: ScreenshotBackgroundOptions, size: NSSize, scale: CGFloat = 2) -> NSImage {
        let renderScale = max(scale, 1)
        let pixelWidth = max(1, Int(ceil(size.width * renderScale)))
        let pixelHeight = max(1, Int(ceil(size.height * renderScale)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        context.scaleBy(x: renderScale, y: renderScale)
        context.interpolationQuality = .high
        drawBackground(in: context, rect: CGRect(origin: .zero, size: size), options: options)

        guard let preview = context.makeImage() else { return NSImage(size: size) }
        let rep = NSBitmapImageRep(cgImage: preview)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Live preview for the sidebar "Blurred" tiles: renders the sharp background
    /// described by `options` (a .blurredImage style previews its underlying image
    /// source) at thumbnail size, then blurs it with a radius scaled DOWN to that
    /// tiny canvas, the full-resolution radius would wash a ~40 pt tile to a flat
    /// color and the three levels would look identical.
    static func blurredPreviewImage(options: ScreenshotBackgroundOptions, blurIntensity: CGFloat, size: NSSize, scale: CGFloat = 2) -> NSImage {
        var sharp = options
        sharp.isEnabled = true
        if sharp.style == .blurredImage { sharp.style = .image }
        let base = previewImage(options: sharp, size: size, scale: scale)
        guard let cg = base.bestCGImage else { return base }
        // Map the canvas-space radius into thumbnail space; /320 keeps 10/22/40
        // readable as light/medium/strong on an ~80 px tile.
        let radius = max(0.5, blurIntensity * CGFloat(cg.width) / 320)
        guard let blurred = gaussianBlurred(cg, radius: radius) else { return base }
        let rep = NSBitmapImageRep(cgImage: blurred)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // Reorganizes the LAYOUT around the print (padding, inset, shadow, corners) into
    // harmonious values for the shot's size and aspect. It deliberately leaves the
    // background untouched, no style, color, gradient or image change, so the user's
    // chosen backdrop stays exactly as picked. This is "balance the framing", not
    // "recolor the background".
    static func autoBalancedOptions(for image: NSImage, base: ScreenshotBackgroundOptions) -> ScreenshotBackgroundOptions {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return base }

        var result = base
        let minDim = Swift.min(size.width, size.height)
        let maxDim = Swift.max(size.width, size.height)

        // Padding proportional to the shot's short side, framed within the slider
        // range so a tiny shot is not swallowed and a huge one is not cramped.
        result.padding = clamped(minDim * 0.10, min: 32, max: 160)

        // Aspect drives how lopsided the frame feels: a wide/tall shot gets a touch
        // more inset to settle it; a near-square one keeps a clean, minimal frame.
        let aspect = maxDim / minDim
        let insetTarget = aspect > 1.6 ? minDim * 0.035 : minDim * 0.02
        result.inset = clamped(insetTarget, min: 0, max: 64)

        // Corners scale with the short side for proportional rounding.
        result.cornerRadius = clamped(minDim * 0.018, min: 8, max: 28)

        // A balanced, perceptible drop shadow that reads on any backdrop.
        result.shadow = 0.42
        result.shadowStrength = 1
        return result
    }

    // `sourceImage` is the screenshot being edited. It is only consulted by the
    // .blurredImage style as its fallback blur source (CleanShot's default look:
    // the print itself, softly blurred) when no wallpaper/custom image is chosen.
    // The preview paths pass nil, so the sidebar tiles keep previewing the preset.
    // The generated background carries NO vignette: the dono was explicit that the
    // background must not have a shadow on its own edges.
    private static func drawBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions, sourceImage: CGImage? = nil) {
        if options.style == .blurredImage {
            drawBlurredImageBackground(in: context, rect: rect, options: options, sourceImage: sourceImage)
            return
        }

        if options.style == .image {
            drawImageBackground(in: context, rect: rect, options: options)
            return
        }

        if options.style == .gradient {
            let start = color(from: options.gradientStartHex)
            let end = color(from: options.gradientEndHex)
            let accents = options.accentHexes.isEmpty ? [end, start] : options.accentHexes.map(color(from:))
            drawMesh(in: context, rect: rect, start: start, end: end, accents: accents)
            return
        }

        context.setFillColor(color(from: options.colorHex).cgColor)
        context.fill(rect)
    }

    private static func drawImageBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions) {
        if let data = options.customImageData,
           let image = NSImage(data: data),
           let cgImage = image.bestCGImage {
            context.draw(cgImage, in: aspectFillRect(for: CGSize(width: cgImage.width, height: cgImage.height), in: rect))
            return
        }

        let preset = ScreenshotBackgroundOptions.imagePresets.first { $0.name == options.presetName }
            ?? ScreenshotBackgroundOptions.imagePresets[0]
        drawPresetImageBackground(in: context, rect: rect, preset: preset)
    }

    private static func drawBlurredImageBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions, sourceImage: CGImage? = nil) {
        let source: CGImage?
        if let data = options.customImageData,
           let image = NSImage(data: data),
           let cgImage = image.bestCGImage {
            source = cgImage
        } else if let sourceImage {
            // CleanShot's default: with no wallpaper picked, blur the screenshot
            // itself so the print floats over a soft, on-brand version of its own
            // content instead of an unrelated preset.
            source = sourceImage
        } else {
            // Render the preset image into a backing bitmap, then blur it.
            let preset = ScreenshotBackgroundOptions.imagePresets.first { $0.name == options.presetName }
                ?? ScreenshotBackgroundOptions.imagePresets[0]
            source = renderedPresetImage(preset: preset, size: rect.size)
        }

        let radius = clamped(options.blurIntensity, min: 0, max: 100)
        guard let cg = source, let blurred = gaussianBlurred(cg, radius: radius) else {
            // Fall back to the non-blurred path so we never paint nothing.
            drawImageBackground(in: context, rect: rect, options: options)
            return
        }
        context.draw(blurred, in: aspectFillRect(for: CGSize(width: blurred.width, height: blurred.height), in: rect))
    }

    private static func renderedPresetImage(preset: ScreenshotBackgroundImagePreset, size: CGSize) -> CGImage? {
        let pixelWidth = max(1, Int(size.width))
        let pixelHeight = max(1, Int(size.height))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        drawPresetImageBackground(in: ctx, rect: CGRect(origin: .zero, size: CGSize(width: pixelWidth, height: pixelHeight)), preset: preset)
        return ctx.makeImage()
    }

    private static func gaussianBlurred(_ source: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: source)
        // Clamp the edges to infinity BEFORE blurring. Without this, CIGaussianBlur
        // samples transparent pixels outside the image and the borders darken into a
        // halo (the "depth out of nowhere"). Clamp extends the edge color outward so
        // the blur stays uniform across the whole frame.
        guard let clamp = CIFilter(name: "CIAffineClamp") else { return nil }
        clamp.setValue(input, forKey: kCIInputImageKey)
        clamp.setValue(NSAffineTransform(), forKey: "inputTransform")
        guard let clamped = clamp.outputImage else { return nil }

        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        // Crop back to the original image rect: the clamped input is infinite, so we
        // keep exactly the source extent with clean, even edges (no dark falloff).
        let cropped = output.cropped(to: input.extent)
        return ciContext.createCGImage(cropped, from: input.extent)
    }

    private static func drawPresetImageBackground(in context: CGContext, rect: CGRect, preset: ScreenshotBackgroundImagePreset) {
        drawMesh(
            in: context,
            rect: rect,
            start: color(from: preset.startHex),
            end: color(from: preset.endHex),
            accents: preset.accentHexes.map(color(from:))
        )
    }

    // MARK: - Mesh gradient (the "10x" look)

    // Builds a designed-wallpaper backdrop the way CleanShot does: an atmospheric
    // vertical base (deep below, bright above) with a soft diagonal lean, two or
    // three luminous blooms with eased falloff so they read as LIGHT not paint
    // blobs, an overhead sheen, a gentle corner vignette for real depth, and a
    // fine dither that erases 8-bit banding even on 2000px+ canvases. Every layer
    // is keyed off the base luminance so light and dark palettes both stay clean.
    private static func drawMesh(in context: CGContext, rect: CGRect, start: NSColor, end: NSColor, accents: [NSColor]) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let maxDim = max(rect.width, rect.height)
        let light = isLightBase(start, end)

        // Dark palettes want the deep tone to OWN the field with a contained light
        // accent (dramatic, CleanShot-dark); light/mid palettes want a broader,
        // brighter spread. `keepDeep` (0...1, higher = darker base) drives how far
        // the base ramp climbs and how large/strong the corner light reads.
        let baseLum = relativeLuminance(start)
        let keepDeep = clamped(1 - baseLum * 2.4, min: 0, max: 1)   // ~1 for near-black, 0 for light

        // 1. Deep diagonal base. The dark tone fills the bottom-left and climbs only
        //    to a MID tone at the top-right; the bright `end` arrives separately as a
        //    radial light. Stopping the ramp short of `end` keeps the deep corner
        //    genuinely dark and the far edges from washing out, so depth lives inside
        //    the visible field on a full-bleed canvas. The top blend is lower for
        //    dark palettes so their field stays moody.
        let topBlend = 0.50 - 0.30 * keepDeep                       // 0.50 light, ~0.20 dark
        let baseTop = start.blended(withFraction: topBlend, of: end) ?? end
        let q1 = start.blended(withFraction: topBlend * 0.30, of: end) ?? end
        let q2 = start.blended(withFraction: topBlend * 0.66, of: end) ?? end
        if let base = CGGradient(
            colorsSpace: colorSpace,
            colors: [start.cgColor, q1.cgColor, q2.cgColor, baseTop.cgColor] as CFArray,
            locations: [0, 0.34, 0.68, 1]
        ) {
            let over = maxDim * 0.10
            context.drawLinearGradient(
                base,
                start: CGPoint(x: rect.minX - over, y: rect.minY - over),
                end: CGPoint(x: rect.maxX + over, y: rect.maxY + over),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(start.cgColor)
            context.fill(rect)
        }

        let anchors = meshAnchors(in: rect)

        // 2. Multi-hue accent fields, the heart of the CleanShot look. Each accent
        //    is painted as a large, soft radial in NORMAL blend so its hue lands as
        //    real color on the field, not a near-white screen tint (screen pulled
        //    every preset toward its base, the monochrome bug). Three accents sit in
        //    three regions so two or three distinct hues coexist (purple+pink,
        //    blue+teal, indigo+violet) and the preset reads at a glance. Saturation
        //    is boosted first so the hue is vivid; the soft mid stop in
        //    drawGradientGlow feathers each field so it blends instead of edging.
        let fieldSpec: [(radius: CGFloat, alpha: CGFloat)] = light
            ? [(1.05, 0.52), (0.95, 0.44), (0.86, 0.36)]
            : [(1.10, 0.66), (1.00, 0.56), (0.90, 0.46)]
        for (index, accent) in accents.prefix(3).enumerated() {
            let center = anchors[index % anchors.count]
            let spec = fieldSpec[index]
            context.saveGState()
            context.setBlendMode(.normal)
            drawGradientGlow(in: context, rect: rect, color: saturated(accent, by: 1.25),
                             center: center, radius: maxDim * spec.radius, alpha: spec.alpha)
            context.restoreGState()
        }

        // 2b. Luminous lift on the brightest accent: a screen pass over the same
        //     region adds glow on top of the now-colored field, so the light hue
        //     gleams without bleaching its neighbors. Skipped on light palettes
        //     where screen would just blow out to white.
        if !light, let lead = accents.first {
            context.saveGState()
            context.setBlendMode(.screen)
            drawGradientGlow(in: context, rect: rect, color: saturated(lead, by: 1.2),
                             center: anchors[0], radius: maxDim * 0.60, alpha: 0.30)
            context.restoreGState()
        }

        // 3. The end color as a CONTAINED corner light: a tight glow at the top-right
        //    that pools highlight where the light source is and falls off fast, so it
        //    grounds the composition with a bright corner WITHOUT flooding the field
        //    and washing the hues. Tinted toward the lead accent so even the light
        //    carries color, never a pure-white hotspot.
        let lightTint = (accents.first.map { end.blended(withFraction: 0.40, of: $0) ?? end }) ?? end
        do {
            let lightCenter = CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.16)
            let lightRadius = maxDim * (0.52 - 0.16 * keepDeep)
            context.saveGState()
            context.setBlendMode(.screen)
            drawGradientGlow(in: context, rect: rect, color: lightTint,
                             center: lightCenter, radius: lightRadius, alpha: light ? 0.34 : 0.46)
            context.restoreGState()
        }

        // 4. Corner vignette for depth. A large dark radial multiplied in from the
        //    edges, kept subtle so it grounds the composition without darkening the
        //    print's surroundings into a frame. This is the wallpaper depth the
        //    backdrop needs; it is NOT the print's drop shadow.
        drawVignette(in: context, rect: rect, strength: light ? 0.10 : 0.18)

        // 5. Dither pass to kill 8-bit banding. Stronger on the smooth lower band
        //    where the eye catches steps most; it shifts luminance by under a code
        //    value, invisible as texture but enough to dissolve the contours.
        drawGrain(in: context, rect: rect, alpha: light ? 0.030 : 0.045)
    }

    // Bloom anchors that SPREAD the accent hues across the composition instead of
    // stacking them on the light axis. The first accent lands top-left (opposite
    // the corner light, so its hue is not bleached), the second holds the bottom
    // band, the third sits mid-right. With three accents this gives three distinct
    // colored regions, the multi-hue field CleanShot is known for.
    private static func meshAnchors(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.78),
            CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.14),
            CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.42)
        ]
    }

    private static func relativeLuminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    private static func isLightBase(_ a: NSColor, _ b: NSColor) -> Bool {
        (relativeLuminance(a) + relativeLuminance(b)) / 2 > 0.62
    }

    // Pushes a color's saturation up (factor > 1) before it is blended in, so the
    // accent hue survives the screen/soft-light pass and reads as real color
    // instead of a near-white tint. Clamps to valid HSB so it never overflows.
    private static func saturated(_ color: NSColor, by factor: CGFloat) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: Swift.min(1, s * factor), brightness: b, alpha: a)
    }

    // A soft dark radial pulled in from the edges, multiplied over the field so
    // the corners recede and the composition gains volume. The clear core leaves
    // the center untouched; only the outer ~30% darkens, and gently.
    private static func drawVignette(in context: CGContext, rect: CGRect, strength: CGFloat) {
        guard strength > 0 else { return }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(strength).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.62, 1]) else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        // Radius reaches the corners so the darkening hugs the frame edges evenly.
        let radius = hypot(rect.width, rect.height) * 0.62
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: rect.midX, y: rect.midY),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.midY),
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
        context.restoreGState()
    }

    // A deterministic noise tile generated once and tiled under a soft light
    // blend. Soft light shifts luminance by a fraction of a code value, the exact
    // tool to dissolve 8-bit banding without adding visible film grain.
    private static let noiseTile: CGImage? = makeNoiseTile(side: 192)

    private static func makeNoiseTile(side: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = ctx.data else { return nil }

        // Center the noise around mid-gray so soft light neither lifts nor crushes
        // the average tone; only the per-pixel jitter survives, which is what
        // breaks the banding contours.
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(side * side) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            // Map to a tight band around 128 so the dither stays sub-perceptual.
            let n = Int(truncatingIfNeeded: seed) & 0x3f      // 0...63
            buffer[i] = UInt8(96 + n)                          // 96...159, centered ~128
        }
        return ctx.makeImage()
    }

    private static func drawGrain(in context: CGContext, rect: CGRect, alpha: CGFloat) {
        guard let tile = noiseTile else { return }
        context.saveGState()
        context.setBlendMode(.softLight)
        context.setAlpha(alpha)
        let side: CGFloat = 192
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                context.draw(tile, in: CGRect(x: x, y: y, width: side, height: side))
                x += side
            }
            y += side
        }
        context.restoreGState()
    }

    private static func aspectFillRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func drawGradientGlow(in context: CGContext, rect: CGRect, color: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        // Three stops with an eased middle: the glow holds near full strength close
        // to the center, then feathers out smoothly. A flat two-stop ramp gives a
        // hard linear edge that reads as a paint blob; the mid stop turns it into
        // light. The mid sits at ~70% alpha and 45% radius for a soft shoulder.
        let colors = [
            color.withAlphaComponent(alpha).cgColor,
            color.withAlphaComponent(alpha * 0.55).cgColor,
            color.withAlphaComponent(0).cgColor
        ] as CFArray
        let colorSpace = color.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.45, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
    }

    private static func drawShadow(in context: CGContext, container: CGRect, rect: CGRect, radius: CGFloat, intensity: CGFloat) {
        guard intensity > 0 else { return }

        // Depth that reads on both light and dark backdrops, with a response curve
        // tuned for the slider: no alpha floor (0 means off) and no early ceiling,
        // so every step of the control visibly changes the depth. The spread grows
        // up to ~15% of the canvas at full intensity. Two layers sell the depth:
        // a wide soft ambient shadow plus a tight dark contact shadow under the
        // print (the classic CleanShot recipe). Both are cast only by the shot's
        // rounded path and clipped to outside it, so they never bleed onto the
        // canvas edges, only the ground around the print.
        let canvasMin = Swift.min(container.width, container.height)
        let t = Swift.min(intensity, 3)
        // Bottom-weighted on purpose: the offset grows faster than the spread so
        // at high settings the mass of the shadow sits UNDER the print (grounded,
        // CleanShot-like) instead of a symmetric haze around it. Alpha tops out
        // near solid black so the max setting is genuinely heavy.
        let ambientBlur = canvasMin * (0.015 + 0.165 * t)
        let ambientOffsetY = -canvasMin * (0.008 + 0.072 * t)
        let ambientAlpha = Swift.min(0.96, 0.95 * pow(t, 0.75))

        let path = roundedPath(for: rect, radius: radius)
        // Inflate generously so a large blur is never clipped at the canvas border.
        let outerRect = container.insetBy(dx: -(ambientBlur * 3 + 120), dy: -(ambientBlur * 3 + 120))
        let shadowClip = CGMutablePath()
        shadowClip.addRect(outerRect)
        shadowClip.addPath(path)

        context.saveGState()
        context.addPath(shadowClip)
        context.clip(using: .evenOdd)

        context.setShadow(
            offset: CGSize(width: 0, height: ambientOffsetY),
            blur: ambientBlur,
            color: NSColor.black.withAlphaComponent(ambientAlpha).cgColor
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(path)
        context.fillPath()

        context.setShadow(
            offset: CGSize(width: 0, height: ambientOffsetY * 0.45),
            blur: ambientBlur * 0.20,
            color: NSColor.black.withAlphaComponent(ambientAlpha).cgColor
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(path)
        context.fillPath()

        context.restoreGState()
    }

    private static func drawEdgeStroke(in context: CGContext, rect: CGRect, radius: CGFloat, scale: CGFloat) {
        let lineWidth = CGFloat(1) / max(scale, 1)
        let strokeRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let strokeRadius = max(0, radius - lineWidth / 2)

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.addPath(roundedPath(for: strokeRect, radius: strokeRadius))
        context.strokePath()
        context.restoreGState()
    }

    // Accepts 3 (RGB), 6 (RRGGBB) and 8 (RRGGBBAA) hex digits. Falls back to navy
    // only when the string is genuinely unparseable.
    static func color(from hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()

        func channel(_ value: Int) -> CGFloat { CGFloat(value) / 255 }

        switch trimmed.count {
        case 3:
            guard let value = Int(trimmed, radix: 16) else { return fallbackColor }
            // Expand each nibble: #abc -> #aabbcc
            let r = (value >> 8) & 0xf
            let g = (value >> 4) & 0xf
            let b = value & 0xf
            return NSColor(calibratedRed: channel(r * 17), green: channel(g * 17), blue: channel(b * 17), alpha: 1)
        case 6:
            guard let value = Int(trimmed, radix: 16) else { return fallbackColor }
            return NSColor(
                calibratedRed: channel((value >> 16) & 0xff),
                green: channel((value >> 8) & 0xff),
                blue: channel(value & 0xff),
                alpha: 1
            )
        case 8:
            guard let value = UInt64(trimmed, radix: 16) else { return fallbackColor }
            return NSColor(
                calibratedRed: channel(Int((value >> 24) & 0xff)),
                green: channel(Int((value >> 16) & 0xff)),
                blue: channel(Int((value >> 8) & 0xff)),
                alpha: channel(Int(value & 0xff))
            )
        default:
            return fallbackColor
        }
    }

    private static let fallbackColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)

    private static func hexString(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // Median color sampled from the outermost rows and columns of the image. The
    // inset frame uses it as the dominant border color painted around the print.
    private static func medianBorderColor(of cg: CGImage) -> NSColor? {
        let width = cg.width
        let height = cg.height
        guard width > 1, height > 1 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var reds: [Int] = []
        var greens: [Int] = []
        var blues: [Int] = []

        func sample(x: Int, y: Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let a = Int(pixels[offset + 3])
            guard a > 8 else { return }
            // Un-premultiply so transparent edges do not bias toward black.
            let r = Int(pixels[offset]) * 255 / a
            let g = Int(pixels[offset + 1]) * 255 / a
            let b = Int(pixels[offset + 2]) * 255 / a
            reds.append(min(255, r))
            greens.append(min(255, g))
            blues.append(min(255, b))
        }

        let stepX = max(1, width / 64)
        let stepY = max(1, height / 64)
        for x in stride(from: 0, to: width, by: stepX) {
            sample(x: x, y: 0)
            sample(x: x, y: height - 1)
        }
        for y in stride(from: 0, to: height, by: stepY) {
            sample(x: 0, y: y)
            sample(x: width - 1, y: y)
        }

        guard !reds.isEmpty else { return nil }
        func median(_ values: [Int]) -> CGFloat {
            let sorted = values.sorted()
            return CGFloat(sorted[sorted.count / 2]) / 255
        }
        return NSColor(srgbRed: median(reds), green: median(greens), blue: median(blues), alpha: 1)
    }

    private static func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private static func canvasSize(for paddedSize: NSSize, aspectPreset: BackgroundAspectPreset?) -> NSSize {
        guard let preset = aspectPreset, preset.ratio > 0 else { return paddedSize }
        let target = preset.ratio
        let current = paddedSize.width / paddedSize.height
        if current > target {
            // Padded box is wider than the target: grow height to match.
            return NSSize(width: paddedSize.width, height: paddedSize.width / target)
        } else {
            // Grow width to match.
            return NSSize(width: paddedSize.height * target, height: paddedSize.height)
        }
    }

    /// Top-left origin (flipped/editor coords) of the screenshot slot within a
    /// `canvasSize` canvas, matching `composeIfNeeded`'s placement. The editor uses
    /// this to keep annotations registered with the slot as it moves.
    static func imageSlotOrigin(imageSize: NSSize, canvasSize: NSSize, options: ScreenshotBackgroundOptions) -> CGPoint {
        imageSlotRect(imageSize: imageSize, canvasSize: canvasSize, options: options).origin
    }

    /// THE source of slot geometry: the exact rect (in flipped/top-left canvas
    /// points) where `composeIfNeeded` draws the screenshot, honoring padding,
    /// inset, alignment and aspect. The editor canvas reads this for blur/pixelate
    /// mapping and crop bounds so the view->image transform never drifts. The
    /// render itself derives its draw rect from the same `slotRect` math (just in
    /// bottom-left space), so on-screen and exported geometry are identical.
    static func imageSlotRect(imageSize: NSSize, canvasSize: NSSize, options: ScreenshotBackgroundOptions) -> CGRect {
        guard options.isEnabled else { return CGRect(origin: .zero, size: canvasSize) }
        let padding = clamped(options.padding, min: 0, max: 240)
        let inset = clamped(options.inset, min: 0, max: 240)
        let imagePointSize = insetShotSize(source: imageSize, inset: inset)
        return slotRect(
            imagePointSize: imagePointSize,
            padding: padding,
            canvasSize: canvasSize,
            alignment: options.alignment,
            snapScale: 1,
            flipped: true
        )
    }

    /// Places `imagePointSize` inside `canvasSize` per padding + alignment, then
    /// pixel-snaps at `snapScale`. With `flipped == false` it returns a bottom-left
    /// CG rect (for the unflipped compose context); with `flipped == true` it
    /// returns a top-left rect (for the flipped editor canvas). One implementation
    /// so both consumers agree to the pixel.
    private static func slotRect(
        imagePointSize: NSSize,
        padding: CGFloat,
        canvasSize: NSSize,
        alignment: BackgroundAlignment,
        snapScale: CGFloat,
        flipped: Bool
    ) -> CGRect {
        let bottomLeft = alignedOrigin(
            content: imagePointSize, inset: padding,
            container: canvasSize, alignment: alignment
        )
        let snapped = pixelAligned(
            CGRect(origin: bottomLeft, size: imagePointSize),
            scale: Swift.max(snapScale, 1)
        )
        guard flipped else { return snapped }
        let topY = canvasSize.height - snapped.origin.y - snapped.height
        return CGRect(x: snapped.origin.x, y: topY, width: snapped.width, height: snapped.height)
    }

    // Places a content rect (with `inset` margin from the slot) inside `container`,
    // honoring the alignment anchor and never letting the content cross the inset.
    private static func alignedOrigin(content: NSSize, inset: CGFloat, container: NSSize, alignment: BackgroundAlignment) -> CGPoint {
        let freeX = Swift.max(0, container.width - content.width - inset * 2)
        let freeY = Swift.max(0, container.height - content.height - inset * 2)
        let unit = alignment.unit
        return CGPoint(
            x: inset + freeX * unit.x,
            y: inset + freeY * unit.y
        )
    }

    private static func cornerRadius(for rect: CGRect, options: ScreenshotBackgroundOptions, shrink: CGFloat = 1) -> CGFloat {
        min(clamped(options.cornerRadius, min: 0, max: 36) * Swift.max(Swift.min(shrink, 1), 0.2),
            min(rect.width, rect.height) / 2)
    }

    private static func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }
}
