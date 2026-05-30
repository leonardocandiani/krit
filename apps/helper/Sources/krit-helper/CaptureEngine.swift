import AppKit
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers

/// Frozen screenshot of a specific display.
struct DisplayFreeze {
    let display: SCDisplay
    /// Display frame in AppKit global coordinates (bottom-left origin, points).
    let frame: CGRect
    /// Backing scale factor of the corresponding NSScreen.
    let scale: CGFloat
    /// Screenshot captured at native resolution (pixels).
    let image: CGImage
    /// Corresponding NSScreen (used for coordinate conversions).
    let screen: NSScreen?
}

enum CaptureError: Error, CustomStringConvertible {
    case noShareableContent
    case noDisplays
    case captureFailed(String)
    case cropOutOfBounds

    var description: String {
        switch self {
        case .noShareableContent: return "Could not obtain shareable screen content."
        case .noDisplays: return "No displays found."
        case .captureFailed(let m): return "Capture failed: \(m)"
        case .cropOutOfBounds: return "Selected area is outside display bounds."
        }
    }
}

/// Capture engine backed by ScreenCaptureKit.
///
/// Region capture works in two steps:
/// 1. `freezeAllDisplays()` grabs a screenshot of each display BEFORE the overlay appears.
/// 2. The overlay draws those frozen frames; on mouse-up, `crop(...)` cuts the
///    selected area directly from the freeze-frame (no re-capture needed).
@MainActor
final class CaptureEngine {

    /// Where the captured PNG is written.
    enum Output {
        /// Resident mode (hotkeys): saves to Desktop with a human-friendly name.
        case desktop
        /// One-shot mode (CLI/tray): saves to a unique temporary file.
        case temporary
    }

    /// Screenshot destination. CLI one-shot mode switches this to `.temporary`.
    var output: Output = .desktop

    /// Frozen frames from the last capture session, keyed by displayID.
    private(set) var freezes: [CGDirectDisplayID: DisplayFreeze] = [:]

    // MARK: - Freeze

    /// Captures a screenshot of each display and stores it in `freezes`.
    /// Must be called BEFORE showing the selection overlays.
    func freezeAllDisplays() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var result: [CGDirectDisplayID: DisplayFreeze] = [:]

        for display in content.displays {
            let cgImage = try await screenshot(of: display)

            let screen = nsScreen(for: display.displayID)
            let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
            let scale = screen?.backingScaleFactor ?? 1.0

            result[display.displayID] = DisplayFreeze(
                display: display,
                frame: frame,
                scale: scale,
                image: cgImage,
                screen: screen
            )
        }

        freezes = result
    }

    func clearFreezes() {
        freezes = [:]
    }

    /// Captures a screenshot of a display at native resolution (pixels).
    ///
    /// macOS 14+: uses `SCScreenshotManager.captureImage` (preferred path).
    /// macOS 13: falls back to `CGDisplayCreateImage` (deprecated in 14+ but functional;
    /// also requires Screen Recording permission).
    private func screenshot(of display: SCDisplay) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Native resolution (pixels), not points.
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } else {
            guard let image = CGDisplayCreateImage(display.displayID) else {
                throw CaptureError.captureFailed("CGDisplayCreateImage returned nil (display \(display.displayID))")
            }
            return image
        }
    }

    // MARK: - Fullscreen

    /// Captures the full screen of the display under the cursor.
    /// Performs the freeze internally (independent of the region flow).
    /// Returns the path of the written PNG.
    @discardableResult
    func captureFullScreenUnderCursor() async throws -> URL {
        try await freezeAllDisplays()

        let mouse = NSEvent.mouseLocation
        let freeze = freezeContaining(globalPoint: mouse) ?? freezes.values.first

        guard let freeze else { throw CaptureError.noDisplays }
        let url = try save(image: freeze.image)
        clearFreezes()
        return url
    }

    // MARK: - Crop (region)

    /// Crops a region from the freeze-frame.
    ///
    /// - Parameter globalRect: rectangle in AppKit GLOBAL coordinates
    ///   (bottom-left origin, points), as returned by `NSEvent.mouseLocation`
    ///   and NSScreen frames.
    ///
    /// ## Coordinate conversion
    ///
    /// AppKit uses a bottom-left origin and measures in POINTS. CGImage uses a
    /// top-left origin and measures in PIXELS. To crop correctly:
    ///   1. Find which display contains the rect (by its center).
    ///   2. Translate the global rect to display-local coordinates (subtract the frame origin).
    ///   3. Flip the Y axis (bottom-left -> top-left).
    ///   4. Multiply by `backingScaleFactor` to go from points to pixels.
    ///
    /// With multiple displays at different scales this becomes fragile; pixel-perfect
    /// is guaranteed on the main display and best-effort on the rest.
    @discardableResult
    func crop(globalRect: CGRect) throws -> URL {
        let normalized = globalRect.standardized
        guard normalized.width >= 1, normalized.height >= 1 else {
            throw CaptureError.cropOutOfBounds
        }

        let center = CGPoint(x: normalized.midX, y: normalized.midY)
        guard let freeze = freezeContaining(globalPoint: center) ?? freezes.values.first else {
            throw CaptureError.noDisplays
        }

        // 1. Display-local coordinates (bottom-left origin, points).
        let localX = normalized.origin.x - freeze.frame.origin.x
        let localBottomY = normalized.origin.y - freeze.frame.origin.y

        // 2. Flip Y to top-left. Display height in points is frame.height.
        let displayHeightPts = freeze.frame.height
        let localTopY = displayHeightPts - (localBottomY + normalized.height)

        // 3. Points -> pixels.
        let scale = freeze.scale
        var pxRect = CGRect(
            x: localX * scale,
            y: localTopY * scale,
            width: normalized.width * scale,
            height: normalized.height * scale
        ).integral

        // 4. Clamp to image bounds.
        let bounds = CGRect(x: 0, y: 0, width: freeze.image.width, height: freeze.image.height)
        pxRect = pxRect.intersection(bounds)

        guard !pxRect.isNull, pxRect.width >= 1, pxRect.height >= 1,
              let cropped = freeze.image.cropping(to: pxRect) else {
            throw CaptureError.cropOutOfBounds
        }

        let url = try save(image: cropped)
        clearFreezes()
        return url
    }

    // MARK: - Output

    /// Saves the CGImage as a PNG (to the configured destination) and copies it to the clipboard.
    /// Plays the capture sound at the moment the image is written, then returns the URL.
    @discardableResult
    func save(image: CGImage) throws -> URL {
        let pixelSize = NSSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: pixelSize)

        // Clipboard.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])

        // PNG to destination.
        let url = destinationURL()
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.captureFailed("could not encode PNG")
        }
        try pngData.write(to: url)

        // Shutter fires exactly when the capture is committed.
        KritSounds.shared.play("capture")

        print(url.path)
        fflush(stdout)
        return url
    }

    private func destinationURL() -> URL {
        switch output {
        case .desktop:
            // Human-friendly name, matching the native macOS screenshot style.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let stamp = fmt.string(from: Date())
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            return desktop.appendingPathComponent("KRIT-\(stamp).png")
        case .temporary:
            // No spaces — clean path for stdout (read by the shell).
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let stamp = fmt.string(from: Date())
            let dir = FileManager.default.temporaryDirectory
            let unique = UUID().uuidString.prefix(8)
            return dir.appendingPathComponent("KRIT-\(stamp)-\(unique).png")
        }
    }

    // MARK: - Display helpers

    func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(num.uint32Value) == displayID {
                return screen
            }
        }
        return nil
    }

    /// Returns the freeze whose frame (global bottom-left coordinates) contains the given point.
    func freezeContaining(globalPoint: CGPoint) -> DisplayFreeze? {
        freezes.values.first { $0.frame.contains(globalPoint) }
    }
}
