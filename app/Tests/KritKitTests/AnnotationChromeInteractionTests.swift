import AppKit
import XCTest
@testable import KritKit

@MainActor
final class AnnotationChromeInteractionTests: XCTestCase {
    func testEditorToolAndToggleButtonsInstallTheSamePointerTrackingContract() {
        let tool = FlatToolButton(tool: .arrow, target: nil, action: nil)
        let toggle = ChromeToggleButton(symbol: "eye.slash", target: nil, action: nil)

        tool.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        toggle.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        tool.updateTrackingAreas()
        toggle.updateTrackingAreas()

        assertPointerFeedback(on: tool)
        assertPointerFeedback(on: toggle)
    }

    func testEditorModeSegmentUsesKritAccentInsteadOfSystemBlue() throws {
        let bar = EditorBottomBar(frame: NSRect(x: 0, y: 0, width: 720, height: 56))
        // Searched by descendant rather than direct subview: the bar's controls
        // now live inside the glass capsule that backs the pill.
        let mode = try XCTUnwrap(descendants(of: NSSegmentedControl.self, in: bar).first)
        let actual = try XCTUnwrap(mode.selectedSegmentBezelColor?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(KritColors.accent.usingColorSpace(.sRGB))

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
        XCTAssertFalse(FlatToolButton(tool: .arrow, target: nil, action: nil).mouseDownCanMoveWindow)
    }

    func testEditorToolbarUsesOneBandAndGroupsSecondaryToolsByIntent() {
        let toolbar = AnnotationToolbar(frame: NSRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: AnnotationToolbar.totalHeight
        ))

        // The pill is padding, one control, padding: nothing else may creep into
        // its height, or the capsule stops being a capsule.
        XCTAssertEqual(
            AnnotationToolbar.totalHeight,
            AnnotationToolbar.controlSize + AnnotationToolbar.pillPadding * 2
        )
        XCTAssertEqual(descendants(of: ToolFamilyButton.self, in: toolbar).count, 3)
        XCTAssertEqual(descendants(of: FlatToolButton.self, in: toolbar).count, 6)
        toolbar.layoutSubtreeIfNeeded()

        // The toolbar floats over the stage, so its width is its content's. The
        // guard that matters is that it stays a pill: wide enough for the tools,
        // and nowhere near the full width of an editor window (which is what it
        // used to span as a band).
        XCTAssertGreaterThanOrEqual(toolbar.fittingWidth, AnnotationToolbar.requiredWidth)
        XCTAssertLessThan(toolbar.fittingWidth, 900)
    }

    func testBottomBarDragPillAcceptsFirstMouseAndUsesProfessionalHitArea() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        let pill = BottomBarDragPill(frame: NSRect(x: 20, y: 20, width: 116, height: 22))
        host.addSubview(pill)
        let event = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 58, y: 11))

        XCTAssertTrue(pill.acceptsFirstMouse(for: event))
        XCTAssertTrue(pill.mouseDownCanMoveWindow == false)
        XCTAssertTrue(pill.hitTest(NSPoint(x: 78, y: 14)) === pill)
    }

    func testEditorOpensWithVisibleFullDragOutAffordance() throws {
        let image = NSImage(size: NSSize(width: 900, height: 580))
        let editor = AnnotationWindowController(image: image, historyItem: nil, historyManager: nil)
        defer { editor.window?.close() }

        let content = try XCTUnwrap(editor.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(descendants(of: BottomBarDragPill.self, in: content).first)

        XCTAssertFalse(pill.isHidden, "The editor must expose drag-out when it first opens")
        guard case .full = pill.mode else {
            return XCTFail("The editor has enough room for the labeled drag-out control")
        }
        XCTAssertEqual(pill.frame.width, BottomBarDragPill.fullWidth, accuracy: 0.5)

        for localPoint in [
            NSPoint(x: 8, y: pill.bounds.midY),
            NSPoint(x: pill.bounds.midX, y: pill.bounds.midY),
            NSPoint(x: pill.bounds.maxX - 8, y: pill.bounds.midY),
        ] {
            let pointInContent = pill.convert(localPoint, to: content)
            let hit = content.hitTest(pointInContent)
            let hitType = hit.map { String(describing: type(of: $0)) } ?? "none"
            XCTAssertTrue(
                hit === pill,
                "Every visible Drag out point must hit the pill, got \(hitType) at \(localPoint)"
            )
        }
    }

    func testBottomBarDragPillUsesAnExplicitPlatformDragIcon() {
        XCTAssertNotNil(BottomBarDragPill.dragSymbolName)
        XCTAssertEqual(BottomBarDragPill.dragTitle, "Drag out")
    }

    func testBottomBarDragPillDoesNotRequestImageBeforeDragThreshold() throws {
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 116, height: 22))
        var providerCalls = 0
        pill.exportSnapshotProvider = {
            providerCalls += 1
            return nil
        }

        pill.mouseDown(with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 10, y: 10)))
        pill.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 12, y: 11)))

        XCTAssertEqual(providerCalls, 0)
    }

    func testBottomBarDragPillPreviewFrameUsesPreviewAspectAndSize() {
        let wide = BottomBarDragPill.previewSize(for: NSSize(width: 400, height: 200))
        XCTAssertEqual(wide.width, 120, accuracy: 0.001)
        XCTAssertEqual(wide.height, 60, accuracy: 0.001)

        let tall = BottomBarDragPill.previewSize(for: NSSize(width: 100, height: 400))
        XCTAssertEqual(tall.width, 30, accuracy: 0.001)
        XCTAssertEqual(tall.height, 120, accuracy: 0.001)

        let frame = BottomBarDragPill.draggingFrame(centeredAt: NSPoint(x: 20, y: 30), previewSize: tall)
        XCTAssertEqual(frame.size, tall)
        XCTAssertEqual(frame.midX, 20, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 30, accuracy: 0.001)
    }

    func testBottomBarDragPayloadIsOneConcreteFileURL() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-editor-drag-\(UUID().uuidString).png")
        try Data("krit-editor-file".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let frame = NSRect(x: 10, y: 20, width: 80, height: 40)
        let item = BottomBarDragPill.draggingItem(
            fileURL: fileURL,
            preview: NSImage(size: frame.size),
            frame: frame
        )

        let writer = try XCTUnwrap(item.item as? NSURL)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.krit.tests.editor-drag.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([writer]))

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), fileURL.absoluteString)
        XCTAssertNil(pasteboard.propertyList(forType: NSPasteboard.PasteboardType(
            "com.apple.pasteboard.promised-file-content-type"
        )))
        XCTAssertEqual(item.draggingFrame, frame)
    }

    func testBottomBarPreparesConcreteFileBeforeTheGesture() async throws {
        let originalFormat = Settings.screenshotFormat
        Settings.screenshotFormat = "png"
        defer { Settings.screenshotFormat = originalFormat }

        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        canvas.backgroundImage = image
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 96, height: 32))
        pill.exportSnapshotProvider = { canvas.makeExportSnapshot() }

        let preparedURL = await pill.prepareConcreteDragFile()
        let url = try XCTUnwrap(preparedURL)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(pill.preparedDragFileURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testBottomBarMaterializesConcreteFallbackWhenPreparationIsNotReady() throws {
        let originalFormat = Settings.screenshotFormat
        Settings.screenshotFormat = "png"
        defer { Settings.screenshotFormat = originalFormat }

        let image = NSImage(size: NSSize(width: 48, height: 32))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 96, height: 32))
        pill.immediateExportImageProvider = { image }

        let url = try XCTUnwrap(pill.concreteDragFileForCurrentDocument())
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(pill.preparedDragFileURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testBottomBarInvalidatesPreparedFileBeforeAnImmediatePostEditDrag() async throws {
        let originalFormat = Settings.screenshotFormat
        Settings.screenshotFormat = "png"
        defer { Settings.screenshotFormat = originalFormat }

        let beforeEdit = NSImage(size: NSSize(width: 48, height: 32))
        beforeEdit.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(origin: .zero, size: beforeEdit.size).fill()
        beforeEdit.unlockFocus()
        let afterEdit = NSImage(size: beforeEdit.size)
        afterEdit.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: afterEdit.size).fill()
        afterEdit.unlockFocus()
        let beforeCanvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: beforeEdit.size))
        beforeCanvas.backgroundImage = beforeEdit
        let pill = BottomBarDragPill(frame: NSRect(x: 0, y: 0, width: 96, height: 32))
        pill.exportSnapshotProvider = { beforeCanvas.makeExportSnapshot() }
        pill.immediateExportImageProvider = { afterEdit }

        let preparedBeforeEditURL = await pill.prepareConcreteDragFile()
        let preparedBeforeEdit = try XCTUnwrap(preparedBeforeEditURL)
        let preparedBeforeEditData = try Data(contentsOf: preparedBeforeEdit)
        pill.invalidatePreparedDragFile()
        let draggedImmediatelyAfterEdit = try XCTUnwrap(pill.concreteDragFileForCurrentDocument())
        defer {
            try? FileManager.default.removeItem(at: preparedBeforeEdit)
            try? FileManager.default.removeItem(at: draggedImmediatelyAfterEdit)
        }

        XCTAssertNotEqual(draggedImmediatelyAfterEdit, preparedBeforeEdit)
        XCTAssertNotEqual(
            try Data(contentsOf: draggedImmediatelyAfterEdit),
            preparedBeforeEditData
        )
    }

    func testCancelledEditorPromiseRejectsAReceiverThatStartsLate() throws {
        let image = NSImage(size: NSSize(width: 32, height: 24))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        canvas.backgroundImage = image
        let exportSnapshot = canvas.makeExportSnapshot()
        let delegate = BottomBarFilePromiseDelegate(
            exportSnapshot: exportSnapshot,
            encoding: .png,
            fileExtension: "png",
            fileType: "public.png",
            onWriteStarted: {},
            onCompletion: { _ in }
        )
        let provider = RetainedFilePromiseProvider.make(
            fileType: "public.png",
            delegate: delegate
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-cancelled-editor-promise-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertTrue(delegate.cancelIfNotStarted())
        XCTAssertFalse(delegate.cancelIfNotStarted())

        let completion = expectation(description: "late receiver is rejected")
        var completionError: Error?
        delegate.filePromiseProvider(provider, writePromiseTo: outputURL) { error in
            completionError = error
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)

        XCTAssertNotNil(completionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testEditorPromiseMaterializesTheFrozenSnapshotAfterCanvasChanges() throws {
        let source = NSImage(size: NSSize(width: 64, height: 48))
        source.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: source.size).fill()
        source.unlockFocus()

        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: source.size))
        canvas.backgroundImage = source
        let marker = RectangleAnnotation(rect: CGRect(x: 8, y: 8, width: 36, height: 24))
        marker.color = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        marker.lineWidth = 8
        canvas.objects = [marker]
        let frozenSnapshot = canvas.makeExportSnapshot()
        canvas.objects = []

        let delegate = BottomBarFilePromiseDelegate(
            exportSnapshot: frozenSnapshot,
            encoding: .png,
            fileExtension: "png",
            fileType: "public.png",
            onWriteStarted: {},
            onCompletion: { _ in }
        )
        let provider = RetainedFilePromiseProvider.make(fileType: "public.png", delegate: delegate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-frozen-editor-promise-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let completion = expectation(description: "frozen snapshot materializes")
        var completionError: Error?
        delegate.filePromiseProvider(provider, writePromiseTo: outputURL) { error in
            completionError = error
            completion.fulfill()
        }
        wait(for: [completion], timeout: 3)

        XCTAssertNil(completionError)
        let data = try Data(contentsOf: outputURL)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var magentaPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.redComponent > 0.8,
                   color.greenComponent < 0.2,
                   color.blueComponent > 0.8,
                   color.alphaComponent > 0.8 {
                    magentaPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(magentaPixels, 100)
    }

    private func assertPointerFeedback(on view: NSView) {
        XCTAssertTrue(view.trackingAreas.contains { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.activeAlways)
        })
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { view -> [T] in
            let current = (view as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }

    private func mouseEvent(type: NSEvent.EventType, location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

private final class EditorFilePromiseProbe: NSObject, NSFilePromiseProviderDelegate {
    private(set) var writeCount = 0

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
        writeCount += 1
        handler(nil)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        OperationQueue()
    }
}
