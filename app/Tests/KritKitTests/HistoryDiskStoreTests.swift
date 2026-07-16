import AppKit
import XCTest
@testable import KritKit

@MainActor
final class HistoryDiskStoreTests: XCTestCase {
    func testCorruptIndexIsQuarantinedBeforeNextInsert() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-corrupt-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        let indexURL = storage.appendingPathComponent("index.json")
        let corruptData = Data("not valid JSON".utf8)
        try corruptData.write(to: indexURL)

        let manager = HistoryManager(storageDir: storage)
        await manager.waitUntilLoaded()
        let inserted = manager.add(image: makeImage(), rect: .zero)

        let persisted = await waitForValidIndex(at: indexURL)
        XCTAssertEqual(persisted?.map(\.id), [inserted.id])

        let quarantinedURLs = try FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("index.corrupt-") }
        let quarantinedURL = try XCTUnwrap(quarantinedURLs.first)
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), corruptData)
    }

    func testUnsafeIndexEntryIsQuarantinedWhileInternalEntrySurvives() throws {
        let storage = try makeStorageDirectory(prefix: "krit-history-unsafe-index")
        let outside = try makeStorageDirectory(prefix: "krit-history-outside-index")
        defer {
            try? FileManager.default.removeItem(at: storage)
            try? FileManager.default.removeItem(at: outside)
        }

        let safeImage = storage.appendingPathComponent("safe.png")
        let safeThumbnail = storage.appendingPathComponent("safe-thumb.png")
        let outsideImage = outside.appendingPathComponent("outside.png")
        try Data("safe-image".utf8).write(to: safeImage)
        try Data("safe-thumbnail".utf8).write(to: safeThumbnail)
        try Data("outside-image".utf8).write(to: outsideImage)

        let safeItem = makeItem(image: safeImage, thumbnail: safeThumbnail)
        let unsafeItem = makeItem(
            image: outsideImage,
            thumbnail: storage.appendingPathComponent("outside-thumb.png")
        )
        let indexURL = storage.appendingPathComponent("index.json")
        let originalIndex = try JSONEncoder().encode([safeItem, unsafeItem])
        try originalIndex.write(to: indexURL)

        let loaded = HistoryDiskStore.loadIndex(from: indexURL)

        XCTAssertEqual(loaded.map(\.id), [safeItem.id])
        XCTAssertEqual(try loadIndex(at: indexURL).map(\.id), [safeItem.id])
        let quarantined = try quarantinedIndex(in: storage)
        XCTAssertEqual(try Data(contentsOf: quarantined), originalIndex)
    }

    func testDeleteDoesNotRemoveExternalFileReferencedByUnsafeIndex() async throws {
        let storage = try makeStorageDirectory(prefix: "krit-history-delete-unsafe")
        let outside = try makeStorageDirectory(prefix: "krit-history-outside-delete")
        defer {
            try? FileManager.default.removeItem(at: storage)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideImage = outside.appendingPathComponent("outside.png")
        let originalImage = Data("do-not-delete".utf8)
        try originalImage.write(to: outsideImage)
        let unsafeItem = makeItem(
            image: outsideImage,
            thumbnail: storage.appendingPathComponent("thumb.png")
        )
        let indexURL = storage.appendingPathComponent("index.json")
        try JSONEncoder().encode([unsafeItem]).write(to: indexURL)

        let store = HistoryDiskStore(storageDir: storage)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)

        await store.delete(unsafeItem)

        XCTAssertEqual(try Data(contentsOf: outsideImage), originalImage)
    }

    func testInsertDoesNotWriteThroughSymlinkedParentOutsideHistoryDirectory() async throws {
        let storage = try makeStorageDirectory(prefix: "krit-history-symlink-insert")
        let outside = try makeStorageDirectory(prefix: "krit-history-outside-insert")
        defer {
            try? FileManager.default.removeItem(at: storage)
            try? FileManager.default.removeItem(at: outside)
        }

        let escapedParent = storage.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapedParent, withDestinationURL: outside)
        let escapedImage = escapedParent.appendingPathComponent("capture.png")
        let item = makeItem(
            image: escapedImage,
            thumbnail: storage.appendingPathComponent("thumb.png")
        )
        let artifact = try XCTUnwrap(CaptureArtifact(image: makeImage()))
        let request = HistoryDiskStore.InsertRequest(
            item: item,
            rawArtifact: artifact,
            thumbnailArtifact: nil,
            presentedArtifact: nil,
            captureRect: nil
        )

        let store = HistoryDiskStore(storageDir: storage)
        _ = await store.insert(request)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("capture.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("index.json").path))
    }

    func testSymlinkedIndexEntryCannotLoadOrOverwriteItsExternalTarget() async throws {
        let storage = try makeStorageDirectory(prefix: "krit-history-symlink-index")
        let outside = try makeStorageDirectory(prefix: "krit-history-outside-symlink")
        defer {
            try? FileManager.default.removeItem(at: storage)
            try? FileManager.default.removeItem(at: outside)
        }

        let outsideImage = outside.appendingPathComponent("outside.png")
        let originalImage = Data("do-not-overwrite".utf8)
        try originalImage.write(to: outsideImage)
        let escapedImage = storage.appendingPathComponent("escaped.png")
        try FileManager.default.createSymbolicLink(at: escapedImage, withDestinationURL: outsideImage)
        let item = makeItem(
            image: escapedImage,
            thumbnail: storage.appendingPathComponent("thumb.png")
        )
        let indexURL = storage.appendingPathComponent("index.json")
        try JSONEncoder().encode([item]).write(to: indexURL)

        let store = HistoryDiskStore(storageDir: storage)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)

        let artifact = try XCTUnwrap(CaptureArtifact(image: makeImage()))
        let updated = await store.updatePresentation(
            .init(item: item, artifact: artifact)
        )

        XCTAssertNil(updated)
        XCTAssertEqual(try Data(contentsOf: outsideImage), originalImage)
        _ = try quarantinedIndex(in: storage)
    }

    func testInjectedLoaderCannotExposeAnExternalPath() async throws {
        let storage = try makeStorageDirectory(prefix: "krit-history-injected-loader")
        let outside = try makeStorageDirectory(prefix: "krit-history-injected-outside")
        defer {
            try? FileManager.default.removeItem(at: storage)
            try? FileManager.default.removeItem(at: outside)
        }

        let externalImage = outside.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: externalImage)
        let forged = makeItem(
            image: externalImage,
            thumbnail: storage.appendingPathComponent("thumb.png")
        )
        let store = HistoryDiskStore(storageDir: storage) { _ in [forged] }

        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
    }

    private func makeStorageDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeItem(
        image: URL,
        thumbnail: URL,
        presented: URL? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: image.path,
            thumbnailPath: thumbnail.path,
            captureRect: nil,
            presentedPath: presented?.path
        )
    }

    private func loadIndex(at url: URL) throws -> [HistoryItem] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([HistoryItem].self, from: data)
    }

    private func quarantinedIndex(in storage: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        )
        return try XCTUnwrap(contents.first { $0.lastPathComponent.hasPrefix("index.corrupt-") })
    }

    private func waitForValidIndex(at indexURL: URL) async -> [HistoryItem]? {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: indexURL),
               let items = try? JSONDecoder().decode([HistoryItem].self, from: data),
               !items.isEmpty {
                return items
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}
