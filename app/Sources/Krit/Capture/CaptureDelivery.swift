import AppKit

/// Immutable raster passed across the AppKit/background boundary. `CGImage` is
/// immutable; the wrapper keeps the unchecked conformance local instead of
/// sending `NSImage` through detached encoding tasks.
struct CaptureRaster: @unchecked Sendable {
    let cgImage: CGImage
    let pointSize: CGSize
}

/// Every property that changes the encoded bytes is part of this key. The cache
/// belongs to one capture, so it never retains or reuses pixels across captures.
enum CaptureEncoding: Hashable, Sendable {
    case png
    case jpeg(quality: Int)
    case webp(quality: Int)
    case pdf
    case thumbnailPNG(maxDimension: Int)

    static func fileFormat(extension rawExtension: String, jpegQuality: Double) -> CaptureEncoding {
        switch rawExtension.lowercased() {
        case "jpg", "jpeg":
            return .jpeg(quality: quantized(jpegQuality))
        case "webp":
            return .webp(quality: 9_000)
        case "pdf":
            return .pdf
        default:
            return .png
        }
    }

    fileprivate static func quantized(_ quality: Double) -> Int {
        min(max(Int((quality * 10_000).rounded()), 0), 10_000)
    }
}

struct EncodedCapture: Sendable {
    let data: Data
    let ext: String
    let uti: String
}

/// Per-capture rendition cache. It stores the in-flight Task as well as the
/// completed result, so concurrent history/clipboard/autosave requests share
/// the same encode instead of merely sharing the bytes after the first finishes.
actor CaptureArtifact {
    typealias Encoder = @Sendable (CaptureRaster, CaptureEncoding) -> EncodedCapture?

    private enum Cached: Sendable {
        case value(EncodedCapture)
        case failure
    }

    private let raster: CaptureRaster
    private let encoder: Encoder
    private var cached: [CaptureEncoding: Cached] = [:]
    private var inFlight: [CaptureEncoding: Task<EncodedCapture?, Never>] = [:]

    init?(image: NSImage) {
        self.init(image: image) { raster, format in
            CaptureArtifact.encode(raster, as: format)
        }
    }

    init?(image: NSImage, encoder: @escaping Encoder) {
        guard let cgImage = image.bestCGImage else { return nil }
        let pointSize = image.size.width >= 1 && image.size.height >= 1
            ? image.size
            : CGSize(width: cgImage.width, height: cgImage.height)
        raster = CaptureRaster(cgImage: cgImage, pointSize: pointSize)
        self.encoder = encoder
    }

    func encoded(as format: CaptureEncoding) async -> EncodedCapture? {
        if let cached = cached[format] {
            switch cached {
            case .value(let capture): return capture
            case .failure: return nil
            }
        }

        if let task = inFlight[format] {
            return await task.value
        }

        let raster = raster
        let encoder = encoder
        let task = Task.detached(priority: .userInitiated) {
            encoder(raster, format)
        }
        inFlight[format] = task

        let result = await task.value
        inFlight[format] = nil
        if let result {
            cached[format] = .value(result)
        } else {
            cached[format] = .failure
        }
        return result
    }

    private nonisolated static func encode(
        _ raster: CaptureRaster,
        as format: CaptureEncoding
    ) -> EncodedCapture? {
        switch format {
        case .png:
            guard let data = ImageExporter.pngData(from: raster.cgImage) else { return nil }
            return EncodedCapture(data: data, ext: "png", uti: "public.png")
        case .jpeg(let quality):
            guard let data = ImageExporter.jpegData(
                from: raster.cgImage,
                quality: CGFloat(quality) / 10_000
            ) else { return nil }
            return EncodedCapture(data: data, ext: "jpg", uti: "public.jpeg")
        case .webp(let quality):
            if let data = ImageExporter.webpData(
                from: raster.cgImage,
                quality: CGFloat(quality) / 10_000
            ) {
                return EncodedCapture(data: data, ext: "webp", uti: "org.webmproject.webp")
            }
            guard let data = ImageExporter.pngData(from: raster.cgImage) else { return nil }
            return EncodedCapture(data: data, ext: "png", uti: "public.png")
        case .pdf:
            guard let data = ImageExporter.pdfData(
                from: raster.cgImage,
                pointSize: raster.pointSize
            ) else { return nil }
            return EncodedCapture(data: data, ext: "pdf", uti: "com.adobe.pdf")
        case .thumbnailPNG(let maxDimension):
            guard let thumbnail = downsample(
                raster.cgImage,
                maxDimension: maxDimension
            ), let data = ImageExporter.pngData(from: thumbnail) else { return nil }
            return EncodedCapture(data: data, ext: "png", uti: "public.png")
        }
    }

    private nonisolated static func downsample(
        _ image: CGImage,
        maxDimension: Int
    ) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > CGFloat(maxDimension) else { return image }

        let scale = CGFloat(maxDimension) / longest
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        return context.makeImage()
    }
}

struct CaptureActionRequest: Sendable {
    let actions: [CaptureAction]
    let format: String
    let jpegQuality: Double
    let saveURL: URL
}

/// True external effects for an action chain. Encoding stays in
/// `CaptureArtifact`; the sink receives ready-to-use bytes and can fail one
/// destination without aborting the remaining actions.
@MainActor
protocol CaptureActionSink: AnyObject {
    func copyPNG(_ data: Data)
    func save(_ capture: EncodedCapture, to requestedURL: URL) async -> Bool
    func edit(_ image: NSImage)
    func pin(_ image: NSImage)
}

@MainActor
final class LiveCaptureActionSink: CaptureActionSink {
    static let shared = LiveCaptureActionSink()

    private init() {}

    func copyPNG(_ data: Data) {
        ImageExporter.copyPNGToClipboard(data)
    }

    func save(_ capture: EncodedCapture, to requestedURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            ImageExporter.save(
                encoded: capture,
                to: requestedURL,
                collisionPolicy: .uniquify
            ) != nil
        }.value
    }

    func edit(_ image: NSImage) {
        AnnotationWindowController.open(image: image)
        NSApp.activate(ignoringOtherApps: true)
    }

    func pin(_ image: NSImage) {
        PinnedWindow.pin(image: image)
    }
}

@MainActor
struct CaptureDeliveryReceipt {
    let presentedImage: NSImage
    let historyItem: HistoryItem
    let presentedArtifact: CaptureArtifact?
}

/// Single post-capture boundary. The synchronous half stages history and starts
/// visual feedback. Only after the optional one-shot follow-up has observed that
/// receipt does the asynchronous destination chain begin.
@MainActor
enum CaptureDelivery {
    struct Request {
        let rawImage: NSImage
        let presentedImage: NSImage
        let rect: CGRect
        let screen: NSScreen?
        let isWindowCapture: Bool
        let showOverlay: Bool
        let automaticActions: CaptureActionRequest?
    }

    @discardableResult
    static func submit(
        _ request: Request,
        historyManager: HistoryManager,
        followUp: ((CaptureDeliveryReceipt) -> Void)? = nil
    ) -> CaptureDeliveryReceipt {
        let rawArtifact = CaptureArtifact(image: request.rawImage)
        let presentedArtifact = request.presentedImage === request.rawImage
            ? rawArtifact
            : CaptureArtifact(image: request.presentedImage)

        let item = historyManager.add(
            image: request.rawImage,
            rect: request.rect,
            isWindowCapture: request.isWindowCapture,
            presentedImage: request.presentedImage,
            rawArtifact: rawArtifact,
            presentedArtifact: presentedArtifact
        )

        if request.showOverlay, let screen = request.screen {
            QuickAccessOverlay.show(
                image: request.presentedImage,
                historyItem: item,
                historyManager: historyManager,
                presentedArtifact: presentedArtifact,
                screen: screen,
                entrance: .handoff
            )
            // The capture already received shutter feedback at the gesture. Surface
            // the real card now instead of placing an inert fly-to-tray ghost above
            // it, so the first drag after a capture always has a live target.
            QuickAccessOverlay.revealPendingHandoff(after: 0)
        }

        let receipt = CaptureDeliveryReceipt(
            presentedImage: request.presentedImage,
            historyItem: item,
            presentedArtifact: presentedArtifact
        )

        // Keep the established ordering: one-shot `then=` / Snap & Paste sees the
        // presented receipt before Preferences auto-actions are scheduled.
        followUp?(receipt)

        if let actions = request.automaticActions, !actions.actions.isEmpty {
            if let presentedArtifact {
                Task { @MainActor in
                    await CaptureActionChain.run(
                        actions,
                        image: request.presentedImage,
                        artifact: presentedArtifact,
                        sink: LiveCaptureActionSink.shared
                    )
                }
            } else {
                CaptureActionChain.apply(
                    actions.actions,
                    to: request.presentedImage,
                    format: actions.format
                )
            }
        }

        return receipt
    }
}
