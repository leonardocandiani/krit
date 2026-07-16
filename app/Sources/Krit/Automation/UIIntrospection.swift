import AppKit
import CoreGraphics

/// Introspects and drives KRIT's OWN UI without any macOS Accessibility permission.
///
/// Unlike `AXInspector` (which walks another app's AX tree via out-of-process
/// `AXUIElement` round-trips and requires the user to grant Accessibility), this
/// type is compiled straight into KRIT: it reads the real `NSWindow`/`NSView`
/// object graph directly, in-process, permission-free by construction. It exists
/// so an agent can introspect and drive KRIT's own live-annotation toolbar the
/// same way a human clicking it would, which is exactly the surface `AXInspector`
/// cannot see reliably without a trusted AX session.
@MainActor
enum UIIntrospection {

    // MARK: - ui_snapshot

    /// One multi-line text report: app/activation state, every AppKit window KRIT
    /// owns, the window server's own front-to-back truth for this pid (the two can
    /// disagree, see `LiveAnnotationController.logState`), live-annotation state,
    /// and the view tree of every currently visible window.
    static func snapshot(liveAnnotation: LiveAnnotationController?) -> String {
        var lines: [String] = [header(), ""]
        lines += appKitWindowLines()
        lines.append("")
        lines += windowServerLines()
        lines.append("")
        lines.append(liveAnnotationLine(liveAnnotation))
        lines.append("")
        lines += viewTreeLines()
        return lines.joined(separator: "\n")
    }

    private static func header() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        return "app active=\(NSApp.isActive) policy=\(policyName(NSApp.activationPolicy())) pid=\(pid)"
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:    return "regular"
        case .accessory:  return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }

    private static func sharingName(_ sharing: NSWindow.SharingType) -> String {
        switch sharing {
        case .none:      return "none"
        case .readOnly:  return "readOnly"
        case .readWrite: return "readWrite"
        @unknown default: return "unknown(\(sharing.rawValue))"
        }
    }

    private static func appKitWindowLines() -> [String] {
        var lines = ["AppKit windows (\(NSApp.windows.count)):"]
        for window in NSApp.windows {
            let f = window.frame
            lines.append(
                "  #\(window.windowNumber) \(String(describing: type(of: window))) " +
                "title=\"\(window.title)\" level=\(window.level.rawValue) " +
                "visible=\(window.isVisible) key=\(window.isKeyWindow) " +
                "ignoresMouse=\(window.ignoresMouseEvents) sharing=\(sharingName(window.sharingType)) " +
                "frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))) " +
                "firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            )
        }
        return lines
    }

    /// The window server's own front-to-back order for this pid, straight from
    /// `CGWindowListCopyWindowInfo` (see `LiveAnnotationController.logState`'s same
    /// pattern). AppKit's `window.level`/order can disagree with it, so a snapshot
    /// always carries both sides rather than trusting AppKit alone.
    private static func windowServerLines() -> [String] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        var lines = ["Window server, front-to-back (\(mine.count)):"]
        for entry in mine {
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            let layer = entry[kCGWindowLayer as String] as? Int ?? -999
            let name = (entry[kCGWindowName as String] as? String) ?? ""
            let suffix = name.isEmpty ? "" : " name=\"\(name)\""
            lines.append("  #\(number) layer=\(layer)\(suffix)")
        }
        return lines
    }

    private static func liveAnnotationLine(_ controller: LiveAnnotationController?) -> String {
        guard let controller else { return "Live annotation: unavailable" }
        return "Live annotation: mode=\(modeName(controller.mode)) objects=\(controller.annotationObjectCount)"
    }

    static func modeName(_ mode: LiveAnnotationController.Mode) -> String {
        switch mode {
        case .off:     return "off"
        case .drawing: return "drawing"
        case .passive: return "passive"
        }
    }

    private static func viewTreeLines() -> [String] {
        var lines: [String] = []
        for window in NSApp.windows where window.isVisible {
            lines.append("View tree #\(window.windowNumber) (\(String(describing: type(of: window)))):")
            if let contentView = window.contentView {
                lines += viewLines(contentView, depth: 1)
            }
        }
        return lines
    }

    /// AppKit view graphs are trees (no cycles), so only a depth cap is needed as a
    /// safety net against a pathological hierarchy — no node-count budget like
    /// `AXInspector` needs for arbitrary third-party AX trees.
    private static let maxViewDepth = 60

    private static func viewLines(_ view: NSView, depth: Int) -> [String] {
        guard depth < maxViewDepth else { return ["\(indent(depth))… (max depth reached)"] }

        let frame = view.convert(view.bounds, to: nil)
        var parts = [String(describing: type(of: view))]
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { parts.append("id=\"\(id)\"") }
        if let label = view.accessibilityLabel(), !label.isEmpty { parts.append("label=\"\(label)\"") }
        parts.append("frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))")
        parts.append("hidden=\(view.isHidden)")

        var lines = ["\(indent(depth))\(parts.joined(separator: " "))"]
        for sub in view.subviews {
            lines += viewLines(sub, depth: depth + 1)
        }
        return lines
    }

    private static func indent(_ depth: Int) -> String { String(repeating: "  ", count: depth) }

    // MARK: - ui_click

    /// Finds the view with `accessibilityIdentifier == id` across every app window
    /// and fires it via `accessibilityPerformPress()` (real AX, not a synthetic
    /// click — the same entry point VoiceOver would use). Throws a structured error
    /// listing every identifier seen so far when nothing matches or the view found
    /// declines the press.
    static func click(id: String) throws -> (className: String, id: String) {
        var seenIds: [String] = []
        guard let found = findView(withId: id, seenIds: &seenIds) else {
            let available = seenIds.isEmpty ? "(none)" : seenIds.sorted().joined(separator: ", ")
            throw AutomationError.uiTargetNotFound("no view with accessibilityIdentifier '\(id)'. Available ids: \(available)")
        }
        let className = String(describing: type(of: found))
        if let button = found as? NSButton {
            guard button.isEnabled else {
                throw AutomationError.uiTargetNotFound("view '\(id)' (\(className)) is disabled")
            }
            guard button.action != nil else {
                throw AutomationError.uiTargetNotFound("view '\(id)' (\(className)) does not have an action")
            }
            button.performClick(nil)
            return (className, id)
        }
        guard found.accessibilityPerformPress() else {
            throw AutomationError.uiTargetNotFound("view '\(id)' (\(className)) does not implement accessibilityPerformPress()")
        }
        return (className, id)
    }

    private static func findView(withId id: String, seenIds: inout [String]) -> NSView? {
        // Only visible windows: a passive live-annotation toolbar is orderOut'd but
        // its window object stays alive, and pressing its hidden trash/close/camera
        // controls fires real side effects the user can't see. `isVisible` is false
        // for an ordered-out window, so it drops out of both the search and the
        // available-ids list, matching what a user could actually click. Start at
        // the WindowServer-facing front of NSApp.orderedWindows: overlay cards reuse
        // their action identifiers, and an automation press must choose the topmost
        // visible card rather than arbitrary NSApp.windows insertion order.
        var seenWindows = Set<ObjectIdentifier>()
        let windows = (NSApp.orderedWindows + NSApp.windows).filter {
            $0.isVisible && seenWindows.insert(ObjectIdentifier($0)).inserted
        }
        for window in windows {
            guard let content = window.contentView else { continue }
            if let match = searchView(content, targetId: id, seenIds: &seenIds) { return match }
        }
        return nil
    }

    private static func searchView(_ view: NSView, targetId: String, seenIds: inout [String]) -> NSView? {
        let identifier = view.accessibilityIdentifier()
        if !identifier.isEmpty {
            seenIds.append(identifier)
            if identifier == targetId { return view }
        }
        for sub in view.subviews {
            if let match = searchView(sub, targetId: targetId, seenIds: &seenIds) { return match }
        }
        return nil
    }

    // MARK: - ui_audit

    /// Best-effort accessibility audit over every visible window, inspired by the
    /// Native SDK's `a11y_audit`: (a) interactive controls missing a label, (b)
    /// duplicate labels between direct siblings, (c) a key window with nothing
    /// keyboard-focusable in it. One violation per line; "0 violations" when clean.
    static func audit() -> String {
        var violations: [String] = []
        for window in NSApp.windows where window.isVisible {
            guard let content = window.contentView else { continue }
            let rootPath = [String(describing: type(of: window))]
            auditTree(content, path: rootPath, violations: &violations)
            if window.isKeyWindow, !hasFocusableView(content) {
                violations.append("\(rootPath.joined(separator: " > ")): key window has no keyboard-focusable view")
            }
        }
        return violations.isEmpty ? "0 violations" : violations.joined(separator: "\n")
    }

    private static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .comboBox, .slider, .menuButton, .link,
    ]

    private static func isInteractive(_ view: NSView) -> Bool {
        // A static NSTextField (`labelWithString:`, the common case for a caption)
        // is an NSControl but accepts neither editing nor selection, it is not
        // actually interactive; only count it when it behaves like a real field.
        if let field = view as? NSTextField {
            return field.isEditable || field.isSelectable
        }
        if view is NSControl { return true }
        if let role = view.accessibilityRole(), interactiveRoles.contains(role) { return true }
        return false
    }

    private static func auditTree(_ view: NSView, path: [String], violations: inout [String]) {
        if isInteractive(view), !view.isHidden, (view.accessibilityLabel() ?? "").isEmpty {
            violations.append("\(path.joined(separator: " > ")): interactive \(String(describing: type(of: view))) has no accessibilityLabel")
        }

        var labelCounts: [String: Int] = [:]
        for sub in view.subviews {
            if let label = sub.accessibilityLabel(), !label.isEmpty {
                labelCounts[label, default: 0] += 1
            }
        }
        for (label, count) in labelCounts where count > 1 {
            violations.append("\(path.joined(separator: " > ")): \(count) sibling views share accessibilityLabel \"\(label)\"")
        }

        for sub in view.subviews {
            auditTree(sub, path: path + [String(describing: type(of: sub))], violations: &violations)
        }
    }

    private static func hasFocusableView(_ view: NSView) -> Bool {
        if view.acceptsFirstResponder { return true }
        return view.subviews.contains { hasFocusableView($0) }
    }
}
