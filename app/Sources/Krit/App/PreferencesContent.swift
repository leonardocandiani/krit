import SwiftUI
import AVFoundation
import KeyboardShortcuts
import ServiceManagement

/// SwiftUI content for each Preferences section. The window chrome (dark window,
/// glass sidebar, section switching) stays in AppKit; each section's body is a
/// grouped `Form` hosted in an `NSHostingView`, so the controls are the same
/// native components System Settings uses (Toggle, Picker, Slider, the
/// KeyboardShortcuts.Recorder), styled with KRIT's coral tint over dark mode.

// MARK: - Hosting bridge

/// Builds the `NSView` for a section: a grouped SwiftUI `Form` inside an
/// `NSHostingView`. The Form's own scroll background is hidden so KRIT's void
/// content surface shows through, matching the rest of the dark chrome.
@MainActor
enum PreferencesContent {

    static func makeView(for tab: PreferencesTab) -> NSView {
        let root: AnyView
        switch tab {
        case .general:   root = AnyView(GeneralForm())
        case .capture:   root = AnyView(CaptureForm())
        case .recording: root = AnyView(RecordingForm())
        case .preview:   root = AnyView(PreviewForm())
        case .editor:    root = AnyView(EditorForm())
        case .shortcuts: root = AnyView(ShortcutsForm())
        case .presets:   root = AnyView(PresetsForm())
        case .about:     root = AnyView(AboutForm())
        }

        let hosting = NSHostingView(rootView: PreferencesSection { root })
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}

/// Common chrome around every section's Form: grouped style, coral tint, hidden
/// scroll background so the dark content pane reads through, and top padding to
/// clear the transparent titlebar.
private struct PreferencesSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Color(KritColors.accent))
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralForm: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var playSounds = Settings.playSounds
    @State private var captureSound = Settings.captureSoundStyle
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var hideDesktopIcons = Settings.hideDesktopIconsWhileCapturing
    @State private var copyToClipboard = Settings.afterCaptureCopyToClipboard
    @State private var saveAutomatically = Settings.afterCaptureSaveAutomatically
    @State private var appearance = Settings.appearanceMode

    var body: some View {
        Section("Appearance") {
            Picker(selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Text("Theme")
                Text("Match the system, or always use Light or Dark.")
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { newValue in
                Settings.appearanceMode = newValue
                AppearanceMode.applyCurrent()
            }
        }

        Section("Startup") {
            Toggle(isOn: $launchAtLogin) {
                Text("Launch KRIT at login")
                Text("Start the menu bar app automatically.")
            }
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    // Re-read so the toggle reverts if the system rejected it.
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        }

        Section("Sounds") {
            Toggle(isOn: $playSounds) {
                Text("Play sounds")
                Text("Capture, copy, save, and recording cues.")
            }
            .onChange(of: playSounds) { Settings.playSounds = $0 }

            Picker("Capture sound", selection: $captureSound) {
                ForEach(CaptureSoundStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .onChange(of: captureSound) { newValue in
                Settings.captureSoundStyle = newValue
                // Play the chosen cue so picking is tactile.
                SoundManager.play(newValue == .classic ? .captureClassic : .captureBigSur)
            }
        }

        Section("Menu bar") {
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                .onChange(of: showMenuBarIcon) { Settings.showMenuBarIcon = $0 }
            Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
                .onChange(of: hideDesktopIcons) { Settings.hideDesktopIconsWhileCapturing = $0 }
        }

        Section("After capture") {
            Toggle(isOn: $copyToClipboard) {
                Text("Copy screenshots to clipboard")
                Text("New screenshots are copied automatically.")
            }
            .onChange(of: copyToClipboard) { Settings.afterCaptureCopyToClipboard = $0 }

            Toggle(isOn: $saveAutomatically) {
                Text("Save automatically")
                Text("Write each capture to the save location without asking.")
            }
            .onChange(of: saveAutomatically) { Settings.afterCaptureSaveAutomatically = $0 }
        }
    }
}

// MARK: - Capture

private struct CaptureForm: View {
    @State private var captureScale = Settings.captureScale
    @State private var format = Settings.screenshotFormat
    @State private var jpegQuality = Settings.jpegQuality
    @State private var countdown = Settings.captureCountdownSeconds
    @State private var saveLocation = Settings.autoSaveLocation
    @State private var windowBackground = Settings.windowCaptureBackground

    var body: some View {
        Section("Quality") {
            Picker(selection: $captureScale) {
                ForEach(CaptureScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            } label: {
                Text("Capture resolution")
                Text(captureScale.detail)
            }
            .onChange(of: captureScale) { Settings.captureScale = $0 }
        }

        Section("Export format") {
            Picker("File format", selection: $format) {
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
                Text("WebP").tag("webp")
            }
            .onChange(of: format) { Settings.screenshotFormat = $0 }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("JPEG quality")
                    Spacer()
                    Text("\(Int(jpegQuality * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $jpegQuality, in: 0.1...1.0)
                    .onChange(of: jpegQuality) { Settings.jpegQuality = $0 }
            }
        }

        Section("Countdown") {
            Picker(selection: $countdown) {
                Text("Off").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            } label: {
                Text("Self-timer")
                Text("Counts 3, 2, 1 before the capture fires. Esc cancels.")
            }
            .onChange(of: countdown) { Settings.captureCountdownSeconds = $0 }
        }

        Section("Window capture") {
            Picker(selection: $windowBackground) {
                ForEach(WindowCaptureBackground.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Background")
                Text("Window shots open composed on the current desktop wallpaper, centered with a shadow.")
            }
            .onChange(of: windowBackground) { Settings.windowCaptureBackground = $0 }
        }

        Section("Save location") {
            HStack {
                Text("Screenshots folder")
                Spacer()
                Text(saveLocation)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { chooseFolder() }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.autoSaveLocation)
        if panel.runModal() == .OK, let url = panel.url {
            if Settings.setAutoSaveLocation(url.path) {
                saveLocation = Settings.autoSaveLocation
            } else {
                ToastWindow.show(message: "Choose a writable folder for auto-save.")
            }
        }
    }
}

// MARK: - Recording

private struct RecordingForm: View {
    @State private var quality = Settings.recordingQuality
    @State private var fps = Settings.recordingFPS
    @State private var showsCursor = Settings.recordingShowsCursor
    @State private var systemAudio = Settings.recordingSystemAudio
    @State private var microphone = Settings.recordingMicrophone
    @State private var micDevice = Settings.recordingMicrophoneDeviceID
    @State private var webcam = Settings.recordingWebcam
    @State private var webcamDevice = Settings.recordingWebcamDeviceID
    @State private var showsClicks = Settings.recordingShowsClicks
    @State private var showsKeystrokes = Settings.recordingShowsKeystrokes
    @State private var gifFPS = Settings.recordingGIFFPS
    @State private var gifMaxDimension = Settings.recordingGIFMaxDimension

    var body: some View {
        Section("Video") {
            Picker(selection: $quality) {
                Text("Balanced").tag("balanced")
                Text("High").tag("high")
                Text("Max").tag("max")
            } label: {
                Text("Quality")
                Text("Max keeps more detail for demos but makes larger files.")
            }
            .onChange(of: quality) { Settings.recordingQuality = $0 }

            Picker("Frame rate", selection: $fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .onChange(of: fps) { Settings.recordingFPS = $0 }

            Toggle("Show cursor", isOn: $showsCursor)
                .onChange(of: showsCursor) { Settings.recordingShowsCursor = $0 }
        }

        Section("Audio") {
            Toggle(isOn: $systemAudio) {
                Text("Record system audio")
                Text("Excludes KRIT's own sounds to avoid feedback.")
            }
            .onChange(of: systemAudio) { Settings.recordingSystemAudio = $0 }

            Toggle("Record microphone", isOn: $microphone)
                .onChange(of: microphone) { Settings.recordingMicrophone = $0 }

            DevicePicker(
                title: "Microphone",
                options: PreferencesDeviceProvider.microphones,
                selection: $micDevice
            )
            .onChange(of: micDevice) { Settings.recordingMicrophoneDeviceID = $0 }
        }

        Section("Webcam") {
            Toggle(isOn: $webcam) {
                Text("Webcam overlay")
                Text("Circular picture in picture in the corner. Needs camera permission.")
            }
            .onChange(of: webcam) { Settings.recordingWebcam = $0 }

            DevicePicker(
                title: "Camera",
                options: PreferencesDeviceProvider.cameras,
                selection: $webcamDevice
            )
            .onChange(of: webcamDevice) { Settings.recordingWebcamDeviceID = $0 }
        }

        Section("Clicks and keystrokes") {
            Toggle("Highlight mouse clicks", isOn: $showsClicks)
                .onChange(of: showsClicks) { Settings.recordingShowsClicks = $0 }

            Toggle(isOn: $showsKeystrokes) {
                Text("Show pressed keys")
                Text("Keystroke HUD inside the recording. Needs Accessibility permission.")
            }
            .onChange(of: showsKeystrokes) { Settings.recordingShowsKeystrokes = $0 }
        }

        Section("GIF export") {
            Picker("Frame rate", selection: $gifFPS) {
                Text("10 fps").tag(10)
                Text("15 fps").tag(15)
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
            }
            .onChange(of: gifFPS) { Settings.recordingGIFFPS = $0 }

            Picker(selection: $gifMaxDimension) {
                Text("480 px").tag(480)
                Text("640 px").tag(640)
                Text("800 px").tag(800)
                Text("1024 px").tag(1024)
            } label: {
                Text("Max size")
                Text("Largest dimension in pixels; frames downscale to fit.")
            }
            .onChange(of: gifMaxDimension) { Settings.recordingGIFMaxDimension = $0 }
        }
    }
}

/// Picker over (name, uniqueID) device pairs. Shares the same value type as the
/// AppKit popup it replaces, so the persisted ID stays compatible.
private struct DevicePicker: View {
    let title: String
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.1) { option in
                Text(option.0).tag(option.1)
            }
        }
    }
}

// MARK: - Preview overlay

private struct PreviewForm: View {
    @State private var size = Settings.overlaySize
    @State private var timeout = Settings.overlayTimeout
    @State private var onLeft = Settings.overlayOnLeft

    var body: some View {
        Section("Size") {
            Picker("Preview size", selection: $size) {
                ForEach(OverlaySize.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .onChange(of: size) { Settings.overlaySize = $0 }
        }

        Section("Behavior") {
            Picker("Auto dismiss", selection: $timeout) {
                Text("3 seconds").tag(3.0)
                Text("6 seconds").tag(6.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("Never").tag(-1.0)
            }
            .onChange(of: timeout) { Settings.overlayTimeout = $0 }

            Picker("Screen side", selection: $onLeft) {
                Text("Left").tag(true)
                Text("Right").tag(false)
            }
            .onChange(of: onLeft) { Settings.overlayOnLeft = $0 }
        }
    }
}

// MARK: - Editor

private struct EditorForm: View {
    @State private var lineWidth = Settings.annotationLineWidth
    @State private var defaultTemplate = Settings.defaultTemplateName

    private var templateOptions: [(String, String)] {
        var options: [(String, String)] = [("None", "")]
        options += TemplateStore.all().map { ($0.name, $0.name) }
        return options
    }

    var body: some View {
        Section("Annotations") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Default thickness")
                    Spacer()
                    Text("\(Int(lineWidth)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("New arrows, lines, and shapes start at this stroke width.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Slider(value: $lineWidth, in: 1...20, step: 1)
                    .onChange(of: lineWidth) { Settings.annotationLineWidth = $0 }
            }
        }

        Section("Templates") {
            Picker(selection: $defaultTemplate) {
                ForEach(templateOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            } label: {
                Text("Default template")
                Text("Applied automatically to new captures.")
            }
            .onChange(of: defaultTemplate) {
                TemplateStore.setDefault(name: $0.isEmpty ? nil : $0)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsForm: View {
    var body: some View {
        Section("Screenshots") {
            KeyboardShortcuts.Recorder("All-in-one", name: .allInOne)
            KeyboardShortcuts.Recorder("Capture area", name: .captureArea)
            KeyboardShortcuts.Recorder("Capture window", name: .captureWindow)
            KeyboardShortcuts.Recorder("Capture full screen", name: .captureFullscreen)
            KeyboardShortcuts.Recorder("Repeat last area", name: .capturePreviousArea)
            KeyboardShortcuts.Recorder("Snap and paste", name: .snapAndPaste)
            KeyboardShortcuts.Recorder("Toggle capture history", name: .captureHistory)
        }

        Section("Recording") {
            KeyboardShortcuts.Recorder("Record screen", name: .recordScreen)
        }

        Section("Tools") {
            KeyboardShortcuts.Recorder("Capture text (OCR)", name: .ocrCapture)
            KeyboardShortcuts.Recorder("Scrolling capture", name: .scrollingCapture)
        }

        Section {
            HStack {
                Text("Restore defaults")
                Spacer()
                Button("Restore") {
                    KeyboardShortcuts.reset(KeyboardShortcuts.Name.allCapture)
                }
            }
        } footer: {
            Text("Click a shortcut to change it. Shortcuts are global while KRIT runs.")
        }
    }
}

// MARK: - Presets

/// Snap Presets: named regions with their own global hotkey, output format, and a
/// chain of post-capture actions. Each row edits a `SnapPreset` live (every change
/// writes back through PresetStore, which re-registers the dynamic hotkeys). The
/// "New preset from selection" button drops into the area selection to define a
/// region, then appends a preset for it.
private struct PresetsForm: View {
    @State private var presets: [SnapPreset] = PresetStore.all()

    var body: some View {
        Section {
            if presets.isEmpty {
                Text("No presets yet. Create one from a screen region to snap it with a single hotkey.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets) { preset in
                    PresetRow(
                        preset: preset,
                        onChange: { updated in update(updated) },
                        onDelete: { delete(preset) },
                        onTest: { runNow(preset) }
                    )
                }
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("A preset captures a fixed region headlessly and runs its actions, no selection needed. Set a hotkey to trigger it from anywhere.")
        }

        Section {
            Button {
                newFromSelection()
            } label: {
                Label("New preset from selection", systemImage: "plus.viewfinder")
            }
        } footer: {
            Text("Drag a region on screen; KRIT saves it as a preset you can name and bind.")
        }
    }

    private func reload() {
        presets = PresetStore.all()
    }

    private func update(_ preset: SnapPreset) {
        PresetStore.update(preset)
        reload()
    }

    private func delete(_ preset: SnapPreset) {
        PresetStore.delete(id: preset.id)
        reload()
    }

    private func runNow(_ preset: SnapPreset) {
        (NSApp.delegate as? AppDelegate)?.runPreset(preset)
    }

    private func newFromSelection() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        // Order the Settings window out of the way so the selection overlay owns
        // the screen, then bring it back once the rect is chosen.
        let window = PreferencesWindowController.shared.uiTestWindow
        window?.orderOut(nil)
        delegate.selectPresetRect { rect in
            window?.makeKeyAndOrderFront(nil)
            guard let rect, rect.width > 1, rect.height > 1 else { return }
            let index = PresetStore.all().count + 1
            PresetStore.add(SnapPreset(name: "Preset \(index)", rect: rect))
            reload()
        }
    }
}

/// One editable preset: name field, region summary, hotkey recorder, format
/// picker, action toggles, an enable toggle, and delete. Local @State mirrors the
/// model and pushes every edit back up via `onChange`.
private struct PresetRow: View {
    let preset: SnapPreset
    let onChange: (SnapPreset) -> Void
    let onDelete: () -> Void
    let onTest: () -> Void

    @State private var name: String
    @State private var format: String
    @State private var hotkeyEnabled: Bool
    @State private var doesCopy: Bool
    @State private var doesSave: Bool
    @State private var doesEdit: Bool
    @State private var doesPin: Bool

    init(preset: SnapPreset, onChange: @escaping (SnapPreset) -> Void, onDelete: @escaping () -> Void, onTest: @escaping () -> Void) {
        self.preset = preset
        self.onChange = onChange
        self.onDelete = onDelete
        self.onTest = onTest
        _name = State(initialValue: preset.name)
        _format = State(initialValue: preset.format)
        _hotkeyEnabled = State(initialValue: preset.hotkeyEnabled)
        _doesCopy = State(initialValue: preset.actions.contains(.copy))
        _doesSave = State(initialValue: preset.actions.contains(.save))
        _doesEdit = State(initialValue: preset.actions.contains(.edit))
        _doesPin = State(initialValue: preset.actions.contains(.pin))
    }

    private var regionSummary: String {
        let r = preset.rect
        return "\(Int(r.width)) × \(Int(r.height)) at (\(Int(r.origin.x)), \(Int(r.origin.y)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _ in push() }
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Text(regionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            KeyboardShortcuts.Recorder("Hotkey", name: .snapPreset(id: preset.id))

            Toggle("Enable hotkey", isOn: $hotkeyEnabled)
                .onChange(of: hotkeyEnabled) { _ in push() }

            Picker("Format", selection: $format) {
                Text("PNG").tag("png")
                Text("JPG").tag("jpg")
            }
            .pickerStyle(.segmented)
            .onChange(of: format) { _ in push() }

            HStack(spacing: 16) {
                Toggle("Copy", isOn: $doesCopy).onChange(of: doesCopy) { _ in push() }
                Toggle("Save", isOn: $doesSave).onChange(of: doesSave) { _ in push() }
                Toggle("Edit", isOn: $doesEdit).onChange(of: doesEdit) { _ in push() }
                Toggle("Pin", isOn: $doesPin).onChange(of: doesPin) { _ in push() }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Test now", action: onTest)
            }
        }
        .padding(.vertical, 4)
    }

    /// Rebuilds a SnapPreset from the row's local state and pushes it up. Actions
    /// keep a stable order (copy, save, edit, pin) so the chain is deterministic.
    private func push() {
        var actions: [CaptureAction] = []
        if doesCopy { actions.append(.copy) }
        if doesSave { actions.append(.save) }
        if doesEdit { actions.append(.edit) }
        if doesPin { actions.append(.pin) }
        var updated = preset
        updated.name = name
        updated.format = format
        updated.hotkeyEnabled = hotkeyEnabled
        updated.actions = actions
        onChange(updated)
    }
}

// MARK: - About

private struct AboutForm: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.15.4"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        Section {
            HStack(spacing: 18) {
                Image(nsImage: NSImage(named: "NSApplicationIcon")
                    ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
                    ?? NSImage())
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("KRIT")
                        .font(.system(size: 24, weight: .bold))
                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }

        Section("Links") {
            HStack {
                Text("Source on GitHub")
                Spacer()
                Button("Open") {
                    if let link = URL(string: "https://github.com/leonardocandiani/krit") {
                        NSWorkspace.shared.open(link)
                    }
                }
            }
        }

        Section {
            EmptyView()
        } footer: {
            Text("© 2026 Leonardo Candiani. MIT License, free and open source.")
        }
    }
}

// MARK: - Device discovery

/// Audio/video input devices for the Recording pickers. Kept here so the section
/// views stay declarative.
@MainActor
enum PreferencesDeviceProvider {

    static var microphones: [(String, String)] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        return devices(deviceTypes, mediaType: .audio)
    }

    static var cameras: [(String, String)] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external, .continuityCamera]
        }
        return devices(deviceTypes, mediaType: .video)
    }

    private static func devices(_ types: [AVCaptureDevice.DeviceType], mediaType: AVMediaType) -> [(String, String)] {
        var options: [(String, String)] = [("System Default", "")]
        options += AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: mediaType, position: .unspecified
        )
        .devices
        .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        .map { ($0.localizedName, $0.uniqueID) }
        return options
    }
}
