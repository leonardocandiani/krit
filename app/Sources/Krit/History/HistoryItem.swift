import AppKit

/// What kind of capture an item holds. Drives the band's filter tabs. Stored on
/// disk so old items (which predate the field) decode as nil and fall back to
/// the file extension via `HistoryItem.kind`.
enum HistoryKind: String, Codable {
    case screenshot, video, gif
}

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let imagePath: String     // Full-res PNG on disk
    let thumbnailPath: String // Smaller PNG for list UI
    let captureRect: CodableRect?
    // Window shots are the ONLY captures that auto-apply a background in the
    // editor (user rule). Optional so pre-existing history decodes as nil.
    var isWindowCapture: Bool? = nil
    // Stored capture kind. Optional so pre-existing history decodes as nil and
    // falls back to the extension-derived `kind`.
    var storedKind: HistoryKind? = nil
    // Bundle id of the app that was frontmost when the capture was taken, used
    // for the source-app badge on the thumbnail. Optional: captures taken before
    // this field existed (or where no app was frontmost) decode as nil and the
    // badge is simply omitted.
    var sourceBundleID: String? = nil
    // Full-res composed PNG (raw shot + preset/background), present only when a
    // preset was applied at capture. The drag and any "use the finished image"
    // path read this so dragging from history carries the preset, while the
    // editor keeps re-editing from the raw imagePath. Optional: nil = no preset,
    // and legacy items decode as nil and fall back to imagePath.
    var presentedPath: String? = nil

    var fullImage: NSImage { HistoryImageCache.fullImage(for: imagePath) }
    var thumbnail: NSImage { HistoryImageCache.thumbnail(for: thumbnailPath) }

    /// The file to hand off on drag / copy-as-file: the composed image (with the
    /// preset) when one exists, otherwise the raw shot. This is what the user sees
    /// in the band, so it is what they expect to drag out.
    var presentedFileURL: URL {
        URL(fileURLWithPath: presentedPath ?? imagePath)
    }

    /// Effective kind: the stored value when present, otherwise inferred from the
    /// file extension so legacy items still classify under the filter tabs.
    var kind: HistoryKind {
        if let storedKind { return storedKind }
        let lower = imagePath.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return .video }
        if lower.hasSuffix(".gif") { return .gif }
        return .screenshot
    }

    /// Icon of the source app for the thumbnail badge, resolved from the stored
    /// bundle id via NSWorkspace. Nil when no source app was recorded or the app
    /// can no longer be located on disk.
    var sourceAppIcon: NSImage? {
        guard let sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct CodableRect: Codable {
    let x, y, width, height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
}

/// Shared in-memory cache for history images. Eliminates repeated disk reads
/// when the user clicks Copy / Edit / Save / Pin on the same cell. Bounded so
/// memory never grows unbounded regardless of history size.
enum HistoryImageCache {

    private static let fullCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 30
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    static func fullImage(for path: String) -> NSImage {
        let key = path as NSString
        if let hit = fullCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return NSImage() }
        fullCache.setObject(img, forKey: key, cost: imageCost(img))
        return img
    }

    static func thumbnail(for path: String) -> NSImage {
        let key = path as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return NSImage() }
        thumbCache.setObject(img, forKey: key, cost: imageCost(img))
        return img
    }

    static func primeFull(_ image: NSImage, for path: String) {
        fullCache.setObject(image, forKey: path as NSString, cost: imageCost(image))
    }

    static func primeThumbnail(_ image: NSImage, for path: String) {
        thumbCache.setObject(image, forKey: path as NSString, cost: imageCost(image))
    }

    static func evict(fullPath: String, thumbnailPath: String) {
        fullCache.removeObject(forKey: fullPath as NSString)
        thumbCache.removeObject(forKey: thumbnailPath as NSString)
    }

    static func evictAll() {
        fullCache.removeAllObjects()
        thumbCache.removeAllObjects()
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let px = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(px * 4, 1)
    }
}
