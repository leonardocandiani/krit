import Foundation
import XCTest
@testable import KritKit

final class KritTestOutputTests: XCTestCase {
    func testRejectsAChangedOutputLeafThatBecomesASymlink() throws {
        let outputURL = URL(fileURLWithPath: "/tmp/krit-harness-output-\(UUID().uuidString).json")
        let protectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-protected-\(UUID().uuidString).txt")
        let original = Data("unchanged".utf8)
        try original.write(to: protectedURL)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: protectedURL)
        }

        let acceptedURL = try XCTUnwrap(KritTestOutput.temporaryURL(for: outputURL.path))
        try FileManager.default.createSymbolicLink(atPath: outputURL.path, withDestinationPath: protectedURL.path)

        XCTAssertThrowsError(try KritTestOutput.write(Data("replacement".utf8), to: acceptedURL))
        XCTAssertEqual(try Data(contentsOf: protectedURL), original)
    }

    func testAcceptsOnlyDirectChildrenOfTheSharedTemporaryDirectory() {
        XCTAssertNotNil(KritTestOutput.temporaryURL(for: "/tmp/krit-harness-report.json"))
        XCTAssertNil(KritTestOutput.temporaryURL(for: "/tmp/krit-harness/report.json"))
        XCTAssertNil(KritTestOutput.temporaryURL(for: "/Users/shared/krit-harness-report.json"))
    }
}
