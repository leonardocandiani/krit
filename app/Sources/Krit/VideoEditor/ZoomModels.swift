import CoreGraphics
import Foundation

// Auto-zoom data model, ported from Snapzy's video editor. The camera follows the
// recorded cursor path (RecordingMetadata.mouseSamples) inside a zoom segment, the
// same screen-studio effect. Pure value types + math; no UI, no AVFoundation.

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension CGPoint {
    var clampedToUnitRect: CGPoint {
        CGPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
    }
}

/// Tuning for the cursor-follow smart camera.
struct AutoFocusSettings: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 1.0...4.0
    static let followSpeedRange: ClosedRange<Double> = 0.2...1.0
    static let focusMarginRange: ClosedRange<CGFloat> = 0.2...0.9
    static let defaultZoomLevel: CGFloat = 2.0
    static let defaultFollowSpeed: Double = 0.55
    static let defaultFocusMargin: CGFloat = 0.45

    var isEnabled: Bool = false
    var zoomLevel: CGFloat = Self.defaultZoomLevel
    var followSpeed: Double = Self.defaultFollowSpeed
    var focusMargin: CGFloat = Self.defaultFocusMargin

    init(
        isEnabled: Bool = false,
        zoomLevel: CGFloat = Self.defaultZoomLevel,
        followSpeed: Double = Self.defaultFollowSpeed,
        focusMargin: CGFloat = Self.defaultFocusMargin
    ) {
        self.isEnabled = isEnabled
        self.zoomLevel = zoomLevel.clamped(to: Self.zoomRange)
        self.followSpeed = followSpeed.clamped(to: Self.followSpeedRange)
        self.focusMargin = focusMargin.clamped(to: Self.focusMarginRange)
    }

    static func clampFollowSpeed(_ value: Double) -> Double { value.clamped(to: followSpeedRange) }
    static func clampFocusMargin(_ value: CGFloat) -> CGFloat { value.clamped(to: focusMarginRange) }
}

/// One precomputed camera center on the auto-focus path (normalized, top-left).
struct AutoFocusCameraSample: Equatable {
    var time: TimeInterval
    var center: CGPoint
}

/// The resolved camera at a moment: how much to zoom and where to center it.
/// `.identity` means no zoom (full frame).
struct CameraState: Equatable {
    var zoomLevel: CGFloat
    var center: CGPoint

    static let identity = CameraState(zoomLevel: 1.0, center: CGPoint(x: 0.5, y: 0.5))
}

/// Auto = follow the recorded cursor path within the segment; Manual = a fixed framing.
enum ZoomType: String, Codable, CaseIterable, Equatable {
    case auto
    case manual

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "cursorarrow.click"
        case .manual: return "hand.tap"
        }
    }
}

/// A zoom effect over a span of the timeline.
struct ZoomSegment: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var startTime: TimeInterval
    var duration: TimeInterval
    var zoomLevel: CGFloat
    var zoomCenter: CGPoint
    var zoomType: ZoomType
    var followSpeed: Double
    var focusMargin: CGFloat
    var isEnabled: Bool

    var endTime: TimeInterval { startTime + duration }

    static let defaultDuration: TimeInterval = 2.0
    static let defaultZoomLevel: CGFloat = 2.0
    static let minDuration: TimeInterval = 0.5
    static let maxDuration: TimeInterval = 30.0
    static let minZoomLevel: CGFloat = 1.0
    static let maxZoomLevel: CGFloat = 4.0

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        duration: TimeInterval = ZoomSegment.defaultDuration,
        zoomLevel: CGFloat = ZoomSegment.defaultZoomLevel,
        zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        zoomType: ZoomType = .manual,
        followSpeed: Double = AutoFocusSettings.defaultFollowSpeed,
        focusMargin: CGFloat = AutoFocusSettings.defaultFocusMargin,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.duration = duration.clamped(to: Self.minDuration...Self.maxDuration)
        self.zoomLevel = zoomLevel.clamped(to: Self.minZoomLevel...Self.maxZoomLevel)
        self.zoomCenter = zoomCenter.clampedToUnitRect
        self.zoomType = zoomType
        self.followSpeed = AutoFocusSettings.clampFollowSpeed(followSpeed)
        self.focusMargin = AutoFocusSettings.clampFocusMargin(focusMargin)
        self.isEnabled = isEnabled
    }

    func contains(time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }

    func overlaps(with other: ZoomSegment) -> Bool {
        startTime < other.endTime && endTime > other.startTime
    }

    func clamped(to videoDuration: TimeInterval) -> ZoomSegment {
        var clamped = self
        clamped.startTime = max(0, min(startTime, videoDuration - Self.minDuration))
        clamped.duration = min(duration, videoDuration - clamped.startTime)
        return clamped
    }

    var autoFocusSettings: AutoFocusSettings {
        AutoFocusSettings(
            isEnabled: zoomType == .auto,
            zoomLevel: zoomLevel,
            followSpeed: followSpeed,
            focusMargin: focusMargin
        )
    }

    var isAutoMode: Bool { zoomType == .auto }

    var formattedZoomLevel: String {
        zoomLevel == floor(zoomLevel)
            ? String(format: "%.0fx", zoomLevel)
            : String(format: "%.1fx", zoomLevel)
    }
}
