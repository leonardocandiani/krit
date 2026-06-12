import AppIntents
import AppKit

// App Intents expose KRIT's capture actions to Shortcuts.app and the Spotlight
// command bar, something neither Shottr nor CleanShot ship. Each intent drives
// the SAME AppDelegate selectors the menu bar uses, so there is exactly one code
// path per action. They open the app on run because every capture needs the
// running process that holds the Screen Recording grant (and most show UI).
//
// SPM caveat (reported honestly): App Intents discovery in Shortcuts/Spotlight is
// driven by an `AppIntentsMetadata.bundle` that Xcode's build phase generates from
// the App Intents SSU compiler. A plain `swift build` executable does not run that
// phase, so the system may not surface these intents until the app is built
// through Xcode (or the metadata is produced separately). The code compiles and
// the intents are correct; the `krit://` URL scheme is the universal fallback that
// works regardless of metadata generation.

/// Shared bridge: resolve the live AppDelegate on the main actor so intents can
/// invoke the existing menu selectors without duplicating capture logic.
@available(macOS 13.0, *)
@MainActor
private enum IntentBridge {
    static var delegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }
}

@available(macOS 13.0, *)
struct CaptureAreaIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Area"
    static var description = IntentDescription(
        "Select a rectangular region of the screen and capture it with KRIT."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.captureArea()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureFullscreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Fullscreen"
    static var description = IntentDescription(
        "Capture the entire display under the cursor with KRIT."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.captureFullscreen()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Window"
    static var description = IntentDescription(
        "Pick a window and capture it cleanly with KRIT, with transparent rounded corners."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.captureWindow()
        return .result()
    }
}

@available(macOS 13.0, *)
struct OCRIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Text (OCR)"
    static var description = IntentDescription(
        "Select a region, recognize its text with KRIT, and copy it to the clipboard."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.captureText()
        return .result()
    }
}

@available(macOS 13.0, *)
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Screen Recording"
    static var description = IntentDescription(
        "Start a KRIT screen recording. Select the area to record, then choose audio and camera options."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.recordArea()
        return .result()
    }
}

@available(macOS 13.0, *)
struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Screen Recording"
    static var description = IntentDescription(
        "Stop the screen recording currently in progress in KRIT."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.delegate?.stopRecording()
        return .result()
    }
}

/// Groups the intents under a KRIT shortcut provider so they appear together in
/// Shortcuts.app with phrases for the Spotlight / Siri command bar.
@available(macOS 13.0, *)
struct KritShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureAreaIntent(),
            phrases: ["Capture area with \(.applicationName)"],
            shortTitle: "Capture Area",
            systemImageName: "rectangle.dashed"
        )
        AppShortcut(
            intent: CaptureFullscreenIntent(),
            phrases: ["Capture fullscreen with \(.applicationName)"],
            shortTitle: "Capture Fullscreen",
            systemImageName: "rectangle.on.rectangle"
        )
        AppShortcut(
            intent: CaptureWindowIntent(),
            phrases: ["Capture window with \(.applicationName)"],
            shortTitle: "Capture Window",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: OCRIntent(),
            phrases: ["Capture text with \(.applicationName)"],
            shortTitle: "Capture Text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
