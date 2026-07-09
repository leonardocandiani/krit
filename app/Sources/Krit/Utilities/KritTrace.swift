import Foundation
import os

/// Permanent tracing sink for KRIT, mirroring the Vercel Native SDK's pattern of
/// pairing an os.Logger with an optional file sink and a panic capture hook.
///
/// Motivation: on this machine `log show` never returns os_log messages emitted
/// by ad-hoc signed dev builds, so runtime debugging needs an opt-in file sink
/// that bypasses the unified logging pipeline entirely.
enum KritTrace {

    private static let loggerLock = NSLock()
    private static var loggers: [String: Logger] = [:]

    /// Emits to os.Logger (always) and, when the file sink is active, appends
    /// the same line to the trace file. Safe to call from any thread.
    static func log(_ category: String, _ message: String) {
        logger(for: category).log("\(message, privacy: .public)")
        writeToFileSink(category: category, message: message)
    }

    private static func logger(for category: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let cached = loggers[category] { return cached }
        let logger = Logger(subsystem: "com.krit.app", category: category)
        loggers[category] = logger
        return logger
    }

    // MARK: - File sink

    /// Resolved once and cached: env var `KRIT_TRACE_FILE` takes precedence over
    /// the `kritTraceFile` default; nil means the sink is off.
    private static let fileSinkHandle: FileHandle? = {
        let path = ProcessInfo.processInfo.environment["KRIT_TRACE_FILE"]
            ?? UserDefaults.standard.string(forKey: "kritTraceFile")
        guard let path, !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        return FileHandle(forWritingAtPath: path)
    }()

    private static let fileSinkLock = NSLock()
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func writeToFileSink(category: String, message: String) {
        guard let handle = fileSinkHandle else { return }

        fileSinkLock.lock()
        defer { fileSinkLock.unlock() }
        let line = "\(timestampFormatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Panic capture

    /// Stashed here (rather than captured by the handler closure below) because
    /// `NSSetUncaughtExceptionHandler` requires a plain C function pointer, which
    /// cannot close over local state.
    private static var previousExceptionHandler: NSUncaughtExceptionHandler?

    /// Installs an uncaught-exception handler that writes name, reason and call
    /// stack to `~/Library/Logs/KRIT/last-panic.txt`, chaining any handler that
    /// was already installed. Call once at launch. Signal handlers (SIGSEGV
    /// etc.) are out of scope here, they're unsafe to catch from Swift.
    static func installPanicCapture() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            KritTrace.previousExceptionHandler?(exception)
            KritTrace.writePanicReport(for: exception)
        }
    }

    private static func writePanicReport(for exception: NSException) {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KRIT")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let report = """
        \(Date())
        name: \(exception.name.rawValue)
        reason: \(exception.reason ?? "unknown")
        callStackSymbols:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        try? report.write(
            to: logsDir.appendingPathComponent("last-panic.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
