import AppKit

// MARK: - Tool Types

enum AnnotationTool: String, CaseIterable {
    case select, arrow, rectangle, filledRectangle, ellipse, line, freehand
    case text, numberedStep, highlighter, blur, pixelate, crop, eyedropper

    var icon: String {
        switch self {
        // The pointer arrow, not the resize diagonal: this is the "pick and
        // move things" tool and its glyph must read as a mouse cursor.
        case .select:          return "cursorarrow"
        case .arrow:           return "arrow.up.right"
        case .rectangle:       return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse:         return "circle"
        case .line:            return "line.diagonal"
        case .freehand:        return "pencil"
        case .text:            return "textformat"
        case .numberedStep:    return "1.circle.fill"
        case .highlighter:     return "highlighter"
        case .blur:            return "camera.filters"
        case .pixelate:        return "square.grid.3x3.fill"
        case .crop:            return "crop"
        case .eyedropper:      return "eyedropper"
        }
    }

    var tooltip: String {
        switch self {
        case .select:          return "Select (V)"
        case .arrow:           return "Arrow (A)"
        case .rectangle:       return "Rectangle (R)"
        case .filledRectangle: return "Filled Rectangle (\u{21E7}R)"
        case .ellipse:         return "Ellipse (E)"
        case .line:            return "Line (L)"
        case .freehand:        return "Freehand Draw (D)"
        case .text:            return "Text (T)"
        case .numberedStep:    return "Numbered Steps (N)"
        case .highlighter:     return "Highlighter (H)"
        case .blur:            return "Blur (B)"
        case .pixelate:        return "Pixelate (P)"
        case .crop:            return "Crop (C)"
        case .eyedropper:      return "Pick Color (I)"
        }
    }
}

// MARK: - Base Protocol

protocol AnnotationObject: AnyObject {
    var id: UUID { get }
    var color: NSColor { get set }
    var lineWidth: CGFloat { get set }
    var isSelected: Bool { get set }
    func draw(in context: CGContext, scale: CGFloat)
    func contains(point: CGPoint) -> Bool
    func move(by delta: CGPoint)
    func copy() -> any AnnotationObject
    var bounds: CGRect { get }
}

// MARK: - Arrow

final class ArrowAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 3
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint
    var controlPoint: CGPoint?

    init(start: CGPoint, end: CGPoint, id: UUID = UUID()) {
        self.startPoint = start
        self.endPoint = end
        self.id = id
    }

    var bounds: CGRect {
        var points = [startPoint, endPoint]
        if let controlPoint { points.append(controlPoint) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let padding = max(lineWidth * 6, 18)
        return CGRect(x: minX - padding, y: minY - padding,
                      width: maxX - minX + padding * 2,
                      height: maxY - minY + padding * 2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard let path = kritArrowPath(
            start: startPoint, end: endPoint, control: controlPoint,
            lineWidth: lineWidth
        ) else { return }

        ctx.saveGState()
        if KritArrow.shadowAlpha > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: KritArrow.shadowOffsetY),
                          blur: KritArrow.shadowBlur,
                          color: NSColor.black.withAlphaComponent(KritArrow.shadowAlpha).cgColor)
        }
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool {
        let d: CGFloat
        if let controlPoint {
            d = distanceFromQuadraticCurve(point: point, control: controlPoint)
        } else {
            d = distanceFromLineSegment(point: point, a: startPoint, b: endPoint)
        }
        return d < max(lineWidth + 4, 8)
    }

    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
        controlPoint = controlPoint.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    func copy() -> any AnnotationObject {
        let annotation = ArrowAnnotation(start: startPoint, end: endPoint, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.controlPoint = controlPoint
        return annotation
    }

    // The control handle is presented ON the curve (its midpoint), not at the
    // raw quadratic control point, which sits far off the curve and feels
    // broken to drag. Mapping: curve midpoint B = (S + 2C + E)/4, so dragging
    // the handle to M solves C = 2M - (S + E)/2.
    func handlePoint(_ handle: ArrowHandle) -> CGPoint {
        switch handle {
        case .start:   return startPoint
        case .end:     return endPoint
        case .control: return pointOnCurve(at: 0.5)
        }
    }

    func setHandle(_ handle: ArrowHandle, to point: CGPoint) {
        switch handle {
        case .start:   startPoint = point
        case .end:     endPoint = point
        case .control:
            controlPoint = CGPoint(
                x: 2 * point.x - (startPoint.x + endPoint.x) / 2,
                y: 2 * point.y - (startPoint.y + endPoint.y) / 2
            )
            // Snap back to straight when dragged onto the chord.
            if let c = controlPoint {
                let mid = midpoint
                if hypot(c.x - mid.x, c.y - mid.y) < 3 { controlPoint = nil }
            }
        }
    }

    var midpoint: CGPoint {
        CGPoint(x: (startPoint.x + endPoint.x) / 2, y: (startPoint.y + endPoint.y) / 2)
    }

    func pointOnCurve(at t: CGFloat) -> CGPoint {
        guard let controlPoint else {
            return CGPoint(x: startPoint.x + (endPoint.x - startPoint.x) * t,
                           y: startPoint.y + (endPoint.y - startPoint.y) * t)
        }
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * startPoint.x + 2 * mt * t * controlPoint.x + t * t * endPoint.x,
            y: mt * mt * startPoint.y + 2 * mt * t * controlPoint.y + t * t * endPoint.y
        )
    }

    private func distanceFromLineSegment(point p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(p.x-a.x, p.y-a.y) }
        let t = max(0, min(1, ((p.x-a.x)*dx + (p.y-a.y)*dy) / len2))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }

    private func distanceFromQuadraticCurve(point: CGPoint, control: CGPoint) -> CGFloat {
        var closest = CGFloat.greatestFiniteMagnitude
        var previous = startPoint
        for step in 1...28 {
            let current = pointOnCurve(at: CGFloat(step) / 28)
            closest = min(closest, distanceFromLineSegment(point: point, a: previous, b: current))
            previous = current
        }
        return closest
    }
}

enum ArrowHandle {
    case start, end, control
}

// MARK: - Rectangle

final class RectangleAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 3
    var isSelected = false
    var filled: Bool
    var rect: CGRect

    init(rect: CGRect, filled: Bool = false, id: UUID = UUID()) {
        self.rect = rect
        self.filled = filled
        self.id = id
    }

    var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Normalize so a drag in any direction still yields a positive-sized rect
        // (negative width/height breaks CGPath corner rounding).
        let r = rect.standardized
        guard r.width > 0, r.height > 0 else { return }

        // Target corner radius, computed on the OUTER rect (matches the spec).
        let radius = kritClamp(max(6, lineWidth * 2.2),
                               lower: 0,
                               upper: min(r.width, r.height) / 2)

        ctx.saveGState()

        // Filled variant: lay down the soft tint FIRST, with NO shadow, so the
        // elevation comes only from the outline silhouette (never a muddy double).
        if filled {
            let fillPath = CGPath(roundedRect: r,
                                  cornerWidth: radius,
                                  cornerHeight: radius,
                                  transform: nil)
            ctx.addPath(fillPath)
            ctx.setFillColor(color.withAlphaComponent(0.20).cgColor)
            ctx.fillPath()
        }

        // Inset by half the line width so the stroke stays fully inside `rect`
        // (a centered stroke would otherwise bleed lineWidth/2 outside the bounds).
        let strokeRect = r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard strokeRect.width > 0, strokeRect.height > 0 else {
            ctx.restoreGState()
            return
        }
        // Keep the rounded corners concentric with the outer rect.
        let strokeRadius = max(0, radius - lineWidth / 2)

        // Single rounded-rect stroke = the one silhouette that carries the shadow.
        let strokePath = CGPath(roundedRect: strokeRect,
                                cornerWidth: strokeRadius,
                                cornerHeight: strokeRadius,
                                transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                      color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.addPath(strokePath)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // Hollow rectangles hit only on the stroke band so objects inside them
    // stay clickable; filled ones hit anywhere inside.
    func contains(point: CGPoint) -> Bool {
        let r = rect.standardized
        if filled { return r.insetBy(dx: -8, dy: -8).contains(point) }
        let outline = CGPath(rect: r, transform: nil)
        let band = outline.copy(strokingWithWidth: max(lineWidth + 12, 16),
                                lineCap: .round, lineJoin: .round, miterLimit: 10)
        return band.contains(point, using: .winding)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = RectangleAnnotation(rect: rect, filled: filled, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: - Ellipse

final class EllipseAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 3
    var isSelected = false
    var rect: CGRect

    init(rect: CGRect, id: UUID = UUID()) {
        self.rect = rect
        self.id = id
    }

    var bounds: CGRect { rect.insetBy(dx: -lineWidth, dy: -lineWidth) }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Inset by half the line width so the stroke stays fully inside `rect`.
        let r = rect.standardized.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard r.width > 0, r.height > 0 else { return }

        let path = CGPath(ellipseIn: r, transform: nil)

        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)

        // Shared elevation shadow on the single stroked silhouette.
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                      color: NSColor.black.withAlphaComponent(0.18).cgColor)

        ctx.addPath(path)
        ctx.strokePath()
    }

    // Hit only on the stroke band, mirroring the hollow-rectangle behavior.
    func contains(point: CGPoint) -> Bool {
        let outline = CGPath(ellipseIn: rect.standardized, transform: nil)
        let band = outline.copy(strokingWithWidth: max(lineWidth + 12, 16),
                                lineCap: .round, lineJoin: .round, miterLimit: 10)
        return band.contains(point, using: .winding)
    }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = EllipseAnnotation(rect: rect, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: - Line

final class LineAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 3
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint

    init(start: CGPoint, end: CGPoint, id: UUID = UUID()) {
        self.startPoint = start
        self.endPoint = end
        self.id = id
    }

    var bounds: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x) - lineWidth,
            y: min(startPoint.y, endPoint.y) - lineWidth,
            width: abs(endPoint.x - startPoint.x) + lineWidth*2,
            height: abs(endPoint.y - startPoint.y) + lineWidth*2
        )
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Guard zero-length lines: a round-capped stroke of a degenerate segment
        // would render a stray dot, and the shadow would smear it. Bail cleanly.
        guard startPoint != endPoint else { return }

        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)

        // Shared elevation shadow on the single stroked silhouette.
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                      color: NSColor.black.withAlphaComponent(0.18).cgColor)

        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()
    }

    func contains(point: CGPoint) -> Bool {
        let dx = endPoint.x - startPoint.x, dy = endPoint.y - startPoint.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(point.x-startPoint.x, point.y-startPoint.y) < 8 }
        let t = max(0, min(1, ((point.x-startPoint.x)*dx + (point.y-startPoint.y)*dy) / len2))
        return hypot(point.x-(startPoint.x+t*dx), point.y-(startPoint.y+t*dy)) < max(lineWidth+4, 8)
    }

    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = LineAnnotation(start: startPoint, end: endPoint, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: - Freehand

final class FreehandAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 3
    var isSelected = false
    var points: [CGPoint] = []

    init(id: UUID = UUID()) { self.id = id }

    var bounds: CGRect {
        guard !points.isEmpty else { return .zero }
        var minX = points[0].x, maxX = minX
        var minY = points[0].y, maxY = minY
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX-lineWidth, y: minY-lineWidth,
                      width: maxX-minX+lineWidth*2, height: maxY-minY+lineWidth*2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard points.count >= 2 else { return }

        let path = kritSmoothInkPath(points)

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Shared elevation shadow on the single ink silhouette. One shadow, once.
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2,
                      color: NSColor.black.withAlphaComponent(0.18).cgColor)

        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }

    func contains(point: CGPoint) -> Bool { bounds.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { points = points.map { CGPoint(x: $0.x+delta.x, y: $0.y+delta.y) } }
    func copy() -> any AnnotationObject {
        let annotation = FreehandAnnotation(id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.points = points
        return annotation
    }
}

// MARK: - Highlighter

final class HighlighterAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = .systemYellow
    var lineWidth: CGFloat = 16
    var isSelected = false
    var startPoint: CGPoint
    var endPoint: CGPoint

    init(start: CGPoint, end: CGPoint, id: UUID = UUID()) {
        self.startPoint = start
        self.endPoint = end
        self.id = id
    }

    var bounds: CGRect {
        CGRect(x: min(startPoint.x, endPoint.x) - lineWidth,
               y: min(startPoint.y, endPoint.y) - lineWidth,
               width: abs(endPoint.x - startPoint.x) + lineWidth*2,
               height: abs(endPoint.y - startPoint.y) + lineWidth*2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Real-marker behavior: .multiply lets overlapping passes and the colored
        // content underneath darken naturally instead of reading as flat paint.
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(color.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.round)
        // No drop shadow on purpose: the highlighter sits IN the content, it is not
        // an object floating above it. This is the one element that skips the
        // shared shadow spec.

        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let len = (dx * dx + dy * dy).squareRoot()

        // Degenerate tap: a butt-capped zero-length subpath renders NOTHING, so the
        // mark would be invisible. Fall back to a square "dab" the width of the band.
        guard startPoint.x.isFinite, startPoint.y.isFinite,
              endPoint.x.isFinite, endPoint.y.isFinite, len > 0.001 else {
            let half = lineWidth / 2
            let dab = CGRect(x: startPoint.x - half, y: startPoint.y - half,
                             width: lineWidth, height: lineWidth)
            ctx.fill(dab)
            return
        }

        // Single straight band, start -> end. One stroke = one clean silhouette,
        // which keeps the multiply layering crisp rather than muddy.
        ctx.move(to: startPoint)
        ctx.addLine(to: endPoint)
        ctx.strokePath()
    }

    func contains(point: CGPoint) -> Bool { bounds.contains(point) }
    func move(by delta: CGPoint) {
        startPoint.x += delta.x; startPoint.y += delta.y
        endPoint.x += delta.x;   endPoint.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = HighlighterAnnotation(start: startPoint, end: endPoint, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: - Text Highlight (OCR-snapped)

/// A highlighter that snapped onto detected text: instead of one free band it
/// holds a fixed rectangle per text line, each covering only the writing. The
/// canvas builds these from `TextRegionDetector` lines that intersect the drag,
/// so the mark reads as a clean, straight highlight over the text. The free-band
/// `HighlighterAnnotation` is still used wherever the drag misses all text.
final class TextHighlightAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = .systemYellow
    var lineWidth: CGFloat = 0
    var isSelected = false
    /// One straight highlight rect per snapped text line, in canvas coordinates.
    var rects: [CGRect]

    init(rects: [CGRect], id: UUID = UUID()) {
        self.rects = rects
        self.id = id
    }

    var bounds: CGRect {
        guard var union = rects.first else { return .zero }
        for rect in rects.dropFirst() { union = union.union(rect) }
        return union
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard !rects.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Match the free highlighter exactly: .multiply at 0.5 alpha so it darkens
        // the content underneath like a real marker, with no drop shadow because
        // the highlight sits IN the content rather than floating above it.
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(color.withAlphaComponent(0.5).cgColor)
        for rect in rects where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect.standardized)
        }
    }

    func contains(point: CGPoint) -> Bool {
        rects.contains { $0.standardized.contains(point) }
    }

    func move(by delta: CGPoint) {
        rects = rects.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
    }

    func copy() -> any AnnotationObject {
        let annotation = TextHighlightAnnotation(rects: rects, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        return annotation
    }
}

// MARK: - Effect cache key

/// Identity of a fully-rendered blur/pixelate region. The render is reusable only
/// while every input matches: the region rect, the screenshot slot it samples
/// from, the filter strength, and the background composition (style/preset/
/// padding/inset/alignment/aspect, via `ScreenshotBackgroundOptions`). Any change
/// invalidates and forces a re-render at the new geometry, so stale offset content
/// can never linger.
struct EffectCacheKey: Equatable {
    let region: CGRect
    let slot: CGRect
    let strength: Double
    // Distinguishes a plain gaussian from a Secure Blur at the same strength, so
    // toggling secure re-renders instead of serving the stale plain render.
    let secure: Bool
    let options: ScreenshotBackgroundOptions
    let imagePixelWidth: Int
    let imagePixelHeight: Int
}

// MARK: - Blur

final class BlurAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var radius: Double = 12
    /// Secure Blur: a heavy block mosaic underneath the gaussian pass so the
    /// underlying text loses its word shapes entirely (irreversible redaction),
    /// unlike a plain gaussian whose low frequencies still leak the outline.
    /// Defaults to false, so blurs created before this flag stay plain gaussian.
    var secure: Bool = false
    var cachedRender: NSImage?
    // Full cache key: any change to the region rect, the screenshot slot, the
    // radius or the background identity re-renders. Keying on the rect alone let
    // stale (offset) content survive a padding/inset/alignment/preset change.
    var cachedKey: EffectCacheKey?

    init(rect: CGRect, id: UUID = UUID()) {
        self.rect = rect
        self.id = id
    }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas using CIFilter
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = BlurAnnotation(rect: rect, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.radius = radius
        annotation.secure = secure
        return annotation
    }
}

// MARK: - Pixelate

final class PixelateAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = .clear
    var lineWidth: CGFloat = 0
    var isSelected = false
    var rect: CGRect
    var scale: Double = 10
    var cachedRender: NSImage?
    // Full cache key (see BlurAnnotation): region + slot + scale + background id.
    var cachedKey: EffectCacheKey?

    init(rect: CGRect, id: UUID = UUID()) {
        self.rect = rect
        self.id = id
    }

    var bounds: CGRect { rect }

    func draw(in ctx: CGContext, scale: CGFloat) {
        // Rendered specially by AnnotationCanvas
    }

    func contains(point: CGPoint) -> Bool { rect.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { rect.origin.x += delta.x; rect.origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = PixelateAnnotation(rect: rect, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.scale = scale
        return annotation
    }
}

// MARK: - Text

/// Font families offered by the text tool. Resolved at draw time so the
/// system picks the right face per weight.
enum AnnotationFontFamily: String, CaseIterable {
    case system, rounded, serif, mono

    var displayName: String {
        switch self {
        case .system:  return "Sans"
        case .rounded: return "Rounded"
        case .serif:   return "Serif"
        case .mono:    return "Mono"
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .system:  return base
        case .rounded: design = .rounded
        case .serif:   design = .serif
        case .mono:    design = .monospaced
        }
        if let descriptor = base.fontDescriptor.withDesign(design),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }
}

/// Backplate behind the text, CleanShot-style "Click here" chip.
enum TextBackplate: String, CaseIterable {
    case none, pill
}

/// The CleanShot-style style presets shown in the text style popover. Each maps
/// to a combination of the text model's traits (weight + italic + backplate +
/// outline), so applying a preset is just copying these flags onto the object.
enum TextStylePreset: String, CaseIterable {
    case regular, bold, italic, boldItalic, backplate, outlined

    var title: String {
        switch self {
        case .regular:    return "Regular"
        case .bold:       return "Bold"
        case .italic:     return "Italic"
        case .boldItalic: return "Bold Italic"
        case .backplate:  return "Backplate"
        case .outlined:   return "Outlined"
        }
    }

    var weight: NSFont.Weight {
        switch self {
        case .bold, .boldItalic, .backplate: return .bold
        case .regular, .italic, .outlined:   return .regular
        }
    }

    var italic: Bool {
        switch self {
        case .italic, .boldItalic: return true
        default:                   return false
        }
    }

    var backplate: TextBackplate { self == .backplate ? .pill : .none }

    var outline: Bool { self == .outlined }

    /// Reads the preset that currently matches a text object's traits, so the
    /// popover can light the active swatch. Falls back to regular when the exact
    /// combo has no named preset (e.g. an italic backplate).
    static func matching(_ text: TextAnnotation) -> TextStylePreset {
        allCases.first {
            $0.weight == text.fontWeight
                && $0.italic == text.italic
                && $0.backplate == text.backplate
                && $0.outline == text.outline
        } ?? .regular
    }
}

final class TextAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 0
    var isSelected = false
    var origin: CGPoint
    var text: String = ""
    var fontSize: CGFloat = 24
    var fontFamily: AnnotationFontFamily = .system
    var fontWeight: NSFont.Weight = .bold
    var italic: Bool = false
    var backplate: TextBackplate = .none
    /// Heavier legibility ring around the glyphs (style preset "no fill, outlined"),
    /// so plain text reads on busy imagery without a backplate chip behind it.
    var outline: Bool = false
    var font: NSFont {
        let base = fontFamily.font(size: fontSize, weight: fontWeight)
        guard italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }

    init(origin: CGPoint, id: UUID = UUID()) {
        self.origin = origin
        self.id = id
    }

    private var backplatePadding: CGSize {
        backplate == .pill
            ? CGSize(width: fontSize * 0.55, height: fontSize * 0.30)
            : .zero
    }

    var textSize: CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: max(size.width, 10), height: max(size.height, fontSize * 1.2))
    }

    var bounds: CGRect {
        let pad = backplatePadding
        let size = textSize
        return CGRect(x: origin.x - pad.width, y: origin.y - pad.height,
                      width: size.width + pad.width * 2,
                      height: size.height + pad.height * 2)
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        guard !text.isEmpty else { return }

        if backplate == .pill {
            let rect = bounds
            let radius = min(rect.height / 2, fontSize * 0.55)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 6,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
            // The plate takes the annotation color; the glyphs flip to white/black
            // for contrast, so the chip reads like a button.
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Dark halo so colored text stays legible on busy or same-colored backgrounds.
        // The NSShadow travels with each glyph, so it hugs the letterforms.
        //
        // Flipped-context gotcha: text is drawn through NSGraphicsContext(flipped:true),
        // whose vertical convention is OPPOSITE the raw flipped CGContext, a POSITIVE
        // NSShadow height moves the halo UP. So a NEGATIVE height seats it just below
        // the glyphs. (Do NOT reuse the shared "+1.5 = below" CGContext value here.)
        let shadow = NSShadow()
        // The outline style leans on a tighter, all-around dark halo for contrast
        // over imagery, so it gets a heavier, centered shadow than the default.
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            backplate == .pill ? 0.30 : (outline ? 0.85 : 0.55)
        )
        shadow.shadowBlurRadius = backplate == .pill ? 1.5 : (outline ? 4 : 3)
        shadow.shadowOffset = outline ? .zero : CGSize(width: 0, height: -1.5)

        let glyphColor: NSColor
        if backplate == .pill {
            // White on dark plates, near-black on light plates.
            let luma = color.usingColorSpace(.sRGB).map {
                0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent
            } ?? 0
            glyphColor = luma > 0.62 ? NSColor.black.withAlphaComponent(0.85) : .white
        } else {
            glyphColor = color
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: glyphColor,
            .shadow: shadow
        ]
        // Outline style: a dark stroke ring around the glyphs in addition to the
        // halo. A NEGATIVE strokeWidth fills AND strokes (Cocoa convention), so the
        // letters keep their color and gain a crisp dark edge for legibility.
        if outline {
            attrs[.strokeColor] = NSColor.black.withAlphaComponent(0.9)
            attrs[.strokeWidth] = -6.0
        }

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func contains(point: CGPoint) -> Bool { bounds.insetBy(dx: -8, dy: -8).contains(point) }
    func move(by delta: CGPoint) { origin.x += delta.x; origin.y += delta.y }
    func copy() -> any AnnotationObject {
        let annotation = TextAnnotation(origin: origin, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.text = text
        annotation.fontSize = fontSize
        annotation.fontFamily = fontFamily
        annotation.fontWeight = fontWeight
        annotation.italic = italic
        annotation.backplate = backplate
        annotation.outline = outline
        return annotation
    }
}

// MARK: - Numbered Step

final class NumberedStepAnnotation: AnnotationObject {
    let id: UUID
    var color: NSColor = KritColors.accent
    var lineWidth: CGFloat = 0
    var isSelected = false
    var origin: CGPoint
    var number: Int
    var diameter: CGFloat = 30

    private var textLayout: (font: NSFont, attrs: [NSAttributedString.Key: Any], size: CGSize) {
        let font = NSFont.boldSystemFont(ofSize: diameter * 0.55)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let size = ("\(number)" as NSString).size(withAttributes: attrs)
        return (font, attrs, size)
    }

    init(center: CGPoint, number: Int, id: UUID = UUID()) {
        self.origin = center
        self.number = number
        self.id = id
    }

    var bounds: CGRect {
        CGRect(x: origin.x - diameter/2, y: origin.y - diameter/2,
               width: diameter, height: diameter)
    }

    func contains(point: CGPoint) -> Bool {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        return (dx*dx + dy*dy) <= (diameter/2 + 4) * (diameter/2 + 4)
    }

    func move(by delta: CGPoint) {
        origin.x += delta.x
        origin.y += delta.y
    }

    func copy() -> any AnnotationObject {
        let annotation = NumberedStepAnnotation(center: origin, number: number, id: id)
        annotation.color = color
        annotation.lineWidth = lineWidth
        annotation.isSelected = isSelected
        annotation.diameter = diameter
        return annotation
    }

    func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()

        let circleRect = bounds

        // Shadow behind the circle
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                       color: NSColor.black.withAlphaComponent(0.3).cgColor)

        // Filled circle
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circleRect)

        // Reset shadow before drawing border and text
        ctx.setShadow(offset: .zero, blur: 0)

        // White border
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circleRect)

        let layout = textLayout
        let textRect = CGRect(
            x: circleRect.minX,
            y: circleRect.midY - layout.size.height / 2 - 1,
            width: circleRect.width,
            height: layout.size.height + 2
        )

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx
        ("\(number)" as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: layout.attrs
        )
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }
}

// MARK: - Duplicate support

extension AnnotationObject {
    /// Like copy(), but with a fresh identity, for duplicate (⌘D) operations.
    func cloneWithNewID() -> any AnnotationObject {
        switch self {
        case let a as ArrowAnnotation:
            let c = ArrowAnnotation(start: a.startPoint, end: a.endPoint)
            c.color = a.color; c.lineWidth = a.lineWidth; c.controlPoint = a.controlPoint
            return c
        case let r as RectangleAnnotation:
            let c = RectangleAnnotation(rect: r.rect, filled: r.filled)
            c.color = r.color; c.lineWidth = r.lineWidth
            return c
        case let e as EllipseAnnotation:
            let c = EllipseAnnotation(rect: e.rect)
            c.color = e.color; c.lineWidth = e.lineWidth
            return c
        case let l as LineAnnotation:
            let c = LineAnnotation(start: l.startPoint, end: l.endPoint)
            c.color = l.color; c.lineWidth = l.lineWidth
            return c
        case let f as FreehandAnnotation:
            let c = FreehandAnnotation()
            c.color = f.color; c.lineWidth = f.lineWidth; c.points = f.points
            return c
        case let h as HighlighterAnnotation:
            let c = HighlighterAnnotation(start: h.startPoint, end: h.endPoint)
            c.color = h.color; c.lineWidth = h.lineWidth
            return c
        case let b as BlurAnnotation:
            let c = BlurAnnotation(rect: b.rect)
            c.radius = b.radius
            c.secure = b.secure
            return c
        case let p as PixelateAnnotation:
            let c = PixelateAnnotation(rect: p.rect)
            c.scale = p.scale
            return c
        case let t as TextAnnotation:
            let c = TextAnnotation(origin: t.origin)
            c.color = t.color; c.text = t.text; c.fontSize = t.fontSize
            c.fontFamily = t.fontFamily; c.fontWeight = t.fontWeight; c.italic = t.italic
            c.backplate = t.backplate; c.outline = t.outline
            return c
        case let s as NumberedStepAnnotation:
            let c = NumberedStepAnnotation(center: s.origin, number: s.number)
            c.color = s.color; c.diameter = s.diameter
            return c
        default:
            return copy()
        }
    }
}

// MARK: - Rendering helpers

private func kritClamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
}

// MARK: Arrow geometry

// Arrow shadow constants, shared by the silhouette fill.
enum KritArrow {
    static let shadowOffsetY: CGFloat = 0.5
    static let shadowBlur: CGFloat = 1.5
    static let shadowAlpha: CGFloat = 0.18
}

// Builds the arrow as a SINGLE filled silhouette in the CleanShot style:
// a needle-point tail widening into the shaft, ending in a dart head whose
// base is CONCAVE (a swept-back V) instead of a flat triangle base. The
// centerline follows the optional quadratic curve. Head proportions clamp
// down for short arrows so the head never swallows the shaft.
// Returns nil for a degenerate (zero-length) arrow.
func kritArrowPath(start: CGPoint, end: CGPoint, control: CGPoint?,
                   lineWidth w: CGFloat) -> CGMutablePath? {
    // Proportions relative to stroke width.
    let headLen  = max(w * 4.6, 14)    // tip -> barbs distance along the axis
    let headHalf = max(w * 2.1, 6.5)   // half-width at the barbs
    let notchR: CGFloat = 0.74         // shaft joins at this fraction of headLen from tip
    let neckHalfBase = max(w * 0.92, 2.6)
    let tailHalf = max(w * 0.10, 0.6)  // near-point tail
    let taperExp: CGFloat = 1.55

    // Quadratic (or linear when control == nil) point sampler.
    let sample: (CGFloat) -> CGPoint = { t in
        guard let c = control else {
            let lx: CGFloat = start.x + (end.x - start.x) * t
            let ly: CGFloat = start.y + (end.y - start.y) * t
            return CGPoint(x: lx, y: ly)
        }
        let mt: CGFloat = 1 - t
        let a: CGFloat = mt * mt
        let b: CGFloat = 2 * mt * t
        let d: CGFloat = t * t
        let qx: CGFloat = a * start.x + b * c.x + d * end.x
        let qy: CGFloat = a * start.y + b * c.y + d * end.y
        return CGPoint(x: qx, y: qy)
    }

    let tip = end
    let span = hypot(tip.x - start.x, tip.y - start.y)
    guard span > 2 else { return nil }

    // Short-arrow clamp: shrink the head with the available length.
    let hl = min(headLen, span * 0.55)
    let hh = headHalf * (hl / headLen)
    let nh = min(neckHalfBase, hh * 0.55)

    // Tangent direction at the tip.
    let tangentRef = sample(0.92)
    var dx = tip.x - tangentRef.x, dy = tip.y - tangentRef.y
    var len = hypot(dx, dy)
    if len < 0.0001 { dx = tip.x - start.x; dy = tip.y - start.y; len = hypot(dx, dy) }
    guard len > 0.0001 else { return nil }
    let dirY = dy / len
    let dirX = dx / len
    let perpX = -dirY, perpY = dirX

    // Walk back from the tip along real arc length.
    func tAtDistanceFromTip(_ dist: CGFloat) -> CGFloat {
        let steps = 96
        var prev = sample(1.0); var acc: CGFloat = 0
        var i = steps - 1
        while i >= 0 {
            let t = CGFloat(i) / CGFloat(steps)
            let cur = sample(t)
            let seg = hypot(cur.x - prev.x, cur.y - prev.y)
            if acc + seg >= dist {
                let f = seg > 0.0001 ? (dist - acc) / seg : 0
                let tNext = CGFloat(i + 1) / CGFloat(steps)
                return max(0, min(1, tNext + (t - tNext) * f))
            }
            acc += seg; prev = cur; i -= 1
        }
        return 0
    }

    let barbT  = tAtDistanceFromTip(hl)
    let notchT = tAtDistanceFromTip(hl * notchR)
    let barbAnchor  = sample(barbT)
    let notchCenter = sample(notchT)

    let barbL = CGPoint(x: barbAnchor.x + perpX * hh, y: barbAnchor.y + perpY * hh)
    let barbR = CGPoint(x: barbAnchor.x - perpX * hh, y: barbAnchor.y - perpY * hh)

    // Shaft centerline tail(0)..notch, widening toward the head.
    let bs = 28
    var center: [CGPoint] = []; var hw: [CGFloat] = []
    center.reserveCapacity(bs + 1); hw.reserveCapacity(bs + 1)
    for k in 0...bs {
        let s = CGFloat(k) / CGFloat(bs)
        center.append(sample(notchT * s))
        hw.append(tailHalf + (nh - tailHalf) * pow(s, taperExp))
    }
    func normal(_ idx: Int) -> (CGFloat, CGFloat) {
        let a = center[max(0, idx - 1)], b = center[min(center.count - 1, idx + 1)]
        let tx = b.x - a.x, ty = b.y - a.y
        let l = hypot(tx, ty)
        guard l > 0.0001 else { return (perpX, perpY) }
        return (-ty / l, tx / l)
    }

    let notchL = CGPoint(x: notchCenter.x + perpX * nh, y: notchCenter.y + perpY * nh)
    let notchRPt = CGPoint(x: notchCenter.x - perpX * nh, y: notchCenter.y - perpY * nh)

    let path = CGMutablePath()
    // Needle tail: a single vertex.
    path.move(to: sample(0))
    // Right shaft edge: tail -> notch.
    for k in 1..<center.count {
        let (nx, ny) = normal(k)
        path.addLine(to: CGPoint(x: center[k].x - nx * hw[k], y: center[k].y - ny * hw[k]))
    }
    path.addLine(to: notchRPt)
    // Concave dart base: notch -> barb, out to the tip and back.
    path.addLine(to: barbR)
    path.addLine(to: tip)
    path.addLine(to: barbL)
    path.addLine(to: notchL)
    // Left shaft edge: notch -> tail.
    for k in stride(from: center.count - 1, through: 1, by: -1) {
        let (nx, ny) = normal(k)
        path.addLine(to: CGPoint(x: center[k].x + nx * hw[k], y: center[k].y + ny * hw[k]))
    }
    path.closeSubpath()
    return path
}

// MARK: Freehand smoothing

// Smooth ink path through `pts` via midpoint-quadratic smoothing: the curve flows
// BETWEEN consecutive midpoints, using each raw interior point as the control.
// Both ends anchor on the real first/last points so round caps sit where the user
// started and finished. With <= 2 distinct points it degrades to a straight segment.
private func kritSmoothInkPath(_ rawPts: [CGPoint]) -> CGPath {
    let path = CGMutablePath()

    var pts: [CGPoint] = []
    pts.reserveCapacity(rawPts.count)
    for p in rawPts {
        if let last = pts.last, kritApproxEqual(last, p) { continue }
        pts.append(p)
    }

    guard pts.count >= 2 else {
        if let only = pts.first { path.move(to: only) }
        return path
    }

    path.move(to: pts[0])

    if pts.count == 2 {
        path.addLine(to: pts[1])
        return path
    }

    let firstMid = kritMidpoint(pts[0], pts[1])
    path.addLine(to: firstMid)

    for i in 1 ..< (pts.count - 1) {
        let control = pts[i]
        let endMid = kritMidpoint(pts[i], pts[i + 1])
        path.addQuadCurve(to: endMid, control: control)
    }

    path.addLine(to: pts[pts.count - 1])
    return path
}

private func kritMidpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
}

private func kritApproxEqual(_ a: CGPoint, _ b: CGPoint) -> Bool {
    abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
}
