import CoreGraphics
import Foundation
import os.log

/// One cursor sample taken during a recording. Coordinates are normalized to the
/// capture region with a TOP-LEFT origin (y grows downward, like video pixels),
/// so the auto-zoom engine can map a sample straight onto a frame.
struct RecordedMouseSample: Codable, Equatable {
    var time: TimeInterval
    var normalizedX: CGFloat
    var normalizedY: CGFloat
    var isInsideCapture: Bool

    var normalizedPoint: CGPoint { CGPoint(x: normalizedX, y: normalizedY) }
}

/// Editor-only sidecar for a recording: the cursor path that drives auto-zoom plus
/// the capture size it was sampled against. The recorded MP4 itself stays clean;
/// this lives beside it only in spirit.
struct RecordingMetadata: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = RecordingMetadata.currentVersion
    var captureSize: CGSize
    var samplesPerSecond: Int
    var mouseSamples: [RecordedMouseSample]
}

/// Persists `RecordingMetadata` in Application Support keyed by the video's file
/// name, NOT as a JSON next to the clip. KRIT saves recordings to the Desktop, and
/// a stray sidecar there would be noise; the store keeps the user's folder clean.
/// Keying by name (recording names are timestamped to the second and de-duped on
/// save) is enough for the editor, which opens right after capture; a rename after
/// the fact orphans the metadata, which the editor treats as "no zoom data".
enum RecordingMetadataStore {
    private static let log = Logger(subsystem: "com.krit.app", category: "recording-metadata")

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("KRIT/RecordingMetadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sidecarURL(for videoURL: URL) -> URL? {
        folder?
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("json")
    }

    static func save(_ metadata: RecordingMetadata, for videoURL: URL) {
        guard let url = sidecarURL(for: videoURL) else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(metadata).write(to: url, options: .atomic)
        } catch {
            log.error("metadata save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load(for videoURL: URL) -> RecordingMetadata? {
        guard let url = sidecarURL(for: videoURL),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingMetadata.self, from: data)
    }

    static func delete(for videoURL: URL) {
        guard let url = sidecarURL(for: videoURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
