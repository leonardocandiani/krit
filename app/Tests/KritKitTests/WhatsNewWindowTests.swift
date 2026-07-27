import XCTest
@testable import KritKit

@MainActor
final class WhatsNewWindowTests: XCTestCase {
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
            .init(title: "Capture", items: ["Faster window capture", "Better shadows"]),
            .init(title: "Editor", items: ["Preview is now read-only"]),
        ])
    }
}
