import AppKit
import CoreGraphics
import os

/// Executes automation commands against the live app. Capture commands run on the
/// `CaptureEngine` (the only process that holds the Screen Recording grant);
/// annotate commands render headlessly. Pure logic, the transport (CFMessagePort,
/// request-id bookkeeping) lives in `AutomationPort`.
@MainActor
final class AutomationService {

    private static let log = Logger(subsystem: "com.krit.app", category: "automation")

    private let engine: CaptureEngine
    /// Weak: the service must never keep the live-annotation feature alive on its
    /// own, it only reads/drives it when the app has one wired up.
    private weak var liveAnnotation: LiveAnnotationController?

    init(engine: CaptureEngine, liveAnnotation: LiveAnnotationController?) {
        self.engine = engine
        self.liveAnnotation = liveAnnotation
    }

    /// Runs one command and returns its result payload (the object that goes under
    /// `result` in a poll response). Throws `AutomationError` on failure.
    func execute(_ command: AutomationCommand) async throws -> [String: Any] {
        switch command {
        case .captureRegion(let x, let y, let w, let h, let display):
            return try await captureRegion(rect: CGRect(x: x, y: y, width: w, height: h), display: display, explicitOut: nil)
        case .captureFullscreen(let display):
            return try await captureFullscreen(display: display, explicitOut: nil)
        case .annotate(let input, let output, let spec):
            return try annotate(input: input, output: output, spec: spec)
        case .inspect(let target, let options):
            return try await inspect(target: target, options: options)
        case .uiSnapshot:
            return uiSnapshot()
        case .uiClick(let id):
            return try uiClick(id: id)
        case .liveAnnotation(let action):
            return try runLiveAnnotationAction(action)
        case .uiAudit:
            return uiAudit()
        }
    }

    /// Variant used by the port, which carries the raw request so an explicit
    /// `path` (capture output destination) can be honored.
    func execute(_ command: AutomationCommand, explicitOutputPath: String?) async throws -> [String: Any] {
        switch command {
        case .captureRegion(let x, let y, let w, let h, let display):
            return try await captureRegion(rect: CGRect(x: x, y: y, width: w, height: h), display: display, explicitOut: explicitOutputPath)
        case .captureFullscreen(let display):
            return try await captureFullscreen(display: display, explicitOut: explicitOutputPath)
        case .annotate(let input, let output, let spec):
            return try annotate(input: input, output: output, spec: spec)
        case .inspect(let target, let options):
            return try await inspect(target: target, options: options)
        case .uiSnapshot:
            return uiSnapshot()
        case .uiClick(let id):
            return try uiClick(id: id)
        case .liveAnnotation(let action):
            return try runLiveAnnotationAction(action)
        case .uiAudit:
            return uiAudit()
        }
    }

    // MARK: - UI introspection / drive (in-process, no Accessibility permission)

    private func uiSnapshot() -> [String: Any] {
        ["text": UIIntrospection.snapshot(liveAnnotation: liveAnnotation)]
    }

    private func uiClick(id: String) throws -> [String: Any] {
        let result = try UIIntrospection.click(id: id)
        return ["clicked": result.id, "class": result.className]
    }

    private func uiAudit() -> [String: Any] {
        ["text": UIIntrospection.audit()]
    }

    private func runLiveAnnotationAction(_ action: LiveAnnotationAutomationAction) throws -> [String: Any] {
        guard let liveAnnotation else { throw AutomationError.liveAnnotationUnavailable }
        switch action {
        case .toggle:  liveAnnotation.toggleDrawMode()
        case .esc:     liveAnnotation.exitDrawModeKeepingAnnotations()
        case .state:   break
        case .seedInk: liveAnnotation.seedTestInk()
        }
        return ["mode": liveAnnotationModeName(liveAnnotation.mode), "objects": liveAnnotation.annotationObjectCount]
    }

    private func liveAnnotationModeName(_ mode: LiveAnnotationController.Mode) -> String {
        switch mode {
        case .off:     return "off"
        case .drawing: return "drawing"
        case .passive: return "passive"
        }
    }

    // MARK: - Capture

    private func captureRegion(rect topLeftRect: CGRect, display: Int?, explicitOut: String?) async throws -> [String: Any] {
        guard topLeftRect.width > 0, topLeftRect.height > 0 else {
            throw AutomationError.malformedRequest("region width and height must be positive")
        }
        // Request is TOP-LEFT origin, global, in points. Pick the screen the rect
        // sits on, then convert to AppKit (bottom-left) for the capture engine.
        guard let screen = screenForTopLeftRect(topLeftRect, displayIndex: display) else {
            throw AutomationError.noDisplay
        }
        let appKitRect = CoordinateSpace.appKitRect(fromTopLeft: topLeftRect)
        return try await capture(rect: appKitRect, on: screen, explicitOut: explicitOut)
    }

    private func captureFullscreen(display: Int?, explicitOut: String?) async throws -> [String: Any] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw AutomationError.noDisplay }
        let screen: NSScreen
        if let display, display >= 0, display < screens.count {
            screen = screens[display]
        } else {
            screen = NSScreen.main ?? screens[0]
        }
        return try await capture(rect: screen.frame, on: screen, explicitOut: explicitOut)
    }

    private func capture(rect: CGRect, on screen: NSScreen, explicitOut: String?) async throws -> [String: Any] {
        guard let image = await engine.captureRectToImage(rect, on: screen) else {
            if engine.lastCaptureFailureWasPermission {
                throw AutomationError.screenRecordingDenied
            }
            throw AutomationError.captureFailed("capture returned nil")
        }
        let path = explicitOut ?? Self.temporaryCapturePath()
        guard let (widthPx, heightPx) = writePNG(image, to: path) else {
            throw AutomationError.captureFailed("png encode/write failed")
        }
        return ["path": path, "widthPx": widthPx, "heightPx": heightPx]
    }

    // MARK: - Annotate

    private func annotate(input: String, output: String, spec: [AnnotationSpec]) throws -> [String: Any] {
        do {
            let size = try HeadlessRenderer.renderToFile(inputPath: input, outputPath: output, spec: spec)
            return ["path": output, "widthPx": size.widthPx, "heightPx": size.heightPx]
        } catch let error as HeadlessRenderer.RenderError {
            throw AutomationError.render(error.description)
        }
    }

    // MARK: - Inspect (AX X-Ray)

    private func inspect(target: InspectTarget, options: InspectOptions) async throws -> [String: Any] {
        var limits = AXInspector.Limits()
        if let maxDepth = options.maxDepth, maxDepth > 0 { limits.maxDepth = maxDepth }

        let tree = try await resolveAXTree(target: target, limits: limits)
        var result = tree.toDictionary()
        result["timestamp"] = Self.iso8601Timestamp()

        // Combo: for a rect target, optionally also grab the pixels so an agent gets
        // semantics + image in one round trip. Capture failure is non-fatal here, the
        // tree is the primary product, so we surface a hint instead of throwing.
        if options.includeScreenshot, case .rect(let x, let y, let w, let h) = target {
            if let shot = await captureRegionBase64(x: x, y: y, w: w, h: h) {
                result["screenshot"] = shot
            } else {
                result["screenshotError"] = "capture failed (check Screen Recording permission)"
            }
        }
        return result
    }

    /// The AX traversal is synchronous and can block on slow/unresponsive targets.
    /// Running it inline on this @MainActor method would freeze the main run loop,
    /// which is exactly the loop that serves the automation port: the CLI's `poll`
    /// round trips would never get answered and the client would hang mutely.
    /// Hop off-main so the run loop stays free to reply (AX APIs are thread-safe).
    private func resolveAXTree(target: InspectTarget, limits: AXInspector.Limits) async throws -> AXInspector.Tree {
        do {
            return try await Task.detached(priority: .userInitiated) {
                switch target {
                case .frontmost:
                    return try AXInspector.inspectFrontmost(limits: limits)
                case .rect(let x, let y, let w, let h):
                    return try AXInspector.inspectRect(CGRect(x: x, y: y, width: w, height: h), limits: limits)
                case .window(let id):
                    return try AXInspector.inspectWindow(CGWindowID(id), limits: limits)
                }
            }.value
        } catch let error as AXInspector.InspectError {
            switch error {
            case .notTrusted:  throw AutomationError.accessibilityDenied(error.message)
            case .noTarget:    throw AutomationError.inspectFailed(error.message)
            }
        }
    }

    /// Captures a top-left global rect and returns a base64 PNG plus its pixel size,
    /// or nil if the capture failed. Reuses the same engine path as `capture_region`.
    private func captureRegionBase64(x: Double, y: Double, w: Double, h: Double) async -> [String: Any]? {
        guard w > 0, h > 0 else { return nil }
        let topLeftRect = CGRect(x: x, y: y, width: w, height: h)
        guard let screen = screenForTopLeftRect(topLeftRect, displayIndex: nil) else { return nil }
        let appKitRect = CoordinateSpace.appKitRect(fromTopLeft: topLeftRect)
        guard let image = await engine.captureRectToImage(appKitRect, on: screen),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return [
            "base64": png.base64EncodedString(),
            "mimeType": "image/png",
            "widthPx": rep.pixelsWide,
            "heightPx": rep.pixelsHigh,
        ]
    }

    private static func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    // MARK: - Coordinate conversion

    private func screenForTopLeftRect(_ rect: CGRect, displayIndex: Int?) -> NSScreen? {
        let screens = NSScreen.screens
        if let displayIndex, displayIndex >= 0, displayIndex < screens.count {
            return screens[displayIndex]
        }
        let appKit = CoordinateSpace.appKitRect(fromTopLeft: rect)
        return screens.first(where: { $0.frame.intersects(appKit) })
            ?? screens.max(by: { lhs, rhs in
                lhs.frame.intersection(appKit).area < rhs.frame.intersection(appKit).area
            })
            ?? NSScreen.main
    }

    // MARK: - PNG output

    private func writePNG(_ image: NSImage, to path: String) -> (Int, Int)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            return (rep.pixelsWide, rep.pixelsHigh)
        } catch {
            Self.log.error("writePNG failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func temporaryCapturePath() -> String {
        let dir = picturesKritDirectory() ?? NSTemporaryDirectory()
        let name = "krit-\(Self.timestamp()).png"
        return (dir as NSString).appendingPathComponent(name)
    }

    private static func picturesKritDirectory() -> String? {
        guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = pictures.appendingPathComponent("KRIT", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        } catch {
            return nil
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
