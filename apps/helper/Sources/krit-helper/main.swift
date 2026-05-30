import AppKit
import CoreGraphics

/// KRIT Helper — native macOS screenshot capture.
///
/// Two execution modes:
///
///   1. Resident (default, no arguments): agent app that registers global hotkeys
///      (Cmd+Shift+4 region, Cmd+Shift+3 full screen) and saves to the Desktop.
///
///   2. One-shot (CLI): `krit-helper capture-region` or `krit-helper capture-screen`.
///      Shows the overlay, captures once, saves to a temp file, prints the PNG
///      path to stdout, and exits. Exit 0 on success; exit 1 if cancelled (Esc)
///      or on error. Used by the shell (Tauri) as a sidecar.
///
/// Architecture:
///   - HotkeyManager registers hotkeys via Carbon (resident mode).
///   - OverlayController shows per-display selection overlays.
///   - CaptureEngine uses ScreenCaptureKit to freeze and crop.
///   - KritSounds plays the shutter (`capture.caf`) at the moment of capture.
///
/// Requires Screen Recording permission (TCC), granted by the user.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {

    enum Mode {
        case resident
        case oneShotRegion
        case oneShotScreen
    }

    private let mode: Mode
    private let engine = CaptureEngine()
    private lazy var overlay = OverlayController(engine: engine)
    private var hotkeys: HotkeyManager?

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .resident:
            startResident()
        case .oneShotRegion:
            engine.output = .temporary
            startOneShotRegion()
        case .oneShotScreen:
            engine.output = .temporary
            startOneShotScreen()
        }
    }

    // MARK: - Resident mode

    private func startResident() {
        let hk = HotkeyManager { [weak self] action in
            guard let self else { return }
            switch action {
            case .region:
                self.startRegion()
            case .fullScreen:
                self.startFullScreen()
            }
        }
        hk.register()
        self.hotkeys = hk

        print("KRIT Helper running. Cmd+Shift+4 = region, Cmd+Shift+3 = full screen, Esc = cancel.")
        fflush(stdout)
    }

    private func startRegion() {
        guard !overlay.active else { return }
        overlay.beginRegionCapture()
    }

    private func startFullScreen() {
        guard !overlay.active else { return }
        Task { @MainActor in
            do {
                try await engine.captureFullScreenUnderCursor()
            } catch {
                FileHandle.standardError.write(
                    Data("KRIT: full-screen capture failed: \(error)\n".utf8)
                )
            }
        }
    }

    // MARK: - One-shot mode (CLI/tray)

    private func startOneShotRegion() {
        // Must be active to receive mouse/keyboard events in the overlay.
        NSApp.activate(ignoringOtherApps: true)
        overlay.onComplete = { _ in
            // Path was already printed to stdout by CaptureEngine.save.
            Self.exit(0)
        }
        overlay.onCancelled = {
            FileHandle.standardError.write(Data("KRIT: capture cancelled.\n".utf8))
            Self.exit(1)
        }
        overlay.beginRegionCapture()
    }

    private func startOneShotScreen() {
        Task { @MainActor in
            do {
                _ = try await engine.captureFullScreenUnderCursor()
                Self.exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("KRIT: full-screen capture failed: \(error)\n".utf8)
                )
                Self.exit(1)
            }
        }
    }

    /// Gives AVAudioPlayer a moment to start playing the shutter before the process exits.
    private static func exit(_ code: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Foundation.exit(code)
        }
    }
}

// MARK: - Capture permission (TCC)
//
// These subcommands do not need NSApplication; they resolve and exit.
//
//   check-permission   -> exit 0 if granted, exit 1 otherwise.
//                         Prints "granted" or "denied" to stdout.
//   request-permission -> triggers the native prompt (CGRequestScreenCaptureAccess).
//                         Prints the resulting state and exits 0/1.
//
// CGPreflightScreenCaptureAccess() checks without prompting; used for onboarding polling.
// CGRequestScreenCaptureAccess() opens the system dialog on first call.

func runPermissionCommand(_ command: String) -> Never {
    switch command {
    case "check-permission":
        let granted = CGPreflightScreenCaptureAccess()
        print(granted ? "granted" : "denied")
        fflush(stdout)
        exit(granted ? 0 : 1)
    case "request-permission":
        let granted = CGRequestScreenCaptureAccess()
        print(granted ? "granted" : "denied")
        fflush(stdout)
        exit(granted ? 0 : 1)
    default:
        exit(2)
    }
}

// MARK: - Argument parsing

@MainActor
func parseMode() -> AppController.Mode {
    let args = CommandLine.arguments.dropFirst()
    for arg in args {
        switch arg {
        case "capture-region":
            return .oneShotRegion
        case "capture-screen":
            return .oneShotScreen
        default:
            continue
        }
    }
    return .resident
}

// Permission subcommands are handled before launching NSApplication.
let rawArgs = CommandLine.arguments.dropFirst()
if let permCommand = rawArgs.first(where: {
    $0 == "check-permission" || $0 == "request-permission"
}) {
    runPermissionCommand(permCommand)
}

// Top-level code runs outside @MainActor context; NSApplication may only be used on the
// main thread. By contract the main thread IS the main actor, so we assert the isolation.
MainActor.assumeIsolated {
    let mode = parseMode()

    let app = NSApplication.shared
    // .accessory in both modes: no Dock icon, but overlays and keyboard still work.
    app.setActivationPolicy(.accessory)

    let controller = AppController(mode: mode)
    app.delegate = controller
    app.run()
}
