import AppKit
import UniformTypeIdentifiers
import ImageIO

enum ImageExporter {

    enum ExportError: LocalizedError {
        case pngEncodingFailed
        case encodingFailed(format: String)

        var errorDescription: String? {
            switch self {
            case .pngEncodingFailed:
                "Could not encode screenshot as PNG."
            case .encodingFailed(let format):
                "Could not encode screenshot as \(format.uppercased())."
            }
        }
    }

    enum SavePanelResult {
        case saved(URL)
        case cancelled
        case failed(URL?)

        var didSave: Bool {
            if case .saved = self { return true }
            return false
        }
    }

    private static let webpUTI = "org.webmproject.webp" as CFString
    private static var activeSavePanels: [NSSavePanel] = []

    // MARK: - Clipboard

    static func copyToClipboard(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // PNG only, NSPasteboard synthesizes TIFF on demand for legacy readers,
        // and every modern macOS app (Slack, Notion, Figma, Preview, Messages)
        // prefers PNG. Skipping the TIFF encode saves ~30 MB + ~50 ms per 4K copy.
        guard let cg = image.bestCGImage, let png = pngData(from: cg) else { return }
        pb.declareTypes([.png], owner: nil)
        pb.setData(png, forType: .png)
    }

    private static let nameFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return df
    }()

    static var timestampedName: String {
        "KRIT \(nameFormatter.string(from: Date()))"
    }

    // MARK: - Save with panel

    @MainActor
    static func saveWithPanel(image: NSImage, suggestedName: String, presentingWindow: NSWindow? = nil, completion: ((SavePanelResult) -> Void)? = nil) {
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        presentingWindow?.deminiaturize(nil)
        presentingWindow?.makeKeyAndOrderFront(nil)
        presentingWindow?.orderFrontRegardless()

        let panel = NSSavePanel()
        let preferredExt = Settings.screenshotFormat
        panel.nameFieldStringValue = "\(suggestedName).\(preferredExt)"
        panel.allowedContentTypes = [.png, .jpeg, UTType("org.webmproject.webp") ?? .data, .pdf]
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        activeSavePanels.append(panel)

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            activeSavePanels.removeAll { $0 === panel }

            guard response == .OK else {
                completion?(.cancelled)
                return
            }

            guard let url = panel.url else {
                completion?(.failed(nil))
                showSaveFailedAlert(for: nil, presentingWindow: presentingWindow)
                return
            }

            guard let savedURL = save(image: image, to: url) else {
                completion?(.failed(url))
                showSaveFailedAlert(for: url, presentingWindow: presentingWindow)
                return
            }

            completion?(.saved(savedURL))
        }

        if let presentingWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    @MainActor
    private static func showSaveFailedAlert(for url: URL?, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Save Screenshot"
        if let url {
            alert.informativeText = "KRIT could not write the file to:\n\(url.path)"
        } else {
            alert.informativeText = "The save panel did not return a destination. Please try saving again."
        }
        alert.addButton(withTitle: "OK")

        if let presentingWindow, presentingWindow.isVisible {
            alert.beginSheetModal(for: presentingWindow)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Silent save

    @discardableResult
    static func save(image: NSImage, to url: URL) -> URL? {
        // Extract the CGImage once and reuse it for whichever encoder runs.
        guard let cg = image.bestCGImage else {
            print("[KRIT] Save failed: image has no CGImage backing")
            return nil
        }
        let ext = url.pathExtension.lowercased()
        var outputURL = url
        let data: Data?
        switch ext {
        case "jpg", "jpeg": data = jpegData(from: cg, quality: CGFloat(Settings.jpegQuality))
        case "webp":
            if isWebPSupported, let webp = webpData(from: cg) {
                data = webp
            } else {
                outputURL = url.deletingPathExtension().appendingPathExtension("png")
                data = pngData(from: cg)
            }
        case "pdf":         data = pdfData(from: image)
        default:            data = pngData(from: cg)
        }
        guard let data else {
            print("[KRIT] Save failed: unable to encode image")
            return nil
        }
        do {
            let dir = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
            HistoryManager.applyScreenshotMetadata(to: outputURL.path, rect: nil)
            return outputURL
        } catch {
            print("[KRIT] Save failed at \(outputURL.path): \(error)")
            return nil
        }
    }

    // MARK: - Format helpers
    //
    // The CGImage-taking variants are the primitive, each encode extracts the
    // best CGImage off the NSImage at most once per call site. The NSImage
    // overloads are kept for callers that don't already hold a CGImage.

    static func pngData(from cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from cg: CGImage, quality: CGFloat = 0.95) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func webpData(from cg: CGImage, quality: CGFloat = 0.90) -> Data? {
        guard isWebPSupported else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, webpUTI, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Single-page PDF wrapping the capture. The page is sized in POINTS (the
    /// capture's logical size) with the full-resolution bitmap embedded, so the
    /// document opens at the screenshot's natural size in Preview and stays crisp
    /// when zoomed or printed — a Retina/supersampled shot does not blow the page
    /// up to its raw pixel dimensions. The bitmap is embedded losslessly, not
    /// re-rendered. Falls back to the pixel size when no point size is supplied.
    static func pdfData(from cg: CGImage, pointSize: CGSize? = nil) -> Data? {
        guard cg.width > 0, cg.height > 0 else { return nil }
        let pageSize: CGSize = {
            if let pointSize, pointSize.width >= 1, pointSize.height >= 1 { return pointSize }
            return CGSize(width: cg.width, height: cg.height)
        }()
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.draw(cg, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Preferred-format export
    //
    // Single source of truth for "what format does the user want and how do we
    // name/tag it". Save, drag-to-file and share all run through this so a PDF (or
    // JPEG/WebP) choice is honored everywhere a FILE is produced. The clipboard
    // deliberately stays PNG (every target app prefers it).

    /// The user's chosen output format, normalized: webp falls back to png when the
    /// codec is missing, jpg/jpeg collapse to jpg, anything unknown is png.
    static func preferredFormat() -> (ext: String, uti: String) {
        switch Settings.screenshotFormat.lowercased() {
        case "jpg", "jpeg": return ("jpg", "public.jpeg")
        case "webp":        return isWebPSupported ? ("webp", webpUTI as String) : ("png", "public.png")
        case "pdf":         return ("pdf", "com.adobe.pdf")
        default:            return ("png", "public.png")
        }
    }

    /// Encode `image` in the user's preferred format, returning the bytes plus the
    /// matching file extension and UTI so a drag/share/save stay in sync.
    static func encodedForExport(_ image: NSImage) -> (data: Data, ext: String, uti: String)? {
        guard let cg = image.bestCGImage else { return nil }
        let pts = (image.size.width >= 1 && image.size.height >= 1) ? image.size
            : CGSize(width: cg.width, height: cg.height)
        return encodedForExport(cg: cg, pointSize: pts)
    }

    /// CGImage variant, safe to call off the main thread (no NSImage access).
    /// `pointSize` is the logical size used for the PDF page; raster formats ignore it.
    static func encodedForExport(cg: CGImage, pointSize: CGSize) -> (data: Data, ext: String, uti: String)? {
        let format = preferredFormat()
        let data: Data?
        switch format.ext {
        case "jpg":  data = jpegData(from: cg, quality: CGFloat(Settings.jpegQuality))
        case "webp": data = webpData(from: cg)
        case "pdf":  data = pdfData(from: cg, pointSize: pointSize)
        default:     data = pngData(from: cg)
        }
        guard let data else { return nil }
        return (data, format.ext, format.uti)
    }

    private static var isWebPSupported: Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
        return identifiers.contains(webpUTI)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return pngData(from: cg)
    }

    static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return jpegData(from: cg, quality: quality)
    }

    static func webpData(from image: NSImage, quality: CGFloat = 0.90) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return webpData(from: cg, quality: quality)
    }

    static func pdfData(from image: NSImage) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        let pts = (image.size.width >= 1 && image.size.height >= 1) ? image.size : nil
        return pdfData(from: cg, pointSize: pts)
    }
}

extension NSImage {
    /// Extract the highest-resolution CGImage backing this NSImage.
    /// Prefers the raw CGImage from NSBitmapImageRep (zero resampling) over
    /// `cgImage(forProposedRect:)` which re-renders through CoreGraphics and
    /// can introduce interpolation blur.
    ///
    /// Cached per-instance via associated object so repeated export paths
    /// (history PNG + thumbnail + clipboard) only compute this once.
    var bestCGImage: CGImage? {
        if let cached = objc_getAssociatedObject(self, &NSImage.bestCGImageKey) as! CGImage? {
            return cached
        }
        let computed = computeBestCGImage()
        if let computed {
            objc_setAssociatedObject(self, &NSImage.bestCGImageKey, computed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return computed
    }

    private static var bestCGImageKey: UInt8 = 0

    private func computeBestCGImage() -> CGImage? {
        var best: CGImage?
        var bestPixels = 0
        for rep in representations {
            if let bitmapRep = rep as? NSBitmapImageRep, let cg = bitmapRep.cgImage {
                let pixels = cg.width * cg.height
                if pixels > bestPixels {
                    best = cg
                    bestPixels = pixels
                }
            }
        }
        if let best { return best }

        let maxRep = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        let pixelW = maxRep?.pixelsWide ?? Int(size.width)
        let pixelH = maxRep?.pixelsHigh ?? Int(size.height)
        var proposedRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
