import XCTest
@testable import KritKit

@MainActor
final class VideoEditorStateTests: XCTestCase {
    func testWallpaperPreviewOptionsDoNotSynchronouslyLoadFullImageData() throws {
        let state = VideoEditorState(url: URL(fileURLWithPath: "/tmp/krit-video-editor-state-test.mp4"))
        defer { state.tearDown() }

        guard !state.wallpapers.isEmpty else {
            throw XCTSkip("No bundled wallpapers are available in this build.")
        }

        state.backgroundEnabled = true
        state.backgroundKind = .wallpaper
        state.selectedWallpaperIndex = 0

        XCTAssertNil(state.backgroundOptions.wallpaperData)
    }
}
