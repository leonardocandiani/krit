import AppKit
import ScreenCaptureKit

/// Scrolling capture: user selects a region, then scrolls. KRIT stitches frames.
@MainActor
final class ScrollingCaptureController: NSObject {

    private var selectionWindow: AreaSelectionWindow?
    private var captureRect: CGRect?
    private var captureScreen: NSScreen?
    private var frames: [NSImage] = []
    /// Hard cap on retained Retina frames: a runaway scroll would otherwise hoard
    /// every full-resolution frame in RAM (each stitched into a contiguous RGBA8
    /// buffer later), spiking to hundreds of MB. ~300 frames * 300ms ≈ 90s, enough
    /// for any real page; past it we stop sampling rather than risk OOM.
    private static let maxRetainedFrames = 300
    private var isCapturing = false
    private var isCapturingFrame = false
    /// True from finishCapture until the detached stitch + save completes, so a new
    /// scrolling capture can't start (and race a second stitch/overlay) while the
    /// previous one is still being assembled off-main.
    private var isFinishing = false
    private var captureTimer: Timer?
    private var statusWindow: ScrollingStatusWindow?
    private var hiddenDesktopIconsByCapture = false
    private var pendingStopHistoryManager: HistoryManager?
    /// Single reusable capture engine, never allocate per-frame
    private let captureEngine = CaptureEngine()

    var isActive: Bool { isCapturing || isFinishing || selectionWindow != nil }

    deinit {
        captureTimer?.invalidate()
    }

    func start(historyManager: HistoryManager, hiddenDesktopIconsByCapture: Bool = false) async {
        self.hiddenDesktopIconsByCapture = hiddenDesktopIconsByCapture
        selectionWindow = AreaSelectionWindow(mode: .area) { [weak self] rect, screen, _ in
            guard let self else { return }
            self.selectionWindow = nil
            guard let rect else {
                DesktopIconsManager.showAfterCapture(ifHiddenByCapture: self.hiddenDesktopIconsByCapture)
                self.hiddenDesktopIconsByCapture = false
                return
            }
            self.captureRect = rect
            self.captureScreen = screen
            self.beginScrollingPhase(historyManager: historyManager)
        }
        await selectionWindow?.prepareAndShow(engine: captureEngine)
    }

    private func beginScrollingPhase(historyManager: HistoryManager) {
        guard let rect = captureRect else { return }
        frames = []
        isCapturing = true

        statusWindow = ScrollingStatusWindow()
        statusWindow?.show(near: CGPoint(x: rect.midX, y: rect.maxY + 20))
        statusWindow?.stopHandler = { [weak self] in
            self?.stopCapture(historyManager: historyManager)
        }

        // Capture first frame immediately
        captureFrame()

        // Then capture a frame every 300ms while user scrolls (150ms was too aggressive)
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.captureFrame() }
        }
    }

    private func captureFrame() {
        guard isCapturing, let rect = captureRect, let screen = captureScreen else { return }
        guard !isCapturingFrame else { return }
        // Stop sampling once the retained-frame cap is hit so memory can't run away.
        guard frames.count < Self.maxRetainedFrames else {
            captureTimer?.invalidate()
            captureTimer = nil
            statusWindow?.updateCount(frames.count)
            return
        }
        isCapturingFrame = true
        Task {
            if let img = await captureEngine.captureRectToImage(rect, on: screen) {
                self.frames.append(img)
                self.statusWindow?.updateCount(self.frames.count)
            }
            self.isCapturingFrame = false
            if let historyManager = self.pendingStopHistoryManager {
                self.pendingStopHistoryManager = nil
                self.finishCapture(historyManager: historyManager)
            }
        }
    }

    private func stopCapture(historyManager: HistoryManager) {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false

        if isCapturingFrame {
            pendingStopHistoryManager = historyManager
            return
        }

        finishCapture(historyManager: historyManager)
    }

    private func finishCapture(historyManager: HistoryManager) {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        isCapturingFrame = false
        selectionWindow = nil
        statusWindow?.orderOut(nil)
        statusWindow = nil
        let shouldRestoreDesktopIcons = hiddenDesktopIconsByCapture
        hiddenDesktopIconsByCapture = false

        guard !frames.isEmpty else {
            DesktopIconsManager.showAfterCapture(ifHiddenByCapture: shouldRestoreDesktopIcons)
            return
        }
        // Keep isActive true across the off-main stitch so a new scrolling capture
        // can't start and race a second stitch/overlay.
        isFinishing = true
        let framesToStitch = frames
        let rect = captureRect ?? .zero
        // Capture the values directly (no [weak self]/guard): the finished capture
        // must be saved even if the controller would otherwise be released, and
        // self is needed to clear isFinishing, so retain it for the stitch.
        Task.detached(priority: .userInitiated) {
            let stitched = FrameStitcher.stitch(frames: framesToStitch)
            await MainActor.run {
                self.isFinishing = false
                let item = historyManager.add(image: stitched, rect: rect)

                if Settings.afterCaptureCopyToClipboard {
                    ImageExporter.copyToClipboard(image: stitched)
                }
                if Settings.afterCaptureSaveAutomatically {
                    let dir = Settings.autoSaveLocation
                    let name = ImageExporter.timestampedName
                    let ext = Settings.screenshotFormat
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
                    ImageExporter.save(image: stitched, to: url)
                }
                if Settings.afterCaptureShowOverlay {
                    QuickAccessOverlay.show(image: stitched, historyItem: item, historyManager: historyManager, screen: self.captureScreen)
                }
                DesktopIconsManager.showAfterCapture(ifHiddenByCapture: shouldRestoreDesktopIcons)
            }
        }
    }
}

// MARK: - Frame Stitcher

enum FrameStitcher {

    /// Band height (rows) used as the cross-correlation template. 8 rows is enough
    /// to lock the seam reliably and keeps the search cheap (O(frameHeight * band * width)).
    private static let correlationRows = 8
    /// Mean absolute per-byte difference under which a seam candidate is accepted.
    /// Same magnitude as CaptureEngine's flat-frame tolerance (maxV-minV > 6), so
    /// anti-aliasing / subpixel jitter between frames stays under it.
    private static let matchTolerance = 6.0

    /// Tightly-packed RGBA8 buffer, top row first (row 0 = top of the image).
    /// Every frame is re-drawn through this same layout so cross-frame row
    /// comparison is apples-to-apples regardless of the source CGImage format.
    private struct PixelBuffer {
        let width: Int
        let height: Int
        var pixels: [UInt8]   // RGBA8, bytesPerRow == width*4
        @inline(__always) func rowOffset(_ y: Int) -> Int { y * width * 4 }
    }

    /// Convert any NSImage to NSBitmapImageRep reliably (handles CGImage-backed images).
    private static func bitmapRep(from image: NSImage) -> NSBitmapImageRep? {
        // First try direct cast, works for images created from NSBitmapImageRep
        if let existing = image.representations.first as? NSBitmapImageRep {
            return existing
        }
        // Fall back to drawing into a new bitmap (handles CGImage-backed NSImages from SCScreenshotManager)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep
    }

    /// Normalize an NSImage into a tightly-packed RGBA8 buffer using the same
    /// CGContext recipe as CaptureEngine.uniformColorDescription (deviceRGB +
    /// premultipliedLast + interpolation .none). This is what makes the seam
    /// correlation reliable across frames with different native pixel layouts.
    private static func pixelBuffer(from image: NSImage) -> PixelBuffer? {
        let cgImage: CGImage
        if let direct = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = direct
        } else if let rep = bitmapRep(from: image), let fromRep = rep.cgImage {
            cgImage = fromRep
        } else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return PixelBuffer(width: width, height: height, pixels: pixels)
    }

    /// Find the y in `frame` (top-origin) at which genuinely-new rows begin.
    /// Returns 0 = zero overlap (append whole frame), `frame.height` = full
    /// overlap (append nothing), or a value in between (the seam). `canvasPixels`
    /// is the live accumulator and `canvasHeight` its current row count (the
    /// buffer may already hold extra capacity from earlier appends).
    private static func findSeam(canvasPixels: [UInt8], canvasWidth: Int, canvasHeight: Int,
                                 frame: PixelBuffer, maxOverlap: Int) -> Int {
        // Width mismatch (window resized / different scale mid-scroll): can't
        // correlate across column counts, so treat as a hard cut.
        guard canvasWidth == frame.width else { return 0 }

        let width = canvasWidth
        let band = min(correlationRows, canvasHeight, frame.height)
        guard band > 0 else { return 0 }

        let bandBytes = band * width * 4
        let templateStart = (canvasHeight - band) * width * 4

        // Slide the canvas-tail template down the head of the frame. Iterate
        // low→high with a STRICT `<` so on near-equal SAD the SMALLEST `top`
        // (smallest overlap) wins. Smaller overlap appends MORE rows, which biases
        // toward keeping genuinely-new content rather than dropping it, the safe
        // default for a stitched screenshot where flat/whitespace regions make many
        // offsets score near-identically.
        let lastTop = min(maxOverlap, frame.height - band)
        guard lastTop >= 0 else { return 0 }

        var bestSAD = Double.greatestFiniteMagnitude
        var bestTop = -1

        canvasPixels.withUnsafeBufferPointer { cBuf in
            frame.pixels.withUnsafeBufferPointer { fBuf in
                let cBase = cBuf.baseAddress!
                let fBase = fBuf.baseAddress!
                for top in 0...lastTop {
                    let frameStart = top * width * 4
                    var sad = 0.0
                    var i = 0
                    // Early-out prune once we exceed the running best.
                    while i < bandBytes {
                        let diff = Int(cBase[templateStart + i]) - Int(fBase[frameStart + i])
                        sad += Double(abs(diff))
                        if sad >= bestSAD { break }
                        i += 1
                    }
                    if i == bandBytes, sad < bestSAD {
                        bestSAD = sad
                        bestTop = top
                    }
                }
            }
        }

        guard bestTop >= 0 else { return 0 }
        let meanAbsDiff = bestSAD / Double(bandBytes)
        guard meanAbsDiff <= matchTolerance else { return 0 }

        // New content starts below the matched band. Clamp so a band landing at
        // the very bottom reports full overlap, not a 1px sliver.
        let newStart = bestTop + band
        return newStart >= frame.height ? frame.height : newStart
    }

    /// Vertical stitch with real overlap detection: cross-correlate the bottom
    /// rows of the accumulated canvas against the head of each new frame to find
    /// the scroll seam, then append only the genuinely-new rows below it.
    static func stitch(frames: [NSImage]) -> NSImage {
        guard let firstImage = frames.first else { return NSImage() }
        guard frames.count > 1 else { return firstImage }
        // Seed the canvas from the first frame that normalizes; skipping a bad
        // leading frame is far better than throwing away the whole scroll.
        guard let seedIndex = frames.firstIndex(where: { pixelBuffer(from: $0) != nil }),
              let first = pixelBuffer(from: frames[seedIndex]) else { return firstImage }

        let width = first.width
        var canvasPixels = first.pixels   // grows in place; never re-copy a full image per frame
        var height = first.height
        // Reserve an upper-bound so append(contentsOf:) doesn't repeatedly realloc
        // and copy the whole growing buffer (amortized but with huge constants on a
        // tall page). Worst case = no overlap detected on any frame.
        canvasPixels.reserveCapacity(frames.count * width * first.height * 4)

        for i in (seedIndex + 1)..<frames.count {
            guard let frame = pixelBuffer(from: frames[i]) else { continue }  // skip a frame that fails to normalize
            // A single-width output buffer can't hold mixed-width rows: a stray
            // frame at a different scale (display change mid-scroll) is dropped
            // rather than corrupting the canvas layout.
            guard frame.width == width else { continue }

            let seam = findSeam(canvasPixels: canvasPixels, canvasWidth: width, canvasHeight: height,
                                frame: frame, maxOverlap: frame.height)
            if seam >= frame.height { continue }  // full overlap, nothing new

            // Append rows [seam, frame.height) onto the bottom of the canvas.
            let appendStart = frame.rowOffset(seam)
            canvasPixels.append(contentsOf: frame.pixels[appendStart...])
            height += frame.height - seam
        }

        guard let result = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let dest = result.bitmapData else { return firstImage }

        // Direct buffer copy: the canvas is already RGBA8 premultipliedLast in
        // deviceRGB, exactly the NSBitmapImageRep layout, no re-render needed.
        canvasPixels.withUnsafeBytes { src in
            memcpy(dest, src.baseAddress!, width * height * 4)
        }

        let output = NSImage(size: NSSize(width: width, height: height))
        output.addRepresentation(result)
        return output
    }
}

// MARK: - Scrolling Status Window

@MainActor
private final class ScrollingStatusWindow: NSWindow {

    var stopHandler: (() -> Void)?
    private let countLabel = NSTextField(labelWithString: "0 frames")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true

        guard let contentView else { return }
        // Single glass backing on the panel-radius scale, same language as the
        // recording HUD. The label, frame count and Done button stack flat above
        // it (flat-on-one-glass is correct; glass-on-glass is not).
        let view = ChromeFactory.backing(frame: contentView.bounds, cornerRadius: ChromeFactory.Radius.panel)
        contentView.addSubview(view)

        let label = NSTextField(labelWithString: "Scroll to capture…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.frame = NSRect(x: 12, y: 12, width: 110, height: 20)
        contentView.addSubview(label)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 122, y: 12, width: 64, height: 20)
        contentView.addSubview(countLabel)

        let btn = NSButton(title: "Done", target: self, action: #selector(stopTapped))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 192, y: 8, width: 56, height: 28)
        contentView.addSubview(btn)
    }

    func updateCount(_ count: Int) {
        countLabel.stringValue = "\(count) frame\(count == 1 ? "" : "s")"
    }

    func show(near point: CGPoint) {
        setFrameOrigin(NSPoint(x: point.x - frame.width / 2, y: point.y))
        orderFrontRegardless()
    }

    @objc private func stopTapped() { stopHandler?() }
}
