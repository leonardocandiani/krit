import AppKit
import CoreGraphics

/// Wire protocol for the automation port. All requests are JSON objects with a
/// `cmd` discriminator; all responses are JSON objects with an `ok` boolean.
///
/// Because captures are interactive and slow, the transport uses a request-id +
/// poll pattern (the CFMessagePort callback must return synchronously and can
/// never block the main thread on a capture):
///
///   submit {cmd, ...}      -> {ok:true, requestId} | {ok:false, error, code}
///   poll {requestId}       -> {ok:true, done:false}
///                          -> {ok:true, done:true, result:{...}}
///                          -> {ok:false, error, code}            (unknown id)
///
/// `annotate` is fast and could run inline, but it follows the same submit/poll
/// path for one uniform client loop.

// MARK: - Commands

enum AutomationCommand {
    case captureRegion(x: Double, y: Double, w: Double, h: Double, display: Int?)
    case captureFullscreen(display: Int?)
    case annotate(input: String, output: String, spec: [AnnotationSpec])
    case inspect(InspectTarget, options: InspectOptions)

    /// Where, if specified, the result PNG should be written.
    var outputPath: String? {
        switch self {
        case .captureRegion, .captureFullscreen, .inspect: return nil
        case .annotate(_, let output, _):                  return output
        }
    }
}

// MARK: - Inspect (AX X-Ray)

/// What to read the semantic UI tree from. The parser picks exactly one, with
/// `frontmost` as the fallback when no rect or window is given.
enum InspectTarget: Sendable {
    case frontmost
    case rect(x: Double, y: Double, w: Double, h: Double)
    case window(id: UInt32)
}

struct InspectOptions: Sendable {
    var maxDepth: Int?
    /// When true, also capture the region as a PNG so an agent gets pixels + semantics
    /// in one call. Only meaningful for the rect target (the only one with a region).
    var includeScreenshot: Bool
}

// MARK: - Annotation spec

/// A single annotation in PIXEL coordinates of the input image (top-left origin).
struct AnnotationSpec {
    enum Kind {
        case arrow(from: CGPoint, to: CGPoint, curve: CGPoint?)
        case box(rect: CGRect, fill: Bool)
        case ellipse(rect: CGRect)
        case line(from: CGPoint, to: CGPoint)
        case text(at: CGPoint, text: String, size: CGFloat?)
        case step(at: CGPoint, number: Int)
        case highlight(from: CGPoint, to: CGPoint)
        case blur(rect: CGRect, radius: Double)
        case pixelate(rect: CGRect, scale: Double)
    }

    let kind: Kind
    let color: NSColor?
    let width: CGFloat?
}

// MARK: - Errors

enum AutomationError: Error {
    case malformedRequest(String)
    case unknownCommand(String)
    case screenRecordingDenied
    case captureFailed(String)
    case noDisplay
    case render(String)
    case accessibilityDenied(String)
    case inspectFailed(String)

    var code: String {
        switch self {
        case .malformedRequest:     return "malformed_request"
        case .unknownCommand:       return "unknown_command"
        case .screenRecordingDenied: return "screen_recording_denied"
        case .captureFailed:        return "capture_failed"
        case .noDisplay:            return "no_display"
        case .render:               return "render_error"
        case .accessibilityDenied:  return "accessibility_denied"
        case .inspectFailed:        return "inspect_failed"
        }
    }

    var message: String {
        switch self {
        case .malformedRequest(let s): return "malformed request: \(s)"
        case .unknownCommand(let s):   return "unknown command: \(s)"
        case .screenRecordingDenied:   return "screen recording permission denied"
        case .captureFailed(let s):    return "capture failed: \(s)"
        case .noDisplay:               return "no matching display found"
        case .render(let s):           return "render failed: \(s)"
        case .accessibilityDenied(let s): return s
        case .inspectFailed(let s):    return "inspect failed: \(s)"
        }
    }
}

// MARK: - JSON decoding

/// Hand-rolled JSON parsing so the wire format stays explicit and tolerant of
/// the optional fields automation clients send. No Codable ceremony for a handful
/// of shapes.
enum AutomationJSON {

    static func parseCommand(_ object: [String: Any]) throws -> AutomationCommand {
        guard let cmd = object["cmd"] as? String else {
            throw AutomationError.malformedRequest("missing 'cmd'")
        }
        switch cmd {
        case "capture_region":
            let x = try doubleField(object, "x")
            let y = try doubleField(object, "y")
            let w = try doubleField(object, "w")
            let h = try doubleField(object, "h")
            return .captureRegion(x: x, y: y, w: w, h: h, display: intField(object, "display"))

        case "capture_fullscreen":
            return .captureFullscreen(display: intField(object, "display"))

        case "annotate":
            guard let input = object["input"] as? String else {
                throw AutomationError.malformedRequest("annotate: missing 'input'")
            }
            guard let output = object["output"] as? String else {
                throw AutomationError.malformedRequest("annotate: missing 'output'")
            }
            let rawSpec = object["spec"] as? [[String: Any]] ?? []
            let spec = try rawSpec.map { try parseSpec($0) }
            return .annotate(input: input, output: output, spec: spec)

        case "inspect":
            let target = try parseInspectTarget(object)
            let options = InspectOptions(
                maxDepth: intField(object, "maxDepth"),
                includeScreenshot: (object["includeScreenshot"] as? Bool) ?? false
            )
            return .inspect(target, options: options)

        default:
            throw AutomationError.unknownCommand(cmd)
        }
    }

    /// Target precedence: explicit rect, then windowId, then frontmost. A rect needs
    /// all four numbers; a window needs a non-negative id.
    private static func parseInspectTarget(_ object: [String: Any]) throws -> InspectTarget {
        if let rectArr = object["rect"] as? [Any] {
            guard rectArr.count == 4,
                  let x = (rectArr[0] as? NSNumber)?.doubleValue,
                  let y = (rectArr[1] as? NSNumber)?.doubleValue,
                  let w = (rectArr[2] as? NSNumber)?.doubleValue,
                  let h = (rectArr[3] as? NSNumber)?.doubleValue else {
                throw AutomationError.malformedRequest("inspect: 'rect' must be [x,y,w,h]")
            }
            guard w > 0, h > 0 else {
                throw AutomationError.malformedRequest("inspect: rect width and height must be positive")
            }
            return .rect(x: x, y: y, w: w, h: h)
        }
        if let windowId = (object["windowId"] as? NSNumber)?.uint32Value {
            return .window(id: windowId)
        }
        // `frontmost: false` with no rect/window is still treated as frontmost, there
        // is nothing else to inspect.
        return .frontmost
    }

    static func parseSpec(_ object: [String: Any]) throws -> AnnotationSpec {
        guard let type = object["type"] as? String else {
            throw AutomationError.malformedRequest("spec item missing 'type'")
        }
        let color = (object["color"] as? String).flatMap { NSColor(hex: $0) }
        let width = (object["width"] as? NSNumber).map { CGFloat(truncating: $0) }

        func point(_ key: String) throws -> CGPoint {
            guard let arr = object[key] as? [Any], arr.count == 2,
                  let px = (arr[0] as? NSNumber)?.doubleValue,
                  let py = (arr[1] as? NSNumber)?.doubleValue else {
                throw AutomationError.malformedRequest("\(type): '\(key)' must be [x,y]")
            }
            return CGPoint(x: px, y: py)
        }
        func rect(_ key: String) throws -> CGRect {
            guard let arr = object[key] as? [Any], arr.count == 4,
                  let rx = (arr[0] as? NSNumber)?.doubleValue,
                  let ry = (arr[1] as? NSNumber)?.doubleValue,
                  let rw = (arr[2] as? NSNumber)?.doubleValue,
                  let rh = (arr[3] as? NSNumber)?.doubleValue else {
                throw AutomationError.malformedRequest("\(type): '\(key)' must be [x,y,w,h]")
            }
            return CGRect(x: rx, y: ry, width: rw, height: rh)
        }

        let kind: AnnotationSpec.Kind
        switch type {
        case "arrow":
            let curve: CGPoint? = {
                guard let arr = object["curve"] as? [Any], arr.count == 2,
                      let cx = (arr[0] as? NSNumber)?.doubleValue,
                      let cy = (arr[1] as? NSNumber)?.doubleValue else { return nil }
                return CGPoint(x: cx, y: cy)
            }()
            kind = .arrow(from: try point("from"), to: try point("to"), curve: curve)
        case "box":
            kind = .box(rect: try rect("rect"), fill: (object["fill"] as? Bool) ?? false)
        case "ellipse":
            kind = .ellipse(rect: try rect("rect"))
        case "line":
            kind = .line(from: try point("from"), to: try point("to"))
        case "text":
            guard let text = object["text"] as? String else {
                throw AutomationError.malformedRequest("text: missing 'text'")
            }
            let size = (object["size"] as? NSNumber).map { CGFloat(truncating: $0) }
            kind = .text(at: try point("at"), text: text, size: size)
        case "step":
            guard let number = (object["number"] as? NSNumber)?.intValue else {
                throw AutomationError.malformedRequest("step: missing 'number'")
            }
            kind = .step(at: try point("at"), number: number)
        case "highlight":
            kind = .highlight(from: try point("from"), to: try point("to"))
        case "blur":
            let radius = (object["radius"] as? NSNumber)?.doubleValue ?? 12
            kind = .blur(rect: try rect("rect"), radius: radius)
        case "pixelate":
            let scale = (object["scale"] as? NSNumber)?.doubleValue ?? 10
            kind = .pixelate(rect: try rect("rect"), scale: scale)
        default:
            throw AutomationError.malformedRequest("unknown spec type: \(type)")
        }
        return AnnotationSpec(kind: kind, color: color, width: width)
    }

    private static func doubleField(_ object: [String: Any], _ key: String) throws -> Double {
        guard let v = (object[key] as? NSNumber)?.doubleValue else {
            throw AutomationError.malformedRequest("missing or non-numeric '\(key)'")
        }
        return v
    }

    private static func intField(_ object: [String: Any], _ key: String) -> Int? {
        (object[key] as? NSNumber)?.intValue
    }
}

// MARK: - Hex color

extension NSColor {
    /// Parses "#RRGGBB" (case-insensitive, leading '#' optional). Returns nil on
    /// anything else so the caller can fall back to the default accent.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
