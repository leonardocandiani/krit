import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Detects which AI engines this Mac can actually run, so features can gate
/// themselves and Preferences can explain what's available. Pure local probing:
/// no network, no secrets, no API key.
///
/// KRIT's AI is two tiers:
///   • On-device (default, free, offline) — Apple's Vision / Translation work
///     everywhere; the Foundation Models on-device LLM needs Apple Intelligence
///     (Apple Silicon, enabled), so it is absent on Intel.
///   • Cloud (opt-in, off by default) — runs through the user's OWN Claude
///     subscription via the `claude` binary they installed and authenticated
///     (`claude login` / `claude setup-token`). KRIT spawns it and never holds
///     an API key. No paid API key path exists, by design.
enum AICapability {

    /// True when Apple's on-device language model is usable right now
    /// (Apple Intelligence-capable Mac with the model downloaded). False on
    /// Intel, when Apple Intelligence is off, or below macOS 26.
    static var onDeviceLanguageModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// Path to the user's installed `claude` binary, or nil if not found. This
    /// is how the cloud tier reaches the user's Claude subscription — KRIT only
    /// runs this binary; the binary owns the auth. KRIT stores no credential.
    static var claudeCLIPath: String? {
        // GUI apps launched by launchd inherit a minimal PATH that omits
        // Homebrew, so probe the common absolute locations first…
        let known = [
            "/opt/homebrew/bin/claude",                 // Apple Silicon Homebrew
            "/usr/local/bin/claude",                    // Intel Homebrew / manual
            "\(NSHomeDirectory())/.local/bin/claude",   // user-local install
        ]
        for path in known where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // …then a best-effort login-shell lookup for PATHs set in the user's
        // shell profile. Best-effort only: a non-interactive login shell sources
        // .zprofile/.zlogin but NOT .zshrc (where many users put PATH edits), so
        // the absolute-path list above stays the primary mechanism.
        return resolveViaLoginShell()
    }

    /// Whether the opt-in cloud tier is usable: the user enabled it AND a
    /// `claude` binary is present to run it.
    static var cloudReady: Bool {
        Settings.aiCloudEnabled && claudeCLIPath != nil
    }

    private static func resolveViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            // Profile scripts can print banners to stdout, so take the last
            // non-empty line and accept it only if it is an executable file.
            let line = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            guard let path = line, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
