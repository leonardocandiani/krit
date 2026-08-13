import AppKit
import XCTest
@testable import KritKit

final class DragFilePromiseTests: XCTestCase {
    func testProviderRetainsWeakDelegateForPromiseLifetime() {
        weak var weakDelegate: FilePromiseProbe?

        let provider: NSFilePromiseProvider = autoreleasepool {
            let delegate = FilePromiseProbe()
            weakDelegate = delegate
            return RetainedFilePromiseProvider.make(fileType: "public.png", delegate: delegate)
        }

        XCTAssertNotNil(weakDelegate)
        XCTAssertNotNil(provider.delegate)
        XCTAssertTrue(provider.delegate === weakDelegate)
    }

    func testProviderAdvertisesOneStablePromiseItem() {
        let provider = RetainedFilePromiseProvider.make(
            fileType: "public.png",
            delegate: FilePromiseProbe()
        )

        let promiseContentType = NSPasteboard.PasteboardType(
            "com.apple.pasteboard.promised-file-content-type"
        )
        let writableTypes = provider.writableTypes(for: NSPasteboard(name: .drag))
        XCTAssertFalse(writableTypes.contains(.fileURL))
        XCTAssertTrue(writableTypes.contains(promiseContentType))

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.krit.tests.drag.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertNotNil(pasteboard.propertyList(forType: promiseContentType))
    }

    func testProviderNeverAdvertisesTimingDependentFileURL() {
        let provider = RetainedFilePromiseProvider.make(
            fileType: "public.png",
            delegate: FilePromiseProbe()
        )

        XCTAssertFalse(provider.writableTypes(for: NSPasteboard(name: .drag)).contains(.fileURL))
    }

    func testRetainedDelegateCanMaterializePromiseAfterFactoryScopeEnds() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-promised-drag-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let provider: NSFilePromiseProvider = autoreleasepool {
            RetainedFilePromiseProvider.make(fileType: "public.png", delegate: FilePromiseProbe())
        }
        let completed = expectation(description: "promise write completed")
        var completionError: Error?

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: outputURL,
            completionHandler: { error in
                completionError = error
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 1)
        XCTAssertNil(completionError)
        XCTAssertEqual(try Data(contentsOf: outputURL), FilePromiseProbe.payload)
    }
}

private final class FilePromiseProbe: NSObject, NSFilePromiseProviderDelegate {
    static let payload = Data("krit-file-promise".utf8)

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        "capture.png"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        do {
            try Self.payload.write(to: url)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        OperationQueue()
    }
}
