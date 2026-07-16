import AppKit
import Darwin

/// Persists captures to ~/Library/Application Support/KRIT/History/
@MainActor
final class HistoryManager: ObservableObject {

    enum LoadState {
        case loading
        case loaded
    }

    private enum PendingMutation {
        case add(HistoryItem)
        case update(HistoryItem)
        case delete(UUID)
        case deleteAll
    }

    private(set) var items: [HistoryItem] = []
    private(set) var loadState: LoadState = .loading
    var isLoading: Bool { loadState == .loading }
    private let storageDir: URL
    private let diskStore: HistoryDiskStore
    private var initialLoadTask: Task<Void, Never>?
    private var operationTail: Task<Void, Never>?
    private var pendingMutations: [PendingMutation] = []
    private var loadCallbacks: [@MainActor () -> Void] = []

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

    /// Drops source-app metadata when a capture flow ends before it creates a
    /// history item. Without this, a cancelled selection can badge an unrelated
    /// later capture or an editor save with the app that was active earlier.
    func cancelPreparedCapture() {
        pendingSourceBundleID = nil
    }

    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[KRIT] Application Support directory not found")
        }
        let storageDir = appSupport.appendingPathComponent("KRIT/History", isDirectory: true)
        self.storageDir = storageDir
        diskStore = HistoryDiskStore(storageDir: storageDir)
        startInitialLoad()
    }

    /// Test boundary for exercising persistence without touching the user's real
    /// history. Production continues to use `init()` and Application Support.
    init(storageDir: URL) {
        self.storageDir = storageDir
        diskStore = HistoryDiskStore(storageDir: storageDir)
        startInitialLoad()
    }

    init(storageDir: URL, initialLoader: @escaping HistoryDiskStore.Loader) {
        self.storageDir = storageDir
        diskStore = HistoryDiskStore(storageDir: storageDir, loader: initialLoader)
        startInitialLoad()
    }

    func waitUntilLoaded() async {
        await initialLoadTask?.value
    }

    func whenLoaded(_ callback: @escaping @MainActor () -> Void) {
        if isLoading {
            loadCallbacks.append(callback)
        } else {
            callback()
        }
    }

    private func startInitialLoad() {
        let store = diskStore
        let task = Task { @MainActor [weak self] in
            let loaded = await store.load()
            guard let self else { return }
            self.finishInitialLoad(loaded)
        }
        initialLoadTask = task
        operationTail = task
    }

    private func finishInitialLoad(_ loaded: [HistoryItem]) {
        var merged = loaded
        for mutation in pendingMutations {
            switch mutation {
            case .add(let item):
                merged.removeAll { $0.id == item.id }
                merged.insert(item, at: 0)
            case .update(let item):
                if let index = merged.firstIndex(where: { $0.id == item.id }) {
                    merged[index] = item
                }
            case .delete(let id):
                merged.removeAll { $0.id == id }
            case .deleteAll:
                merged.removeAll()
            }
        }
        items = merged
        pendingMutations.removeAll()
        loadState = .loaded
        let callbacks = loadCallbacks
        loadCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    private func enqueue(
        _ operation: @escaping @MainActor @Sendable (HistoryDiskStore) async -> Void
    ) {
        let previous = operationTail
        let store = diskStore
        operationTail = Task { @MainActor in
            await previous?.value
            await operation(store)
        }
    }

    // MARK: - Add
    //
    // Two-phase insert: the HistoryItem is returned synchronously so the UI
    // (overlay, auto-copy, auto-save) unblocks immediately. PNG encoding,
    // thumbnail generation, xattr metadata and JSON index write all happen in
    // the serial HistoryDiskStore actor. We prime HistoryImageCache with the
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
             kind: HistoryKind = .screenshot, sourceBundleID: String? = nil,
             rawArtifact suppliedRawArtifact: CaptureArtifact? = nil,
             presentedArtifact suppliedPresentedArtifact: CaptureArtifact? = nil) -> HistoryItem {
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
        if isLoading {
            pendingMutations.append(.add(item))
        }

        // The thumbnail mirrors the presented (finished) frame when we have one,
        // so the band shows the result; the full-res cache and disk file stay raw.
        let thumbSource = presentedImage ?? image
        let rawArtifact = suppliedRawArtifact ?? CaptureArtifact(image: image)
        let presentedArtifact = suppliedPresentedArtifact ?? {
            if thumbSource === image { return rawArtifact }
            return CaptureArtifact(image: thumbSource)
        }()

        // Serve the full image from memory until the disk write lands.
        HistoryImageCache.primeFull(image, for: imagePath)
        // Stand-in thumbnail: the source image scales down fine in NSImageView
        // until the real thumbnail is generated. Cheap perceptual win.
        HistoryImageCache.primeThumbnail(thumbSource, for: thumbPath)
        if let presentedPath, let presentedImage {
            // The drag reads the composed file straight away, before disk write.
            HistoryImageCache.primeFull(presentedImage, for: presentedPath)
        }

        let request = HistoryDiskStore.InsertRequest(
            item: item,
            rawArtifact: rawArtifact,
            thumbnailArtifact: presentedArtifact ?? rawArtifact,
            presentedArtifact: hasPreset ? presentedArtifact : nil,
            captureRect: rect
        )
        enqueue { store in
            let thumbData = await store.insert(request)
            if let thumbData, let thumbImage = NSImage(data: thumbData) {
                HistoryImageCache.primeThumbnail(thumbImage, for: item.thumbnailPath)
            }
        }
        return item
    }

    /// Queues an explicit snapshot after every earlier history operation. Normal
    /// inserts and deletes persist inside `HistoryDiskStore` themselves.
    func persistCurrentIndex() {
        enqueue { [weak self] store in
            guard let self else { return }
            await store.replaceIndex(with: self.items)
        }
    }

    /// Replaces the representation visible in the overlay, history, drag and
    /// Finder while preserving the raw capture used by the editor. The first
    /// transformation of a plain capture promotes it to a presented sidecar rather
    /// than overwriting the editor's original image.
    @discardableResult
    func updatePresentedImage(_ image: NSImage, for requestedItem: HistoryItem) -> HistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == requestedItem.id }) else {
            return nil
        }
        guard let artifact = CaptureArtifact(image: image) else {
            print("[KRIT] History presentation update skipped: image has no CGImage backing")
            return nil
        }

        var item = items[index]
        if item.presentedPath == nil {
            item.presentedPath = storageDir
                .appendingPathComponent("\(item.id.uuidString)_presented.png")
                .path
            items[index] = item
            if isLoading {
                pendingMutations.append(.update(item))
            }
        }
        let targetPath = item.presentedPath ?? item.imagePath
        HistoryImageCache.primeFull(image, for: targetPath)
        HistoryImageCache.primeThumbnail(image, for: item.thumbnailPath)

        let request = HistoryDiskStore.PresentationUpdateRequest(
            item: item,
            artifact: artifact
        )
        enqueue { store in
            let thumbnailData = await store.updatePresentation(request)
            if let thumbnailData, let thumbnail = NSImage(data: thumbnailData) {
                HistoryImageCache.primeThumbnail(thumbnail, for: item.thumbnailPath)
            }
        }
        return item
    }

    func contains(_ item: HistoryItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    // MARK: - Thumbnail access (UI convenience)

    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        HistoryImageCache.thumbnail(for: item.thumbnailPath)
    }

    // MARK: - Delete

    func delete(_ requestedItem: HistoryItem) {
        let item = items.first { $0.id == requestedItem.id } ?? requestedItem
        items.removeAll { $0.id == item.id }
        if isLoading {
            pendingMutations.append(.delete(item.id))
        }
        HistoryImageCache.evict(fullPath: item.imagePath, thumbnailPath: item.thumbnailPath)
        if let presented = item.presentedPath {
            HistoryImageCache.evict(fullPath: presented, thumbnailPath: presented)
        }
        enqueue { store in
            await store.delete(item)
        }
    }

    func deleteAll() {
        items.removeAll()
        if isLoading {
            pendingMutations.append(.deleteAll)
        }
        HistoryImageCache.evictAll()
        enqueue { store in
            await store.deleteAll()
        }
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
