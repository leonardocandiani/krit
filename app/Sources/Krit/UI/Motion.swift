import AppKit

/// Central motion token for KRIT, the animation sibling of `ChromeFactory`
/// (chrome) and `KritType` (type). One place defines the app's feel so springs
/// and durations stop being re-rolled with different numbers across the codebase.
///
/// Every accessor honors Reduce Motion: when the user asked for less motion the
/// duration collapses to 0 (an instant change), so callers do not each have to
/// remember the check.
enum Motion {

    /// True when the user enabled Reduce Motion in System Settings.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    enum Duration {
        static let quick: TimeInterval = 0.16
        static let standard: TimeInterval = 0.28
        static let slow: TimeInterval = 0.42
    }

    /// Snappy spring (fast settle, slight overshoot) for cards, HUD and hovers.
    static func snappy() -> CASpringAnimation { spring(stiffness: 320, damping: 26) }
    /// Gentle spring (soft settle, no overshoot) for panels and sheets.
    static func gentle() -> CASpringAnimation { spring(stiffness: 180, damping: 24) }
    /// Bouncier spring for playful confirmations.
    static func bounce() -> CASpringAnimation { spring(stiffness: 260, damping: 16) }

    private static func spring(stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
        let s = CASpringAnimation()
        s.mass = 1
        s.stiffness = stiffness
        s.damping = damping
        s.duration = reduced ? 0 : s.settlingDuration
        return s
    }

    /// Run a block inside an NSAnimationContext with the standard ease and Reduce
    /// Motion handling. Duration collapses to 0 when reduced, so the change still
    /// happens, just instantly.
    @MainActor
    static func animate(_ duration: TimeInterval = Duration.standard,
                        timing: CAMediaTimingFunctionName = .easeOut,
                        _ body: (NSAnimationContext) -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduced ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            body(ctx)
        }
    }
}

extension NSWindow {
    /// Spring-scale + fade entrance shared by the recording surfaces (preflight,
    /// controls, HUD), which each carried a byte-identical copy of this. Honors
    /// Reduce Motion: when the user asked for less motion the window just appears,
    /// no scale or fade, instead of springing in regardless (the old behavior
    /// ignored the setting entirely).
    ///
    /// - Parameter takesKey: whether to make the window key and take first
    ///   responder. True for chooser-style surfaces the user drives; pass false
    ///   for a passive HUD that must never steal focus mid-recording.
    @MainActor
    func animateSpringEntrance(takesKey: Bool = true) {
        alphaValue = 0
        orderFrontRegardless()
        if takesKey {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(contentView)
        }
        guard !Motion.reduced else { alphaValue = 1; return }
        if let layer = contentView?.layer {
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            let scale = CASpringAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.mass = 1
            scale.stiffness = 320
            scale.damping = 24
            scale.duration = scale.settlingDuration
            layer.add(scale, forKey: "entranceScale")
            layer.transform = CATransform3DIdentity
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
}
