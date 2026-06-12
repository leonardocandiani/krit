import AppKit
import os

/// Parses and executes `krit://` URLs so other apps, scripts, Shortcuts, and the
/// Spotlight bar can drive KRIT the way Shottr's `shottr://` scheme does.
///
/// Shape: `krit://<verb>/<action>?<params>`. The host is the verb namespace
/// (`capture`, `record`, `ocr`, `history`) and the first path component is the
/// action. Examples:
///   - krit://capture/area
///   - krit://capture/rect?x=100&y=200&w=640&h=480&then=copy,save
///   - krit://record/start?x=0&y=0&w=1280&h=720
///   - krit://record/stop
///   - krit://ocr
///   - krit://history
///
/// Capture actions accept an optional `then=` chain applied after the shot, in
/// order: `copy` (clipboard), `save` (auto-save location), `edit` (annotation
/// editor), `pin` (pin window). `upload` has no public KRIT API and is reported
/// as unsupported rather than faked.
@MainActor
enum URLCommandRouter {

    static let scheme = "krit"

    private static let log = Logger(subsystem: "com.krit.app", category: "url-scheme")

    /// Post-capture chain steps. `copy/save/edit/pin` map onto the shared
    /// `CaptureActionChain`. `upload` is parsed so a malformed chain isn't silently
    /// dropped, but it has no backing API and is logged as unsupported.
    enum ThenAction: String {
        case copy
        case save
        case edit
        case pin
        case upload

        /// The shared chain action, or nil for the unsupported `upload`.
        var captureAction: CaptureAction? {
            switch self {
            case .copy: return .copy
            case .save: return .save
            case .edit: return .edit
            case .pin: return .pin
            case .upload: return nil
            }
        }
    }

    /// Routes one URL. Returns true when it was a recognized `krit://` URL (even
    /// if the specific action was a no-op), false when the scheme doesn't match so
    /// the caller can fall back to its file-open path.
    @discardableResult
    static func handle(_ url: URL, appDelegate: AppDelegate) -> Bool {
        guard url.scheme?.lowercased() == scheme else { return false }

        let verb = (url.host ?? "").lowercased()
        // First non-empty path component is the action; the rest is reserved.
        let action = url.pathComponents.first(where: { $0 != "/" })?.lowercased() ?? ""
        let params = queryItems(from: url)

        log.info("krit url verb=\(verb, privacy: .public) action=\(action, privacy: .public)")

        switch verb {
        case "capture":
            handleCapture(action: action, params: params, appDelegate: appDelegate)
        case "record":
            handleRecord(action: action, params: params, appDelegate: appDelegate)
        case "ocr":
            appDelegate.captureText()
        case "history":
            appDelegate.openHistory()
        default:
            log.error("krit url: unknown verb \(verb, privacy: .public); ignoring")
        }
        return true
    }

    // MARK: - Capture

    private static func handleCapture(action: String, params: [String: String], appDelegate: AppDelegate) {
        let then = parseThen(params["then"])

        switch action {
        case "area":
            appDelegate.captureInteractive(.area, then: then)
        case "window":
            appDelegate.captureInteractive(.window, then: then)
        case "fullscreen":
            appDelegate.captureInteractive(.fullscreen, then: then)
        case "scrolling":
            // Scrolling capture stitches in its own controller and never reaches
            // the engine's finishCapture, so the one-shot completion can't fire;
            // a `then=` here would silently never run. Trigger the flow and log.
            if !then.isEmpty {
                log.error("krit capture/scrolling: then= is not supported for scrolling capture; ignoring chain")
            }
            appDelegate.captureScrolling()
        case "rect":
            guard let rect = rect(from: params) else {
                log.error("krit capture/rect: malformed or missing x/y/w/h; ignoring")
                return
            }
            // Headless rect grab is the path we fully own end to end, so the
            // `then` chain runs here against the produced image.
            appDelegate.captureRectHeadless(topLeft: rect) { image in
                guard let image else {
                    log.error("krit capture/rect: capture returned no image")
                    return
                }
                applyThen(then, to: image)
            }
        default:
            log.error("krit capture: unknown action \(action, privacy: .public); ignoring")
        }
    }

    // MARK: - Record

    private static func handleRecord(action: String, params: [String: String], appDelegate: AppDelegate) {
        switch action {
        case "start":
            guard let rect = rect(from: params) else {
                log.error("krit record/start: malformed or missing x/y/w/h; ignoring")
                return
            }
            appDelegate.startRectRecordingHeadless(topLeft: rect)
        case "stop":
            appDelegate.stopRecordingFromURL()
        default:
            log.error("krit record: unknown action \(action, privacy: .public); ignoring")
        }
    }

    // MARK: - then chain

    private static func parseThen(_ raw: String?) -> [ThenAction] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { token in
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard let parsed = ThenAction(rawValue: name) else {
                log.error("krit then: unknown step '\(name, privacy: .public)'; skipping")
                return nil
            }
            return parsed
        }
    }

    /// Runs the parsed chain via the shared `CaptureActionChain`. `upload` has no
    /// backing API, so it's logged as unsupported and dropped rather than faked.
    static func applyThen(_ actions: [ThenAction], to image: NSImage) {
        if actions.contains(.upload) {
            log.error("krit then: 'upload' is not supported (no upload backend)")
        }
        let chain = actions.compactMap { $0.captureAction }
        CaptureActionChain.apply(chain, to: image)
    }

    // MARK: - Parsing helpers

    private static func queryItems(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            if let value = item.value { result[item.name.lowercased()] = value }
        }
        return result
    }

    /// Reads x/y/w/h as a TOP-LEFT global rect in points (the same convention the
    /// CFMessagePort automation uses). Returns nil if any are missing, non-numeric,
    /// or the size is non-positive, so the caller can ignore a malformed URL.
    private static func rect(from params: [String: String]) -> CGRect? {
        guard let xs = params["x"], let ys = params["y"],
              let ws = params["w"], let hs = params["h"],
              let x = Double(xs), let y = Double(ys),
              let w = Double(ws), let h = Double(hs),
              w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
