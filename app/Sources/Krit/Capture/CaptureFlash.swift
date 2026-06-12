import AppKit
import QuartzCore

/// The capture "moment": a quick white flash over the grabbed region, then a
/// snapshot of the shot that springs into the corner where the Quick Access
/// overlay lands (Apple-Photos pinch-to-thumbnail language). Pure eye-candy,
/// it never blocks the capture pipeline and self-destructs when done.
@MainActor
enum CaptureFlash {

    /// Shutter feedback alone: the white blink over the captured region, fired
    /// BEFORE the SCK grab so the response to the gesture is instant (the grab
    /// at supersampling scale plus template compose take long enough to read as
    /// lag when the blink waits for them). This window is NEVER capturable
    /// (sharingType .none unconditionally): it is on screen DURING the grab, so
    /// even the UI-test gate must not let it leak into the shot it announces.
    static func blink(rect: CGRect, on screen: NSScreen) {
        let window = FlashWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.sharingType = .none

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host
        window.orderFrontRegardless()

        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: rect.minY - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        let flash = CALayer()
        flash.frame = local
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        flash.cornerRadius = 4
        flash.cornerCurve = .continuous
        host.layer?.addSublayer(flash)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flash.add(fade, forKey: "rm-flash")
            tearDown(window, after: 0.2)
            return
        }

        let up = CABasicAnimation(keyPath: "opacity")
        up.fromValue = 0
        up.toValue = 0.85
        up.duration = 0.06
        up.timingFunction = CAMediaTimingFunction(name: .easeOut)
        up.beginTime = 0
        let down = CABasicAnimation(keyPath: "opacity")
        down.fromValue = 0.85
        down.toValue = 0
        down.duration = 0.18
        down.timingFunction = CAMediaTimingFunction(name: .easeIn)
        down.beginTime = 0.06
        let group = CAAnimationGroup()
        group.animations = [up, down]
        group.duration = 0.24
        flash.add(group, forKey: "flash")
        tearDown(window, after: 0.3)
    }

    /// Plays the flash (+ optional zoom-to-tray) on `screen`. Returns how long
    /// the flying snapshot takes to settle (0 when there is no fly), so the
    /// caller can reveal the real overlay card exactly under the ghost's landing.
    /// - rect: captured region in AppKit global coordinates (bottom-left origin).
    /// - image: the captured image, used for the flying snapshot. Pass nil to
    ///   flash only (e.g. fullscreen, where a flying thumbnail reads as clutter).
    /// - landLeft: whether the overlay lands on the left corner (Settings.overlayOnLeft).
    /// - target: the REAL slot frame of the overlay card in global AppKit coords.
    ///   Without it the ghost lands on a generic 240×150 corner guess, which sat
    ///   on top of the real card at a different size: the post-capture flicker.
    /// - includeBlink: false when the white blink already fired at the gesture
    ///   (see `blink`), so this only flies the ghost into the slot.
    @discardableResult
    static func play(rect: CGRect, on screen: NSScreen, image: NSImage?, landLeft: Bool,
                     target globalTarget: CGRect? = nil, includeBlink: Bool = true) -> TimeInterval {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Ghost-only call with nothing to fly: nothing to draw at all.
        if !includeBlink && image == nil { return 0 }

        let window = FlashWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        // Keep the flash/ghost out of any concurrent recording. In UI-test mode
        // it stays capturable so the harness can film the fly-to-tray handoff.
        window.sharingType = ProcessInfo.processInfo.environment["KRIT_UI_TEST"] == "1" ? .readWrite : .none

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host
        window.orderFrontRegardless()

        // Region rect in window-local (bottom-left) coordinates.
        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: rect.minY - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )

        // 1. White flash clipped to the captured region (skipped when the blink
        //    already fired at the gesture).
        if includeBlink {
            let flash = CALayer()
            flash.frame = local
            flash.backgroundColor = NSColor.white.cgColor
            flash.opacity = 0
            flash.cornerRadius = 4
            flash.cornerCurve = .continuous
            host.layer?.addSublayer(flash)

            if reduceMotion {
                // A single soft cross-fade; no zoom.
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.55
                fade.toValue = 0
                fade.duration = 0.15
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                flash.add(fade, forKey: "rm-flash")
                tearDown(window, after: 0.2)
                return 0
            }

            let up = CABasicAnimation(keyPath: "opacity")
            up.fromValue = 0
            up.toValue = 0.85
            up.duration = 0.06
            up.timingFunction = CAMediaTimingFunction(name: .easeOut)
            up.beginTime = 0
            let down = CABasicAnimation(keyPath: "opacity")
            down.fromValue = 0.85
            down.toValue = 0
            down.duration = 0.18
            down.timingFunction = CAMediaTimingFunction(name: .easeIn)
            down.beginTime = 0.06
            let group = CAAnimationGroup()
            group.animations = [up, down]
            group.duration = 0.24
            flash.add(group, forKey: "flash")
        } else if reduceMotion {
            // Blink already happened and motion is reduced: no zoom either.
            tearDown(window, after: 0.05)
            return 0
        }

        // 2. Zoom-to-tray: the shot flies into the overlay's corner slot.
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            tearDown(window, after: 0.3)
            return 0
        }

        let snap = CALayer()
        snap.frame = local
        snap.contents = cg
        snap.contentsGravity = .resizeAspectFill
        snap.masksToBounds = true
        snap.cornerRadius = 6
        snap.cornerCurve = .continuous
        snap.shadowColor = NSColor.black.cgColor
        snap.shadowOpacity = 0.35
        snap.shadowRadius = 18
        snap.shadowOffset = CGSize(width: 0, height: -8)
        host.layer?.addSublayer(snap)

        // Land on the REAL card slot when the caller provides it (global → this
        // screen's local coords); otherwise fall back to a generic corner guess.
        let target: CGRect
        if let g = globalTarget {
            target = CGRect(
                x: g.minX - screen.frame.minX,
                y: g.minY - screen.frame.minY,
                width: g.width, height: g.height
            )
        } else {
            let thumbW: CGFloat = 240, thumbH: CGFloat = 150, margin: CGFloat = 36
            let aspect = local.height / max(local.width, 1)
            let targetW = thumbW
            let targetH = min(thumbH, targetW * aspect)
            let targetX = landLeft ? margin : screen.frame.width - margin - targetW
            target = CGRect(x: targetX, y: margin, width: targetW, height: targetH)
        }

        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: CGPoint(x: local.midX, y: local.midY))
        spring.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
        spring.mass = 1; spring.stiffness = 300; spring.damping = 20; spring.initialVelocity = 0
        spring.duration = spring.settlingDuration

        // Animate BOUNDS, not a uniform transform scale: with aspect-fill
        // gravity the contents re-crop every frame, so the ghost lands with
        // EXACTLY the slot's geometry. The old min(scaleX, scaleY) transform
        // landed a wide capture as a short letterboxed strip, and the card
        // revealing at full slot height underneath read as a visible glitch
        // (the "appears broken, then snaps right" flick).
        let boundsSpring = CASpringAnimation(keyPath: "bounds.size")
        boundsSpring.fromValue = NSValue(size: local.size)
        boundsSpring.toValue = NSValue(size: target.size)
        boundsSpring.mass = 1; boundsSpring.stiffness = 300; boundsSpring.damping = 20
        boundsSpring.duration = boundsSpring.settlingDuration

        // Corner radius eases to the card's thumb radius so the rounded corners
        // match at the moment of the handoff. The thumb radius scales with the
        // overlay size setting (180/240/320 wide -> 10/12/14).
        let cardRadius: CGFloat = target.width <= 200 ? 10 : (target.width <= 260 ? 12 : 14)
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = 6
        radius.toValue = cardRadius
        radius.duration = spring.settlingDuration * 0.6
        radius.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.beginTime = CACurrentMediaTime() + max(spring.settlingDuration - 0.12, 0.2)
        fade.duration = 0.12
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        snap.position = CGPoint(x: target.midX, y: target.midY)
        snap.bounds = CGRect(origin: .zero, size: target.size)
        snap.cornerRadius = cardRadius
        snap.opacity = 0
        snap.add(spring, forKey: "fly-pos")
        snap.add(boundsSpring, forKey: "fly-bounds")
        snap.add(radius, forKey: "fly-radius")
        snap.add(fade, forKey: "fly-fade")

        tearDown(window, after: max(spring.settlingDuration, 0.42) + 0.05)
        return spring.settlingDuration
    }

    private static func tearDown(_ window: NSWindow, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            window.orderOut(nil)
        }
    }
}

/// Borderless window that never steals key, so the flash never disturbs focus.
private final class FlashWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
