import AppKit
import Darwin

/// Persists captures to ~/Library/Application Support/KRIT/History/
@MainActor
final class HistoryManager: ObservableObject {

    private(set) var items: [HistoryItem] = []
    private let storageDir: URL
    private let indexURL: URL

    // Source app captured by `prepareForCapture()` just before KRIT activates and
    // steals focus. Consumed (and cleared) by the next `add()`. Once KRIT is
    // frontmost, `NSWorkspace.frontmostApplication` returns KRIT itself, so the
    // real source app can only be read at capture-trigger time.
    private var pendingSourceBundleID: String?

    /// Snapshot the frontmost app's bundle id so the next capture can badge its
    /// thumbnail with that app's icon. Call this at the START of a capture flow,
    /// before any KRIT window activates. KRIT's own bundle id is ignored so a
    /// re-edit/save from the editor never badges itself.
    func prepareForCapture() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            pendingSourceBundleID = nil
            return
        }
        pendingSourceBundleID = front.bundleIdentifier
    }

    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[KRIT] Application Support directory not found")
        }
        storageDir = appSupport.appendingPathComponent("KRIT/History", isDirectory: true)
        indexURL   = storageDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Add
    //
    // Two-phase insert: the HistoryItem is returned synchronously so the UI
    // (overlay, auto-copy, auto-save) unblocks immediately. PNG encoding,
    // thumbnail generation, xattr metadata and JSON index write all happen on
    // a detached background Task. We prime HistoryImageCache with the
    // in-memory NSImage so any call to `item.fullImage` / `item.thumbnail`
    // before the disk write finishes serves from memory.
    //
    // `presentedImage` is the finished frame (template/background composited),
    // used ONLY for the thumbnail so the history band previews the result the
    // user saw, not the raw grab. `imagePath` always stores the raw `image` so
    // the editor keeps re-editing from the original. When nil, the thumbnail
    // falls back to the raw image (legacy behaviour).

    @discardableResult
    func add(image: NSImage, rect: CGRect?, isWindowCapture: Bool = false, presentedImage: NSImage? = nil,
             kind: HistoryKind = .screenshot, sourceBundleID: String? = nil) -> HistoryItem {
        let id = UUID()
        let imagePath = storageDir.appendingPathComponent("\(id.uuidString).png").path
        let thumbPath = storageDir.appendingPathComponent("\(id.uuidString)_thumb.png").path

        // An explicit source wins; otherwise fall back to the one snapshotted by
        // prepareForCapture() before KRIT took focus. Consume it either way so it
        // never bleeds into a later capture.
        let resolvedSource = sourceBundleID ?? pendingSourceBundleID
        pendingSourceBundleID = nil

        // A preset/background was applied only when the presented frame is a
        // DIFFERENT object than the raw image (composeIfNeeded returns the same
        // instance when there is nothing to compose). Persist that composed
        // full-res frame so dragging from history carries the preset.
        let hasPreset = presentedImage != nil && presentedImage !== image
        let presentedPath = hasPreset
            ? storageDir.appendingPathComponent("\(id.uuidString)_presented.png").path
            : nil

        let item = HistoryItem(
            id: id,
            createdAt: Date(),
            imagePath: imagePath,
            thumbnailPath: thumbPath,
            captureRect: rect.map(CodableRect.init),
            isWindowCapture: isWindowCapture ? true : nil,
            storedKind: kind,
            sourceBundleID: resolvedSource,
            presentedPath: presentedPath
        )
        items.insert(item, at: 0)

        // The thumbnail mirrors the presented (finished) frame when we have one,
        // so the band shows the result; the full-res cache and disk file stay raw.
        let thumbSource = presentedImage ?? image

        // Serve the full image from memory until the disk write lands.
        HistoryImageCache.primeFull(image, for: imagePath)
        // Stand-in thumbnail: the source image scales down fine in NSImageView
        // until the real thumbnail is generated. Cheap perceptual win.
        HistoryImageCache.primeThumbnail(thumbSource, for: thumbPath)
        if let presentedPath, let presentedImage {
            // The drag reads the composed file straight away, before disk write.
            HistoryImageCache.primeFull(presentedImage, for: presentedPath)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            Self.encodeAndPersist(
                image: image,
                thumbnailSource: thumbSource,
                imagePath: imagePath,
                thumbPath: thumbPath,
                rect: rect,
                manager: self
            )
            // Persist the composed full-res frame next to the raw shot when a
            // preset was applied, so the drag file survives an app restart.
            if let presentedPath, let presentedImage,
               let tiff = presentedImage.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: presentedPath))
            }
        }
        return item
    }

    /// Called from the detached encode task once the index needs to be written.
    /// Runs on the main actor because it reads `items`, which is actor-isolated.
    func persistCurrentIndex() {
        Self.persist(items: items, to: indexURL)
    }

    // MARK: - Thumbnail access (UI convenience)

    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        HistoryImageCache.thumbnail(for: item.thumbnailPath)
    }

    // MARK: - Delete

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        HistoryImageCache.evict(fullPath: item.imagePath, thumbnailPath: item.thumbnailPath)
        if let presented = item.presentedPath {
            HistoryImageCache.evict(fullPath: presented, thumbnailPath: presented)
        }
        let imgPath = item.imagePath
        let thumbPath = item.thumbnailPath
        let presentedPath = item.presentedPath
        persistCurrentIndex()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: imgPath)
            try? FileManager.default.removeItem(atPath: thumbPath)
            if let presentedPath { try? FileManager.default.removeItem(atPath: presentedPath) }
        }
    }

    func deleteAll() {
        let removed = items
        items.removeAll()
        HistoryImageCache.evictAll()
        persistCurrentIndex()
        Task.detached(priority: .utility) {
            removed.forEach {
                try? FileManager.default.removeItem(atPath: $0.imagePath)
                try? FileManager.default.removeItem(atPath: $0.thumbnailPath)
                if let presented = $0.presentedPath { try? FileManager.default.removeItem(atPath: presented) }
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            items = decoded.filter { FileManager.default.fileExists(atPath: $0.imagePath) }
        } catch {
            print("[KRIT] History index corrupted, starting fresh: \(error)")
            // Don't overwrite, the corrupt file may be recoverable manually.
        }
    }

    @discardableResult
    nonisolated private static func persist(items: [HistoryItem], to indexURL: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            print("[KRIT] History persist failed: \(error)")
            return false
        }
    }

    // MARK: - Encode + persist (off-main)
    //
    // Runs on a detached background Task. Does the expensive PNG encode, the
    // thumbnail downsample + encode, xattr metadata, and JSON index write,
    // none of which need the main actor. Once the files are on disk, we
    // reach back to the main actor to prime the thumbnail cache with the
    // downsampled version so the history grid picks it up.

    nonisolated private static func encodeAndPersist(
        image: NSImage,
        thumbnailSource: NSImage,
        imagePath: String,
        thumbPath: String,
        rect: CGRect?,
        manager: HistoryManager?
    ) {
        guard let fullCG = image.bestCGImage else {
            print("[KRIT] History persist failed: image has no CGImage backing")
            return
        }

        guard let pngFull = ImageExporter.pngData(from: fullCG) else {
            print("[KRIT] History persist failed: unable to encode full image")
            return
        }

        do {
            try pngFull.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
            applyScreenshotMetadata(to: imagePath, rect: rect)
        } catch {
            print("[KRIT] History persist failed at \(imagePath): \(error)")
            return
        }

        // Thumbnail via CoreGraphics (thread-safe, ~2-3× faster than lockFocus).
        // Downsample the presented frame when one was supplied (falls back to the
        // raw image), so the band thumbnail matches what the user saw.
        let thumbCGSource = thumbnailSource.bestCGImage ?? fullCG
        var thumbImage: NSImage?
        if let thumbCG = downsample(cg: thumbCGSource, maxDimension: 240),
           let pngThumb = ImageExporter.pngData(from: thumbCG) {
            do {
                try pngThumb.write(to: URL(fileURLWithPath: thumbPath), options: .atomic)
                let logicalSize = NSSize(width: thumbCG.width, height: thumbCG.height)
                thumbImage = CaptureEngine.nsImage(from: thumbCG, logicalSize: logicalSize)
            } catch {
                print("[KRIT] History thumbnail persist failed at \(thumbPath): \(error)")
            }
        }

        Task { @MainActor in
            if let thumbImage {
                HistoryImageCache.primeThumbnail(thumbImage, for: thumbPath)
            }
            manager?.persistCurrentIndex()
        }
    }

    /// Downsample a CGImage so its longest edge is `maxDimension` points.
    /// Returns the input unchanged if it already fits.
    nonisolated private static func downsample(cg: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cg }
        let scale = maxDimension / longest
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    // MARK: - Screenshot metadata

    nonisolated static func applyScreenshotMetadata(to path: String, rect: CGRect?) {
        let url = URL(fileURLWithPath: path) as NSURL
        // Mark as screenshot for Spotlight/Finder (same as macOS native + CleanShot X)
        let isScreenCapture = true as NSNumber
        let plist = try? PropertyListSerialization.data(fromPropertyList: isScreenCapture, format: .binary, options: 0)
        if let plist {
            _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath else { return -1 }
                return setxattr(cPath, "com.apple.metadata:kMDItemIsScreenCapture", (plist as NSData).bytes, plist.count, 0, XATTR_NOFOLLOW)
            }
        }

        // Screenshot type
        let typeData = try? PropertyListSerialization.data(fromPropertyList: "selection" as NSString, format: .binary, options: 0)
        if let typeData {
            _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath else { return -1 }
                return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureType", (typeData as NSData).bytes, typeData.count, 0, XATTR_NOFOLLOW)
            }
        }

        // Capture rect
        if let rect {
            let rectArray = [rect.origin.x, rect.origin.y, rect.width, rect.height] as NSArray
            let rectData = try? PropertyListSerialization.data(fromPropertyList: rectArray, format: .binary, options: 0)
            if let rectData {
                _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                    guard let cPath else { return -1 }
                    return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", (rectData as NSData).bytes, rectData.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
    }
}
