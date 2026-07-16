import AppKit
import XCTest
@testable import KritKit

@MainActor
final class CaptureDeliveryTests: XCTestCase {
    func testUniqueSavePreservesExistingGeneratedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-save-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let requested = directory.appendingPathComponent("KRIT capture.png")
        let original = Data([0x01])
        try original.write(to: requested)
        let capture = EncodedCapture(data: Data([0x02]), ext: "png", uti: "public.png")

        let saved = try XCTUnwrap(
            ImageExporter.save(encoded: capture, to: requested, collisionPolicy: .uniquify)
        )

        XCTAssertEqual(try Data(contentsOf: requested), original)
        XCTAssertEqual(saved.lastPathComponent, "KRIT capture 2.png")
        XCTAssertEqual(try Data(contentsOf: saved), capture.data)
    }

    func testUniqueSaveKeepsEveryConcurrentAutosave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-save-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let requested = directory.appendingPathComponent("KRIT capture.png")
        let payloads = (1...8).map { Data([UInt8($0)]) }
        let urls = await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for payload in payloads {
                group.addTask {
                    ImageExporter.save(
                        encoded: EncodedCapture(data: payload, ext: "png", uti: "public.png"),
                        to: requested,
                        collisionPolicy: .uniquify
                    )
                }
            }
            var result: [URL] = []
            for await url in group {
                if let url { result.append(url) }
            }
            return result
        }

        XCTAssertEqual(urls.count, payloads.count)
        XCTAssertEqual(Set(urls).count, payloads.count)
        XCTAssertEqual(Set(try urls.map { try Data(contentsOf: $0) }), Set(payloads))
    }

    func testSaveFailureDoesNotBlockCopyAndBothReuseOnePNGEncode() async throws {
        let image = makeImage(color: .systemBlue)
        let encoder = EncoderProbe()
        guard let artifact = CaptureArtifact(image: image, encoder: { [encoder] raster, format in
            encoder.encode(raster, as: format)
        }) else {
            XCTFail("Expected a CGImage-backed capture artifact.")
            return
        }
        let sink = FailingSaveSink()
        let request = CaptureActionRequest(
            actions: [.save, .copy],
            format: "png",
            jpegQuality: 0.9,
            saveURL: URL(fileURLWithPath: "/tmp/krit-delivery-test.png")
        )

        await CaptureActionChain.run(
            request,
            image: image,
            artifact: artifact,
            sink: sink
        )

        XCTAssertEqual(sink.events, ["save", "copy"])
        XCTAssertEqual(encoder.callCount, 1)
        XCTAssertFalse(encoder.ranOnMainThread)
    }

    func testConcurrentRequestsShareTheInFlightEncode() async throws {
        let image = makeImage(color: .systemGreen)
        let encoder = EncoderProbe()
        guard let artifact = CaptureArtifact(image: image, encoder: { [encoder] raster, format in
            encoder.encode(raster, as: format)
        }) else {
            XCTFail("Expected a CGImage-backed capture artifact.")
            return
        }

        async let first = artifact.encoded(as: .png)
        async let second = artifact.encoded(as: .png)
        let values = await [first, second]

        XCTAssertEqual(values.compactMap(\.self).count, 2)
        XCTAssertEqual(encoder.callCount, 1)
    }

    func testHistoryAndCopyShareTheSameFullSizePNG() async throws {
        let image = makeImage(color: .systemOrange)
        let encoder = EncoderProbe()
        guard let artifact = CaptureArtifact(image: image, encoder: { [encoder] raster, format in
            encoder.encode(raster, as: format)
        }) else {
            XCTFail("Expected a CGImage-backed capture artifact.")
            return
        }
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-delivery-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryManager(storageDir: storage)
        let item = history.add(
            image: image,
            rect: .zero,
            presentedImage: image,
            rawArtifact: artifact,
            presentedArtifact: artifact
        )
        let sink = FailingSaveSink()
        let request = CaptureActionRequest(
            actions: [.copy],
            format: "png",
            jpegQuality: 0.9,
            saveURL: storage.appendingPathComponent("copy.png")
        )

        await CaptureActionChain.run(request, image: image, artifact: artifact, sink: sink)
        await waitUntilFileExists(item.imagePath)

        XCTAssertEqual(encoder.callCount(for: .png), 1)
        XCTAssertEqual(sink.events, ["copy"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.imagePath))
    }

    func testSubmitStagesRawHistoryAndRunsFollowUpWithPresentedReceipt() async throws {
        let raw = makeImage(color: .systemRed)
        let presented = makeImage(color: .systemPurple)
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-delivery-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryManager(storageDir: storage)
        var followUpRan = false

        let receipt = CaptureDelivery.submit(
            .init(
                rawImage: raw,
                presentedImage: presented,
                rect: CGRect(x: 10, y: 20, width: 16, height: 16),
                screen: NSScreen.main,
                isWindowCapture: false,
                showOverlay: false,
                automaticActions: nil
            ),
            historyManager: history
        ) { staged in
            followUpRan = true
            XCTAssertTrue(staged.presentedImage === presented)
            XCTAssertEqual(history.items.count, 1)
        }

        XCTAssertTrue(followUpRan)
        XCTAssertTrue(receipt.historyItem.fullImage === raw)
        XCTAssertTrue(history.cachedThumbnail(for: receipt.historyItem) === presented)
    }

    private func makeImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
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

private final class EncoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var callsByFormat: [CaptureEncoding: Int] = [:]
    private var observedMainThread = false

    var callCount: Int {
        lock.withLock { calls }
    }

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func callCount(for format: CaptureEncoding) -> Int {
        lock.withLock { callsByFormat[format, default: 0] }
    }

    func encode(_ raster: CaptureRaster, as format: CaptureEncoding) -> EncodedCapture? {
        lock.withLock {
            calls += 1
            callsByFormat[format, default: 0] += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return EncodedCapture(data: Data([0x4b, 0x52, 0x49, 0x54]), ext: "png", uti: "public.png")
    }
}

@MainActor
private final class FailingSaveSink: CaptureActionSink {
    private(set) var events: [String] = []

    func copyPNG(_ data: Data) {
        events.append("copy")
    }

    func save(_ capture: EncodedCapture, to requestedURL: URL) async -> Bool {
        events.append("save")
        return false
    }

    func edit(_ image: NSImage) {
        events.append("edit")
    }

    func pin(_ image: NSImage) {
        events.append("pin")
    }
}
