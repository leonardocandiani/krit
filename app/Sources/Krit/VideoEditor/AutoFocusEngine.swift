import CoreGraphics
import Foundation

/// Precomputes and resolves the cursor-follow smart camera. Feed it a recording's
/// cursor path (RecordingMetadata.mouseSamples) and an auto zoom segment; it returns
/// a smoothed camera-center path and, per time, the resolved CameraState the
/// compositor/preview crops with. Ported from Snapzy; KRIT samples are already
/// top-left normalized, so there is no coordinate-space conversion here.
enum AutoFocusEngine {

    /// Smoothed camera-center path following the cursor inside an auto segment.
    static func buildPath(from metadata: RecordingMetadata, segment: ZoomSegment) -> [AutoFocusCameraSample] {
        guard segment.isAutoMode else { return [] }

        let settings = segment.autoFocusSettings
        let samples = canonicalSamples(from: metadata)
        guard samples.count >= 2 else { return [] }

        let zoomLevel = settings.zoomLevel.clamped(to: AutoFocusSettings.zoomRange)
        let cropHalfWidth = 0.5 / zoomLevel
        let cropHalfHeight = 0.5 / zoomLevel
        let margin = settings.focusMargin.clamped(to: AutoFocusSettings.focusMarginRange)
        let safeHalfWidth = max(cropHalfWidth * margin, 0.02)
        let safeHalfHeight = max(cropHalfHeight * margin, 0.02)

        var lastVisiblePoint = samples.first(where: \.isInsideCapture)?.point.clampedToUnitRect
            ?? CGPoint(x: 0.5, y: 0.5)
        var currentCenter = clampCenter(lastVisiblePoint, cropHalfWidth: cropHalfWidth, cropHalfHeight: cropHalfHeight)

        let minimumDelta = 1.0 / Double(max(metadata.samplesPerSecond, 1))
        let maxResampleStep: TimeInterval = 1.0 / 60.0
        var path: [AutoFocusCameraSample] = [
            AutoFocusCameraSample(time: samples[0].time, center: currentCenter)
        ]

        var previousTime = samples[0].time
        var previousCursorPoint = samples[0].point.clampedToUnitRect

        for sample in samples.dropFirst() {
            let cursorPoint = sample.point.clampedToUnitRect
            if sample.isInsideCapture { lastVisiblePoint = cursorPoint }

            let cursorTarget = sample.isInsideCapture ? cursorPoint : lastVisiblePoint
            let deltaTime = max(sample.time - previousTime, minimumDelta)
            let filteredCursorTarget = clampedCursorPoint(from: previousCursorPoint, to: cursorTarget, deltaTime: deltaTime)
            let stepCount = max(1, Int(ceil(deltaTime / maxResampleStep)))
            let motion = motionIntensity(from: previousCursorPoint, to: filteredCursorTarget, deltaTime: deltaTime)

            for step in 1...stepCount {
                let progress = CGFloat(step) / CGFloat(stepCount)
                let interpolatedCursor = interpolate(from: previousCursorPoint, to: filteredCursorTarget, progress: progress)
                let adaptiveSafeHalfWidth = max(safeHalfWidth * (1 - 0.45 * motion), 0.015)
                let adaptiveSafeHalfHeight = max(safeHalfHeight * (1 - 0.45 * motion), 0.015)

                let targetCenter = deadZoneAdjustedCenter(
                    currentCenter: currentCenter,
                    cursorPoint: interpolatedCursor,
                    safeHalfWidth: adaptiveSafeHalfWidth,
                    safeHalfHeight: adaptiveSafeHalfHeight,
                    cropHalfWidth: cropHalfWidth,
                    cropHalfHeight: cropHalfHeight
                )

                let alpha = smoothingAlpha(
                    deltaTime: deltaTime / Double(stepCount),
                    followSpeed: settings.followSpeed.clamped(to: AutoFocusSettings.followSpeedRange),
                    motionIntensity: motion
                )
                currentCenter = CGPoint(
                    x: currentCenter.x + (targetCenter.x - currentCenter.x) * alpha,
                    y: currentCenter.y + (targetCenter.y - currentCenter.y) * alpha
                )
                currentCenter = clampCenter(currentCenter, cropHalfWidth: cropHalfWidth, cropHalfHeight: cropHalfHeight)

                path.append(AutoFocusCameraSample(
                    time: previousTime + (deltaTime * Double(step) / Double(stepCount)),
                    center: currentCenter
                ))
            }

            previousTime = sample.time
            previousCursorPoint = filteredCursorTarget
        }

        return deduplicated(path)
    }

    /// CameraState for an auto segment at `time`, blending the zoom-in transition
    /// with the precomputed follow path.
    static func cameraState(
        at time: TimeInterval,
        segment: ZoomSegment,
        path: [AutoFocusCameraSample],
        transitionDuration: TimeInterval
    ) -> CameraState {
        let interpolated = ZoomCalculator.interpolateZoom(
            segment: segment,
            currentTime: time,
            transitionDuration: transitionDuration
        )
        guard interpolated.level > 1.0 else { return .identity }

        let targetCenter = path.isEmpty ? segment.zoomCenter : center(at: time, in: path)
        let blendedCenter = ZoomCalculator.interpolateCenter(
            from: ZoomCalculator.neutralCenter,
            to: targetCenter,
            progress: interpolated.progress
        )
        return CameraState(zoomLevel: interpolated.level, center: blendedCenter)
    }

    /// The single function the compositor/preview calls per frame: the resolved
    /// camera at `time` across all segments (manual or auto).
    static func resolvedCameraState(
        at time: TimeInterval,
        segments: [ZoomSegment],
        autoFocusPaths: [UUID: [AutoFocusCameraSample]],
        transitionDuration: TimeInterval
    ) -> CameraState {
        guard let activeSegment = ZoomCalculator.activeSegment(at: time, in: segments) else {
            return .identity
        }

        switch activeSegment.zoomType {
        case .manual:
            let interpolated = ZoomCalculator.interpolateZoom(
                segment: activeSegment,
                currentTime: time,
                transitionDuration: transitionDuration
            )
            let blendedCenter = ZoomCalculator.interpolateCenter(
                from: ZoomCalculator.neutralCenter,
                to: interpolated.center,
                progress: interpolated.progress
            )
            return CameraState(zoomLevel: interpolated.level, center: blendedCenter)
        case .auto:
            return cameraState(
                at: time,
                segment: activeSegment,
                path: autoFocusPaths[activeSegment.id] ?? [],
                transitionDuration: transitionDuration
            )
        }
    }

    // MARK: - Path sampling

    private static func center(at time: TimeInterval, in path: [AutoFocusCameraSample]) -> CGPoint {
        guard let first = path.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard let last = path.last else { return first.center }
        if time <= first.time { return first.center }
        if time >= last.time { return last.center }

        var low = 0
        var high = path.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if path[mid].time <= time { low = mid } else { high = mid }
        }

        let previous = path[low]
        let next = path[high]
        let duration = max(next.time - previous.time, 0.0001)
        let progress = ((time - previous.time) / duration).clamped(to: 0...1)
        return CGPoint(
            x: previous.center.x + (next.center.x - previous.center.x) * progress,
            y: previous.center.y + (next.center.y - previous.center.y) * progress
        )
    }

    private static func smoothingAlpha(deltaTime: TimeInterval, followSpeed: Double, motionIntensity: CGFloat) -> CGFloat {
        let responseRate = 2.0 + (followSpeed * 10.0) + (Double(motionIntensity) * 6.0)
        let alpha = 1.0 - exp(-responseRate * deltaTime)
        return CGFloat(alpha).clamped(to: 0...1)
    }

    private static func deadZoneAdjustedCenter(
        currentCenter: CGPoint,
        cursorPoint: CGPoint,
        safeHalfWidth: CGFloat,
        safeHalfHeight: CGFloat,
        cropHalfWidth: CGFloat,
        cropHalfHeight: CGFloat
    ) -> CGPoint {
        var target = currentCenter
        if cursorPoint.x < currentCenter.x - safeHalfWidth {
            target.x = cursorPoint.x + safeHalfWidth
        } else if cursorPoint.x > currentCenter.x + safeHalfWidth {
            target.x = cursorPoint.x - safeHalfWidth
        }
        if cursorPoint.y < currentCenter.y - safeHalfHeight {
            target.y = cursorPoint.y + safeHalfHeight
        } else if cursorPoint.y > currentCenter.y + safeHalfHeight {
            target.y = cursorPoint.y - safeHalfHeight
        }
        return clampCenter(target, cropHalfWidth: cropHalfWidth, cropHalfHeight: cropHalfHeight)
    }

    private static func clampCenter(_ center: CGPoint, cropHalfWidth: CGFloat, cropHalfHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x.clamped(to: cropHalfWidth...(1 - cropHalfWidth)),
            y: center.y.clamped(to: cropHalfHeight...(1 - cropHalfHeight))
        )
    }

    private static func deduplicated(_ path: [AutoFocusCameraSample]) -> [AutoFocusCameraSample] {
        var result: [AutoFocusCameraSample] = []
        for sample in path {
            if let last = result.last, abs(last.time - sample.time) < 0.0001 {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    private struct CanonicalCursorSample {
        var time: TimeInterval
        var point: CGPoint
        var isInsideCapture: Bool
    }

    private static func canonicalSamples(from metadata: RecordingMetadata) -> [CanonicalCursorSample] {
        let sorted = metadata.mouseSamples.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        var canonical: [CanonicalCursorSample] = []
        canonical.reserveCapacity(sorted.count)
        for sample in sorted {
            let canonicalSample = CanonicalCursorSample(
                time: sample.time,
                point: sample.normalizedPoint.clampedToUnitRect,
                isInsideCapture: sample.isInsideCapture
            )
            if let last = canonical.last, abs(last.time - canonicalSample.time) < 0.0001 {
                canonical[canonical.count - 1] = canonicalSample
            } else {
                canonical.append(canonicalSample)
            }
        }
        return canonical
    }

    private static func clampedCursorPoint(from previous: CGPoint, to current: CGPoint, deltaTime: TimeInterval) -> CGPoint {
        let maxSpeed: CGFloat = 4.0  // normalized units per second
        let minDelta = max(deltaTime, 0.0001)
        let maxDistance = maxSpeed * CGFloat(minDelta)
        let distance = hypot(current.x - previous.x, current.y - previous.y)
        guard distance > maxDistance, distance > 0.0001 else { return current.clampedToUnitRect }
        let progress = (maxDistance / distance).clamped(to: 0...1)
        return interpolate(from: previous, to: current, progress: progress).clampedToUnitRect
    }

    private static func motionIntensity(from previous: CGPoint, to current: CGPoint, deltaTime: TimeInterval) -> CGFloat {
        let minDelta = max(deltaTime, 0.0001)
        let speed = hypot(current.x - previous.x, current.y - previous.y) / CGFloat(minDelta)
        return (speed / 1.2).clamped(to: 0...1)
    }

    private static func interpolate(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }
}
