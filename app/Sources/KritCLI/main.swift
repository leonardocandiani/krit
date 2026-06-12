import Foundation

// krit, command-line client for the KRIT automation port.
//
// Subcommands:
//   krit capture --region x,y,w,h [--out path]
//   krit capture --fullscreen [--display N] [--out path]
//   krit annotate --in a.png --out b.png --spec '<json-array>'
//   krit annotate --in a.png --out b.png --spec-file spec.json
//   krit inspect --frontmost [--max-depth N] [--pretty]
//   krit inspect --window <id> [--max-depth N] [--pretty]
//   krit inspect --rect x,y,w,h [--max-depth N] [--screenshot] [--pretty]
//   krit mcp                       (MCP stdio server: JSON-RPC over stdin/stdout)
//
// Output: one JSON object on stdout (single line by default, multi-line with
// --pretty). Exit code 0 on success, non-zero on error.

let portName = "com.krit.app.automation" as CFString
let appBundleID = "com.krit.app"

/// Opt-in pretty-printing for inspect output. Default is compact (one line) so
/// downstream tooling can read stdout line by line.
var prettyOutput = false

// MARK: - Output helpers

func emit(_ object: [String: Any]) {
    var options: JSONSerialization.WritingOptions = [.sortedKeys]
    if prettyOutput { options.insert(.prettyPrinted) }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{\"ok\":false,\"error\":\"encode failed\"}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String, code: String = "client_error") -> Never {
    emit(["ok": false, "error": message, "code": code])
    exit(1)
}

func succeed(_ result: [String: Any]) -> Never {
    var out = result
    out["ok"] = true
    emit(out)
    exit(0)
}

// MARK: - Argument parsing

/// Minimal flag parser: collects `--key value` and bare `--flag` pairs.
struct Args {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            guard token.hasPrefix("--") else { i += 1; continue }
            let key = String(token.dropFirst(2))
            if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                values[key] = raw[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

// MARK: - Port connection

func remotePort() -> CFMessagePort? {
    CFMessagePortCreateRemote(kCFAllocatorDefault, portName)
}

/// Connects to the running app's port, launching the app (background) and polling
/// for up to ~5s if the port is not yet up.
func connect() -> CFMessagePort {
    if let port = remotePort() { return port }

    // Port absent, launch the app in the background, then poll for the port.
    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments = ["-g", "-b", appBundleID]
    try? launch.run()
    launch.waitUntilExit()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let port = remotePort() { return port }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail("KRIT app not reachable (automation port \(portName as String) never came up)", code: "app_unreachable")
}

/// Outcome of one port round trip. A transport timeout is NOT fatal on its own:
/// the poll loop may still have budget left, so it decides whether to retry or give
/// up. Only a genuine wire error (bad status other than timeout, undecodable reply)
/// is terminal.
enum SendOutcome {
    case reply([String: Any])
    case timedOut
    case wireError(String)
}

/// Sends one JSON request over the port. `timeout` caps BOTH the send and the
/// receive, so a single call can never block longer than `timeout`, no matter what
/// the app does, and the caller stays inside its overall budget.
func send(_ request: [String: Any], to port: CFMessagePort, timeout: CFTimeInterval) -> SendOutcome {
    guard let payload = try? JSONSerialization.data(withJSONObject: request) else {
        return .wireError("could not encode request")
    }
    var responseData: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
        port,
        0,
        payload as CFData,
        timeout,
        timeout,
        CFRunLoopMode.defaultMode.rawValue,
        &responseData
    )
    if status == kCFMessagePortSendTimeout || status == kCFMessagePortReceiveTimeout {
        return .timedOut
    }
    guard status == kCFMessagePortSuccess else {
        return .wireError("port send failed (status \(status))")
    }
    guard let cfData = responseData?.takeRetainedValue() as Data?,
          let object = (try? JSONSerialization.jsonObject(with: cfData)) as? [String: Any] else {
        return .wireError("port returned an undecodable response")
    }
    return .reply(object)
}

/// Submits a request and polls (200ms interval) until done or the budget runs out.
/// `budget` is the overall wall-clock ceiling, honored end to end: each round trip
/// is capped at the time LEFT in the budget, so the whole call returns at or before
/// `budget` whatever the app does. Interactive captures get the generous default;
/// non-interactive commands (inspect) pass a tighter one so they can never hang.
func submitAndPoll(_ request: [String: Any], budget: TimeInterval = 30) -> Never {
    let port = connect()
    let deadline = Date().addingTimeInterval(budget)

    func remaining() -> CFTimeInterval { max(0, deadline.timeIntervalSinceNow) }
    func timeoutOut() -> Never { fail("app did not respond within \(Int(budget))s", code: "timeout") }

    // Cap each round trip at the smaller of 5s and whatever budget is left.
    switch send(["cmd": "submit", "request": request], to: port, timeout: min(5, remaining())) {
    case .timedOut:
        timeoutOut()
    case .wireError(let message):
        fail(message, code: "port_send_failed")
    case .reply(let submitResponse):
        if (submitResponse["ok"] as? Bool) != true {
            fail((submitResponse["error"] as? String) ?? "submit failed",
                 code: (submitResponse["code"] as? String) ?? "submit_failed")
        }
        guard let requestId = submitResponse["requestId"] as? String else {
            fail("submit response missing requestId", code: "bad_response")
        }

        while remaining() > 0 {
            switch send(["cmd": "poll", "requestId": requestId], to: port, timeout: min(5, remaining())) {
            case .timedOut:
                // A slow round trip is not fatal while budget remains; loop and retry.
                continue
            case .wireError(let message):
                fail(message, code: "port_send_failed")
            case .reply(let pollResponse):
                if (pollResponse["ok"] as? Bool) != true {
                    fail((pollResponse["error"] as? String) ?? "command failed",
                         code: (pollResponse["code"] as? String) ?? "command_failed")
                }
                if (pollResponse["done"] as? Bool) == true {
                    succeed((pollResponse["result"] as? [String: Any]) ?? [:])
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        timeoutOut()
    }
}

// MARK: - Subcommands

func runCapture(_ args: Args) -> Never {
    var request: [String: Any]
    if let region = args.value("region") {
        let parts = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            fail("--region expects x,y,w,h", code: "bad_args")
        }
        request = ["cmd": "capture_region", "x": parts[0], "y": parts[1], "w": parts[2], "h": parts[3]]
        if let display = args.value("display"), let n = Int(display) { request["display"] = n }
    } else if args.flag("fullscreen") {
        request = ["cmd": "capture_fullscreen"]
        if let display = args.value("display"), let n = Int(display) { request["display"] = n }
    } else {
        fail("capture needs --region x,y,w,h or --fullscreen", code: "bad_args")
    }

    if let out = args.value("out") { request["path"] = out }
    submitAndPoll(request)
}

func runAnnotate(_ args: Args) -> Never {
    guard let input = args.value("in") else { fail("annotate needs --in <path>", code: "bad_args") }
    guard let output = args.value("out") else { fail("annotate needs --out <path>", code: "bad_args") }

    let specJSON: String
    if let inline = args.value("spec") {
        specJSON = inline
    } else if let file = args.value("spec-file") {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            fail("could not read --spec-file \(file)", code: "bad_args")
        }
        specJSON = contents
    } else {
        fail("annotate needs --spec '<json>' or --spec-file <path>", code: "bad_args")
    }

    guard let specData = specJSON.data(using: .utf8),
          let spec = (try? JSONSerialization.jsonObject(with: specData)) as? [[String: Any]] else {
        fail("--spec must be a JSON array of annotation objects", code: "bad_args")
    }

    let request: [String: Any] = ["cmd": "annotate", "input": input, "output": output, "spec": spec]
    submitAndPoll(request)
}

func runInspect(_ args: Args) -> Never {
    if args.flag("pretty") { prettyOutput = true }

    var request: [String: Any] = ["cmd": "inspect"]
    // Target precedence mirrors the parser: rect, then window, then frontmost.
    if let rect = args.value("rect") {
        let parts = rect.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            fail("--rect expects x,y,w,h", code: "bad_args")
        }
        request["rect"] = parts
        if args.flag("screenshot") { request["includeScreenshot"] = true }
    } else if let window = args.value("window"), let id = UInt32(window) {
        request["windowId"] = id
    } else if args.flag("frontmost") {
        // frontmost is the default; nothing extra to set.
    } else {
        fail("inspect needs --frontmost, --window <id> or --rect x,y,w,h", code: "bad_args")
    }

    if let depth = args.value("max-depth"), let n = Int(depth) { request["maxDepth"] = n }
    // Inspect is non-interactive and capped internally (~2s walk + 0.5s per AX call),
    // so a 10s ceiling is generous. Past that the app is wedged, not working: fail
    // loudly instead of hanging.
    submitAndPoll(request, budget: 10)
}

let usage = "usage: krit <capture|annotate|inspect|mcp> [options]"

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
    fail(usage, code: "bad_args")
}

if subcommand == "--help" || subcommand == "-h" || subcommand == "help" {
    emit([
        "ok": true,
        "usage": usage,
        "subcommands": [
            "capture --region x,y,w,h [--out path] | --fullscreen [--display N] [--out path]",
            "annotate --in a.png --out b.png --spec '<json>' | --spec-file spec.json",
            "inspect --frontmost | --window <id> | --rect x,y,w,h [--max-depth N] [--screenshot] [--pretty]",
            "mcp",
        ],
    ])
    exit(0)
}

let rest = Args(Array(arguments.dropFirst()))

switch subcommand {
case "capture":
    runCapture(rest)
case "annotate":
    runAnnotate(rest)
case "inspect":
    runInspect(rest)
case "mcp":
    // Stdio MCP server: reads JSON-RPC over stdin, writes responses on stdout.
    // Runs until EOF; uses its own output path (never the one-shot emit/exit helpers).
    exit(runMCPServer())
default:
    fail("unknown subcommand: \(subcommand)", code: "bad_args")
}
