import Foundation
import AppKit
import os

/// Hosts the local CFMessagePort ("com.krit.app.automation") and bridges its
/// synchronous C callback to the async `AutomationService`.
///
/// The CFMessagePort callback runs on the main run loop and MUST return promptly,
/// it can never block on an interactive capture. So the wire protocol is
/// submit + poll:
///
///   submit {request:{cmd,...}}  -> {ok:true, requestId:"<uuid>"}
///   poll   {requestId:"<uuid>"} -> {ok:true, done:false}
///                                  {ok:true, done:true, result:{...}}
///                                  {ok:false, error, code}
///
/// `submit` validates and kicks off a detached @MainActor task, returning the id
/// immediately. The task stores the outcome; the client polls until `done`.
@MainActor
final class AutomationPort {

    static let portName = "com.krit.app.automation" as CFString
    private static let log = Logger(subsystem: "com.krit.app", category: "automation")

    private let service: AutomationService
    private var messagePort: CFMessagePort?
    private var runLoopSource: CFRunLoopSource?

    private enum Pending {
        case running
        case done([String: Any])
        case failed(code: String, message: String)
    }
    private var jobs: [String: Pending] = [:]

    init(service: AutomationService) {
        self.service = service
    }

    /// Creates the local port and attaches it to the main run loop. Idempotent.
    /// Returns false if the port name is already taken (another instance running).
    @discardableResult
    func start() -> Bool {
        guard messagePort == nil else { return true }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: CFMessagePortCallBack = { (_, _, data, info) -> Unmanaged<CFData>? in
            guard let info else { return nil }
            let port = Unmanaged<AutomationPort>.fromOpaque(info).takeUnretainedValue()
            let requestData = (data as Data?) ?? Data()
            // The local port's callback is delivered on the run loop it was added
            // to, the main run loop, so main-actor isolation holds here.
            let response = MainActor.assumeIsolated {
                port.handleSynchronously(requestData)
            }
            return Unmanaged.passRetained(response as CFData)
        }

        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            Self.portName,
            callback,
            &context,
            nil
        ) else {
            Self.log.error("CFMessagePortCreateLocal failed, name likely already in use")
            return false
        }

        let source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        messagePort = port
        runLoopSource = source
        Self.log.info("automation port up: \(Self.portName as String)")
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let messagePort {
            CFMessagePortInvalidate(messagePort)
        }
        runLoopSource = nil
        messagePort = nil
    }

    // MARK: - Synchronous request handling

    private func handleSynchronously(_ requestData: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] else {
            return Self.encode(["ok": false, "error": "request was not a JSON object", "code": "malformed_request"])
        }
        guard let cmd = object["cmd"] as? String else {
            return Self.encode(["ok": false, "error": "missing 'cmd'", "code": "malformed_request"])
        }

        switch cmd {
        case "submit":
            return handleSubmit(object)
        case "poll":
            return handlePoll(object)
        default:
            return Self.encode(["ok": false, "error": "unknown transport cmd: \(cmd)", "code": "unknown_command"])
        }
    }

    private func handleSubmit(_ object: [String: Any]) -> Data {
        guard let requestObject = object["request"] as? [String: Any] else {
            return Self.encode(["ok": false, "error": "submit: missing 'request'", "code": "malformed_request"])
        }

        let command: AutomationCommand
        do {
            command = try AutomationJSON.parseCommand(requestObject)
        } catch let error as AutomationError {
            return Self.encode(["ok": false, "error": error.message, "code": error.code])
        } catch {
            return Self.encode(["ok": false, "error": error.localizedDescription, "code": "malformed_request"])
        }

        let explicitOut = requestObject["path"] as? String
        let requestId = UUID().uuidString
        jobs[requestId] = .running

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.execute(command, explicitOutputPath: explicitOut)
                self.jobs[requestId] = .done(result)
            } catch let error as AutomationError {
                self.jobs[requestId] = .failed(code: error.code, message: error.message)
            } catch {
                self.jobs[requestId] = .failed(code: "internal_error", message: error.localizedDescription)
            }
        }

        return Self.encode(["ok": true, "requestId": requestId])
    }

    private func handlePoll(_ object: [String: Any]) -> Data {
        guard let requestId = object["requestId"] as? String else {
            return Self.encode(["ok": false, "error": "poll: missing 'requestId'", "code": "malformed_request"])
        }
        guard let job = jobs[requestId] else {
            return Self.encode(["ok": false, "error": "unknown requestId", "code": "unknown_request"])
        }
        switch job {
        case .running:
            return Self.encode(["ok": true, "done": false])
        case .done(let result):
            jobs[requestId] = nil // one-shot: free once collected
            return Self.encode(["ok": true, "done": true, "result": result])
        case .failed(let code, let message):
            jobs[requestId] = nil
            return Self.encode(["ok": false, "error": message, "code": code])
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false,\"error\":\"encode failed\",\"code\":\"internal_error\"}".utf8)
    }
}
