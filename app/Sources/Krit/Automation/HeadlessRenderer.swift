import AppKit
import CoreImage
import CoreGraphics

/// Draws annotations onto a screenshot without any window or live canvas.
///
/// The interactive `AnnotationCanvas` is an `isFlipped = true` view: annotations
/// store and draw in a top-left origin, points-based coordinate space. Automation
/// specs arrive in PIXEL coordinates of the input file (also top-left). So here we
/// build a bitmap context at the image's exact pixel size, flip it to a top-left
/// origin, and let each `AnnotationObject.draw(in:scale:)` paint directly, the
/// same path the canvas takes, just without a screen.
enum HeadlessRenderer {

    enum RenderError: Error, CustomStringConvertible {
        case inputUnreadable
        case inputNotImage
        case contextCreationFailed
        case pngEncodeFailed

        var description: String {
            switch self {
            case .inputUnreadable:       return "input file could not be read"
            case .inputNotImage:         return "input is not a decodable image"
            case .contextCreationFailed: return "could not create bitmap context"
            case .pngEncodeFailed:       return "could not encode output PNG"
            }
        }
    }

    /// Loads `inputPath`, draws `spec`, and writes a PNG to `outputPath`.
    /// Returns the output pixel size.
    static func renderToFile(inputPath: String, outputPath: String, spec: [AnnotationSpec]) throws -> (widthPx: Int, heightPx: Int) {
        guard let data = FileManager.default.contents(atPath: inputPath) else {
            throw RenderError.inputUnreadable
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderError.inputNotImage
        }

        let rendered = try render(cgImage: cgImage, spec: spec)

        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outputPath) as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw RenderError.pngEncodeFailed
        }
        CGImageDestinationAddImage(dest, rendered, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.pngEncodeFailed
        }
        return (rendered.width, rendered.height)
    }

    /// Composites `spec` over `cgImage`, returning a new CGImage at the same pixel size.
    static func render(cgImage: CGImage, spec: [AnnotationSpec]) throws -> CGImage {
        let width = cgImage.width
        let height = cgImage.height

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.contextCreationFailed
        }

        // Lay down the screenshot in the native bottom-left CG space first.
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Blur / pixelate read the background and run before the flip: sample from
        // the source CGImage (pixel coords, top-left) and paint the filtered tile
        // back into the same bottom-left context space.
        for s in spec {
            switch s.kind {
            case .blur(let rect, let radius):
                applyRegionFilter(.gaussianBlur(radius: radius), source: cgImage, pixelRectTopLeft: rect, into: ctx, imageHeight: height)
            case .pixelate(let rect, let scale):
                applyRegionFilter(.pixellate(scale: scale), source: cgImage, pixelRectTopLeft: rect, into: ctx, imageHeight: height)
            default:
                break
            }
        }

        // Flip to a top-left origin so AnnotationObject.draw lands where the spec says.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        for s in spec {
            switch s.kind {
            case .blur, .pixelate:
                continue // already composited above
            default:
                if let object = makeAnnotation(from: s) {
                    object.draw(in: ctx, scale: 1)
                }
            }
        }

        guard let output = ctx.makeImage() else {
            throw RenderError.contextCreationFailed
        }
        return output
    }

    // MARK: - Region filters (blur / pixelate)

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private enum RegionFilter {
        case gaussianBlur(radius: Double)
        case pixellate(scale: Double)
    }

    /// Crops the source at a top-left pixel rect, runs a CIFilter, and paints the
    /// result into `ctx` at the matching bottom-left location. Mirrors the
    /// CIGaussianBlur / CIPixellate logic the live canvas uses in drawBlur/drawPixelate.
    private static func applyRegionFilter(_ filter: RegionFilter, source: CGImage, pixelRectTopLeft rect: CGRect, into ctx: CGContext, imageHeight: Int) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return }

        let cropTopLeft = clamped.integral
        // CGImage.cropping uses a top-left origin, same as the spec.
        guard let cropped = source.cropping(to: cropTopLeft) else { return }

        let ci = CIImage(cgImage: cropped)
        let coreFilter: CIFilter?
        switch filter {
        case .gaussianBlur(let radius):
            coreFilter = CIFilter(name: "CIGaussianBlur")
            coreFilter?.setValue(ci, forKey: kCIInputImageKey)
            coreFilter?.setValue(max(radius, 1), forKey: kCIInputRadiusKey)
        case .pixellate(let scale):
            coreFilter = CIFilter(name: "CIPixellate")
            coreFilter?.setValue(ci, forKey: kCIInputImageKey)
            coreFilter?.setValue(max(scale, 4), forKey: kCIInputScaleKey)
        }
        guard let output = coreFilter?.outputImage else { return }
        // Clamp the (blur-expanded) result back to the source tile extent.
        let result = output.cropped(to: ci.extent)
        guard let filteredCG = ciContext.createCGImage(result, from: ci.extent) else { return }

        // Convert top-left tile rect to the bottom-left context rect.
        let destY = CGFloat(imageHeight) - cropTopLeft.maxY
        let destRect = CGRect(x: cropTopLeft.minX, y: destY, width: cropTopLeft.width, height: cropTopLeft.height)
        ctx.saveGState()
        ctx.draw(filteredCG, in: destRect)
        ctx.restoreGState()
    }

    // MARK: - Spec -> AnnotationObject

    private static func makeAnnotation(from spec: AnnotationSpec) -> (any AnnotationObject)? {
        let color = spec.color ?? KritColors.accent
        let width = spec.width

        switch spec.kind {
        case .arrow(let from, let to, let curve):
            let arrow = ArrowAnnotation(start: from, end: to)
            arrow.color = color
            if let width { arrow.lineWidth = width }
            arrow.controlPoint = curve
            return arrow

        case .box(let rect, let fill):
            let box = RectangleAnnotation(rect: rect, filled: fill)
            box.color = color
            if let width { box.lineWidth = width }
            return box

        case .ellipse(let rect):
            let ellipse = EllipseAnnotation(rect: rect)
            ellipse.color = color
            if let width { ellipse.lineWidth = width }
            return ellipse

        case .line(let from, let to):
            let line = LineAnnotation(start: from, end: to)
            line.color = color
            if let width { line.lineWidth = width }
            return line

        case .text(let at, let string, let size):
            let text = TextAnnotation(origin: at)
            text.color = color
            text.text = string
            if let size { text.fontSize = size }
            return text

        case .step(let at, let number):
            let step = NumberedStepAnnotation(center: at, number: number)
            step.color = color
            return step

        case .highlight(let from, let to):
            let highlight = HighlighterAnnotation(start: from, end: to)
            if spec.color != nil { highlight.color = color }
            if let width { highlight.lineWidth = width }
            return highlight

        case .blur, .pixelate:
            return nil // handled by applyRegionFilter
        }
    }
}
