import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - MCP stdio server
//
// Hand-rolled MCP server speaking JSON-RPC 2.0 over stdio, one JSON message per
// line (newline-delimited). No external SDK so Package.resolved stays clean and
// Swift 6 strict-concurrency has nothing extra to reason about.
//
// Contract:
//   - stdin:  one JSON-RPC request/notification per line, read until EOF.
//   - stdout: exactly one JSON-RPC response per line. Nothing else ever.
//   - stderr: all human-facing logging / diagnostics.
//
// Tools wrap the existing CFMessagePort automation client (capture/annotate run
// in the app, which owns the Screen Recording grant) and add a closed-loop
// `capture_and_read` that captures + OCRs the result locally via Vision.

private let mcpProtocolVersion = "2024-11-05"
private let mcpServerName = "krit"
private let mcpServerVersion = "0.1.0"

/// Longest edge (px) of the inline preview image handed back to the agent.
/// Anthropic downsizes images above ~1568px, so cap there to avoid wasting tokens.
private let previewMaxEdge = 1568

// MARK: - Entry

/// Runs the stdio loop until EOF. Returns the process exit code.
func runMCPServer() -> Int32 {
    logStderr("krit mcp: stdio server up (protocol \(mcpProtocolVersion))")
    let stdin = FileHandle.standardInput
    var buffer = Data()

    while true {
        let chunk = stdin.availableData
        if chunk.isEmpty {
            // EOF, client closed the pipe.
            break
        }
        buffer.append(chunk)

        // Drain every complete (newline-terminated) line out of the buffer.
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            handleLine(lineData)
        }
    }

    // A trailing line without a newline is still a valid message.
    if !buffer.isEmpty {
        handleLine(buffer)
    }

    logStderr("krit mcp: stdin closed, exiting")
    return 0
}

// MARK: - Line dispatch

private func handleLine(_ lineData: Data) {
    let trimmed = lineData.trimmingTrailingWhitespace()
    guard !trimmed.isEmpty else { return }

    guard let object = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else {
        // Can't recover an id from unparseable input; reply with null id per spec.
        writeMessage(errorResponse(id: NSNull(), code: -32700, message: "parse error"))
        return
    }

    let id = object["id"]
    let method = object["method"] as? String

    guard let method else {
        if id != nil {
            writeMessage(errorResponse(id: id ?? NSNull(), code: -32600, message: "invalid request: missing 'method'"))
        }
        return
    }

    // Notifications carry no id and must not be answered.
    let isNotification = (id == nil)

    switch method {
    case "initialize":
        respond(id: id, result: initializeResult())

    case "notifications/initialized", "initialized":
        // No-op notification. Nothing to send back.
        break

    case "ping":
        respond(id: id, result: [:])

    case "tools/list":
        respond(id: id, result: ["tools": toolDefinitions()])

    case "tools/call":
        handleToolsCall(id: id, params: object["params"] as? [String: Any])

    default:
        if isNotification {
            logStderr("krit mcp: ignoring unknown notification '\(method)'")
        } else {
            writeMessage(errorResponse(id: id ?? NSNull(), code: -32601, message: "method not found: \(method)"))
        }
    }
}

private func respond(id: Any?, result: [String: Any]) {
    // A request always has an id; if somehow absent (a notification we chose to
    // answer), skip the write rather than emit a malformed response.
    guard let id, !(id is NSNull) else { return }
    writeMessage(["jsonrpc": "2.0", "id": id, "result": result])
}

// MARK: - tools/call

private func handleToolsCall(id: Any?, params: [String: Any]?) {
    guard let params else {
        writeMessage(errorResponse(id: id ?? NSNull(), code: -32602, message: "invalid params: missing params"))
        return
    }
    guard let toolName = params["name"] as? String else {
        writeMessage(errorResponse(id: id ?? NSNull(), code: -32602, message: "invalid params: missing tool 'name'"))
        return
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    do {
        let content = try invokeTool(name: toolName, arguments: arguments)
        respond(id: id, result: ["content": content, "isError": false])
    } catch let error as ToolError {
        // Tool execution failures surface as a tool result with isError:true so the
        // agent can read the reason, not as a transport-level JSON-RPC error.
        respond(id: id, result: [
            "content": [textContent("error [\(error.code)]: \(error.message)")],
            "isError": true,
        ])
    } catch {
        respond(id: id, result: [
            "content": [textContent("error [internal_error]: \(error.localizedDescription)")],
            "isError": true,
        ])
    }
}

// MARK: - Tool errors

struct ToolError: Error {
    let code: String
    let message: String
}

// MARK: - Tool dispatch

private func invokeTool(name: String, arguments: [String: Any]) throws -> [[String: Any]] {
    switch name {
    case "capture_region":
        return try toolCaptureRegion(arguments)
    case "capture_fullscreen":
        return try toolCaptureFullscreen(arguments)
    case "annotate_image":
        return try toolAnnotateImage(arguments)
    case "capture_and_read":
        return try toolCaptureAndRead(arguments)
    case "inspect_ui":
        return try toolInspectUI(arguments)
    default:
        throw ToolError(code: "unknown_tool", message: "no tool named '\(name)'")
    }
}

// MARK: - capture_region / capture_fullscreen

private func toolCaptureRegion(_ args: [String: Any]) throws -> [[String: Any]] {
    let region = try requireRegion(args)
    var request: [String: Any] = [
        "cmd": "capture_region",
        "x": region.x, "y": region.y, "w": region.w, "h": region.h,
    ]
    if let display = optionalInt(args, "display") { request["display"] = display }
    if let out = args["path"] as? String { request["path"] = out }

    let result = try runPortCommand(request)
    return captureContent(from: result)
}

private func toolCaptureFullscreen(_ args: [String: Any]) throws -> [[String: Any]] {
    var request: [String: Any] = ["cmd": "capture_fullscreen"]
    if let display = optionalInt(args, "display") { request["display"] = display }
    if let out = args["path"] as? String { request["path"] = out }

    let result = try runPortCommand(request)
    return captureContent(from: result)
}

/// text(JSON {path,widthPx,heightPx}) + inline downscaled preview.
private func captureContent(from result: [String: Any]) -> [[String: Any]] {
    let path = result["path"] as? String ?? ""
    let widthPx = (result["widthPx"] as? NSNumber)?.intValue ?? 0
    let heightPx = (result["heightPx"] as? NSNumber)?.intValue ?? 0

    var content: [[String: Any]] = [
        textContent(jsonString(["path": path, "widthPx": widthPx, "heightPx": heightPx])),
    ]
    if let preview = makePreviewImageContent(path: path) {
        content.append(preview)
    }
    return content
}

// MARK: - annotate_image

private func toolAnnotateImage(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let input = args["input"] as? String else {
        throw ToolError(code: "bad_args", message: "annotate_image requires 'input'")
    }
    guard let output = args["output"] as? String else {
        throw ToolError(code: "bad_args", message: "annotate_image requires 'output'")
    }
    let spec = args["spec"] as? [[String: Any]] ?? []

    let request: [String: Any] = [
        "cmd": "annotate", "input": input, "output": output, "spec": spec,
    ]
    let result = try runPortCommand(request)
    return captureContent(from: result)
}

// MARK: - capture_and_read (closed-loop)

private func toolCaptureAndRead(_ args: [String: Any]) throws -> [[String: Any]] {
    let region = try requireRegion(args)
    var request: [String: Any] = [
        "cmd": "capture_region",
        "x": region.x, "y": region.y, "w": region.w, "h": region.h,
    ]
    if let display = optionalInt(args, "display") { request["display"] = display }
    if let out = args["path"] as? String { request["path"] = out }

    let result = try runPortCommand(request)
    let path = result["path"] as? String ?? ""
    let widthPx = (result["widthPx"] as? NSNumber)?.intValue ?? 0
    let heightPx = (result["heightPx"] as? NSNumber)?.intValue ?? 0

    let (ocrText, blocks) = recognizeTextWithBlocks(atPath: path)

    var payload: [String: Any] = [
        "path": path,
        "widthPx": widthPx,
        "heightPx": heightPx,
        "ocrText": ocrText,
    ]
    if !blocks.isEmpty { payload["blocks"] = blocks }

    var content: [[String: Any]] = [textContent(jsonString(payload))]
    if let preview = makePreviewImageContent(path: path) {
        content.append(preview)
    }
    return content
}

// MARK: - inspect_ui (semantic UI tree, the agent-native counterpart to pixels)

private func toolInspectUI(_ args: [String: Any]) throws -> [[String: Any]] {
    var request: [String: Any] = ["cmd": "inspect"]

    // Target precedence: rect, then windowId, then frontmost (the default).
    if let x = numberArg(args, "x"), let y = numberArg(args, "y"),
       let w = numberArg(args, "width"), let h = numberArg(args, "height") {
        guard w > 0, h > 0 else {
            throw ToolError(code: "bad_args", message: "width and height must be positive")
        }
        request["rect"] = [x, y, w, h]
        if (args["includeScreenshot"] as? Bool) == true { request["includeScreenshot"] = true }
    } else if let windowId = optionalInt(args, "windowId") {
        request["windowId"] = windowId
    }
    // No rect and no windowId, the app defaults to the frontmost app's tree.

    if let depth = optionalInt(args, "maxDepth") { request["maxDepth"] = depth }

    let result = try runPortCommand(request, budget: 10)

    // The base64 screenshot, if present, is lifted out of the JSON text block and
    // re-emitted as a proper inline image block (downscaled) so the agent can see it
    // without the giant base64 string bloating the text payload.
    var jsonResult = result
    var inlineImage: [String: Any]?
    if let shot = result["screenshot"] as? [String: Any],
       let base64 = shot["base64"] as? String,
       let image = decodeBase64Image(base64) {
        inlineImage = [
            "type": "image",
            "data": (encodePNG(downscale(image, maxEdge: previewMaxEdge)) ?? Data()).base64EncodedString(),
            "mimeType": "image/png",
        ]
        jsonResult["screenshot"] = ["widthPx": shot["widthPx"] ?? 0, "heightPx": shot["heightPx"] ?? 0, "inlined": true]
    }

    var content: [[String: Any]] = [textContent(jsonString(jsonResult))]
    if let inlineImage { content.append(inlineImage) }
    return content
}

private func decodeBase64Image(_ base64: String) -> CGImage? {
    guard let data = Data(base64Encoded: base64),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return image
}

// MARK: - Port command (sync, blocking, fine for the MCP request loop)

/// Runs a submit/poll cycle against the app and returns the result payload, or
/// throws a ToolError carrying the app's code/message. `budget` is the wall-clock
/// ceiling: interactive captures get the generous default, non-interactive commands
/// (inspect) pass a tighter one so a wedged app surfaces a clear error fast.
private func runPortCommand(_ request: [String: Any], budget: TimeInterval = 30) throws -> [String: Any] {
    guard let port = connectMCP() else {
        throw ToolError(code: "app_unreachable", message: "KRIT app not reachable (automation port never came up)")
    }
    let deadline = Date().addingTimeInterval(budget)
    func remaining() -> CFTimeInterval { max(0, deadline.timeIntervalSinceNow) }

    // Each round trip is capped at the time left, so the whole call returns at or
    // before `budget` no matter how the app behaves.
    guard let submit = try sendMCP(["cmd": "submit", "request": request], to: port, timeout: min(5, remaining())) else {
        throw ToolError(code: "timeout", message: "app did not respond within \(Int(budget))s")
    }
    if (submit["ok"] as? Bool) != true {
        throw ToolError(
            code: (submit["code"] as? String) ?? "submit_failed",
            message: (submit["error"] as? String) ?? "submit failed"
        )
    }
    guard let requestId = submit["requestId"] as? String else {
        throw ToolError(code: "bad_response", message: "submit response missing requestId")
    }

    while remaining() > 0 {
        guard let poll = try sendMCP(["cmd": "poll", "requestId": requestId], to: port, timeout: min(5, remaining())) else {
            // Transport timeout, not fatal while budget remains: loop and retry.
            continue
        }
        if (poll["ok"] as? Bool) != true {
            throw ToolError(
                code: (poll["code"] as? String) ?? "command_failed",
                message: (poll["error"] as? String) ?? "command failed"
            )
        }
        if (poll["done"] as? Bool) == true {
            return (poll["result"] as? [String: Any]) ?? [:]
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw ToolError(code: "timeout", message: "app did not respond within \(Int(budget))s")
}

/// Like the CLI's `connect()`, but returns nil instead of exiting so the MCP loop
/// survives an unreachable app and reports a structured tool error.
private func connectMCP() -> CFMessagePort? {
    if let port = CFMessagePortCreateRemote(kCFAllocatorDefault, portName) { return port }

    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments = ["-g", "-b", appBundleID]
    try? launch.run()
    launch.waitUntilExit()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let port = CFMessagePortCreateRemote(kCFAllocatorDefault, portName) { return port }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

/// Returns nil on a transport timeout (the caller decides whether budget remains to
/// retry), throws only on a genuine wire error. `timeout` caps both send and receive.
private func sendMCP(_ request: [String: Any], to port: CFMessagePort, timeout: CFTimeInterval = 5) throws -> [String: Any]? {
    guard let payload = try? JSONSerialization.data(withJSONObject: request) else {
        throw ToolError(code: "client_error", message: "could not encode request")
    }
    var responseData: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
        port, 0, payload as CFData, timeout, timeout,
        CFRunLoopMode.defaultMode.rawValue, &responseData
    )
    if status == kCFMessagePortSendTimeout || status == kCFMessagePortReceiveTimeout {
        return nil
    }
    guard status == kCFMessagePortSuccess else {
        throw ToolError(code: "port_send_failed", message: "port send failed (status \(status))")
    }
    guard let cfData = responseData?.takeRetainedValue() as Data?,
          let object = (try? JSONSerialization.jsonObject(with: cfData)) as? [String: Any] else {
        throw ToolError(code: "bad_response", message: "port returned an undecodable response")
    }
    return object
}

// MARK: - OCR (local Vision, headless on the saved PNG)

/// Runs Vision text recognition synchronously on the file at `path`. The capture
/// already lives on disk (the app owns Screen Recording, not OCR), so reading text
/// runs right here in the CLI process, no extra port round-trip.
private func recognizeTextWithBlocks(atPath path: String) -> (text: String, blocks: [[String: Any]]) {
    guard !path.isEmpty,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return ("", [])
    }

    let widthPx = CGFloat(cgImage.width)
    let heightPx = CGFloat(cgImage.height)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        logStderr("krit mcp: OCR failed: \(error.localizedDescription)")
        return ("", [])
    }

    let observations = request.results ?? []
    var lines: [String] = []
    var blocks: [[String: Any]] = []
    for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        lines.append(candidate.string)
        // Vision boundingBox is normalized, bottom-left origin. Convert to
        // top-left pixel coords so blocks line up with the rest of the protocol.
        let bb = obs.boundingBox
        let pxX = Int((bb.origin.x * widthPx).rounded())
        let pxW = Int((bb.size.width * widthPx).rounded())
        let pxH = Int((bb.size.height * heightPx).rounded())
        let pxYTopLeft = Int(((1 - bb.origin.y - bb.size.height) * heightPx).rounded())
        blocks.append([
            "text": candidate.string,
            "confidence": candidate.confidence,
            "rect": [pxX, pxYTopLeft, pxW, pxH],
        ])
    }
    return (lines.joined(separator: "\n"), blocks)
}

// MARK: - Preview image (downscaled base64 PNG)

/// Loads the PNG at `path`, downscales so the longest edge is <= previewMaxEdge,
/// and returns an MCP image content block. Returns nil if the file can't be read.
private func makePreviewImageContent(path: String) -> [String: Any]? {
    guard !path.isEmpty,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    let scaled = downscale(cgImage, maxEdge: previewMaxEdge)
    guard let pngData = encodePNG(scaled) else { return nil }
    return [
        "type": "image",
        "data": pngData.base64EncodedString(),
        "mimeType": "image/png",
    ]
}

private func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
    let w = image.width
    let h = image.height
    let longest = max(w, h)
    guard longest > maxEdge else { return image }

    let scale = CGFloat(maxEdge) / CGFloat(longest)
    let newW = max(1, Int((CGFloat(w) * scale).rounded()))
    let newH = max(1, Int((CGFloat(h) * scale).rounded()))

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: newW,
        height: newH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return image
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return ctx.makeImage() ?? image
}

private func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - Argument helpers

private struct Region { let x: Double; let y: Double; let w: Double; let h: Double }

private func requireRegion(_ args: [String: Any]) throws -> Region {
    guard let x = numberArg(args, "x"),
          let y = numberArg(args, "y"),
          let w = numberArg(args, "width"),
          let h = numberArg(args, "height") else {
        throw ToolError(code: "bad_args", message: "requires numeric x, y, width, height")
    }
    guard w > 0, h > 0 else {
        throw ToolError(code: "bad_args", message: "width and height must be positive")
    }
    return Region(x: x, y: y, w: w, h: h)
}

private func numberArg(_ args: [String: Any], _ key: String) -> Double? {
    (args[key] as? NSNumber)?.doubleValue
}

private func optionalInt(_ args: [String: Any], _ key: String) -> Int? {
    (args[key] as? NSNumber)?.intValue
}

// MARK: - JSON / content helpers

private func textContent(_ text: String) -> [String: Any] {
    ["type": "text", "text": text]
}

private func jsonString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

/// Writes one JSON-RPC message as a single newline-terminated line on stdout.
private func writeMessage(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Tool definitions (JSON Schema)

private func initializeResult() -> [String: Any] {
    [
        "protocolVersion": mcpProtocolVersion,
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": mcpServerName, "version": mcpServerVersion],
    ]
}

private func toolDefinitions() -> [[String: Any]] {
    let regionProps: [String: Any] = [
        "x": ["type": "number", "description": "Left edge, global top-left origin, in points."],
        "y": ["type": "number", "description": "Top edge, global top-left origin, in points."],
        "width": ["type": "number", "description": "Region width in points (> 0)."],
        "height": ["type": "number", "description": "Region height in points (> 0)."],
        "display": ["type": "integer", "description": "Optional display index to disambiguate which screen."],
        "path": ["type": "string", "description": "Optional output PNG path. Defaults to ~/Pictures/KRIT."],
    ]

    return [
        [
            "name": "capture_region",
            "description": "Capture a rectangular screen region to a PNG. Coordinates are global top-left in points. Returns the full-resolution file path plus an inline downscaled preview the agent can see.",
            "inputSchema": [
                "type": "object",
                "properties": regionProps,
                "required": ["x", "y", "width", "height"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "capture_fullscreen",
            "description": "Capture an entire display to a PNG. Returns the full-resolution file path plus an inline downscaled preview.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "display": ["type": "integer", "description": "Optional display index. Defaults to the main display."],
                    "path": ["type": "string", "description": "Optional output PNG path. Defaults to ~/Pictures/KRIT."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "annotate_image",
            "description": "Draw annotations (arrow, box, ellipse, line, text, step, highlight, blur, pixelate) onto an existing image and write a new PNG. Spec coordinates are in pixels of the input image, top-left origin. Colors are hex \"#RRGGBB\".",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input": ["type": "string", "description": "Path to the source image."],
                    "output": ["type": "string", "description": "Path to write the annotated PNG."],
                    "spec": [
                        "type": "array",
                        "description": "Array of annotation objects. Each has a 'type' plus type-specific fields, e.g. {\"type\":\"box\",\"rect\":[x,y,w,h],\"color\":\"#FF0000\",\"width\":4}, {\"type\":\"arrow\",\"from\":[x,y],\"to\":[x,y]}, {\"type\":\"text\",\"at\":[x,y],\"text\":\"hi\",\"size\":24}, {\"type\":\"step\",\"at\":[x,y],\"number\":1}, {\"type\":\"blur\",\"rect\":[x,y,w,h],\"radius\":12}, {\"type\":\"pixelate\",\"rect\":[x,y,w,h],\"scale\":10}.",
                        "items": ["type": "object"],
                    ],
                ],
                "required": ["input", "output", "spec"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "capture_and_read",
            "description": "Closed-loop verify: capture a screen region, run OCR on the result, and return both the recognized text (with per-block bounding boxes in top-left pixel coords) and an inline preview image. Use this to read what is actually on screen in any UI, e.g. to verify a rendered app state.",
            "inputSchema": [
                "type": "object",
                "properties": regionProps,
                "required": ["x", "y", "width", "height"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "inspect_ui",
            "description": "Read the SEMANTIC UI structure instead of pixels. Returns the live Accessibility tree of on-screen elements as JSON: each node has role (e.g. AXButton, AXTextField), optional subrole, label, value, frame {x,y,w,h} in global top-left points, enabled, and nested children. This is the agent-native sibling of capture_and_read: use inspect_ui to know what the controls ARE and exactly where to click/type, then capture for pixels only when you need to see them. Target precedence: pass x/y/width/height to inspect a screen rect (across the app under it), or windowId for one window, or nothing to inspect the frontmost app. Set includeScreenshot:true (rect only) to also get an inline image of the same region in one call. Requires macOS Accessibility permission (System Settings > Privacy & Security > Accessibility).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "Optional rect left edge, global top-left origin, in points."],
                    "y": ["type": "number", "description": "Optional rect top edge, global top-left origin, in points."],
                    "width": ["type": "number", "description": "Optional rect width in points (> 0). Required with x/y/height to inspect a rect."],
                    "height": ["type": "number", "description": "Optional rect height in points (> 0). Required with x/y/width to inspect a rect."],
                    "windowId": ["type": "integer", "description": "Optional CGWindowID to inspect a single window. Ignored if a rect is given."],
                    "maxDepth": ["type": "integer", "description": "Optional max tree depth (default 12)."],
                    "includeScreenshot": ["type": "boolean", "description": "Rect target only: also return an inline PNG of the region so you get pixels + semantics in one call."],
                ],
                "additionalProperties": false,
            ],
        ],
    ]
}

// MARK: - Data utility

private extension Data {
    /// Drops trailing \r and \n so a CRLF or blank line parses cleanly.
    func trimmingTrailingWhitespace() -> Data {
        var end = endIndex
        while end > startIndex {
            let byte = self[index(before: end)]
            if byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09 {
                end = index(before: end)
            } else {
                break
            }
        }
        return subdata(in: startIndex..<end)
    }
}
