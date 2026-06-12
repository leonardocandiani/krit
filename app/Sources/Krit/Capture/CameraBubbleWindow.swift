import AppKit
import AVFoundation
import QuartzCore

/// Floating circular webcam bubble shown during recording (CleanShot-style). It
/// is a borderless, always-on-top window with a circular live camera preview,
/// a coral ring, and a soft drop shadow. The user can drag it anywhere on the
/// recorded screen.
///
/// Unlike the old PiP compositor (which blended the webcam into every captured
/// frame off-screen), the bubble lives ON the screen and is left IN the
/// SCStream capture (sharingType .readWrite, not excluded), so it is recorded
/// exactly where the viewer sees it. This drops the per-frame CIContext
/// composite and keeps the zero-copy append path for the screen frames.
@MainActor
final class CameraBubbleWindow {

    private let window: BubbleWindow
    private let session: AVCaptureSession
    private let diameter: CGFloat
    private let screen: NSScreen

    /// - deviceID: persisted webcam unique ID; empty falls back to the default
    ///   front camera.
    /// - screen: the recorded screen, so the default position lands on it.
    /// - diameter: bubble size in points (default 150, matching the reference).
    init?(deviceID: String, screen: NSScreen, diameter: CGFloat = 150) {
        guard let device = Self.device(for: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); return nil }
        session.addInput(input)
        session.commitConfiguration()

        self.session = session
        self.diameter = diameter
        self.screen = screen
        self.window = BubbleWindow(diameter: diameter, session: session)
    }

    /// Positions the bubble in the bottom-right corner of the screen and starts
    /// the camera. Capture warm-up blocks for a few hundred ms, so it runs off
    /// the main thread to keep the HUD responsive.
    func start() {
        let margin: CGFloat = 32
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - diameter - margin,
            y: visible.minY + margin
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()

        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    /// Stops the camera and removes the bubble.
    func stop() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
        window.orderOut(nil)
    }

    private static func device(for deviceID: String) -> AVCaptureDevice? {
        if !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}

/// Borderless circular window carrying the webcam preview. Draggable from
/// anywhere inside it; left IN the SCStream capture so it is recorded in place.
@MainActor
private final class BubbleWindow: NSWindow {

    init(diameter: CGFloat, session: AVCaptureSession) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        // Above the HUD so the bubble stays visible, but it MUST be captured, so
        // sharingType stays .readWrite and the engine does NOT exclude it.
        level = .statusBar + 3
        sharingType = .readWrite
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = BubbleContentView(diameter: diameter, session: session)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Circular preview view: a masked AVCaptureVideoPreviewLayer with a coral ring
/// and a drop shadow. Handles drag-to-move on the window directly so the bubble
/// can be repositioned without stealing focus.
@MainActor
private final class BubbleContentView: NSView {

    private let previewLayer: AVCaptureVideoPreviewLayer
    private let ringLayer = CAShapeLayer()
    private var dragOffset: NSPoint = .zero

    init(diameter: CGFloat, session: AVCaptureSession) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))

        wantsLayer = true
        let host = layer!
        host.masksToBounds = false

        // Drop shadow lives on a dedicated layer so the circular mask above does
        // not clip it. It traces the same circle the preview is masked to.
        let shadowLayer = CAShapeLayer()
        shadowLayer.frame = bounds
        shadowLayer.path = CGPath(ellipseIn: bounds, transform: nil)
        shadowLayer.fillColor = NSColor.black.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 16
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        host.addSublayer(shadowLayer)

        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = diameter / 2
        previewLayer.masksToBounds = true
        host.addSublayer(previewLayer)

        // Coral rim, inset by half its width so it sits flush on the circle edge.
        let ringWidth: CGFloat = 3
        ringLayer.frame = bounds
        ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2), transform: nil)
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = KritColors.accent.cgColor
        ringLayer.lineWidth = ringWidth
        host.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Drag the bubble on the very first click even though KRIT is in the
    // background during recording, otherwise the first press would only activate
    // the window and the bubble would not move until a second drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Round hit-testing so clicks just outside the circle (in the square corners)
    // fall through and are not treated as a drag on the bubble.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx + dy * dy) <= (bounds.width / 2) * (bounds.width / 2) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Remember where inside the window the grab happened so the bubble
        // follows the cursor without jumping its corner to the pointer.
        dragOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        // Keep the whole bubble on the screen it is dragged across.
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX), visible.maxX - window.frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - window.frame.height)
        window.setFrameOrigin(origin)
    }
}
