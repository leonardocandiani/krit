import AppKit
import ImageIO
import ScreenCaptureKit

/// Lists the Apple desktop pictures already installed on this Mac so KRIT can
/// offer them as screenshot backgrounds. We read the user's installed wallpapers
/// at runtime instead of bundling Apple's copyrighted art, the end result is the
/// same (Apple wallpapers behind a shot) with no redistribution.
///
/// It scans every full-resolution source on disk (the top-level Desktop Pictures
/// and the `.wallpapers` bundles), skips the tiny 214px thumbnail assets (which
/// would look blurry as a backdrop), and, for the dynamic light/dark HEICs that
/// pack more than one image, exposes both the light and a "<Name> Dark" variant.
/// When nothing readable is found the list is empty and the sidebar keeps its
/// gradient palettes.
enum SystemWallpaperSource {

    struct Wallpaper: Equatable {
        let name: String
        let url: URL
        /// Which image inside the file (dynamic HEICs pack light at 0, dark last).
        let imageIndex: Int
    }

    private static let searchRoots = [
        "/System/Library/Desktop Pictures",
        "/Library/Desktop Pictures"
    ]
    private static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
    /// Anything smaller than this on its long edge is a thumbnail asset, not a
    /// real wallpaper, too small to sit behind a screenshot.
    private static let minLongEdge = 1200

    /// Full-resolution wallpapers, the user's current wallpaper first, then the
    /// system set with light/dark variants. Computed once, lazily, on first access;
    /// `reload()` refreshes after an import.
    ///
    /// IMPORTANT: must be first-touched on the main thread, `load()` calls
    /// main-thread-only AppKit APIs (NSScreen.screens, NSWorkspace.desktopImageURL).
    /// All current callers access it on the main thread.
    private(set) static var all: [Wallpaper] = load()

    static func reload() {
        all = load()
    }

    // MARK: - Current desktop wallpaper

    /// Last live wallpaper grab, downscaled JPEG, keyed by displayID. Populated by
    /// `refreshCurrentWallpaper(for:)` right before a window capture so the sync
    /// `currentDesktopBackgroundData` reads the EXACT desktop the WindowServer is
    /// drawing (static, dynamic, aerial, solid color, anything), not a guessed
    /// file from `desktopImageURL`. In-memory only, lost on relaunch by design,
    /// the next capture refreshes it.
    private static var liveWallpaperCache: [CGDirectDisplayID: Data] = [:]

    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Grabs the wallpaper the WindowServer is actually painting on `screen` and
    /// stores it (downscaled JPEG) in `liveWallpaperCache` for the matching
    /// displayID. The truth is the Dock's wallpaper window, not `desktopImageURL`,
    /// which hands back a folder or an undecodable URL for dynamic/aerial styles
    /// and forces the old fallback to a bundled "downloaded" wallpaper. Any SCK
    /// failure leaves the cache untouched so the sync path still has its static
    /// fallback, a window capture is never broken by a wallpaper grab.
    @available(macOS 14.0, *)
    static func refreshCurrentWallpaper(for screen: NSScreen, maxPixel: CGFloat = 2560) async {
        guard let id = displayID(of: screen) else {
            uiTestLastWallpaperGrab = "no-display-id"
            return
        }
        guard let cg = await captureWallpaperWindowImage(for: screen) else { return }
        // Reject poisoned frames instead of caching them. The display-exclude
        // grab intermittently returns a flat frame (white/black) when it races
        // the picker/flash chrome tearing down; composing a window shot over
        // that produced the "white background, white border" reports. A uniform
        // frame is never a real wallpaper, keep the previous cache instead.
        if let flat = CaptureEngine.uniformColorDescription(cg) {
            uiTestLastWallpaperGrab += "+rejected-uniform(\(flat))"
            return
        }
        guard let data = downscaledJPEG(from: cg, maxPixel: maxPixel) else {
            uiTestLastWallpaperGrab += "+jpeg-failed"
            return
        }
        liveWallpaperCache[id] = data
        uiTestLastWallpaperGrab += "+cached"
    }

    /// The freshest live wallpaper grab for `screen` (or the main display when
    /// nil), or nil if no capture has run for that display yet.
    static func cachedCurrentWallpaperData(for screen: NSScreen?) -> Data? {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        return displayID(of: target).flatMap { liveWallpaperCache[$0] }
    }

    /// Downscaled JPEG of the wallpaper currently shown on `screen` (or the main
    /// display when `screen` is nil), ready to drop straight into a screenshot
    /// background as `customImageData`. Resolved SYNCHRONOUSLY so the editor can
    /// open a window shot already composed with no flash of the unstyled capture.
    ///
    /// Order of truth: the live SCK grab cached by `refreshCurrentWallpaper`
    /// (exact desktop, any style), then the static `desktopImageURL` file (a real
    /// image, or the first readable image inside a rotating folder), then the
    /// first system wallpaper in `all`. Returns nil only when the Mac has no
    /// readable wallpaper at all.
    ///
    /// Main-thread only (NSWorkspace.desktopImageURL / NSScreen).
    static func currentDesktopBackgroundData(for screen: NSScreen?, maxPixel: CGFloat = 2560) -> Data? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let fresh = cachedCurrentWallpaperData(for: screen) {
            uiTestLastWallpaperSource = "live-cache"
            return fresh
        }
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        let fromFile = target.flatMap { resolveImageFile(from: NSWorkspace.shared.desktopImageURL(for: $0)) }
        let resolved = fromFile ?? all.first?.url
        uiTestLastWallpaperSource = resolved == nil ? "none" : (fromFile != nil ? "desktop-image-url" : "builtin-first")
        guard let url = resolved else { return nil }
        // Dynamic HEICs pack the light variant first and the dark one last.
        // Follow the user's CURRENT appearance: composing the light frame for a
        // dark-mode desktop hands back a near-white backdrop that looks nothing
        // like the wallpaper on screen.
        let darkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let frameIndex = darkMode ? Int.max : 0  // downscaled clamps to the last frame
        return downscaled(url: url, index: frameIndex, maxPixel: maxPixel).flatMap { cg -> Data? in
            NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    /// Captures the Dock's wallpaper window for `screen` in isolation, the
    /// WindowServer's own desktop layer. Critère de match (tolerant across macOS
    /// versions where the title varies, "Wallpaper", "Wallpaper-1", localized):
    ///   1. owningApplication.bundleIdentifier == "com.apple.dock", and
    ///   2. the title has the "Wallpaper" prefix, OR (as fallback) the window
    ///      frame equals the screen frame, the desktop layer fills the display.
    /// Among matches we pick the one whose frame best overlaps the target screen,
    /// so multi-monitor grabs the wallpaper of the right display. Returns nil on
    /// any error so the caller keeps its static fallback.
    @available(macOS 14.0, *)
    private static func captureWallpaperWindowImage(for screen: NSScreen) async -> CGImage? {
        // Primary path on macOS 26/27: the Dock no longer exposes a "Wallpaper"
        // window to SCK (the only Dock window reported is the Dock bar itself), so
        // window-finding fails. Instead capture the whole DISPLAY with every window
        // excluded; what remains composited is the live wallpaper exactly as the
        // WindowServer renders it, which resolves the dynamic HEIC variant and the
        // right monitor for free, no desktopImageURL guessing.
        if let cg = await captureDisplayWallpaper(for: screen) {
            uiTestLastWallpaperGrab = "sck-display"
            return cg
        }
        // Legacy fallback: hunt the Dock's wallpaper window (works on older macOS).
        // The active Space is disambiguated by preferring isOnScreen candidates
        // over the identical-frame copies of inactive Spaces.
        if let cg = await captureWallpaperWindowImage(for: screen, onScreenOnly: false) {
            uiTestLastWallpaperGrab = "sck-window"
            return cg
        }
        uiTestLastWallpaperGrab = "sck-failed"
        return nil
    }

    /// Captures the display's desktop layer by filtering the display and excluding
    /// every shareable window, leaving only the wallpaper the WindowServer is
    /// actually compositing right now.
    @available(macOS 14.0, *)
    private static func captureDisplayWallpaper(for screen: NSScreen) async -> CGImage? {
        guard let wantID = displayID(of: screen) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == wantID }) else {
                uiTestLastWallpaperGrabDetail = "no-display(want=\(wantID), displays=\(content.displays.count))"
                return nil
            }
            // Exclude every window so only the desktop wallpaper remains.
            let filter = SCContentFilter(display: scDisplay, excludingWindows: content.windows)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(CGFloat(scDisplay.width) * scale))
            config.height = max(1, Int(CGFloat(scDisplay.height) * scale))
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsDisplay = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            uiTestLastWallpaperGrabDetail = "display-error: \((error as NSError).domain) \((error as NSError).code)"
            return nil
        }
    }

    /// GUI test / diagnostics hooks: which pass produced the last wallpaper grab
    /// ("sck-onscreen", "sck-all-spaces", "sck-failed") and which source resolved
    /// the last sync background read ("live-cache", "desktop-image-url",
    /// "builtin-first", "none").
    nonisolated(unsafe) static var uiTestLastWallpaperGrab = "never"
    nonisolated(unsafe) static var uiTestLastWallpaperSource = "never"

    @available(macOS 14.0, *)
    private static func captureWallpaperWindowImage(for screen: NSScreen, onScreenOnly: Bool) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
            let screenFrameCG = cgFrame(of: screen)
            let candidates = content.windows.filter { window in
                guard window.owningApplication?.bundleIdentifier == "com.apple.dock" else { return false }
                let title = window.title ?? ""
                if title.hasPrefix("Wallpaper") { return true }
                // Fallback: a Dock window that exactly fills a display is the
                // desktop wallpaper layer even when the title doesn't match.
                return screenFrameCG.map { frameMatches(window.frame, $0) } ?? false
            }
            // Every Space keeps a Wallpaper window with the SAME frame, so the
            // overlap tie-break alone cannot tell the active Space from an
            // inactive one. isOnScreen marks the one the WindowServer is
            // actually compositing; prefer it before falling back to overlap.
            let onScreen = candidates.filter(\.isOnScreen)
            let pool = onScreen.isEmpty ? candidates : onScreen
            guard let window = pool.max(by: { lhs, rhs in
                overlapArea(lhs.frame, screenFrameCG) < overlapArea(rhs.frame, screenFrameCG)
            }) else {
                uiTestLastWallpaperGrabDetail = "no-candidates(onScreenOnly=\(onScreenOnly), dockWindows=\(content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.dock" }.count))"
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            uiTestLastWallpaperGrabDetail = "error(onScreenOnly=\(onScreenOnly)): \((error as NSError).domain) \((error as NSError).code)"
            return nil
        }
    }

    /// Diagnostics: why the last grab pass came back empty (no candidate window
    /// or the SCK error domain/code).
    nonisolated(unsafe) static var uiTestLastWallpaperGrabDetail = "none"

    /// `screen.frame` in CoreGraphics (top-left origin) coordinates, the space
    /// SCWindow.frame lives in. Flips around the primary display's height.
    private static func cgFrame(of screen: NSScreen) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let f = screen.frame
        return CGRect(x: f.origin.x, y: primary.frame.height - f.origin.y - f.height, width: f.width, height: f.height)
    }

    private static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect?) -> CGFloat {
        guard let b else { return a.width * a.height }
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private static func downscaledJPEG(from cgImage: CGImage, maxPixel: CGFloat) -> Data? {
        let longEdge = CGFloat(max(cgImage.width, cgImage.height))
        let scaled: CGImage
        if longEdge > maxPixel, let smaller = resized(cgImage, longEdge: maxPixel) {
            scaled = smaller
        } else {
            scaled = cgImage
        }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    private static func resized(_ cgImage: CGImage, longEdge: CGFloat) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let factor = longEdge / max(w, h)
        let newW = max(1, Int(w * factor)), newH = max(1, Int(h * factor))
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    /// Returns a concrete, readable image file for a desktop-image URL. A direct
    /// image file passes through; a directory (rotating/dynamic wallpaper folder)
    /// resolves to its first readable image; anything else yields nil.
    private static func resolveImageFile(from url: URL?) -> URL? {
        guard let url else { return nil }
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            return imageExtensions.contains(url.pathExtension.lowercased()) ? url : nil
        }
        guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return nil }
        for item in items.sorted() where imageExtensions.contains((item as NSString).pathExtension.lowercased()) {
            return url.appendingPathComponent(item)
        }
        return nil
    }

    /// KRIT's own wallpaper library: anything the user imports (e.g. wallpapers
    /// downloaded from Apple) is copied here and listed alongside the system set.
    static var importDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KRIT/Wallpapers", isDirectory: true)
    }

    /// Copies the picked files into the KRIT library and reloads. Returns how
    /// many actually landed (skips unreadable files and same-name duplicates).
    @discardableResult
    static func importWallpapers(from urls: [URL]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        var imported = 0
        for url in urls where imageExtensions.contains(url.pathExtension.lowercased()) {
            let dest = importDirectory.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            if (try? fm.copyItem(at: url, to: dest)) != nil { imported += 1 }
        }
        if imported > 0 { reload() }
        return imported
    }

    private static func load() -> [Wallpaper] {
        // Enforce the implicit contract above: NSScreen / NSWorkspace below are
        // main-thread-only, and this runs on whichever thread first touches `all`.
        dispatchPrecondition(condition: .onQueue(.main))
        let fm = FileManager.default
        var result: [Wallpaper] = []
        // Dedup by content/origin (path#index), NOT by name: Apple reuses basenames
        // across bundles, and a name-based key silently drops genuinely-different
        // images. Display-name collisions are disambiguated separately below.
        var seenSource = Set<String>()
        var usedDisplayNames = Set<String>()

        func addFile(_ url: URL, displayName: String? = nil, bundleName: String? = nil) {
            guard imageExtensions.contains(url.pathExtension.lowercased()),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let frames = CGImageSourceGetCount(source)
            guard frames > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  max(w, h) >= minLongEdge else { return }

            let base = displayName ?? url.deletingPathExtension().lastPathComponent

            func add(_ rawName: String, _ index: Int) {
                let sourceKey = "\(url.path)#\(index)"
                guard !seenSource.contains(sourceKey) else { return }
                seenSource.insert(sourceKey)
                // Disambiguate a colliding display name by prefixing the parent
                // bundle, so two distinct images never share one label.
                var name = rawName
                if usedDisplayNames.contains(name.lowercased()), let bundleName {
                    name = "\(bundleName) · \(rawName)"
                }
                usedDisplayNames.insert(name.lowercased())
                result.append(Wallpaper(name: name, url: url, imageIndex: index))
            }

            add(base, 0)
            // Only a true appearance pair (light at 0, dark at 1) is a clean
            // light/dark HEIC. Solar/time wallpapers pack N frames that vary across
            // the day, where the last frame is NOT a canonical "dark", so we expose
            // a Dark variant ONLY for the 2-image case and treat multi-frame as
            // light-only rather than mislabel an arbitrary frame.
            if frames == 2 { add(base + " Dark", 1) }
        }

        // The user's current desktop wallpaper(s) lead the list.
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                addFile(url, displayName: "Current")
            }
        }

        for root in searchRoots {
            // Top-level full-resolution pictures.
            if let items = try? fm.contentsOfDirectory(atPath: root) {
                for item in items.sorted() where !item.hasPrefix(".") {
                    addFile(URL(fileURLWithPath: root).appendingPathComponent(item))
                }
            }
            // One level into the `.wallpapers` bundles (scenic full-res lives here).
            let bundlesDir = root + "/.wallpapers"
            if let bundles = try? fm.contentsOfDirectory(atPath: bundlesDir) {
                for bundle in bundles.sorted() {
                    let dir = bundlesDir + "/" + bundle
                    let bundleName = (bundle as NSString).deletingPathExtension
                    if let items = try? fm.contentsOfDirectory(atPath: dir) {
                        for item in items.sorted() {
                            addFile(URL(fileURLWithPath: dir).appendingPathComponent(item), bundleName: bundleName)
                        }
                    }
                }
            }
        }

        // Wallpapers da galeria do macOS baixados sob demanda (MobileAsset), só
        // existem depois que o usuário baixa em Ajustes do Sistema.
        let assetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture")
        if let walker = fm.enumerator(at: assetRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > 4000 { break }   // hard stop num asset store gigante
                if imageExtensions.contains(url.pathExtension.lowercased()) {
                    addFile(url)
                }
            }
        }

        // Bibliotecas do usuário: a pasta de import do KRIT e a convencional
        // ~/Pictures/Wallpapers (onde wallpapers baixados costumam ser salvos).
        let userDirs = [
            importDirectory,
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
        ]
        for dir in userDirs {
            if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
                for item in items.sorted() where !item.hasPrefix(".") {
                    addFile(dir.appendingPathComponent(item))
                }
            }
        }
        return result
    }

    // MARK: - Thumbnails (async, cached)

    private static let thumbnailCache = NSCache<NSString, NSImage>()

    private static func cacheKey(_ wallpaper: Wallpaper) -> NSString {
        "\(wallpaper.url.path)#\(wallpaper.imageIndex)" as NSString
    }

    static func thumbnail(for wallpaper: Wallpaper, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(wallpaper)
        if let cached = thumbnailCache.object(forKey: key) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = downscaled(url: wallpaper.url, index: wallpaper.imageIndex, maxPixel: maxPixel).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            if let image { thumbnailCache.setObject(image, forKey: key) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - Background data (async, downscaled JPEG)

    /// Downscaled JPEG of the wallpaper, sized for compositing. Kept modest so
    /// history items don't balloon with a 6K source.
    static func backgroundData(for wallpaper: Wallpaper, maxPixel: CGFloat = 2560, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let data = downscaled(url: wallpaper.url, index: wallpaper.imageIndex, maxPixel: maxPixel).flatMap { cg -> Data? in
                NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            DispatchQueue.main.async { completion(data) }
        }
    }

    private static func downscaled(url: URL, index: Int, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let safeIndex = max(0, min(index, count - 1))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, safeIndex, options as CFDictionary)
    }
}
