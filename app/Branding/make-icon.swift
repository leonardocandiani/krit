import AppKit
import CoreGraphics

// Regenerates the KRIT app icon in the macOS 26 "Liquid Glass" idiom: a dark
// refractive glass tile with a top specular sheen, a coral warmth from below,
// and the brand crop-brackets rendered as lit glass elements (glossy top-light
// + coral bloom + inner rim). Re-rendered crisply at every icon size.
//
//   swiftc Branding/make-icon.swift -o /tmp/krit-make-icon && /tmp/krit-make-icon Branding
//
// Produces Branding/KRIT.iconset/* and Branding/KRIT.icns (via iconutil).

let coral = CGColor(srgbRed: 1.0, green: 0x78/255.0, blue: 0x47/255.0, alpha: 1)
let coralLight = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.42, alpha: 1)
let coralDeep = CGColor(srgbRed: 0.86, green: 0.38, blue: 0.18, alpha: 1)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func lerpRect(_ r: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> CGRect { r.insetBy(dx: r.width * dx, dy: r.height * dy) }

/// Continuous-looking rounded rect (Apple icon squircle approximation).
func squircle(_ rect: CGRect) -> CGPath {
    let r = rect.width * 0.2237
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat, mode: CGBlendMode = .normal) {
    let c = color.copy(alpha: alpha)!
    let clear = color.copy(alpha: 0)!
    guard let g = CGGradient(colorsSpace: sRGB, colors: [c, clear] as CFArray, locations: [0, 1]) else { return }
    ctx.saveGState()
    ctx.setBlendMode(mode)
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
    ctx.restoreGState()
}

/// One crop bracket as a filled L (two overlapping rounded bars meeting at a corner).
/// corner = the inner vertex; hx/vy are the directions the arms extend (+1/-1).
func bracketPath(corner: CGPoint, arm: CGFloat, thickness t: CGFloat, hx: CGFloat, vy: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let cap = t / 2
    // Horizontal arm.
    let hRect = CGRect(
        x: min(corner.x, corner.x + hx * arm),
        y: corner.y - cap,
        width: arm, height: t
    )
    // Vertical arm.
    let vRect = CGRect(
        x: corner.x - cap,
        y: min(corner.y, corner.y + vy * arm),
        width: t, height: arm
    )
    p.addPath(CGPath(roundedRect: hRect, cornerWidth: cap, cornerHeight: cap, transform: nil))
    p.addPath(CGPath(roundedRect: vRect, cornerWidth: cap, cornerHeight: cap, transform: nil))
    return p
}

func drawIcon(size S: CGFloat) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int(S), height: Int(S),
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Apple icons leave a margin; art sits in ~82% of the canvas.
    let margin = S * 0.085
    let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let shape = squircle(rect)

    // ---- Glass tile body ----
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Base vertical gradient: lit charcoal top -> deep void bottom.
    let top = CGColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1)
    let midC = CGColor(srgbRed: 0.09, green: 0.095, blue: 0.115, alpha: 1)
    let bottom = CGColor(srgbRed: 0.05, green: 0.052, blue: 0.066, alpha: 1)
    if let g = CGGradient(colorsSpace: sRGB, colors: [top, midC, bottom] as CFArray, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    }
    // Coral warmth rising from the bottom-right (brand).
    radial(ctx, center: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.18),
           radius: rect.width * 0.85, color: coral, alpha: 0.40, mode: .screen)
    // Cool top-left counter-light for depth.
    radial(ctx, center: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.05),
           radius: rect.width * 0.7, color: CGColor(srgbRed: 0.5, green: 0.6, blue: 0.9, alpha: 1), alpha: 0.12, mode: .screen)
    // Top specular sheen.
    radial(ctx, center: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.04),
           radius: rect.width * 0.62, color: .white, alpha: 0.14, mode: .screen)
    ctx.restoreGState()

    // ---- Brand brackets ----
    let armLen = rect.width * 0.235
    let thick = rect.width * 0.072
    let frame = lerpRect(rect, 0.27, 0.27)   // where the bracket corners live
    // Top-left bracket: corner at top-left, arms go right + down.
    let tl = CGPoint(x: frame.minX, y: frame.maxY)
    let tlPath = bracketPath(corner: tl, arm: armLen, thickness: thick, hx: 1, vy: -1)
    // Bottom-right bracket: corner at bottom-right, arms go left + up.
    let br = CGPoint(x: frame.maxX, y: frame.minY)
    let brPath = bracketPath(corner: br, arm: armLen, thickness: thick, hx: -1, vy: 1)

    let marks = CGMutablePath()
    marks.addPath(tlPath)
    marks.addPath(brPath)

    // Coral bloom behind the marks (lit glass).
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.035, color: coral.copy(alpha: 0.75))
    ctx.addPath(marks)
    ctx.setFillColor(coral)
    ctx.fillPath()
    ctx.restoreGState()

    // Glossy top-lit fill (vertical gradient per mark region).
    ctx.saveGState()
    ctx.addPath(marks)
    ctx.clip()
    if let g = CGGradient(colorsSpace: sRGB, colors: [coralLight, coral, coralDeep] as CFArray, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: frame.maxY + thick / 2), end: CGPoint(x: rect.midX, y: frame.minY - thick / 2), options: [])
    }
    // Specular top edge on the marks.
    radial(ctx, center: CGPoint(x: tl.x + armLen * 0.5, y: tl.y), radius: armLen, color: .white, alpha: 0.30, mode: .screen)
    ctx.restoreGState()

    // ---- Inner rim light on the tile edge ----
    ctx.saveGState()
    ctx.addPath(squircle(rect.insetBy(dx: S * 0.004, dy: S * 0.004)))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, S * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

// ---- Build the iconset ----
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("KRIT.iconset")
try? fm.removeItem(at: iconset)
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in specs {
    if let img = drawIcon(size: CGFloat(px)) {
        writePNG(img, to: iconset.appendingPathComponent(name))
    }
}
// A standalone 512 preview for eyeballing.
if let img = drawIcon(size: 512) {
    writePNG(img, to: URL(fileURLWithPath: outDir).appendingPathComponent("KRIT-preview.png"))
}
print("iconset written to \(iconset.path)")
