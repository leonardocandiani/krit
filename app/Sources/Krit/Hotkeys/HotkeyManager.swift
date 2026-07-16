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
    // Every capture/record/tool handler drops the presentation zoom before it
    // runs: capture frames the real screen, and the selection chrome sits
    // above the magnifier, so mixing the two makes the shot ambiguous.
    private weak var presentationZoom: PresentationZoomController?
    // Same reasoning as presentationZoom above: every capture/record/tool
    // handler also steps live annotation out of interactive drawing mode
    // first. Unlike the zoom (which tears down completely), this keeps the
    // ink on screen — a capture taken right after drawing should still show
    // the marks — it only releases the mouse/keyboard the drawing overlay
    // was holding.
    private weak var liveAnnotation: LiveAnnotationController?

    // Preset shortcut names we've installed a handler for, so re-registration
    // installs exactly one handler per new preset and clears bindings for deleted
    // ones. KeyboardShortcuts.onKeyDown appends, so we never re-add for the same name.
    private var installedPresetNames: Set<String> = []

    func register(captureEngine: CaptureEngine, historyManager: HistoryManager, presentationZoom: PresentationZoomController, liveAnnotation: LiveAnnotationController, onToggleHistory: @escaping () -> Void) {
        guard !didInstall else { return }
        didInstall = true
        self.captureEngine = captureEngine
        self.historyManager = historyManager
        self.presentationZoom = presentationZoom
        self.liveAnnotation = liveAnnotation

        // Split into small installers (below), each with one job, so no
        // single function accumulates every shortcut's branching.
        installAreaHandlers()
        installClipboardHandlers()
        installSingleEngineHandlers()
        installOverlayHandlers(onToggleHistory: onToggleHistory)

        registerPresets()
    }

    /// Handlers that need both the capture engine and history manager and
    /// land the result in the history list.
    private func installAreaHandlers() {
        KeyboardShortcuts.onKeyDown(for: .captureArea) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            AreaSelectionDiag.mark("hotkeyFired")
            e.enqueueInteractiveRequest { await e.startAreaCapture(historyManager: h) }
        }
        KeyboardShortcuts.onKeyDown(for: .captureWindow) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startWindowCapture(historyManager: h) }
        }
        KeyboardShortcuts.onKeyDown(for: .captureFullscreen) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.captureFullscreen(historyManager: h) }
        }
        KeyboardShortcuts.onKeyDown(for: .capturePreviousArea) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.capturePreviousArea(historyManager: h) }
        }
    }

    /// The remaining "needs engine + history" handlers — split from
    /// `installAreaHandlers` purely to keep each installer's complexity low,
    /// not because these are conceptually different.
    private func installClipboardHandlers() {
        KeyboardShortcuts.onKeyDown(for: .allInOne) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startAllInOne(historyManager: h) }
        }
        KeyboardShortcuts.onKeyDown(for: .snapAndPaste) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startSnapAndPaste(historyManager: h) }
        }
        KeyboardShortcuts.onKeyDown(for: .scrollingCapture) { [weak self] in
            guard let self, let e = self.captureEngine, let h = self.historyManager else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startScrollingCapture(historyManager: h) }
        }
    }

    /// Handlers that only need the capture engine (no history entry).
    private func installSingleEngineHandlers() {
        // Record screen is a toggle, like CleanShot: while a recording is live
        // the shortcut stops it; otherwise it opens area recording (the
        // primary case).
        KeyboardShortcuts.onKeyDown(for: .recordScreen) { [weak self] in
            guard let self, let e = self.captureEngine else { return }
            if e.recordingActive {
                e.stopRecording()
            } else {
                self.dropOverlays()
                e.enqueueInteractiveRequest { await e.startAreaRecording() }
            }
        }
        KeyboardShortcuts.onKeyDown(for: .ocrCapture) { [weak self] in
            guard let self, let e = self.captureEngine else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startOCRCapture() }
        }
        KeyboardShortcuts.onKeyDown(for: .pickColor) { [weak self] in
            guard let self, let e = self.captureEngine else { return }
            self.dropOverlays()
            e.enqueueInteractiveRequest { await e.startColorPick() }
        }
    }

    /// Toggles with no capture engine involved: history panel, presentation
    /// zoom, and live annotation.
    private func installOverlayHandlers(onToggleHistory: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .captureHistory) { onToggleHistory() }

        // Presentation zoom: toggle arms/dismisses; in/out drive the level
        // and are inert while the zoom is off (they never conjure it). Key
        // down taps a step and opens a possible hold-ramp; key up closes it —
        // that's what makes press-and-hold zoom continuously while a quick
        // tap steps once. No manual drop of live annotation here:
        // PresentationZoomController's own engage path steps it out of
        // drawing mode itself (see its `liveAnnotation` property), the same
        // mutual-exclusion mechanism this file uses for the reverse direction.
        KeyboardShortcuts.onKeyDown(for: .presentationZoom) { [weak self] in
            self?.presentationZoom?.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .presentationZoomIn) { [weak self] in
            self?.presentationZoom?.beginZoomIn()
        }
        KeyboardShortcuts.onKeyUp(for: .presentationZoomIn) { [weak self] in
            self?.presentationZoom?.endZoomHold()
        }
        KeyboardShortcuts.onKeyDown(for: .presentationZoomOut) { [weak self] in
            self?.presentationZoom?.beginZoomOut()
        }
        KeyboardShortcuts.onKeyUp(for: .presentationZoomOut) { [weak self] in
            self?.presentationZoom?.endZoomHold()
        }

        // Live annotation: same off→drawing→passive→drawing cycle the
        // toolbar's tool buttons drive. Its own engage path drops the
        // presentation zoom (see LiveAnnotationController.engage), so no
        // manual drop here either.
        KeyboardShortcuts.onKeyDown(for: .liveAnnotation) { [weak self] in
            self?.liveAnnotation?.toggleDrawMode()
        }
    }

    /// Shared prefix for every capture/record/tool handler above: drop the
    /// presentation zoom (a live magnified frame makes the shot ambiguous) and
    /// step live annotation out of interactive drawing mode (it releases the
    /// mouse/keyboard the drawing overlay was holding, but leaves the drawn
    /// ink on screen — capturing right after drawing should still show it).
    private func dropOverlays() {
        presentationZoom?.exitForCapture()
        liveAnnotation?.exitDrawModeKeepingAnnotations()
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
                self.dropOverlays()
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
