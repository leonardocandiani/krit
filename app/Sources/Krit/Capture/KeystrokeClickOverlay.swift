import AppKit
import ApplicationServices
import QuartzCore

/// Always-on-top, click-through overlay that lives INSIDE the recorded region
/// so SCStream captures its contents directly (no per-frame compositing). It
/// draws a coral ripple on every mouse-down and a key pill on every keypress,
/// driven by a listen-only CGEvent tap. Both layers are gated independently by
/// Settings.recordingShowsClicks / recordingShowsKeystrokes.
///
/// The tap needs Accessibility (AXIsProcessTrusted). If not granted, the
/// overlay still shows (empty) and recording continues, same graceful-degrade
/// philosophy as the mic path.
@MainActor
final class KeystrokeClickOverlay {

    private let window: OverlayWindow
    private let regionRect: CGRect
    private let screen: NSScreen
    private let showsClicks: Bool
    private let showsKeystrokes: Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyPills: [KeyPillView] = []
    private var paused = false
    // Holds the tap port for the C callback to re-enable without reaching back
    // into @MainActor state from the tap's run-loop thread (a cross-actor read of
    // eventTap would race / fail under strict concurrency).
    private let tapBox = TapPortBox()

    /// - regionRect: the captured region in AppKit (bottom-left) screen coords.
    init(regionRect: CGRect, screen: NSScreen, showsClicks: Bool, showsKeystrokes: Bool) {
        self.regionRect = regionRect
        self.screen = screen
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
        self.window = OverlayWindow(contentRect: regionRect)
    }

    /// Shows the overlay and installs the tap. Returns silently if neither
    /// feature is enabled. Toasts once if Accessibility must be granted.
    func start() {
        guard showsClicks || showsKeystrokes else { return }
        window.orderFrontRegardless()
        installTap()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    /// Tears down the tap and removes the window.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        tapBox.port = nil
        if let ptr = callbackContextPtr {
            Unmanaged<TapCallbackContext>.fromOpaque(ptr).release()
            callbackContextPtr = nil
        }
        window.orderOut(nil)
    }

    // MARK: - Event tap

    private func installTap() {
        guard ensureAccessibility() else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapCallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
            // Re-enable if the system disabled the tap under load, reads the tap
            // from the thread-safe box, never from @MainActor state.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = context.tapBox.port { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let overlay = context.overlay
            let copy = event.copy()
            Task { @MainActor in overlay.handle(type: type, event: copy) }
            return Unmanaged.passUnretained(event)
        }

        let context = TapCallbackContext(overlay: self, tapBox: tapBox)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: contextPtr
        ) else {
            Unmanaged<TapCallbackContext>.fromOpaque(contextPtr).release()
            return
        }
        callbackContextPtr = contextPtr

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapBox.port = tap
        runLoopSource = source
    }

    /// Retained userInfo for the C callback; released in stop().
    private var callbackContextPtr: UnsafeMutableRawPointer?

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Prompt once and degrade: never block recording.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        ToastWindow.show(message: "Enable Accessibility for click/keystroke overlay.")
        return false
    }

    // MARK: - Rendering

    private func handle(type: CGEventType, event: CGEvent?) {
        guard !paused, let event else { return }
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard showsClicks else { return }
            addRipple(at: NSEvent.mouseLocation)
        case .keyDown:
            guard showsKeystrokes else { return }
            let nsEvent = NSEvent(cgEvent: event)
            addKeyPill(label: Self.keyLabel(for: event, nsEvent: nsEvent))
        default:
            break
        }
    }

    /// Highlights a click with concentric coral rings (CleanShot-style): a small
    /// solid core that flashes at the click point plus two rings that expand and
    /// fade outward, staggered so they read as ripples spreading from the cursor.
    private func addRipple(at globalPoint: NSPoint) {
        guard regionRect.contains(globalPoint) else { return }
        let local = NSPoint(x: globalPoint.x - regionRect.minX, y: globalPoint.y - regionRect.minY)
        guard let host = window.contentView?.layer else { return }

        emitCore(at: local, on: host)
        // Second ring starts slightly later and reaches farther, so the two read
        // as a wave rather than one thick stroke.
        emitRing(at: local, on: host, endDiameter: 56, lineWidth: 3, delay: 0)
        emitRing(at: local, on: host, endDiameter: 74, lineWidth: 2, delay: 0.12)
    }

    /// One expanding-and-fading ring centered on the click point.
    private func emitRing(at local: NSPoint, on host: CALayer, endDiameter: CGFloat, lineWidth: CGFloat, delay: CFTimeInterval) {
        let start: CGFloat = 14
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: local.x - endDiameter / 2, y: local.y - endDiameter / 2, width: endDiameter, height: endDiameter)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = KritColors.accent.cgColor
        ring.lineWidth = lineWidth
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: endDiameter, height: endDiameter), transform: nil)
        ring.opacity = 0
        host.addSublayer(ring)

        let duration: CFTimeInterval = 0.5
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = start / endDiameter
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        ring.add(group, forKey: "ring")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak ring] in
            ring?.removeFromSuperlayer()
        }
    }

    /// Small solid coral dot that flashes once at the exact click point, so the
    /// origin of the ripple is unmistakable.
    private func emitCore(at local: NSPoint, on host: CALayer) {
        let size: CGFloat = 16
        let core = CAShapeLayer()
        core.frame = CGRect(x: local.x - size / 2, y: local.y - size / 2, width: size, height: size)
        core.fillColor = KritColors.accent.withAlphaComponent(0.85).cgColor
        core.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        core.opacity = 0
        host.addSublayer(core)

        let duration: CFTimeInterval = 0.32
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.4
        pop.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [pop, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        core.add(group, forKey: "core")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak core] in
            core?.removeFromSuperlayer()
        }
    }

    /// Stacks a key pill bottom-center; each fades after ~1.5s.
    private func addKeyPill(label: String) {
        guard !label.isEmpty, let content = window.contentView else { return }
        let pill = KeyPillView(text: label)
        content.addSubview(pill)
        keyPills.append(pill)
        layoutKeyPills()

        pill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            pill.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak pill] in
            guard let self, let pill else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                pill.animator().alphaValue = 0
            }, completionHandler: {
                pill.removeFromSuperview()
                self.keyPills.removeAll { $0 === pill }
                self.layoutKeyPills()
            })
        }
    }

    private func layoutKeyPills() {
        guard let content = window.contentView else { return }
        let gap: CGFloat = 8
        let totalWidth = keyPills.reduce(0) { $0 + $1.frame.width } + gap * CGFloat(max(keyPills.count - 1, 0))
        var x = (content.bounds.width - totalWidth) / 2
        let y: CGFloat = 28
        for pill in keyPills {
            pill.frame.origin = NSPoint(x: x, y: y)
            x += pill.frame.width + gap
        }
    }

    // MARK: - Key decoding

    /// Builds a readable label like "⌘ C", "⇧⌘4", "esc" from a CGEvent keyDown.
    private static func keyLabel(for event: CGEvent, nsEvent: NSEvent?) -> String {
        let flags = event.flags
        var modifiers = ""
        if flags.contains(.maskControl) { modifiers += "⌃" }
        if flags.contains(.maskAlternate) { modifiers += "⌥" }
        if flags.contains(.maskShift) { modifiers += "⇧" }
        if flags.contains(.maskCommand) { modifiers += "⌘" }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let named = namedKeys[keyCode] {
            return modifiers.isEmpty ? named : "\(modifiers) \(named)"
        }

        let base = nsEvent?.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !base.isEmpty else { return modifiers }
        return modifiers.isEmpty ? base : "\(modifiers) \(base)"
    }

    /// Non-printing keys shown by name. Keyed by virtual keycode.
    private static let namedKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "space", 51: "⌫", 53: "esc",
        76: "⌅", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// Thread-safe holder for the tap's CFMachPort. The CGEvent tap callback (a C
/// function on the tap's run-loop thread) reads this to re-enable the tap without
/// touching @MainActor state.
private final class TapPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _port: CFMachPort?
    var port: CFMachPort? {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock() }
    }
}

/// Retained userInfo bundle for the C callback: the overlay (hopped to @MainActor
/// before use) and the thread-safe tap box.
private final class TapCallbackContext: @unchecked Sendable {
    let overlay: KeystrokeClickOverlay
    let tapBox: TapPortBox
    init(overlay: KeystrokeClickOverlay, tapBox: TapPortBox) {
        self.overlay = overlay
        self.tapBox = tapBox
    }
}

/// Borderless, click-through, capturable overlay window pinned to the region.
@MainActor
private final class OverlayWindow: NSWindow {

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above the HUD (+2) so ripples stay visible. Unlike the HUD this window
        // must be captured, so sharingType stays default (.readWrite) and the
        // engine must NOT add it to the SCStream excluded windows.
        level = .statusBar + 3
        sharingType = .readWrite
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        root.wantsLayer = true
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small coral-tinted glass pill showing one keystroke label.
@MainActor
private final class KeyPillView: NSView {

    init(text: String) {
        let font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let width = max(40, textWidth + 28)
        let height: CGFloat = 38
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.control
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false

        let glass = ChromeFactory.backing(frame: bounds, cornerRadius: ChromeFactory.Radius.control, tint: KritColors.accent)
        addSubview(glass)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (height - 22) / 2, width: width, height: 22)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
