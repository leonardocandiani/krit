import CoreGraphics
import Foundation

/// Zoom math shared by preview and export: crop rects, easing, and the per-time
/// zoom interpolation (ease in, hold, ease out) for a segment. Ported from Snapzy.
enum ZoomCalculator {
    static let transitionDurationRange: ClosedRange<TimeInterval> = 0.15...0.75
    static let defaultTransitionDuration: TimeInterval = 0.4
    static let neutralCenter = CGPoint(x: 0.5, y: 0.5)

    /// Crop rectangle (CoreImage bottom-left space) for a zoom level + center.
    static func calculateCropRect(center: CGPoint, zoomLevel: CGFloat, frameSize: CGSize) -> CGRect {
        guard zoomLevel > 1.0 else { return CGRect(origin: .zero, size: frameSize) }

        let cropWidth = frameSize.width / zoomLevel
        let cropHeight = frameSize.height / zoomLevel
        let maxOriginX = frameSize.width - cropWidth
        let maxOriginY = frameSize.height - cropHeight

        // center is top-left normalized; CoreImage origin is bottom-left.
        let flippedCenterY = 1.0 - center.y
        let originX = max(0, min((center.x * frameSize.width) - (cropWidth / 2), maxOriginX))
        let originY = max(0, min((flippedCenterY * frameSize.height) - (cropHeight / 2), maxOriginY))

        return CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    }

    static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func clampTransitionDuration(_ value: TimeInterval) -> TimeInterval {
        value.clamped(to: transitionDurationRange)
    }

    static func interpolateCenter(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let t = CGFloat(progress.clamped(to: 0...1))
        return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }

    /// Zoom level + center + transition progress at a time within a segment.
    static func interpolateZoom(
        segment: ZoomSegment,
        currentTime: TimeInterval,
        transitionDuration: TimeInterval = defaultTransitionDuration
    ) -> (level: CGFloat, center: CGPoint, progress: Double) {
        guard segment.isEnabled else {
            return (level: 1.0, center: CGPoint(x: 0.5, y: 0.5), progress: 0)
        }

        let timeInSegment = currentTime - segment.startTime
        guard timeInSegment >= 0, timeInSegment < segment.duration else {
            return (level: 1.0, center: segment.zoomCenter, progress: 0)
        }

        let clampedTransition = clampTransitionDuration(transitionDuration)
        let maxTransitionPerEdge = segment.duration * 0.45
        let effectiveTransition = min(clampedTransition, maxTransitionPerEdge)
        let zoomInEnd = max(effectiveTransition, 0.0001)
        let zoomOutStart = min(max(segment.duration - effectiveTransition, 0), segment.duration)

        var progress: Double
        if timeInSegment < zoomInEnd {
            progress = easeInOutCubic(timeInSegment / zoomInEnd)
        } else if timeInSegment > zoomOutStart {
            let t = (timeInSegment - zoomOutStart) / (segment.duration - zoomOutStart)
            progress = 1.0 - easeInOutCubic(t)
        } else {
            progress = 1.0
        }

        let currentLevel = 1.0 + (segment.zoomLevel - 1.0) * CGFloat(progress)
        return (level: currentLevel, center: segment.zoomCenter, progress: progress)
    }

    /// The active (latest) enabled segment containing `time`, if any.
    static func activeSegment(at time: TimeInterval, in segments: [ZoomSegment]) -> ZoomSegment? {
        segments.filter { $0.isEnabled && $0.contains(time: time) }.last
    }

    static func sortedByStartTime(_ segments: [ZoomSegment]) -> [ZoomSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    static func hasOverlap(
        at time: TimeInterval,
        duration: TimeInterval,
        in segments: [ZoomSegment],
        excluding: UUID? = nil
    ) -> Bool {
        let test = ZoomSegment(startTime: time, duration: duration)
        return segments.contains { $0.id != excluding && $0.overlaps(with: test) }
    }
}
