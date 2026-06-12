import AppKit

/// Darkens everything outside the recorded area while an area recording runs,
/// CleanShot-style. Built from a SINGLE borderless window covering the whole
/// screen, with the live rect punched out as a clean transparent hole.
///
/// Using one window (instead of four tiled panels) removes the seams and broken
/// corners that surfaced as a "grid" artifact: the dim is now a single uniform
/// draw, so adjacent edges can never overlap, double their alpha, or misalign.
///
/// The window overlaps the recorded area, but only with fully transparent pixels
/// over the hole, so the cropped SCStream capture is unaffected (the stream sees
/// content inside sourceRect, and transparent pixels do not alter it). The
/// `windowNumbers` API still exposes the window so the capture engine can also
/// exclude it from the SCContentFilter as a safety belt.
///
/// The accent ring is stroked just OUTSIDE the rect, so it marks the boundary
/// without ever bleeding into the captured video.
///
/// The window ignores mouse events: the dim is purely visual. The user keeps
/// clicking through, both inside the live area and on the dimmed surroundings,
/// exactly as they would without the overlay.
@MainActor
final class RecordingDimOverlay {

    /// Dim opacity for the surrounding area. Matches the brief's ~0.35 target.
    private static let dimAlpha: CGFloat = 0.35
    /// Accent ring thickness, stroked outward from the rect.
    private static let borderWidth: CGFloat = 2

    private var window: NSWindow?

    /// Window number of the live dim window, so the capture engine can exclude
    /// it from the SCContentFilter as a safety belt.
    var windowNumbers: [CGWindowID] {
        guard let number = window?.windowNumber, number > 0 else { return [] }
        return [CGWindowID(number)]
    }

    /// Live window count, read by the GUI test harness to prove the dim showed.
    /// Returns 1 while visible, 0 when hidden.
    var panelCount: Int { window == nil ? 0 : 1 }

    /// Shows the dim around `rect` (AppKit global coordinates, bottom-left origin)
    /// on `screen`. One window covers the full screen frame with the rect cut out.
    func show(around rect: CGRect, on screen: NSScreen) {
        guard window == nil else { return }
        let screenFrame = screen.frame
        let live = rect.intersection(screenFrame)
        guard !live.isNull, !live.isEmpty else {
            // Rect is off-screen for this display: dim nothing rather than guess.
            return
        }
        // Fullscreen rect: nothing to dim, preserve the no-overlay behavior.
        guard live != screenFrame else { return }

        let win = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .statusBar + 1
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Keep the dim out of any screen-sharing/recording pipeline as a belt to
        // the geometry guarantee that the hole sits exactly over the captured rect.
        win.sharingType = .none

        // Hole in the view's local (bottom-left origin) coordinate space.
        let holeInView = live.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let content = DimView(frame: NSRect(origin: .zero, size: screenFrame.size))
        content.holeRect = holeInView
        content.borderWidth = Self.borderWidth
        content.dimAlpha = Self.dimAlpha
        win.contentView = content

        window = win
        win.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
private final class DimView: NSView {

    var holeRect: CGRect = .zero
    var borderWidth: CGFloat = 2
    var dimAlpha: CGFloat = 0.35

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Fill the whole screen with the dim, then punch the hole out with an
        // even-odd path so the recorded area stays fully transparent.
        let coverPath = CGMutablePath()
        coverPath.addRect(bounds)
        coverPath.addRect(holeRect)
        context.addPath(coverPath)
        context.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        context.fillPath(using: .evenOdd)

        // Accent ring stroked OUTSIDE the rect: inflate by half the line width so
        // the stroke sits entirely beyond the hole and never enters the capture.
        guard borderWidth > 0 else { return }
        let ringRect = holeRect.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2)
        context.setStrokeColor(KritColors.accent.cgColor)
        context.setLineWidth(borderWidth)
        context.stroke(ringRect)
    }
}
