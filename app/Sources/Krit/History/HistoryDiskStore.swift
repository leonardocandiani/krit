import AppKit

actor HistoryDiskStore {
    typealias Loader = @Sendable (URL) -> [HistoryItem]

    struct InsertRequest: Sendable {
        let item: HistoryItem
        let rawArtifact: CaptureArtifact?
        let thumbnailArtifact: CaptureArtifact?
        let presentedArtifact: CaptureArtifact?
        let captureRect: CGRect?
    }

    struct PresentationUpdateRequest: Sendable {
        let item: HistoryItem
        let artifact: CaptureArtifact
    }

    private let storageDir: URL
    private let indexURL: URL
    private let loader: Loader
    private var persistedItems: [HistoryItem]?

    private struct ItemFileURLs {
        let image: URL
        let thumbnail: URL
        let presented: URL?
    }

    init(storageDir: URL) {
        self.storageDir = storageDir
        indexURL = storageDir.appendingPathComponent("index.json")
        loader = { indexURL in
            HistoryDiskStore.loadIndex(from: indexURL)
        }
    }

    init(storageDir: URL, loader: @escaping Loader) {
        self.storageDir = storageDir
        indexURL = storageDir.appendingPathComponent("index.json")
        self.loader = loader
    }

    func load() -> [HistoryItem] {
        loadIfNeeded()
    }

    func insert(_ request: InsertRequest) async -> Data? {
        guard let fileURLs = safeFileURLs(for: request.item) else {
            print("[KRIT] History persist skipped: item paths escape the history directory")
            return nil
        }
        var items = loadIfNeeded()
        ensureDirectory()

        guard let rawPNG = await request.rawArtifact?.encoded(as: .png)?.data else {
            print("[KRIT] History persist failed: unable to encode full image")
            return nil
        }
        do {
            try rawPNG.write(to: fileURLs.image, options: .atomic)
            HistoryManager.applyScreenshotMetadata(
                to: fileURLs.image.path,
                rect: request.captureRect
            )
        } catch {
            print("[KRIT] History persist failed at \(request.item.imagePath): \(error)")
            return nil
        }

        if let presentedPath = request.item.presentedPath,
           let presentedURL = fileURLs.presented,
           let presentedPNG = await request.presentedArtifact?.encoded(as: .png)?.data {
            do {
                try presentedPNG.write(
                    to: presentedURL,
                    options: .atomic
                )
            } catch {
                print("[KRIT] Presented history persist failed at \(presentedPath): \(error)")
            }
        }

        var thumbnailData: Data?
        if let png = await request.thumbnailArtifact?
            .encoded(as: .thumbnailPNG(maxDimension: 240))?.data {
            do {
                try png.write(
                    to: fileURLs.thumbnail,
                    options: .atomic
                )
                thumbnailData = png
            } catch {
                print("[KRIT] History thumbnail persist failed at \(request.item.thumbnailPath): \(error)")
            }
        }

        items.removeAll { $0.id == request.item.id }
        items.insert(request.item, at: 0)
        persistedItems = items
        persist(items)
        return thumbnailData
    }

    /// Replaces the image users see and drag without violating the raw-capture
    /// contract. The manager promotes a transformed plain capture to a presented
    /// sidecar before this method runs, so the raw image stays editable.
    func updatePresentation(_ request: PresentationUpdateRequest) async -> Data? {
        guard let fileURLs = safeFileURLs(for: request.item) else {
            print("[KRIT] History presentation update skipped: item paths escape the history directory")
            return nil
        }
        var items = loadIfNeeded()
        guard let itemIndex = items.firstIndex(where: { $0.id == request.item.id }) else {
            return nil
        }
        ensureDirectory()

        guard let fullPNG = await request.artifact.encoded(as: .png)?.data else {
            print("[KRIT] History presentation update failed: unable to encode full image")
            return nil
        }

        let targetPath = request.item.presentedPath ?? request.item.imagePath
        let targetURL = fileURLs.presented ?? fileURLs.image
        do {
            try fullPNG.write(to: targetURL, options: .atomic)
        } catch {
            print("[KRIT] History presentation update failed at \(targetPath): \(error)")
            return nil
        }

        items[itemIndex] = request.item
        persistedItems = items
        persist(items)

        guard let thumbnail = await request.artifact
            .encoded(as: .thumbnailPNG(maxDimension: 240))?.data else {
            return nil
        }
        do {
            try thumbnail.write(
                to: fileURLs.thumbnail,
                options: .atomic
            )
            return thumbnail
        } catch {
            print("[KRIT] History thumbnail update failed at \(request.item.thumbnailPath): \(error)")
            return nil
        }
    }

    func delete(_ requestedItem: HistoryItem) {
        var items = loadIfNeeded()
        guard let persistedItem = items.first(where: { $0.id == requestedItem.id }) else {
            return
        }
        items.removeAll { $0.id == requestedItem.id }
        persistedItems = items
        persist(items)
        removeFiles(for: persistedItem)
    }

    func deleteAll() {
        let removed = loadIfNeeded()
        persistedItems = []
        persist([])
        removed.forEach(removeFiles)
    }

    func replaceIndex(with items: [HistoryItem]) {
        _ = loadIfNeeded()
        let safeItems = items.filter { safeFileURLs(for: $0) != nil }
        persistedItems = safeItems
        persist(safeItems)
    }

    private func loadIfNeeded() -> [HistoryItem] {
        if let persistedItems { return persistedItems }
        ensureDirectory()
        let loaded = loader(indexURL)
        let safeItems = loaded.filter { safeFileURLs(for: $0) != nil }
        persistedItems = safeItems
        return safeItems
    }

    private func ensureDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: storageDir,
                withIntermediateDirectories: true
            )
        } catch {
            print("[KRIT] History directory creation failed: \(error)")
        }
    }

    private func persist(_ items: [HistoryItem]) {
        guard HistoryDiskStore.indexCanBeReplaced(at: indexURL, storageDir: storageDir) else {
            print("[KRIT] History index not persisted because the corrupt index could not be quarantined")
            return
        }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("[KRIT] History persist failed: \(error)")
        }
    }

    private func removeFiles(for item: HistoryItem) {
        guard let fileURLs = safeFileURLs(for: item) else {
            print("[KRIT] History delete skipped: item paths escape the history directory")
            return
        }
        try? FileManager.default.removeItem(at: fileURLs.image)
        try? FileManager.default.removeItem(at: fileURLs.thumbnail)
        if let presentedURL = fileURLs.presented {
            try? FileManager.default.removeItem(at: presentedURL)
        }
    }

    nonisolated static func loadIndex(from indexURL: URL) -> [HistoryItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            let storageDir = indexURL.deletingLastPathComponent()
            let unsafeItems = decoded.contains {
                fileURLs(for: $0, containedIn: storageDir) == nil
            }
            let validItems = decoded.filter {
                fileURLs(for: $0, containedIn: storageDir) != nil
                    && FileManager.default.fileExists(atPath: $0.imagePath)
            }
            if unsafeItems, quarantineCorruptIndex(at: indexURL) {
                replaceIndex(at: indexURL, with: validItems)
            }
            return validItems
        } catch {
            print("[KRIT] History index corrupted: \(error)")
            _ = quarantineCorruptIndex(at: indexURL)
            return []
        }
    }

    private func safeFileURLs(for item: HistoryItem) -> ItemFileURLs? {
        HistoryDiskStore.fileURLs(for: item, containedIn: storageDir)
    }

    private nonisolated static func fileURLs(
        for item: HistoryItem,
        containedIn storageDir: URL
    ) -> ItemFileURLs? {
        guard let image = containedFileURL(for: item.imagePath, in: storageDir),
              let thumbnail = containedFileURL(for: item.thumbnailPath, in: storageDir)
        else { return nil }

        let presented = item.presentedPath.flatMap {
            containedFileURL(for: $0, in: storageDir)
        }
        guard item.presentedPath == nil || presented != nil else { return nil }
        return ItemFileURLs(image: image, thumbnail: thumbnail, presented: presented)
    }

    private nonisolated static func containedFileURL(
        for path: String,
        in storageDir: URL
    ) -> URL? {
        guard path.hasPrefix("/") else { return nil }

        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let resolvedCandidate = resolvedFileURL(candidate)
        let resolvedStorage = resolvedFileURL(storageDir.standardizedFileURL)
        let storagePath = resolvedStorage.path.hasSuffix("/")
            ? resolvedStorage.path
            : resolvedStorage.path + "/"
        guard resolvedCandidate.path.hasPrefix(storagePath) else { return nil }
        return candidate
    }

    /// `URL.resolvingSymlinksInPath()` does not consistently resolve an existing
    /// symlinked parent when the final filename has not been written yet. Resolve
    /// the nearest existing ancestor, then rebuild the missing suffix so writes
    /// cannot escape through `History/linked-directory/new-file.png`.
    private nonisolated static func resolvedFileURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existingAncestor = url
        var missingComponents: [String] = []

        while existingAncestor.path != "/"
            && !fileManager.fileExists(atPath: existingAncestor.path) {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }

        let resolvedAncestor = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return missingComponents.reduce(resolvedAncestor) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    private nonisolated static func indexCanBeReplaced(
        at indexURL: URL,
        storageDir: URL
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return true }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            guard decoded.allSatisfy({ fileURLs(for: $0, containedIn: storageDir) != nil }) else {
                return quarantineCorruptIndex(at: indexURL)
            }
            return true
        } catch {
            return quarantineCorruptIndex(at: indexURL)
        }
    }

    private nonisolated static func replaceIndex(
        at indexURL: URL,
        with items: [HistoryItem]
    ) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("[KRIT] Sanitized history index persist failed: \(error)")
        }
    }

    @discardableResult
    private nonisolated static func quarantineCorruptIndex(at indexURL: URL) -> Bool {
        let quarantinedURL = indexURL
            .deletingLastPathComponent()
            .appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: indexURL, to: quarantinedURL)
            print("[KRIT] History index moved to \(quarantinedURL.lastPathComponent)")
            return true
        } catch {
            print("[KRIT] History index quarantine failed: \(error)")
            return false
        }
    }
}
