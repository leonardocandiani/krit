import AppKit
import CoreMedia
import CoreVideo
import KeyboardShortcuts
import QuartzCore
import ScreenCaptureKit

/// How the presentation zoom settles into its target. All three feels run on
/// the same second-order spring; only the damping ratio changes.
enum PresentationZoomFeel: String, CaseIterable, Identifiable {
    case precise, natural, bouncy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .precise: return "Precise"
        case .natural: return "Natural"
        case .bouncy:  return "Bouncy"
        }
    }

    /// Damping ratio ζ: 1 is critically damped (stops dead on target), lower
    /// values overshoot and settle back — the springy look.
    var dampingRatio: Double {
        switch self {
        case .precise: return 1.0
        case .natural: return 0.85
        case .bouncy:  return 0.62
        }
    }
}

/// Live presentation zoom: magnifies the whole screen in real time around the
/// cursor, ZoomIt-style, so presenters can lean into a detail without touching
/// the app they are demoing. The global shortcut ARMS the mode without
/// changing anything on screen: the overlay sits at exactly 1x (a live,
/// pixel-identical pass-through) until the zoom-in shortcut is pressed. The
/// first press jumps to the preferred level from Preferences, further presses
/// step ×1.25, and zoom-out walks back down to 1x while staying armed, so a
/// presenter can dive in and out repeatedly. Toggling again glides out and
/// removes the overlay.
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
/// The "smooth" part: magnification and pan ride second-order damped springs
/// (x″ = −ω²(x − target) − 2ζω·x′), advanced by a 120 Hz tick. Unlike
/// first-order exponential smoothing, spring velocity is CONTINUOUS across
/// target changes, so re-aiming mid-glide bends the motion instead of kinking
/// it. The user tunes the motion in Preferences: a smoothness slider sets the
/// spring's response time (how long a move takes) and a feel picker sets the
/// damping (Precise stops dead, Natural eases with a whisper of overshoot,
/// Bouncy visibly springs). Both are read every tick, so dragging the slider
/// while zoomed adjusts the motion live. The pan spring and the glide-out are
/// always critically damped: an oscillating pan reads as wobble, and an exit
/// undershooting below 1x would flash the desktop's black edges. With Reduce
/// Motion enabled the zoom snaps with no scale animation at all; only the
/// short cursor-follow glide remains (raw pointer jitter would be more
/// motion, not less).
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
    /// Smoothing tick. 120 Hz so the glide stays fluid on ProMotion displays;
    /// on 60 Hz panels the extra ticks are coalesced by the compositor.
    private static let tickInterval: TimeInterval = 1.0 / 120.0
    /// The cursor-follow pan always answers a touch faster than the zoom, so
    /// tracking feels attached to the hand while level changes stay weighty.
    private static let panResponseFactor: Double = 0.6

    /// Smoothness slider position (0…1) → spring response time in seconds.
    /// Exponential, so the slider feels even across its travel:
    /// 0 → 0.10 s (snappy), 0.5 → ≈0.28 s, 1 → 0.80 s (long glide).
    /// Preferences shows the resulting time next to the slider.
    static func responseTime(forSmoothness s: Double) -> Double {
        0.10 * pow(8.0, min(max(s, 0), 1))
    }

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
    private var zoomSpring = SpringValue(value: 1.0)
    private var focusXSpring = SpringValue(value: 0)
    private var focusYSpring = SpringValue(value: 0)
    /// The magnification this armed session is aiming at. Arms at 1.0 (screen
    /// unchanged); the zoom shortcuts drive it. Not persisted — the preferred
    /// level in Settings is where the FIRST zoom-in jumps, set by the
    /// Preferences slider.
    private var sessionLevel: Double = 1.0

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
        case .windingDown:
            state = .active
        }
    }

    /// Zoom shortcuts drive the armed session's level; they are inert while
    /// the mode is off, so they never conjure the overlay by themselves.
    /// From the armed 1x, the first zoom-in jumps straight to the preferred
    /// level (the Preferences slider) — one keypress and the presenter is at
    /// their favorite magnification; further presses step ×1.25.
    func zoomIn() {
        guard case .active = state else { return }
        if sessionLevel < Self.minLevel {
            sessionLevel = Settings.presentationZoomLevel
        } else {
            sessionLevel = min(sessionLevel * Self.levelStep, Self.maxLevel)
        }
    }

    /// Steps back down; below the minimum magnified level it lands on exactly
    /// 1x — screen back to normal, mode still armed for the next dive.
    func zoomOut() {
        guard case .active = state else { return }
        let next = sessionLevel / Self.levelStep
        sessionLevel = next < Self.minLevel ? 1.0 : next
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
            sessionLevel = 1.0
            zoomSpring.snap(to: 1.0)
            let focus = localFocus(for: NSEvent.mouseLocation)
            focusXSpring.snap(to: focus.x)
            focusYSpring.snap(to: focus.y)
            lastTick = CACurrentMediaTime()
            startTicking()
            // Arming leaves the screen pixel-identical, so confirm it worked
            // and point at the key that actually zooms.
            if let shortcut = KeyboardShortcuts.getShortcut(for: .presentationZoomIn) {
                ToastWindow.show(message: "Presentation zoom on — press \(shortcut) to zoom in", icon: "plus.magnifyingglass")
            } else {
                ToastWindow.show(message: "Presentation zoom on — bind Zoom in under Preferences ▸ Shortcuts", icon: "plus.magnifyingglass")
            }
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

        // Motion parameters are read EVERY tick so the Preferences smoothing
        // slider and feel picker steer a live zoom in real time; the zoom
        // target is the armed session's level, driven by the shortcuts.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let zoomResponse = Self.responseTime(forSmoothness: Settings.presentationZoomSmoothness)
        // Only the engaged zoom gets the chosen feel. The glide-out is always
        // critically damped (undershooting below 1x would flash the black
        // letterbox), and so is the pan (an overshooting pan reads as wobble,
        // not smoothness).
        var zoomDamping: Double = 1.0
        if case .active = state, !reduceMotion {
            zoomDamping = Settings.presentationZoomFeel.dampingRatio
        }
        let zoomTarget: Double = { if case .active = state { return sessionLevel } else { return 1.0 } }()
        // A springy step DOWN toward the floor can undershoot below 1x; the
        // render clamp would hold flat at 1x and pop back up — a stutter, not
        // a bounce. When the predicted first undershoot crosses 1x, damp that
        // one move critically instead. Undershoot fraction of an underdamped
        // spring's first swing: e^(−ζπ/√(1−ζ²)).
        if zoomDamping < 1.0, zoomSpring.value > zoomTarget {
            let fraction = exp(-zoomDamping * Double.pi / (1 - zoomDamping * zoomDamping).squareRoot())
            if zoomTarget - (zoomSpring.value - zoomTarget) * fraction < 1.0 {
                zoomDamping = 1.0
            }
        }

        if reduceMotion {
            // Reduce Motion means no scale animation at all: the zoom lands
            // (and exits) instantly. The pan below keeps a short critical
            // glide — that's tracking, and raw cursor jitter would read as
            // MORE motion, not less.
            zoomSpring.snap(to: zoomTarget)
        } else {
            zoomSpring.advance(toward: zoomTarget, dt: dt, response: zoomResponse, dampingRatio: zoomDamping)
        }
        let panResponse = (reduceMotion ? 0.10 : zoomResponse) * Self.panResponseFactor
        let focus = localFocus(for: NSEvent.mouseLocation)
        focusXSpring.advance(toward: focus.x, dt: dt, response: panResponse, dampingRatio: 1.0)
        focusYSpring.advance(toward: focus.y, dt: dt, response: panResponse, dampingRatio: 1.0)

        if case .windingDown = state, zoomSpring.isSettled(at: 1.0, tolerance: 0.01) {
            hardTeardown()
            return
        }
        applyTransform()
    }

    private func applyTransform() {
        guard let layer = contentLayer else { return }
        // Render clamp at 1x: a springy feel may momentarily dip the physics
        // below 1 (bounce), and drawing m < 1 would expose black borders.
        let m = CGFloat(max(zoomSpring.value, 1.0))
        let size = screenFrame.size
        // Source origin so the focus maps to itself, clamped to the screen.
        let focus = CGPoint(x: focusXSpring.value, y: focusYSpring.value)
        var origin = CGPoint(
            x: focus.x * (1 - 1 / m),
            y: focus.y * (1 - 1 / m)
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
        sessionLevel = 1.0
        zoomSpring.snap(to: 1.0)
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

// MARK: - Spring physics

/// One animated scalar on a damped spring: x″ = −ω²(x − target) − 2ζω·x′,
/// with ω = 2π / response. Compared to first-order exponential smoothing,
/// velocity carries across target changes (mid-glide re-aims bend instead of
/// kink) and ζ < 1 yields the deliberate overshoot of the springier feels.
/// Integrated with semi-implicit Euler in capped substeps: at the fastest
/// response the slider allows (0.10 s → ω ≈ 63/s) a 1/240 s substep keeps
/// ω·h ≈ 0.26, far inside the method's stability region, so the spring can
/// never blow up no matter how the wall clock hiccups.
private struct SpringValue {
    var value: Double
    var velocity: Double = 0

    private static let maxSubstep: Double = 1.0 / 240.0

    mutating func advance(toward target: Double, dt: Double, response: Double, dampingRatio: Double) {
        let omega = 2 * Double.pi / max(response, 0.05)
        let zeta = min(max(dampingRatio, 0.1), 1.5)
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, Self.maxSubstep)
            remaining -= h
            let accel = -omega * omega * (value - target) - 2 * zeta * omega * velocity
            velocity += accel * h
            value += velocity * h
        }
    }

    mutating func snap(to target: Double) {
        value = target
        velocity = 0
    }

    /// Settled when displacement AND velocity are negligible — checking the
    /// position alone would end a bouncy glide at its first zero crossing,
    /// mid-oscillation.
    func isSettled(at target: Double, tolerance: Double) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 10
    }
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
