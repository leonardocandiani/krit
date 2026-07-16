import Foundation
import Darwin

/// Build-scoped gate for the unauthenticated local UI harness. A release build
/// must not gain capture or UI-drive capabilities merely because a launcher adds
/// an environment variable. Test builds still require the explicit runtime flag.
enum KritTestHarness {
    static var isEnabled: Bool {
        isEnabled(in: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(in environment: [String: String]) -> Bool {
        #if KRIT_TEST_HARNESS
        runtimeGate(
            buildSupportsHarness: true,
            runtimeFlagPresent: environment["KRIT_UI_TEST"] == "1"
        )
        #else
        false
        #endif
    }

    /// Kept pure so the normal SwiftPM suite can prove both halves of the gate
    /// without compiling a process that accepts unauthenticated notifications.
    static func runtimeGate(
        buildSupportsHarness: Bool,
        runtimeFlagPresent: Bool
    ) -> Bool {
        buildSupportsHarness && runtimeFlagPresent
    }
}

/// Release-safe launch probe for the two SwiftPM resource paths that previously
/// crashed only after the external build directory disappeared. The argument
/// opens the real Shortcuts view, rebuilds it once, and exits with a shell-visible
/// status. It exposes no capture or file-write capability.
@MainActor
enum KritBundleRuntimeProbe {
    static let argument = "--krit-verify-bundle-runtime"

    static var isRequested: Bool {
        isRequested(in: ProcessInfo.processInfo.arguments)
    }

    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    static func run() {
        let preferences = PreferencesWindowController.shared
        preferences.show(tab: .shortcuts)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard preferences.window?.isVisible == true else {
                finish(success: false, message: "Shortcuts preferences did not open")
            }

            preferences.show(tab: .general)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                preferences.show(tab: .shortcuts)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let survivedRebuild = preferences.window?.isVisible == true
                    finish(
                        success: survivedRebuild,
                        message: survivedRebuild
                            ? "Shortcuts resource runtime probe passed"
                            : "Shortcuts preferences failed after rebuilding the section"
                    )
                }
            }
        }
    }

    private static func finish(success: Bool, message: String) -> Never {
        let stream = success ? stdout : stderr
        fputs("\(message)\n", stream)
        fflush(stream)
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

/// Output boundary for the unauthenticated local test harness. The sender may
/// choose only a direct leaf under the shared temporary directory. The actual
/// write opens that leaf with `O_NOFOLLOW`, so a symlink substituted after input
/// validation cannot redirect a Screen Recording capture or test report.
enum KritTestOutput {
    private static let allowedParents: Set<String> = ["/tmp", "/private/tmp"]

    enum OutputError: Error {
        case invalidPath
        case openFailed(Int32)
        case writeFailed(Int32)
    }

    static func temporaryURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              allowedParents.contains(url.deletingLastPathComponent().path) else {
            return nil
        }
        return url
    }

    static func write(_ data: Data, to url: URL) throws {
        guard let acceptedURL = temporaryURL(for: url.path), acceptedURL.path == url.standardizedFileURL.path else {
            throw OutputError.invalidPath
        }

        let fileDescriptor = open(
            acceptedURL.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else { throw OutputError.openFailed(errno) }
        defer { _ = close(fileDescriptor) }

        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw OutputError.writeFailed(code)
                }
                if count == 0 { throw OutputError.writeFailed(EIO) }
                offset += count
            }
        }
    }
}
