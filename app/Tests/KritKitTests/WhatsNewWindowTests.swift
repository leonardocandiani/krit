import AppKit
import XCTest
@testable import KritKit

@MainActor
final class WhatsNewWindowTests: XCTestCase {
    func testWindowProducesDeterministicVisualSnapshot() async throws {
        let path = "/tmp/krit-whats-new-tests-\(UUID().uuidString).png"
        WhatsNewWindowController.showNow()
        defer { WhatsNewWindowController.uiTestClose() }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(WhatsNewWindowController.uiTestRenderSnapshot(to: path))
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        XCTAssertGreaterThan(image.size.width, 500)
        XCTAssertGreaterThan(image.size.height, 500)
    }

    func testShowGateOnlyAcceptsARealUpdateWithMatchingNotes() {
        let version = "1.2.3"

        XCTAssertFalse(WhatsNewWindowController.shouldShow(
            current: version, lastSeen: "", hasLaunched: false, notesVersion: version
        ))
        XCTAssertFalse(WhatsNewWindowController.shouldShow(
            current: version, lastSeen: version, hasLaunched: true, notesVersion: version
        ))
        XCTAssertFalse(WhatsNewWindowController.shouldShow(
            current: version, lastSeen: "1.2.2", hasLaunched: true, notesVersion: "1.2.2"
        ))
        XCTAssertTrue(WhatsNewWindowController.shouldShow(
            current: version, lastSeen: "1.2.2", hasLaunched: true, notesVersion: version
        ))
    }

    func testDocumentParserRecognizesReleaseHeadingLevelsAndBullets() {
        let document = WhatsNewDocument.parse("""
        A focused update.

        ### Capture
        - Faster window capture
        - Better shadows

        ## Editor
        * Preview is now read-only
        """)

        XCTAssertEqual(document.introduction, ["A focused update."])
        XCTAssertEqual(document.sections, [
            .init(title: "Capture", blocks: [
                .bullet("Faster window capture"),
                .bullet("Better shadows"),
            ]),
            .init(title: "Editor", blocks: [
                .bullet("Preview is now read-only"),
            ]),
        ])
    }

    func testDocumentExposesStableEditorialStructure() {
        let document = WhatsNewDocument.parse("""
        A sharper release digest.

        Secondary context stays below the lead.

        ### Capture
        - Faster window capture

        ### Editor
        - Cleaner trim controls
        """)

        XCTAssertEqual(document.summary, "A sharper release digest.")
        XCTAssertEqual(document.supportingIntroduction, ["Secondary context stays below the lead."])
        XCTAssertEqual(document.chapterTitles, ["Capture", "Editor"])
    }

    func testDocumentParserKeepsInstallCommandsAsCodeBlocks() {
        let document = WhatsNewDocument.parse("""
        KRIT v0.29.0 brings a quieter native interface and a more dependable screenshot editor.

        ### Release confidence

        - New regression tests cover release-note parsing and update display gates.

        ### Install

        ```bash
        brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
        brew install --cask krit
        ```

        Or:

        ```bash
        curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.29.0/install.sh | bash
        ```

        On first launch, grant Screen Recording permission in System Settings.
        """)

        XCTAssertEqual(document.introduction, [
            "KRIT v0.29.0 brings a quieter native interface and a more dependable screenshot editor."
        ])
        XCTAssertEqual(document.sections.first?.items, [
            "New regression tests cover release-note parsing and update display gates."
        ])
        XCTAssertEqual(document.sections.last, .init(title: "Install", blocks: [
            .code(language: "bash", body: """
            brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
            brew install --cask krit
            """),
            .paragraph("Or:"),
            .code(language: "bash", body: """
            curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.29.0/install.sh | bash
            """),
            .paragraph("On first launch, grant Screen Recording permission in System Settings."),
        ]))
        XCTAssertEqual(document.sections.last?.items, [])
    }
}
