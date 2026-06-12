import AppKit
import QuartzCore

/// Self-timer countdown shown before a screenshot fires (D1). A centered coral
/// glass badge counts 3-2-1, one second each, then tears itself down so the
/// capture grabs a clean frame. Esc aborts the whole capture. Mirrors the
/// `enum CaptureFlash` namespace style: stateless, the only state is the window
/// it builds and discards per run.
@MainActor
enum CountdownWindow {

    /// Shows a centered countdown on `screen`, resolving `true` when it reaches 0
    /// or `false` if the user pressed Esc (so the caller can abort the capture).
    /// Returns `true` immediately for `seconds <= 0` (no window).
    @discardableResult
    static func run(seconds: Int, on screen: NSScreen) async -> Bool {
        guard seconds > 0 else { return true }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Square badge centered on the captured display.
        let side: CGFloat = 132
        let origin = NSPoint(
            x: screen.frame.midX - side / 2,
            y: screen.frame.midY - side / 2
        )
        let pixel = pixelAligned(origin, scale: screen.backingScaleFactor)
        let window = CountdownPanel(
            contentRect: NSRect(x: pixel.x, y: pixel.y, width: side, height: side),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.sharingType = .none   // belt-and-suspenders: never recorded into a concurrent capture

        // Coral glass capsule (real glass on macOS 26, tinted blur fallback below).
        let backing = ChromeFactory.backing(
            frame: NSRect(origin: .zero, size: CGSize(width: side, height: side)),
            cornerRadius: ChromeFactory.Radius.panel,
            variant: .regular,
            tint: KritColors.accent
        )
        let host = NSView(frame: NSRect(origin: .zero, size: CGSize(width: side, height: side)))
        host.wantsLayer = true
        host.addSubview(backing)
        window.contentView = host

        let label = NSTextField(labelWithString: "\(seconds)")
        label.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        label.textColor = KritColors.accent   // coral digit guarantees the accent cue on both code paths
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        // Esc monitor: keyCode 53. The continuation lets the loop bail mid-tick.
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?
        let cancelOnEsc: () -> Void = {
            guard !cancelled else { return }
            cancelled = true
            // Nil before resuming (mirrors the timer) so the two wake paths can
            // never both resume the same continuation.
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelOnEsc(); return nil }
            return event
        }
        // Global monitor catches Esc even if focus moves to another app during the
        // 1-10s countdown (notification, focus steal, second display click).
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelOnEsc() }
        }
        defer {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        }

        // Key so the local Esc monitor reliably fires on a borderless window;
        // briefly taking key is acceptable for a 1-3s modal countdown.
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        window.alphaValue = 1
        if !reduceMotion, let layer = host.layer {
            // Entrance mirrors the chooser windows: 0.96 scale spring + fade.
            // Animated on the content layer (not NSAnimationContext) to avoid the
            // sync/async overload ambiguity inside this async function.
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "entranceFade")
        }

        var remaining = seconds
        while remaining > 0 {
            label.stringValue = "\(remaining)"
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            if !reduceMotion {
                popDigit(label)
            }

            // Sleep one second, but wake early if Esc fires. Both wake paths (timer
            // and the Esc handler via `continuation?.resume()` in cancelOnEsc) gate
            // on the shared var: whoever wins nils it first, so the continuation is
            // resumed exactly once and never leaks. All on the main actor, no race.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                continuation = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard continuation != nil else { return }   // already resumed by Esc
                    continuation = nil
                    cont.resume()
                }
            }

            if cancelled {
                window.orderOut(nil)
                return false
            }
            remaining -= 1
        }

        window.orderOut(nil)
        // orderOut only flags the window ordered-out; it does NOT guarantee the
        // compositor has dropped it before SCScreenshotManager samples the
        // framebuffer. Flush the transaction and yield a frame so the coral badge
        // never lands in the captured PNG (D1).
        CATransaction.flush()
        try? await Task.sleep(nanoseconds: 60_000_000)
        return true
    }

    /// Per-tick pop: scale 1.18 -> 1.0 spring, matching the chooser entrance spring.
    private static func popDigit(_ view: NSView) {
        guard let layer = view.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.18
        pop.toValue = 1.0
        pop.mass = 1
        pop.stiffness = 320
        pop.damping = 24
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "tickPop")
    }

    private static func pixelAligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}

/// Borderless panel that may become key (so the Esc monitor is reliable) but
/// never main, so it doesn't disturb the app's main-window state.
private final class CountdownPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
