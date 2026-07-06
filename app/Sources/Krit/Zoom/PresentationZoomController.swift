import AppKit
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

/// Live presentation zoom: magnifies the whole screen in real time around the
/// cursor, ZoomIt-style, so presenters can lean into a detail without touching
/// the app they are demoing. Toggled by a global shortcut; while active the
/// zoom-in/out shortcuts step the magnification.
///
/// How it works: a borderless window covers the screen and shows a LIVE
/// ScreenCaptureKit stream of that same screen, scaled around the cursor. The
/// magnifier's own stream excludes the overlay window through its
/// SCContentFilter, so it never captures itself (no mirror feedback). That
/// exclusion is deliberately PER-STREAM, not `sharingType = .none`: the
/// audience on a Meet/Zoom screen share — the whole point of presenting — must
/// see the magnified view, and screen-share apps capture the display through
/// the same APIs a global opt-out would hide the overlay from. KRIT's own
/// recordings pick the zoom up too, which is what a presenter recording a demo
/// wants. The window also ignores mouse events, so the presenter keeps
/// clicking, typing and scrolling straight through into the real apps; content
/// under the cursor keeps working because the zoom is anchored at the cursor
/// (the point under the pointer maps to itself, like the system zoom).
///
/// The "smooth" part: magnification and pan never jump. A 120 Hz tick drives
/// both toward their targets with critically-damped exponential smoothing, so
/// engaging, panning by moving the mouse, stepping the level and disengaging
/// all glide. Toggling off animates back to 1x and only then removes the
/// overlay, so the exit lands exactly on the real screen.
///
/// Zoom math, in the window's top-left coordinate space: at magnification m
/// anchored on focus F, a screen point Q shows source content O + Q/m with
/// O = F·(1 − 1/m), clamped so the visible rect never leaves the screen.
/// Rendering is one CALayer affine transform over the stream's IOSurface, so
/// the GPU does all the work.
@MainActor
final class PresentationZoomController {

    // MARK: - Tunables

    /// Magnification bounds the shortcuts can reach. The lower bound stays
    /// above 1 so "zoomed in at minimum" is still visibly zoomed.
    static let minLevel: Double = 1.25
    static let maxLevel: Double = 6.0
    /// Multiplicative step per zoom-in/out shortcut press.
    private static let levelStep: Double = 1.25
    /// Exponential smoothing rates (1/s). Zoom eases a touch slower than pan
    /// so level changes feel weighty while cursor-follow stays responsive.
    private static let zoomRate: Double = 8.0
    private static let panRate: Double = 12.0
    /// Smoothing tick. 120 Hz so the glide stays fluid on ProMotion displays;
    /// on 60 Hz panels the extra ticks are coalesced by the compositor.
    private static let tickInterval: TimeInterval = 1.0 / 120.0

    // MARK: - State

    private enum State { case idle, starting, active, windingDown }
    private var state: State = .idle
    /// Bumped on every start/teardown so in-flight async setup from a previous
    /// activation can detect it is stale and bail instead of resurrecting UI.
    private var generation = 0

    private var window: NSWindow?
    private var contentLayer: CALayer?
    private var screenFrame: CGRect = .zero

    private var stream: SCStream?
    private var relay: FrameRelay?
    /// The frame currently on screen. Held so the IOSurface backing the layer
    /// contents stays alive until the next frame replaces it.
    private var currentFrame: CVPixelBuffer?
    private var awaitingFirstFrame = false

    private var tickTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var currentZoom: Double = 1.0
    private var targetZoom: Double = 2.0
    private var currentFocus: CGPoint = .zero

    init() {
        // Displays changing resolution/arrangement invalidates the stream, the
        // window frame and the zoom math wholesale; bail out cleanly. The
        // controller lives for the app's lifetime (owned by AppDelegate), so
        // the observation is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.abortForScreenChange() }
        }
    }

    /// True while the magnifier is on screen (any state but idle).
    var isActive: Bool { if case .idle = state { return false }; return true }

    // MARK: - Shortcuts

    /// Global toggle. Off → engage on the screen under the cursor. Engaged →
    /// glide back to 1x and remove. Pressed again mid-glide-out → re-engage.
    func toggle() {
        switch state {
        case .idle:
            start()
        case .starting:
            // Stream setup is still in flight; tear down hard rather than
            // animate a window that never appeared.
            hardTeardown()
        case .active:
            state = .windingDown
            targetZoom = 1.0
        case .windingDown:
            state = .active
            targetZoom = Settings.presentationZoomLevel
        }
    }

    /// Steps magnification while active. Ignored when idle so the (optional)
    /// bindings never conjure the overlay by themselves.
    func zoomIn()  { step(by: Self.levelStep) }
    func zoomOut() { step(by: 1.0 / Self.levelStep) }

    private func step(by factor: Double) {
        guard case .active = state else { return }
        targetZoom = min(max(targetZoom * factor, Self.minLevel), Self.maxLevel)
        // Remember the level so the next activation engages where the
        // presenter last liked it.
        Settings.presentationZoomLevel = targetZoom
    }

    /// Drops the zoom instantly when a KRIT capture or recording begins: the
    /// selection chrome sits at the shielding level (above the magnifier), and
    /// mixing "what you frame" with a magnified live view makes the shot
    /// ambiguous. Captures operate on the real screen; the zoom is a
    /// presentation veneer. Called by every user-facing capture entry point.
    func exitForCapture() {
        guard isActive else { return }
        hardTeardown()
    }

    // MARK: - Engage

    private func start() {
        guard case .idle = state else { return }
        guard let screen = screenUnderCursor() else { return }
        state = .starting
        generation += 1
        let gen = generation
        screenFrame = screen.frame
        let pixelWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let pixelHeight = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        let displayID = Self.displayID(of: screen)

        // The window exists (transparent, click-through) BEFORE the stream so
        // the content filter can exclude it by window ID. It turns visible on
        // the first delivered frame, so there is never a black flash.
        buildWindow()
        guard let windowNumber = window?.windowNumber, windowNumber > 0 else {
            failStart(message: "Presentation zoom couldn't create its overlay.")
            return
        }
        let overlayID = CGWindowID(windowNumber)

        Task { [weak self] in
            do {
                // The freshly ordered window can take a beat to show up in the
                // shareable content list; retry briefly before giving up.
                // Starting WITHOUT the exclusion is never an option — the
                // stream would capture its own overlay and feed back.
                var display: SCDisplay?
                var overlay: SCWindow?
                for attempt in 0..<3 {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let self, self.generation == gen else { return }
                    display = content.displays.first { $0.displayID == displayID }
                    overlay = content.windows.first { $0.windowID == overlayID }
                    if display != nil, overlay != nil { break }
                }
                guard let self, self.generation == gen else { return }
                guard let display else {
                    self.failStart(message: "Presentation zoom couldn't find this display.")
                    return
                }
                guard let overlay else {
                    self.failStart(message: "Presentation zoom couldn't shield its overlay from capture.")
                    return
                }
                try self.beginStream(display: display, excluding: overlay, pixelWidth: pixelWidth, pixelHeight: pixelHeight, generation: gen)
            } catch {
                guard let self, self.generation == gen else { return }
                self.failStart(message: "Presentation zoom needs Screen Recording permission.")
            }
        }
    }

    private func beginStream(display: SCDisplay, excluding overlay: SCWindow, pixelWidth: Int, pixelHeight: Int, generation gen: Int) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [overlay])

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        // Only the real hardware cursor is shown; an overlay cannot suppress
        // it, and a captured (magnified) cursor would double it and visibly
        // detach whenever the smoothed focus lags the pointer. Same choice as
        // the app's other live on-screen capture paths.
        config.showsCursor = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let relay = FrameRelay { [weak self] pixelBuffer in
            guard let self, self.generation == gen else { return }
            self.present(pixelBuffer)
        } onStop: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.hardTeardown()
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: relay)
        try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: Self.frameQueue)
        self.relay = relay
        self.stream = stream
        awaitingFirstFrame = true

        Task { [weak self] in
            do {
                try await stream.startCapture()
                // Belt: if no complete frame lands shortly, fail visibly
                // instead of idling as an invisible window forever.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.generation == gen else { return }
                if self.awaitingFirstFrame {
                    self.failStart(message: "Presentation zoom couldn't start its live view.")
                }
            } catch {
                guard let self, self.generation == gen else { return }
                self.failStart(message: "Presentation zoom needs Screen Recording permission.")
            }
        }
    }

    /// First frame: reveal the (until now transparent) overlay already showing
    /// live content, then start the glide from 1x.
    private func present(_ pixelBuffer: CVPixelBuffer) {
        guard state == .starting || state == .active || state == .windingDown else { return }
        if awaitingFirstFrame {
            awaitingFirstFrame = false
            state = .active
            currentZoom = 1.0
            targetZoom = Settings.presentationZoomLevel
            currentFocus = localFocus(for: NSEvent.mouseLocation)
            lastTick = CACurrentMediaTime()
            startTicking()
        }
        currentFrame = pixelBuffer
        guard let layer = contentLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
            layer.contents = surface
        }
        CATransaction.commit()
        if window?.alphaValue == 0 { window?.alphaValue = 1 }
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Above everything a presenter shows, including the menu bar; clicks
        // pass through so the demo keeps being driven for real.
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // NO sharingType opt-out here, on purpose: screen-share and recording
        // apps must capture this window so the remote audience sees the zoom.
        // The magnifier's own stream excludes it per-stream via the content
        // filter instead. Transparent until the first frame arrives.
        win.alphaValue = 0

        // Flipped host view so layer coordinates match the captured frame
        // (row 0 at the top); all zoom math lives in that one space.
        let host = FlippedHostView(frame: CGRect(origin: .zero, size: screenFrame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.masksToBounds = true

        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = CGRect(origin: .zero, size: screenFrame.size)
        layer.contentsGravity = .resize
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        host.layer?.addSublayer(layer)

        win.contentView = host
        win.orderFrontRegardless()
        window = win
        contentLayer = layer
    }

    // MARK: - Smoothing tick

    private func startTicking() {
        // The timer is added to the MAIN run loop, so the block already runs
        // on the main thread; it calls straight through without a queue hop
        // (a per-tick async dispatch adds a run-loop turn of jitter at 120 Hz).
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the glide keeps running during menu tracking and drags.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard state == .active || state == .windingDown else { return }
        let now = CACurrentMediaTime()
        // Clamp dt so a hiccup (paused debugger, sleeping display) glides on
        // resume instead of teleporting.
        let dt = min(max(now - lastTick, 0), 1.0 / 30.0)
        lastTick = now

        let kZoom = 1 - exp(-dt * Self.zoomRate)
        let kPan = 1 - exp(-dt * Self.panRate)
        currentZoom += (targetZoom - currentZoom) * kZoom
        let focus = localFocus(for: NSEvent.mouseLocation)
        currentFocus.x += (focus.x - currentFocus.x) * kPan
        currentFocus.y += (focus.y - currentFocus.y) * kPan

        if case .windingDown = state, currentZoom < 1.015 {
            hardTeardown()
            return
        }
        applyTransform()
    }

    private func applyTransform() {
        guard let layer = contentLayer else { return }
        let m = CGFloat(currentZoom)
        let size = screenFrame.size
        // Source origin so the focus maps to itself, clamped to the screen.
        var origin = CGPoint(
            x: currentFocus.x * (1 - 1 / m),
            y: currentFocus.y * (1 - 1 / m)
        )
        origin.x = min(max(origin.x, 0), max(size.width - size.width / m, 0))
        origin.y = min(max(origin.y, 0), max(size.height - size.height / m, 0))
        // Scale first, then shift: Q ↦ (Q − O)·m.
        let transform = CGAffineTransform(translationX: -origin.x * m, y: -origin.y * m)
            .scaledBy(x: m, y: m)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// Global (bottom-left) mouse location → window-local top-left space.
    private func localFocus(for mouse: NSPoint) -> CGPoint {
        let x = min(max(mouse.x - screenFrame.minX, 0), screenFrame.width)
        let y = min(max(screenFrame.maxY - mouse.y, 0), screenFrame.height)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Teardown

    private func failStart(message: String) {
        hardTeardown()
        ToastWindow.show(message: message, icon: "plus.magnifyingglass")
    }

    private func abortForScreenChange() {
        guard isActive else { return }
        hardTeardown()
    }

    /// Immediate removal: invalidates in-flight setup, stops the stream and
    /// drops the overlay without animation.
    private func hardTeardown() {
        generation += 1
        state = .idle
        awaitingFirstFrame = false
        tickTimer?.invalidate()
        tickTimer = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        relay = nil
        window?.orderOut(nil)
        window = nil
        contentLayer = nil
        currentFrame = nil
        currentZoom = 1.0
    }

    // MARK: - Helpers

    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        return number.map { CGDirectDisplayID(truncating: $0) } ?? CGMainDisplayID()
    }

    /// Frames are delivered off-main and hopped over; a serial queue keeps
    /// ordering.
    private static let frameQueue = DispatchQueue(label: "krit.presentation-zoom.frames")
}

// MARK: - Stream plumbing

/// Bridges SCStream callbacks (background queue) onto the controller (main).
/// Complete frames only; everything else is dropped, matching the recording
/// engine's treatment of idle/blank stream statuses.
private final class FrameRelay: NSObject, SCStreamOutput, SCStreamDelegate {

    private let onFrame: (CVPixelBuffer) -> Void
    private let onStop: () -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void, onStop: @escaping () -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status],
              Self.frameStatus(from: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let handler = onFrame
        DispatchQueue.main.async { handler(pixelBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onStop
        DispatchQueue.main.async { handler() }
    }

    /// The status attachment's concrete type varies (SCFrameStatus, Int,
    /// NSNumber) across SDKs; accept all three, mirroring RecordingEngine.
    private static func frameStatus(from rawValue: Any) -> SCFrameStatus? {
        if let status = rawValue as? SCFrameStatus { return status }
        if let raw = rawValue as? Int { return SCFrameStatus(rawValue: raw) }
        if let raw = rawValue as? NSNumber { return SCFrameStatus(rawValue: raw.intValue) }
        return nil
    }
}

/// Top-left origin so layer geometry matches the captured frame's row order.
private final class FlippedHostView: NSView {
    override var isFlipped: Bool { true }
}
