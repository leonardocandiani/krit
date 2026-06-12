import AppKit

/// Headless renderer used to eyeball annotation element quality without a screen
/// or any TCC permission. Builds a backdrop that spans light→dark luminance, lays
/// one of every element on top, flattens via the real AnnotationCanvas pipeline
/// (same code path as export), and writes a PNG.
///
/// Invoked with:  KRIT --render-sample /path/out.png
/// This is a development affordance, not a shipped feature.
@MainActor
enum SampleRenderer {

    /// Backgrounds regression grid: the same screenshot composed through the
    /// REAL ScreenshotBackgroundComposer with a spread of preset styles, so the
    /// backgrounds feature can be eyeballed without UI interaction.
    /// Invoked with:  KRIT --backgrounds-lab /path/out.png [/path/input.png]
    static func backgroundsLab(input: String?, to path: String) -> Never {
        let base: NSImage
        if let input, let loaded = NSImage(contentsOfFile: input) {
            base = loaded
        } else {
            // Synthetic stand-in window so the lab also runs with no input.
            let size = NSSize(width: 720, height: 460)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(srgbRed: 0.22, green: 0.24, blue: 0.30, alpha: 1).setFill()
            NSRect(x: 0, y: size.height - 36, width: size.width, height: 36).fill()
            ("Sample window" as NSString).draw(at: NSPoint(x: 16, y: size.height - 28),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
            img.unlockFocus()
            base = img
        }

        func preset(_ name: String, _ mutate: (inout ScreenshotBackgroundOptions) -> Void) -> (String, ScreenshotBackgroundOptions) {
            var options = ScreenshotBackgroundOptions.editorDefault
            options.isEnabled = true
            options.padding = 56
            options.cornerRadius = 14
            options.shadow = 0.7
            mutate(&options)
            return (name, options)
        }

        let cells: [(String, ScreenshotBackgroundOptions)] = [
            preset("Gradient · Aurora") { o in
                o.style = .gradient
                o.gradientStartHex = "#050816"; o.gradientEndHex = "#67d7ff"
                o.accentHexes = ["#7c3aed", "#38f8d4", "#d8f7ff"]
            },
            preset("Gradient · Sunset Coral") { o in
                o.style = .gradient
                o.gradientStartHex = "#fff0d8"; o.gradientEndHex = "#ea4e79"
                o.accentHexes = ["#ffb86b", "#ffd1df", "#7c2d12"]
            },
            preset("Wallpaper · Amber Fold") { o in
                o.style = .image
                let p = ScreenshotBackgroundOptions.imagePresets[0]
                o.presetName = p.name
                o.gradientStartHex = p.startHex; o.gradientEndHex = p.endHex
                o.accentHexes = p.accentHexes
            },
            preset("Wallpaper · Violet Bloom") { o in
                o.style = .image
                let p = ScreenshotBackgroundOptions.imagePresets[8]
                o.presetName = p.name
                o.gradientStartHex = p.startHex; o.gradientEndHex = p.endHex
                o.accentHexes = p.accentHexes
            },
            preset("Blurred wallpaper") { o in
                o.style = .blurredImage
                let p = ScreenshotBackgroundOptions.imagePresets[4]
                o.presetName = p.name
                o.gradientStartHex = p.startHex; o.gradientEndHex = p.endHex
                o.accentHexes = p.accentHexes
            },
            preset("Solid · 1:1 + inset") { o in
                o.style = .solid
                o.colorHex = "#10131c"
                o.aspectPreset = .ratio1x1
                o.inset = 18
            },
        ]

        let composed = cells.map { ScreenshotBackgroundComposer.composeIfNeeded(base, options: $0.1) }
        let cellW: CGFloat = 560
        let labelH: CGFloat = 34
        let cellHs: [CGFloat] = composed.map { img in
            cellW * (img.size.height / max(img.size.width, 1)) + labelH
        }
        let rowH0 = max(cellHs[0], cellHs[1])
        let rowH1 = max(cellHs[2], cellHs[3])
        let rowH2 = max(cellHs[4], cellHs[5])
        let gap: CGFloat = 24
        let sheet = NSImage(size: NSSize(width: cellW * 2 + gap * 3,
                                         height: rowH0 + rowH1 + rowH2 + gap * 4))
        sheet.lockFocus()
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        let rowTops: [CGFloat] = [
            sheet.size.height - gap - rowH0,
            sheet.size.height - gap - rowH0 - gap - rowH1,
            sheet.size.height - gap - rowH0 - gap - rowH1 - gap - rowH2,
        ]
        for (i, img) in composed.enumerated() {
            let row = i / 2, col = i % 2
            let x = gap + CGFloat(col) * (cellW + gap)
            let h = cellW * (img.size.height / max(img.size.width, 1))
            let y = rowTops[row]
            img.draw(in: NSRect(x: x, y: y + labelH, width: cellW, height: h))
            (cells[i].0 as NSString).draw(at: NSPoint(x: x, y: y + 8),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16),
                                 .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("backgrounds lab written to \(path)")
        exit(0)
    }

    /// Full gradient gallery: every curated preset composed through the REAL
    /// ScreenshotBackgroundComposer around a sample window, tiled in a grid so the
    /// whole palette set can be judged at a glance.
    /// Invoked with:  KRIT --gradient-gallery /path/out.png [/path/input.png]
    static func gradientGallery(input: String?, to path: String) -> Never {
        let base: NSImage
        if let input, let loaded = NSImage(contentsOfFile: input) {
            base = loaded
        } else {
            let size = NSSize(width: 640, height: 400)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(srgbRed: 0.22, green: 0.24, blue: 0.30, alpha: 1).setFill()
            NSRect(x: 0, y: size.height - 34, width: size.width, height: 34).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: 14 + CGFloat(i) * 20, y: size.height - 24, width: 12, height: 12)).fill()
            }
            ("Sample window" as NSString).draw(at: NSPoint(x: 84, y: size.height - 27),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            img.unlockFocus()
            base = img
        }

        let presets = ScreenshotBackgroundOptions.imagePresets
        let composed: [(String, NSImage)] = presets.map { preset in
            var o = ScreenshotBackgroundOptions.editorDefault
            o.isEnabled = true
            o.style = .gradient
            o.padding = 64
            o.cornerRadius = 16
            o.shadow = 0.6
            o.gradientStartHex = preset.startHex
            o.gradientEndHex = preset.endHex
            o.accentHexes = preset.accentHexes
            return (preset.name, ScreenshotBackgroundComposer.composeIfNeeded(base, options: o))
        }

        let cols = 3
        let cellW: CGFloat = 460
        let labelH: CGFloat = 30
        let gap: CGFloat = 20
        let aspect = base.size.height / max(base.size.width, 1)
        // The composed cell is the padded canvas; approximate its aspect from padding.
        let cellImgH = cellW * (composed.first?.1.size.height ?? base.size.height) / max(composed.first?.1.size.width ?? base.size.width, 1)
        let cellH = cellImgH + labelH
        _ = aspect
        let rows = Int(ceil(Double(composed.count) / Double(cols)))
        let sheetW = CGFloat(cols) * cellW + CGFloat(cols + 1) * gap
        let sheetH = CGFloat(rows) * cellH + CGFloat(rows + 1) * gap

        let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
        sheet.lockFocus()
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, item) in composed.enumerated() {
            let row = i / cols, col = i % cols
            let x = gap + CGFloat(col) * (cellW + gap)
            // Top-down rows in lockFocus (bottom-left origin) space.
            let yTop = sheetH - gap - CGFloat(row) * (cellH + gap)
            let imgH = cellW * item.1.size.height / max(item.1.size.width, 1)
            item.1.draw(in: NSRect(x: x, y: yTop - imgH, width: cellW, height: imgH))
            (item.0 as NSString).draw(at: NSPoint(x: x + 4, y: yTop - imgH - labelH + 6),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 17),
                                 .foregroundColor: NSColor.white.withAlphaComponent(0.88)])
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("gradient gallery written to \(path)")
        exit(0)
    }

    /// Per-preset gradient proof: renders EVERY curated preset as a standalone
    /// 800x500 PNG of the raw backdrop (no window, no shadow), so each gradient
    /// can be judged full-bleed for banding, depth and palette. Writes one file
    /// per preset into `dir` plus an `_index.txt`, then exits. Headless, no TCC.
    /// Invoked with:  KRIT --render-gradients /path/to/dir
    static func renderGradients(toDirectory dir: String) -> Never {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let size = NSSize(width: 800, height: 500)
        var written: [String] = []
        for preset in ScreenshotBackgroundOptions.imagePresets {
            var o = ScreenshotBackgroundOptions.editorDefault
            o.isEnabled = true
            o.style = .gradient
            o.gradientStartHex = preset.startHex
            o.gradientEndHex = preset.endHex
            o.accentHexes = preset.accentHexes
            // previewImage paints just the backdrop through the REAL drawBackground
            // -> drawMesh path, which is exactly what we want to eyeball.
            let img = ScreenshotBackgroundComposer.previewImage(options: o, size: size, scale: 1)
            let slug = preset.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let outPath = (dir as NSString).appendingPathComponent("\(slug).png")
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: outPath))
            written.append(outPath)
            print(outPath)
        }
        let index = written.joined(separator: "\n") + "\n"
        try? index.write(toFile: (dir as NSString).appendingPathComponent("_index.txt"),
                         atomically: true, encoding: .utf8)
        print("rendered \(written.count) gradients to \(dir)")
        exit(0)
    }

    /// Wallpaper gallery: the sample window composed over real Apple desktop
    /// pictures read from disk (the exact runtime path the sidebar uses), so the
    /// installed-wallpaper background can be eyeballed without UI.
    /// Invoked with:  KRIT --wallpaper-lab /path/out.png [/path/input.png]
    static func wallpaperLab(input: String?, to path: String) -> Never {
        let base: NSImage
        if let input, let loaded = NSImage(contentsOfFile: input) {
            base = loaded
        } else {
            let size = NSSize(width: 640, height: 400)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor(srgbRed: 0.22, green: 0.24, blue: 0.30, alpha: 1).setFill()
            NSRect(x: 0, y: size.height - 34, width: size.width, height: 34).fill()
            ("Sample window" as NSString).draw(at: NSPoint(x: 16, y: size.height - 27),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            img.unlockFocus()
            base = img
        }

        let wallpapers = Array(SystemWallpaperSource.all.prefix(6))
        guard !wallpapers.isEmpty else {
            print("no system wallpapers found")
            exit(1)
        }
        let composed: [(String, NSImage)] = wallpapers.map { w in
            var o = ScreenshotBackgroundOptions.editorDefault
            o.isEnabled = true
            o.style = .image
            o.padding = 80
            o.cornerRadius = 16
            o.shadow = 0.7
            o.presetName = w.name
            // Synchronous decode for the headless lab (sidebar does this async).
            if let src = CGImageSourceCreateWithURL(w.url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: 2200
               ] as CFDictionary) {
                o.customImageData = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            return (w.name, ScreenshotBackgroundComposer.composeIfNeeded(base, options: o))
        }

        let cols = 3
        let cellW: CGFloat = 460
        let labelH: CGFloat = 30
        let gap: CGFloat = 20
        let cellImgH = cellW * (composed[0].1.size.height / max(composed[0].1.size.width, 1))
        let cellH = cellImgH + labelH
        let rows = Int(ceil(Double(composed.count) / Double(cols)))
        let sheetW = CGFloat(cols) * cellW + CGFloat(cols + 1) * gap
        let sheetH = CGFloat(rows) * cellH + CGFloat(rows + 1) * gap

        let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
        sheet.lockFocus()
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, item) in composed.enumerated() {
            let row = i / cols, col = i % cols
            let x = gap + CGFloat(col) * (cellW + gap)
            let yTop = sheetH - gap - CGFloat(row) * (cellH + gap)
            let imgH = cellW * item.1.size.height / max(item.1.size.width, 1)
            item.1.draw(in: NSRect(x: x, y: yTop - imgH, width: cellW, height: imgH))
            (item.0 as NSString).draw(at: NSPoint(x: x + 4, y: yTop - imgH - labelH + 6),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 17),
                                 .foregroundColor: NSColor.white.withAlphaComponent(0.88)])
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wallpaper lab written to \(path)")
        exit(0)
    }

    /// Arrow regression grid: the dart-head arrow across stroke widths and
    /// lengths, straight and curved, so geometry changes are eyeballed fast.
    static func arrowLab(to path: String) -> Never {
        let size = NSSize(width: 1500, height: 1100)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

        // (label, lineWidth)
        let presets: [(String, CGFloat)] = [
            ("w2", 2), ("w4", 4),
            ("w7", 7), ("w10", 10),
            ("w14", 14), ("w20 short", 20),
        ]
        let coral = NSColor(srgbRed: 1.0, green: 0x78/255.0, blue: 0x47/255.0, alpha: 1)
        for (i, p) in presets.enumerated() {
            let row = i / 2, col = i % 2
            let ox: CGFloat = 80 + CGFloat(col) * 720
            let oy: CGFloat = CGFloat(size.height) - 180 - CGFloat(row) * 320
            let span: CGFloat = p.0.hasSuffix("short") ? 90 : 360
            // straight arrow
            if let path = kritArrowPath(start: CGPoint(x: ox, y: oy - 120),
                                        end: CGPoint(x: ox + span, y: oy),
                                        control: nil, lineWidth: p.1) {
                ctx.setFillColor(coral.cgColor); ctx.addPath(path); ctx.fillPath()
            }
            // curved arrow
            if let path = kritArrowPath(start: CGPoint(x: ox + 420, y: oy - 30),
                                        end: CGPoint(x: ox + 660, y: oy - 30),
                                        control: CGPoint(x: ox + 540, y: oy - 150),
                                        lineWidth: p.1) {
                ctx.setFillColor(coral.cgColor); ctx.addPath(path); ctx.fillPath()
            }
            (p.0 as NSString).draw(at: NSPoint(x: ox, y: oy + 60),
                                   withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                                                    .foregroundColor: NSColor.black])
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
        exit(0)
    }

    static func run(to path: String) -> Never {
        let size = NSSize(width: 1400, height: 900)
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: size))
        canvas.backgroundImage = backdrop(size: size)
        var opts = ScreenshotBackgroundOptions.editorDefault
        opts.isEnabled = false   // draw the raw backdrop as if it were the screenshot
        canvas.backgroundOptions = opts
        canvas.objects = sampleObjects()

        let flat = canvas.flatten()
        guard let tiff = flat.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print(path)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// Vertical gradient white→near-black with two neutral cards, so each element
    /// is judged against the full luminance range (shadows on light, text on dark).
    private static func backdrop(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(white: 0.96, alpha: 1),
            NSColor(white: 0.62, alpha: 1),
            NSColor(white: 0.10, alpha: 1),
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // Cards to test contrast extremes (bottom-up coords here, lockFocus space).
        // Upper-right light card: shadows + freehand on white.
        NSColor(white: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 980, y: 540, width: 360, height: 300),
                     xRadius: 16, yRadius: 16).fill()
        // Lower-left light "paper": the realistic highlighter scenario (dark text,
        // yellow marker on light). Multiply only reads correctly over light.
        NSColor(white: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 60, width: 440, height: 240),
                     xRadius: 16, yRadius: 16).fill()
        // Lower-center dark card: coral/halo text legibility on dark.
        NSColor(white: 0.06, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 600, y: 70, width: 340, height: 180),
                     xRadius: 16, yRadius: 16).fill()
        img.unlockFocus()
        return img
    }

    /// One of every element, with brand-coral defaults plus a couple of palette
    /// variants. Coordinates are top-left origin (canvas is isFlipped = true).
    private static func sampleObjects() -> [any AnnotationObject] {
        var out: [any AnnotationObject] = []

        // Arrows: straight + curved, at the new default weight (4).
        let a1 = ArrowAnnotation(start: CGPoint(x: 130, y: 200), end: CGPoint(x: 380, y: 360))
        a1.lineWidth = 4
        out.append(a1)

        let a2 = ArrowAnnotation(start: CGPoint(x: 130, y: 470), end: CGPoint(x: 400, y: 470))
        a2.controlPoint = CGPoint(x: 265, y: 360)
        a2.lineWidth = 4
        out.append(a2)

        // Rectangle outlined + filled
        let r1 = RectangleAnnotation(rect: CGRect(x: 470, y: 150, width: 230, height: 150))
        r1.lineWidth = 4
        out.append(r1)

        let r2 = RectangleAnnotation(rect: CGRect(x: 470, y: 340, width: 230, height: 150), filled: true)
        r2.lineWidth = 4
        out.append(r2)

        // Ellipse + line
        let e1 = EllipseAnnotation(rect: CGRect(x: 740, y: 150, width: 210, height: 150))
        e1.lineWidth = 4
        out.append(e1)

        let l1 = LineAnnotation(start: CGPoint(x: 740, y: 360), end: CGPoint(x: 950, y: 470))
        l1.lineWidth = 4
        out.append(l1)

        // Freehand (wavy)
        let f1 = FreehandAnnotation()
        f1.lineWidth = 4
        var pts: [CGPoint] = []
        for i in 0...40 {
            let t = CGFloat(i) / 40
            pts.append(CGPoint(x: 1010 + t * 320, y: 200 + sin(t * .pi * 3) * 60))
        }
        f1.points = pts
        out.append(f1)

        // Numbered steps
        for (i, x) in [560, 640, 720].enumerated() {
            let n = NumberedStepAnnotation(center: CGPoint(x: CGFloat(x), y: 600), number: i + 1)
            out.append(n)
        }

        // Highlighter over a text label
        let label = TextAnnotation(origin: CGPoint(x: 140, y: 690))
        label.text = "Highlighted text"
        label.fontSize = 30
        label.color = NSColor(white: 0.12, alpha: 1)
        let hl = HighlighterAnnotation(start: CGPoint(x: 150, y: 712),
                                       end: CGPoint(x: 470, y: 712))
        hl.lineWidth = 34
        out.append(hl)
        out.append(label)

        // Text on dark card (legibility test)
        let t1 = TextAnnotation(origin: CGPoint(x: 110, y: 120))
        t1.text = "KRIT"
        t1.fontSize = 56
        out.append(t1)

        // Text on light card
        let t2 = TextAnnotation(origin: CGPoint(x: 1010, y: 620))
        t2.text = "Readable"
        t2.fontSize = 40
        out.append(t2)

        // Coral text over the dark card (halo legibility on dark)
        let t3 = TextAnnotation(origin: CGPoint(x: 650, y: 700))
        t3.text = "On dark"
        t3.fontSize = 38
        out.append(t3)

        return out
    }
}
