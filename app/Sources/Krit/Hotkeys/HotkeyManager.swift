import AppKit
import KeyboardShortcuts

/// Wires every global capture shortcut to its handler. KeyboardShortcuts owns
/// the key/modifier binding per `Name` (persisted in UserDefaults, editable in
/// Preferences) and re-registers automatically when the user rebinds, so this
/// only installs the action closures once.
@MainActor
final class HotkeyManager {

    // `onKeyDown` appends handlers, so calling register twice would double-fire
    // every capture. AppDelegate calls registerHotkeys() more than once (launch
    // plus the native-shortcut prompt callback), so install exactly once.
    private var didInstall = false

    // Weak engine/history refs captured from register(), so registerPresets() can
    // be re-called later (when presets change) without re-threading them through.
    private weak var captureEngine: CaptureEngine?
    private weak var historyManager: HistoryManager?

    // Preset shortcut names we've installed a handler for, so re-registration
    // installs exactly one handler per new preset and clears bindings for deleted
    // ones. KeyboardShortcuts.onKeyDown appends, so we never re-add for the same name.
    private var installedPresetNames: Set<String> = []

    func register(captureEngine: CaptureEngine, historyManager: HistoryManager, onToggleHistory: @escaping () -> Void) {
        guard !didInstall else { return }
        didInstall = true
        self.captureEngine = captureEngine
        self.historyManager = historyManager

        KeyboardShortcuts.onKeyDown(for: .captureArea) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            AreaSelectionDiag.mark("hotkeyFired")
            Task { await e.startAreaCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .captureWindow) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startWindowCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .captureFullscreen) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.captureFullscreen(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .capturePreviousArea) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.capturePreviousArea(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .allInOne) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startAllInOne(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .snapAndPaste) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startSnapAndPaste(historyManager: h) }
        }

        // Record screen is a toggle, like CleanShot: while a recording is live the
        // shortcut stops it; otherwise it opens area recording (the primary case).
        KeyboardShortcuts.onKeyDown(for: .recordScreen) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            if e.recordingActive {
                e.stopRecording()
            } else {
                Task { await e.startAreaRecording() }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .ocrCapture) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startOCRCapture() }
        }

        KeyboardShortcuts.onKeyDown(for: .scrollingCapture) { [weak captureEngine, weak historyManager] in
            guard let e = captureEngine, let h = historyManager else { return }
            Task { await e.startScrollingCapture(historyManager: h) }
        }

        KeyboardShortcuts.onKeyDown(for: .pickColor) { [weak captureEngine] in
            guard let e = captureEngine else { return }
            Task { await e.startColorPick() }
        }

        KeyboardShortcuts.onKeyDown(for: .captureHistory) { onToggleHistory() }

        registerPresets()
    }

    /// (Re)wires the dynamic per-preset shortcuts. Re-callable: AppDelegate wires
    /// PresetStore.onChange to this so adding/removing/editing a preset updates the
    /// live bindings. Idempotent per preset, the handler is installed once per name
    /// (onKeyDown appends, so re-adding would double-fire) and looks the preset up by
    /// id at DISPATCH time, so editing a preset's rect/format/actions takes effect
    /// without reinstalling. Deleted presets get their binding cleared.
    func registerPresets() {
        let presets = PresetStore.all()
        let liveNames = Set(presets.map { KeyboardShortcuts.Name.snapPreset(id: $0.id).rawValue })

        for preset in presets {
            let name = KeyboardShortcuts.Name.snapPreset(id: preset.id)
            // Honor the per-preset toggle: a disabled preset keeps its stored
            // binding but doesn't fire.
            if preset.hotkeyEnabled {
                KeyboardShortcuts.enable(name)
            } else {
                KeyboardShortcuts.disable(name)
            }
            guard !installedPresetNames.contains(name.rawValue) else { continue }
            installedPresetNames.insert(name.rawValue)
            let presetID = preset.id
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self,
                      let engine = self.captureEngine,
                      let history = self.historyManager,
                      let live = PresetStore.preset(id: presetID) else { return }
                Task { await engine.runPreset(live, historyManager: history) }
            }
        }

        // Clear bindings for presets that no longer exist so a deleted preset's
        // key combo stops triggering. The closure stays installed (KeyboardShortcuts
        // can't remove handlers), but with no shortcut and no matching preset it's
        // an inert no-op.
        for rawName in installedPresetNames where !liveNames.contains(rawName) {
            KeyboardShortcuts.setShortcut(nil, for: KeyboardShortcuts.Name(rawName))
        }
    }
}
