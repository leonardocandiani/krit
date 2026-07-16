import AppKit
import ScreenCaptureKit

enum ScreenCaptureSnapshotStoreError: Error {
    case invalidated
}

/// Small single-flight primitive used by the SCK catalog. Completed values are
/// optional per request: display topology opts in, while window inventories
/// share only a currently running enumeration and are discarded immediately.
@MainActor
final class ScreenCaptureSnapshotStore<Key: Hashable & Sendable, Value: Sendable> {
    private struct InFlight {
        let token: UUID
        let revision: UInt64
        let task: Task<Value, Error>
    }

    private var completed: [Key: Value] = [:]
    private var inFlight: [Key: InFlight] = [:]
    private var revision: UInt64 = 0

    func value(
        for key: Key,
        cacheCompleted: Bool,
        loader: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        if cacheCompleted, let value = completed[key] {
            return value
        }

        let flight: InFlight
        if let existing = inFlight[key] {
            flight = existing
        } else {
            let token = UUID()
            let revisionAtStart = revision
            let task = Task { @MainActor in
                try await loader()
            }
            flight = InFlight(token: token, revision: revisionAtStart, task: task)
            inFlight[key] = flight
        }

        do {
            let value = try await flight.task.value
            guard flight.revision == revision else {
                throw ScreenCaptureSnapshotStoreError.invalidated
            }
            if inFlight[key]?.token == flight.token {
                inFlight[key] = nil
            }
            if cacheCompleted {
                completed[key] = value
            }
            return value
        } catch {
            if inFlight[key]?.token == flight.token {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func invalidate(keepCompleted: Bool) {
        revision &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        if !keepCompleted {
            completed.removeAll()
        }
    }
}

private final class ScreenCaptureContentBox: @unchecked Sendable {
    let content: SCShareableContent

    init(_ content: SCShareableContent) {
        self.content = content
    }
}

struct ScreenCaptureDisplaySnapshot: @unchecked Sendable {
    let displays: [SCDisplay]

    func display(id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }
}

struct ScreenCaptureWindowSnapshot: @unchecked Sendable {
    let displays: [SCDisplay]
    let windows: [SCWindow]
    let applications: [SCRunningApplication]

    func display(id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }

    func window(id: CGWindowID) -> SCWindow? {
        windows.first { CGWindowID($0.windowID) == id }
    }
}

/// Shared discovery boundary for ScreenCaptureKit. Display topology is stable
/// until macOS reports a screen-parameter change. Window inventories are never
/// retained after a call, because focus, Spaces and overlay windows change far
/// more often; only concurrent identical queries share the same in-flight work.
@MainActor
final class ScreenCaptureCatalog {
    enum WindowScope: Hashable, Sendable {
        case onScreenOnly
        case allSpaces
    }

    struct Query: Hashable, Sendable {
        let excludesDesktopWindows: Bool
        let scope: WindowScope

        static let visibleContent = Query(
            excludesDesktopWindows: false,
            scope: .onScreenOnly
        )
        static let allContent = Query(
            excludesDesktopWindows: false,
            scope: .allSpaces
        )
        static let windowPicker = Query(
            excludesDesktopWindows: true,
            scope: .onScreenOnly
        )
    }

    typealias Loader = @MainActor @Sendable (Query) async throws -> SCShareableContent

    static let shared = ScreenCaptureCatalog()

    private let store = ScreenCaptureSnapshotStore<Query, ScreenCaptureContentBox>()
    private let loader: Loader
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    convenience init() {
        self.init(
            notificationCenter: .default,
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter
        ) { query in
            try await SCShareableContent.excludingDesktopWindows(
                query.excludesDesktopWindows,
                onScreenWindowsOnly: query.scope == .onScreenOnly
            )
        }
    }

    init(
        notificationCenter: NotificationCenter,
        workspaceNotificationCenter: NotificationCenter,
        loader: @escaping Loader
    ) {
        self.loader = loader
        let screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.store.invalidate(keepCompleted: false)
            }
        }
        observers.append((notificationCenter, screenObserver))

        let spaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Display topology survives a Space switch. Any window query in
                // flight is rejected, while the stable display snapshot remains.
                self?.store.invalidate(keepCompleted: true)
            }
        }
        observers.append((workspaceNotificationCenter, spaceObserver))
    }

    deinit {
        observers.forEach { center, token in
            center.removeObserver(token)
        }
    }

    func displays() async throws -> ScreenCaptureDisplaySnapshot {
        let query = Query.visibleContent
        let box = try await store.value(for: query, cacheCompleted: true) { [loader] in
            ScreenCaptureContentBox(try await loader(query))
        }
        return ScreenCaptureDisplaySnapshot(displays: box.content.displays)
    }

    func windows(_ query: Query) async throws -> ScreenCaptureWindowSnapshot {
        let box = try await store.value(for: query, cacheCompleted: false) { [loader] in
            ScreenCaptureContentBox(try await loader(query))
        }
        return ScreenCaptureWindowSnapshot(
            displays: box.content.displays,
            windows: box.content.windows,
            applications: box.content.applications
        )
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

struct ScreenCaptureRegion: Equatable, Sendable {
    let appKitRect: CGRect
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenCaptureGeometryError: Error {
    case invalidScale
    case emptyRegion
}

/// One display expressed in both coordinate systems used by KRIT. Pixel-grid
/// alignment lives here so screenshots and recordings cannot silently choose
/// different scales or Y flips for the same region.
struct ScreenCaptureDisplayGeometry: Equatable, Sendable {
    /// ScreenCaptureKit rejects buffers larger than the GPU texture ceiling.
    /// Stills and recordings share this guard so a large display degrades by
    /// scaling rather than allowing one capture mode to fail at startup.
    static let maxCaptureEdge = 16_384

    let displayID: CGDirectDisplayID
    let appKitFrame: CGRect
    let coreGraphicsFrame: CGRect
    let backingScale: CGFloat

    func sourceRegion(
        for requestedRect: CGRect,
        evenPixelDimensions: Bool,
        maxEdge: Int
    ) throws -> ScreenCaptureRegion {
        guard backingScale.isFinite, backingScale >= 1 else {
            throw ScreenCaptureGeometryError.invalidScale
        }
        guard requestedRect.width > 0, requestedRect.height > 0, maxEdge > 0 else {
            throw ScreenCaptureGeometryError.emptyRegion
        }

        let localX = floor((requestedRect.minX - appKitFrame.minX) * backingScale) / backingScale
        let localY = floor((requestedRect.minY - appKitFrame.minY) * backingScale) / backingScale
        let logicalWidth = ceil(requestedRect.width * backingScale) / backingScale
        let logicalHeight = ceil(requestedRect.height * backingScale) / backingScale
        let sourceRect = CGRect(
            x: localX,
            y: appKitFrame.height - localY - logicalHeight,
            width: logicalWidth,
            height: logicalHeight
        )
        let appKitRect = CGRect(
            x: appKitFrame.minX + localX,
            y: appKitFrame.minY + localY,
            width: logicalWidth,
            height: logicalHeight
        )

        let rawPixelWidth = max(1, Int((logicalWidth * backingScale).rounded()))
        let rawPixelHeight = max(1, Int((logicalHeight * backingScale).rounded()))
        let pixelWidth = Self.boundedDimension(
            rawPixelWidth,
            even: evenPixelDimensions,
            maxEdge: maxEdge
        )
        let pixelHeight = Self.boundedDimension(
            rawPixelHeight,
            even: evenPixelDimensions,
            maxEdge: maxEdge
        )

        return ScreenCaptureRegion(
            appKitRect: appKitRect,
            sourceRect: sourceRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func appKitRect(fromCoreGraphics rect: CGRect) -> CGRect {
        let localX = rect.minX - coreGraphicsFrame.minX
        let localTop = rect.minY - coreGraphicsFrame.minY
        return CGRect(
            x: appKitFrame.minX + localX,
            y: appKitFrame.minY + appKitFrame.height - localTop - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    func coreGraphicsRect(fromAppKit rect: CGRect) -> CGRect {
        let localX = rect.minX - appKitFrame.minX
        let localBottom = rect.minY - appKitFrame.minY
        return CGRect(
            x: coreGraphicsFrame.minX + localX,
            y: coreGraphicsFrame.minY + appKitFrame.height - localBottom - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func boundedDimension(_ value: Int, even: Bool, maxEdge: Int) -> Int {
        var result = min(value, maxEdge)
        if even, !result.isMultiple(of: 2) {
            result = result < maxEdge ? result + 1 : max(2, result - 1)
        }
        return result
    }
}
