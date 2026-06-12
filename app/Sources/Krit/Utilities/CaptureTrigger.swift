import AppKit
import os

/// Automation hook: lets external tooling (CLIs, agents, tests) drive captures
/// without touching the UI. Post a distributed notification named
/// "com.krit.capture.rect" whose object is "x,y,w,h|/absolute/out.png"
/// (AppKit screen coordinates, in points). KRIT captures the region, writes the
/// PNG to the given path and a "<out>.status" sidecar describing the result.
@MainActor
final class CaptureTrigger: NSObject {

    static let notificationName = Notification.Name("com.krit.capture.rect")
    static let areaSimNotificationName = Notification.Name("com.krit.capture.area-sim")
    static let editorDemoNotificationName = Notification.Name("com.krit.debug.editor")
    private static let log = Logger(subsystem: "com.krit.app", category: "automation")

    private let engine: CaptureEngine
    private var simSelection: AreaSelectionWindow?

    init(engine: CaptureEngine) {
        self.engine = engine
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCaptureRect(_:)),
            name: Self.notificationName,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAreaSim(_:)),
            name: Self.areaSimNotificationName,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleEditorDemo(_:)),
            name: Self.editorDemoNotificationName,
            object: nil
        )
    }

    /// Opens the annotation editor seeded with one of every element, so the
    /// editor's look can be verified programmatically (dev affordance).
    /// Payload (optional): an absolute path; when present, the editor window's
    /// content is rendered offscreen to that PNG, works even on a locked
    /// screen, where the compositor never shows the window.
    @objc private func handleEditorDemo(_ note: Notification) {
        let outPath = (note.object as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        Task { @MainActor in
            guard let screen = NSScreen.main else { return }
            let rect = CGRect(x: screen.frame.midX - 450, y: screen.frame.midY - 280,
                              width: 900, height: 560)
            // Locked/headless sessions cannot capture; a synthetic backdrop still
            // exercises the full editor UI for offscreen rendering.
            let image = await engine.captureRectToImage(rect, on: screen) ?? Self.syntheticBackdrop(size: NSSize(width: 900, height: 560))
            let controller = AnnotationWindowController.openDemo(image: image)

            guard let outPath else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            var status = "error: no window content"
            if let content = controller.window?.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    do {
                        try png.write(to: URL(fileURLWithPath: outPath))
                        status = "ok \(rep.pixelsWide)x\(rep.pixelsHigh)"
                    } catch {
                        status = "error: \(error.localizedDescription)"
                    }
                }
            }
            try? status.write(toFile: outPath + ".status", atomically: true, encoding: .utf8)
        }
    }

    /// Reproduces the interactive area-capture path end to end (frozen
    /// snapshot -> overlay shown -> simulated mouse-up -> teardown -> delayed
    /// recapture) so the real user flow can be exercised programmatically.
    /// Also writes the frozen snapshot to "<out>.frozen.png" for inspection.
    @objc private func handleAreaSim(_ note: Notification) {
        guard let payload = note.object as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        let nums = parts[0].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, nums.count == 4 else {
            Self.log.error("area-sim trigger: malformed payload \(payload)")
            return
        }
        let rect = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
        let outPath = parts[1]
        Self.log.info("area-sim trigger: rect=\(String(describing: rect)) out=\(outPath)")

        Task { @MainActor in
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }

            if let frozen = await engine.captureRectToImage(screen.frame, on: screen) {
                Self.writePNG(frozen, to: outPath + ".frozen.png")
            }

            let selection = AreaSelectionWindow(mode: .area) { [weak self] selectedRect, selScreen, _ in
                guard let self else { return }
                self.simSelection = nil
                guard let selectedRect else { return }
                Task { @MainActor in
                    var status = "error: capture returned nil"
                    defer { try? status.write(toFile: outPath + ".status", atomically: true, encoding: .utf8) }
                    guard let image = await self.engine.captureRectToImage(selectedRect, on: selScreen) else {
                        if self.engine.lastCaptureFailureWasPermission { status = "error: permission declined (-3801)" }
                        return
                    }
                    status = Self.writePNG(image, to: outPath) ?? "error: png encode failed"
                }
            }
            simSelection = selection
            await selection.prepareAndShow(engine: engine)
            try? await Task.sleep(nanoseconds: 800_000_000)
            selection.simulateSelection(rect: rect, on: screen)
        }
    }

    private static func syntheticBackdrop(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.19, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.24, blue: 0.46, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.46, blue: 0.30, alpha: 1),
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        ("Sample backdrop" as NSString).draw(
            at: NSPoint(x: 24, y: size.height - 44),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        image.unlockFocus()
        return image
    }

    /// Writes the image as PNG; returns an "ok WxH uniform=..." status or nil on failure.
    @discardableResult
    private static func writePNG(_ image: NSImage, to path: String) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let flat = rep.cgImage.flatMap { CaptureEngine.uniformColorDescription($0) }
            return "ok \(rep.pixelsWide)x\(rep.pixelsHigh) uniform=\(flat ?? "none")"
        } catch {
            return "error: write failed \(error.localizedDescription)"
        }
    }

    @objc private func handleCaptureRect(_ note: Notification) {
        guard let payload = note.object as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            Self.log.error("capture trigger: malformed payload \(payload)")
            return
        }
        let nums = parts[0].split(separator: ",").compactMap { Double($0) }
        let outPath = parts[1]
        guard nums.count == 4 else {
            Self.log.error("capture trigger: malformed rect \(parts[0])")
            return
        }
        let rect = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
        Self.log.info("capture trigger: rect=\(String(describing: rect)) out=\(outPath)")

        Task { @MainActor in
            var status = "error: no screen intersects rect"
            defer { try? status.write(toFile: outPath + ".status", atomically: true, encoding: .utf8) }

            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
                return
            }
            guard let image = await engine.captureRectToImage(rect, on: screen) else {
                status = engine.lastCaptureFailureWasPermission
                    ? "error: screen recording permission declined (-3801)"
                    : "error: capture returned nil"
                return
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                status = "error: png encode failed"
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: outPath))
                let flat = (rep.cgImage).flatMap { CaptureEngine.uniformColorDescription($0) }
                status = "ok \(rep.pixelsWide)x\(rep.pixelsHigh) uniform=\(flat ?? "none")"
            } catch {
                status = "error: write failed \(error.localizedDescription)"
            }
        }
    }
}
