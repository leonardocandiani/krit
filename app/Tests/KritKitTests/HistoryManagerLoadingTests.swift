import AppKit
import XCTest
@testable import KritKit

@MainActor
final class HistoryManagerLoadingTests: XCTestCase {
    func testCaptureAddedDuringInitialLoadMergesAheadOfDiskHistoryAndPersistsBoth() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-load-\(UUID().uuidString)", isDirectory: true)
        let old = historyItem(in: storage, createdAt: Date(timeIntervalSince1970: 1))
        let gate = HistoryLoadGate(items: [old])
        let manager = HistoryManager(storageDir: storage, initialLoader: { [gate] url in
            gate.load(url)
        })

        XCTAssertTrue(manager.items.isEmpty)
        let new = manager.add(image: makeImage(), rect: .zero)
        manager.persistCurrentIndex()
        gate.release()
        await manager.waitUntilLoaded()

        XCTAssertEqual(manager.items.map(\.id), [new.id, old.id])
        await waitUntilFileExists(storage.appendingPathComponent("index.json").path)
        let data = try Data(contentsOf: storage.appendingPathComponent("index.json"))
        let persisted = try JSONDecoder().decode([HistoryItem].self, from: data)
        XCTAssertEqual(persisted.map(\.id), [new.id, old.id])
    }

    func testDeleteAllDuringInitialLoadPreventsDiskHistoryFromReappearing() async {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-delete-\(UUID().uuidString)", isDirectory: true)
        let old = historyItem(in: storage, createdAt: Date(timeIntervalSince1970: 1))
        let gate = HistoryLoadGate(items: [old])
        let manager = HistoryManager(storageDir: storage, initialLoader: { [gate] url in
            gate.load(url)
        })

        manager.deleteAll()
        gate.release()
        await manager.waitUntilLoaded()

        XCTAssertTrue(manager.items.isEmpty)
    }

    func testLoadCompletionCallbackRefreshesEarlyUI() async {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-callback-\(UUID().uuidString)", isDirectory: true)
        let gate = HistoryLoadGate(items: [])
        let manager = HistoryManager(storageDir: storage, initialLoader: { [gate] url in
            gate.load(url)
        })
        var callbacks = 0
        manager.whenLoaded { callbacks += 1 }

        gate.release()
        await manager.waitUntilLoaded()

        XCTAssertEqual(callbacks, 1)
    }

    private func historyItem(in storage: URL, createdAt: Date) -> HistoryItem {
        let id = UUID()
        return HistoryItem(
            id: id,
            createdAt: createdAt,
            imagePath: storage.appendingPathComponent("\(id).png").path,
            thumbnailPath: storage.appendingPathComponent("\(id)-thumb.png").path,
            captureRect: nil
        )
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
    }

    private func waitUntilFileExists(_ path: String) async {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class HistoryLoadGate: @unchecked Sendable {
    private let items: [HistoryItem]
    private let semaphore = DispatchSemaphore(value: 0)

    init(items: [HistoryItem]) {
        self.items = items
    }

    func load(_ indexURL: URL) -> [HistoryItem] {
        semaphore.wait()
        return items
    }

    func release() {
        semaphore.signal()
    }
}
