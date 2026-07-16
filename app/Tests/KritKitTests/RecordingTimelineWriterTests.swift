import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import KritKit

@MainActor
final class RecordingTimelineWriterTests: XCTestCase {
    func testFinishWithoutAnAppendedVideoReportsNoVideo() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let result = await finish(fixture.timeline)

        guard case .noVideo = result else {
            return XCTFail("Expected no-video result, got \(result)")
        }
    }

    func testPauseRemovesTheSourceGapFromTheFinishedDuration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try appendVideo(at: 0.0, to: fixture)
        try appendVideo(at: 0.1, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), true)
        try appendVideo(at: 0.2, to: fixture)
        try appendVideo(at: 0.3, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), false)
        try appendVideo(at: 1.3, to: fixture)
        try appendVideo(at: 1.4, to: fixture)

        let result = await finish(fixture.timeline)

        guard case .completed(let duration) = result else {
            return XCTFail("Expected completed result, got \(result)")
        }
        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertLessThan(duration, 0.35)
    }

    func testPausingAgainBeforeTheFirstResumedFramePreservesTheOriginalPauseAnchor() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try appendVideo(at: 0.0, to: fixture)
        try appendVideo(at: 0.1, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), true)
        try appendVideo(at: 0.2, to: fixture)
        try appendVideo(at: 0.3, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), false)
        XCTAssertEqual(fixture.timeline.togglePause(), true)
        try appendVideo(at: 1.1, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), false)
        try appendVideo(at: 1.2, to: fixture)
        try appendVideo(at: 1.3, to: fixture)

        let result = await finish(fixture.timeline)

        guard case .completed(let duration) = result else {
            return XCTFail("Expected completed result, got \(result)")
        }
        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertLessThan(duration, 0.35)
    }

    func testPausedVideoDoesNotReplaceTheFrameRetainedForFinalization() throws {
        let fixture = try makeFixture()
        defer {
            fixture.timeline.cancel()
            try? FileManager.default.removeItem(at: fixture.url)
        }

        try appendVideo(at: 0.0, to: fixture)
        try appendVideo(at: 0.1, to: fixture)
        XCTAssertEqual(fixture.timeline.togglePause(), true)
        try appendVideo(at: 0.2, to: fixture)

        let retainedTime = try XCTUnwrap(retainedFinalFrameSourceTime(in: fixture.timeline))
        XCTAssertEqual(
            CMTimeCompare(retainedTime, CMTime(seconds: 0.1, preferredTimescale: 600)),
            0,
            "A frame discarded during pause must not become the final static frame"
        )
    }

    func testDuplicateVideoPTSDoesNotBreakTheFinishedWriter() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        try appendVideo(at: 0.0, to: fixture)
        try appendVideo(at: 0.1, to: fixture)
        let duplicate = try makeVideoSample(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        for _ in 0..<20 {
            fixture.queue.sync {
                fixture.timeline.append(duplicate, from: .video)
            }
        }
        let diagnostics = fixture.timeline.diagnosticsSummary()
        XCTAssertTrue(diagnostics.contains("+"))
        XCTAssertLessThanOrEqual(diagnostics.components(separatedBy: " | ").count, 13)
        try appendVideo(at: 0.2, to: fixture)

        let result = await finish(fixture.timeline)

        guard case .completed(let duration) = result else {
            return XCTFail("Expected completed result, got \(result)")
        }
        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertLessThan(duration, 0.35)
    }

    private func makeFixture() throws -> TimelineFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-timeline-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: 10,
                AVVideoMaxKeyFrameIntervalKey: 10,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "Writer did not start")

        let queue = DispatchQueue(label: "com.krit.tests.timeline.\(UUID().uuidString)")
        let timeline = RecordingTimelineWriter(
            writer: writer,
            videoInput: input,
            systemAudioInput: nil,
            microphoneInput: nil,
            queue: queue,
            frameDuration: CMTime(value: 1, timescale: 10)
        )
        return TimelineFixture(url: url, input: input, queue: queue, timeline: timeline)
    }

    private func appendVideo(at seconds: Double, to fixture: TimelineFixture) throws {
        XCTAssertTrue(waitUntilReady(fixture.input), "Video input did not become ready")
        let sample = try makeVideoSample(at: CMTime(seconds: seconds, preferredTimescale: 600))
        fixture.queue.sync {
            fixture.timeline.append(sample, from: .video)
        }
    }

    private func finish(_ timeline: RecordingTimelineWriter) async -> RecordingTimelineWriter.FinishResult {
        await withCheckedContinuation { continuation in
            timeline.finish { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !input.isReadyForMoreMediaData {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
        }
        return true
    }

    private func retainedFinalFrameSourceTime(in timeline: RecordingTimelineWriter) -> CMTime? {
        let mirror = Mirror(reflecting: timeline)
        guard let retained = mirror.children.first(where: { $0.label == "lastCompleteSampleBuffer" }) else {
            return nil
        }
        return (retained.value as! CMSampleBuffer?)?.presentationTimeStamp
    }

    private func makeVideoSample(at presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                32,
                32,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &format
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(format),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

private struct TimelineFixture {
    let url: URL
    let input: AVAssetWriterInput
    let queue: DispatchQueue
    let timeline: RecordingTimelineWriter
}
