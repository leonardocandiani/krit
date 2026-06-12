import AppKit
import ApplicationServices
import CoreGraphics

/// Walks the macOS Accessibility (AX) tree and produces a JSON-serializable view of
/// the on-screen UI: roles, labels, frames and hierarchy. This is the semantic
/// counterpart to a pixel capture, an agent can read what the UI *is* instead of
/// guessing from pixels.
///
/// Coordinates everywhere are global screen points, top-left origin (the same space
/// the automation port already speaks for capture rects), so an `inspect` result and
/// a `capture_region` of the same rect line up.
///
/// Sanity limits keep a pathological tree (Electron apps, huge tables) from blowing
/// up the response or the wall clock: max depth, max node count, and an internal
/// deadline that returns whatever was collected so far.
enum AXInspector {

    // MARK: - Tuning

    struct Limits: Sendable {
        var maxDepth = 12
        var maxNodes = 1500
        var deadline: TimeInterval = 2.0
        /// AX string values (title/label/value) longer than this are truncated.
        var maxValueChars = 200
        /// Per-call AX messaging timeout (seconds). A single AXUIElementCopy* to an
        /// unresponsive target would otherwise block the caller with no ceiling, so
        /// cap every individual round trip well under the walk deadline.
        var messagingTimeout: Float = 0.5
    }

    // MARK: - Result

    struct Node: Sendable {
        var role: String
        var subrole: String?
        var label: String?     // title, or description, whichever the element exposes
        var value: String?
        var frame: CGRect?     // global, top-left origin, screen points
        var enabled: Bool?
        var children: [Node]

        /// Token-frugal dictionary: omits nil/empty fields, omits `enabled` when true
        /// (the common case), and omits an empty children array.
        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["role": role]
            if let subrole, !subrole.isEmpty { dict["subrole"] = subrole }
            if let label, !label.isEmpty { dict["label"] = label }
            if let value, !value.isEmpty { dict["value"] = value }
            if let frame {
                dict["frame"] = [
                    "x": Int(frame.origin.x.rounded()),
                    "y": Int(frame.origin.y.rounded()),
                    "w": Int(frame.size.width.rounded()),
                    "h": Int(frame.size.height.rounded()),
                ]
            }
            // Only carry `enabled` when it is meaningfully false, agents assume true.
            if enabled == false { dict["enabled"] = false }
            if !children.isEmpty {
                dict["children"] = children.map { $0.toDictionary() }
            }
            return dict
        }
    }

    struct Tree: Sendable {
        var root: Node
        var appName: String?
        var bundleId: String?
        var nodeCount: Int
        var truncated: Bool    // hit a sanity limit before finishing the walk

        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "tree": root.toDictionary(),
                "nodeCount": nodeCount,
            ]
            if let appName, !appName.isEmpty { dict["appName"] = appName }
            if let bundleId, !bundleId.isEmpty { dict["bundleId"] = bundleId }
            if truncated { dict["truncated"] = true }
            return dict
        }
    }

    // MARK: - Errors

    enum InspectError: Error, Sendable {
        case notTrusted
        case noTarget(String)

        var code: String {
            switch self {
            case .notTrusted: return "accessibility_denied"
            case .noTarget:   return "no_target"
            }
        }

        var message: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission denied. Grant it in System Settings > Privacy & Security > Accessibility, then retry."
            case .noTarget(let s):
                return s
            }
        }
    }

    // MARK: - Entry points

    /// Inspects the frontmost application's whole UI tree.
    static func inspectFrontmost(limits: Limits = Limits()) throws -> Tree {
        try ensureTrusted()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw InspectError.noTarget("no frontmost application")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, limits.messagingTimeout)
        let walker = Walker(limits: limits, clip: nil)
        let root = walker.walk(appElement, depth: 0)
        return Tree(
            root: root ?? Node(role: "AXApplication", subrole: nil, label: app.localizedName, value: nil, frame: nil, enabled: nil, children: []),
            appName: app.localizedName,
            bundleId: app.bundleIdentifier,
            nodeCount: walker.nodeCount,
            truncated: walker.truncated
        )
    }

    /// Inspects everything intersecting `rect` (global, top-left, points). Walks the
    /// owning app's tree and clips to the rect.
    static func inspectRect(_ rect: CGRect, limits: Limits = Limits()) throws -> Tree {
        try ensureTrusted()
        // Resolve the owning app via the element at the rect's center, so app
        // metadata is meaningful and the walk starts from that app's tree (much
        // smaller and faster than the full system-wide root).
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let owner = ownerApp(atScreenPoint: center)

        let rootElement: AXUIElement
        if let pid = owner?.processIdentifier {
            rootElement = AXUIElementCreateApplication(pid)
        } else {
            rootElement = AXUIElementCreateSystemWide()
        }
        AXUIElementSetMessagingTimeout(rootElement, limits.messagingTimeout)

        let walker = Walker(limits: limits, clip: rect)
        let root = walker.walk(rootElement, depth: 0)
        return Tree(
            root: root ?? Node(role: "AXApplication", subrole: nil, label: owner?.localizedName, value: nil, frame: rect, enabled: nil, children: []),
            appName: owner?.localizedName,
            bundleId: owner?.bundleIdentifier,
            nodeCount: walker.nodeCount,
            truncated: walker.truncated
        )
    }

    /// Inspects a single window by CGWindowID. Resolves the owning pid from the
    /// window list, then matches the AX window whose frame equals the CG frame.
    static func inspectWindow(_ windowId: CGWindowID, limits: Limits = Limits()) throws -> Tree {
        try ensureTrusted()
        guard let info = windowInfo(for: windowId) else {
            throw InspectError.noTarget("window \(windowId) not found in the window list")
        }
        let appElement = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(appElement, limits.messagingTimeout)
        let walker = Walker(limits: limits, clip: nil)

        // Try to descend straight into the matching AX window so the tree is just
        // that window, not the whole app.
        let target = axWindow(in: appElement, matching: info.bounds) ?? appElement
        let root = walker.walk(target, depth: 0)

        let runningApp = NSRunningApplication(processIdentifier: info.pid)
        return Tree(
            root: root ?? Node(role: "AXWindow", subrole: nil, label: info.title, value: nil, frame: info.bounds, enabled: nil, children: []),
            appName: runningApp?.localizedName ?? info.ownerName,
            bundleId: runningApp?.bundleIdentifier,
            nodeCount: walker.nodeCount,
            truncated: walker.truncated
        )
    }

    // MARK: - Permission

    private static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else { throw InspectError.notTrusted }
    }

    // MARK: - Tree walker

    /// Recursive descent over the AX tree under one root, honoring the sanity
    /// limits. Stateful (node count, deadline, truncation flag) so the recursion
    /// can stop the whole walk the moment a budget is exhausted.
    final class Walker {
        let limits: Limits
        let clip: CGRect?
        let deadline: Date
        private(set) var nodeCount = 0
        private(set) var truncated = false

        init(limits: Limits, clip: CGRect?) {
            self.limits = limits
            self.clip = clip
            self.deadline = Date().addingTimeInterval(limits.deadline)
        }

        func walk(_ element: AXUIElement, depth: Int) -> Node? {
            if nodeCount >= limits.maxNodes || Date() >= deadline {
                truncated = true
                return nil
            }

            let frame = Self.frame(of: element)
            // Drop nodes that fall entirely outside the requested rect. The root of a
            // clipped walk has no frame of its own to test, so let it through and let
            // its children be filtered.
            if let clip, let frame, !clip.intersects(frame) {
                return nil
            }

            let role = Self.stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
            nodeCount += 1

            var node = Node(
                role: role,
                subrole: Self.stringAttribute(element, kAXSubroleAttribute),
                label: Self.label(of: element, limit: limits.maxValueChars),
                value: Self.value(of: element, limit: limits.maxValueChars),
                frame: frame,
                enabled: Self.boolAttribute(element, kAXEnabledAttribute),
                children: []
            )

            if depth >= limits.maxDepth {
                // Past the depth cap, keep the node but stop descending. Flag the tree
                // as truncated only if this node actually had children to drop.
                if !Self.children(of: element).isEmpty { truncated = true }
                return node
            }

            for child in Self.children(of: element) {
                if nodeCount >= limits.maxNodes || Date() >= deadline {
                    truncated = true
                    break
                }
                if let childNode = walk(child, depth: depth + 1) {
                    node.children.append(childNode)
                }
            }
            return node
        }

        // MARK: AX attribute readers

        static func children(of element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let array = value as? [AXUIElement] else {
                return []
            }
            return array
        }

        static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }

        static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let number = value as? NSNumber else {
                return nil
            }
            return number.boolValue
        }

        /// Label resolution order: title, then description, then placeholder. Whatever
        /// names the element for a human is what an agent wants too.
        static func label(of element: AXUIElement, limit: Int) -> String? {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
                if let s = stringAttribute(element, attribute), !s.isEmpty {
                    return truncate(s, limit: limit)
                }
            }
            return nil
        }

        /// AX value, stringified. Only string-like and numeric values are reported,
        /// element values would be noise for an agent reading UI text.
        static func value(of element: AXUIElement, limit: Int) -> String? {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else {
                return nil
            }
            if let s = raw as? String, !s.isEmpty {
                return truncate(s, limit: limit)
            }
            if let n = raw as? NSNumber {
                return n.stringValue
            }
            return nil
        }

        /// Reads kAXPositionAttribute + kAXSizeAttribute (already global, top-left)
        /// and assembles the frame. Returns nil if either is missing.
        static func frame(of element: AXUIElement) -> CGRect? {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                return nil
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard let posValue = posRef, CFGetTypeID(posValue) == AXValueGetTypeID(),
                  AXValueGetValue(posValue as! AXValue, .cgPoint, &point) else {
                return nil
            }
            guard let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
                return nil
            }
            return CGRect(origin: point, size: size)
        }

        private static func truncate(_ s: String, limit: Int) -> String {
            guard s.count > limit else { return s }
            let head = s.prefix(limit)
            return "\(head)… (+\(s.count - limit) chars)"
        }
    }

    // MARK: - Window / app resolution

    private struct WindowInfo {
        let pid: pid_t
        let bounds: CGRect   // global, top-left, points
        let title: String?
        let ownerName: String?
    }

    /// Pulls the on-screen window record for `windowId` from the window server.
    private static func windowInfo(for windowId: CGWindowID) -> WindowInfo? {
        let options: CGWindowListOption = [.optionIncludingWindow, .optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, windowId) as? [[String: Any]],
              let entry = list.first else {
            return nil
        }
        guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return WindowInfo(
            pid: pid_t(pidNumber.int32Value),
            bounds: bounds,
            title: entry[kCGWindowName as String] as? String,
            ownerName: entry[kCGWindowOwnerName as String] as? String
        )
    }

    /// Finds the AX window child of `appElement` whose frame matches `bounds` (within
    /// a couple points, the CG and AX frames can differ by sub-pixel rounding).
    private static func axWindow(in appElement: AXUIElement, matching bounds: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows.first { window in
            guard let frame = Walker.frame(of: window) else { return false }
            return abs(frame.origin.x - bounds.origin.x) <= 2 &&
                   abs(frame.origin.y - bounds.origin.y) <= 2 &&
                   abs(frame.size.width - bounds.size.width) <= 2 &&
                   abs(frame.size.height - bounds.size.height) <= 2
        }
    }

    /// Resolves which app owns the topmost window at a global top-left point, via the
    /// system-wide AX element hit test.
    private static func ownerApp(atScreenPoint point: CGPoint) -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return NSWorkspace.shared.frontmostApplication
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return NSWorkspace.shared.frontmostApplication
        }
        return NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.frontmostApplication
    }
}
