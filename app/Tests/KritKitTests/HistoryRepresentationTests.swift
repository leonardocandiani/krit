import AppKit
import XCTest
@testable import KritKit

@MainActor
final class HistoryRepresentationTests: XCTestCase {
    func testPresentedFileURLFallsBackToRawWhenPresentationIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-representation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawURL = directory.appendingPathComponent("raw.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: rawURL)
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: rawURL.path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil,
            presentedPath: directory.appendingPathComponent("missing-presented.png").path
        )

        XCTAssertEqual(item.presentedFileURL, rawURL)
    }

    func testUpdatingPresentedImagePreservesRawCaptureAndReplacesPresentation() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-representation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let raw = makeImage(width: 16, height: 8, color: .systemRed)
        let presented = makeImage(width: 16, height: 8, color: .systemBlue)
        let rotatedPresentation = makeImage(width: 8, height: 16, color: .systemGreen)
        let manager = HistoryManager(storageDir: storage)
        let item = manager.add(image: raw, rect: .zero, presentedImage: presented)
        let presentedPath = try XCTUnwrap(item.presentedPath)

        let rawExists = await waitUntilFileExists(item.imagePath)
        let presentedExists = await waitUntilFileExists(presentedPath)
        XCTAssertTrue(rawExists)
        XCTAssertTrue(presentedExists)
        let rawBefore = try Data(contentsOf: URL(fileURLWithPath: item.imagePath))
        let presentedBefore = try Data(contentsOf: URL(fileURLWithPath: presentedPath))

        manager.updatePresentedImage(rotatedPresentation, for: item)

        let presentationChanged = await waitUntilFileChanges(at: presentedPath, from: presentedBefore)
        XCTAssertTrue(presentationChanged)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.imagePath)), rawBefore)
        XCTAssertEqual(item.presentedFileURL.path, presentedPath)
        XCTAssertGreaterThan(item.fullImage.size.width, item.fullImage.size.height)
        XCTAssertGreaterThan(item.presentedImage.size.height, item.presentedImage.size.width)
    }

    func testTransformingPlainCapturePromotesPresentationAndPreservesRaw() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-representation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let raw = makeImage(width: 16, height: 8, color: .systemRed)
        let transformed = makeImage(width: 8, height: 16, color: .systemGreen)
        let manager = HistoryManager(storageDir: storage)
        let original = manager.add(image: raw, rect: .zero)
        XCTAssertNil(original.presentedPath)
        let rawPersisted = await waitUntilFileExists(original.imagePath)
        XCTAssertTrue(rawPersisted)
        let rawBefore = try Data(contentsOf: URL(fileURLWithPath: original.imagePath))

        let updated = try XCTUnwrap(manager.updatePresentedImage(transformed, for: original))
        let presentedPath = try XCTUnwrap(updated.presentedPath)
        XCTAssertNotEqual(presentedPath, original.imagePath)
        let presentationPersisted = await waitUntilFileExists(presentedPath)
        XCTAssertTrue(presentationPersisted)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.imagePath)), rawBefore)
        XCTAssertGreaterThan(updated.presentedImage.size.height, updated.presentedImage.size.width)
        XCTAssertEqual(manager.items.first?.presentedPath, presentedPath)

        let indexURL = storage.appendingPathComponent("index.json")
        let indexPersisted = await waitUntilFileExists(indexURL.path)
        XCTAssertTrue(indexPersisted)
        let persisted = try JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(persisted.first?.presentedPath, presentedPath)
    }

    func testDeletedItemRejectsLatePresentationUpdate() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-representation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let raw = makeImage(width: 16, height: 8, color: .systemRed)
        let presented = makeImage(width: 16, height: 8, color: .systemBlue)
        let rotated = makeImage(width: 8, height: 16, color: .systemGreen)
        let manager = HistoryManager(storageDir: storage)
        let item = manager.add(image: raw, rect: .zero, presentedImage: presented)
        let presentedPath = try XCTUnwrap(item.presentedPath)

        let rawPersisted = await waitUntilFileExists(item.imagePath)
        let presentationPersisted = await waitUntilFileExists(presentedPath)
        XCTAssertTrue(rawPersisted)
        XCTAssertTrue(presentationPersisted)

        manager.delete(item)
        let rawRemoved = await waitUntilFileIsGone(item.imagePath)
        let presentationRemoved = await waitUntilFileIsGone(presentedPath)
        XCTAssertTrue(rawRemoved)
        XCTAssertTrue(presentationRemoved)

        manager.updatePresentedImage(rotated, for: item)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.imagePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: presentedPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.thumbnailPath))
    }

    private func makeImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func waitUntilFileExists(_ path: String) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitUntilFileChanges(at path: String, from previous: Data) async -> Bool {
        for _ in 0..<100 {
            if let current = try? Data(contentsOf: URL(fileURLWithPath: path)), current != previous {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitUntilFileIsGone(_ path: String) async -> Bool {
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
