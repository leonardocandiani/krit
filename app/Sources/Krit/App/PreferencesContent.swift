import SwiftUI
import AVFoundation
import KeyboardShortcuts
import ServiceManagement

/// SwiftUI content for each Preferences section. AppKit owns the window and
/// native source-list navigation; the selected section is one grouped `Form`
/// hosted in a single `NSHostingView`, with KRIT coral reserved for active state.

// MARK: - Hosting bridge

/// Builds a fresh root whenever the category changes or the window reopens. The
/// explicit identity prevents stale `@State` copied from Settings surviving a
/// close/reopen cycle.
@MainActor
enum PreferencesContent {
    static let formMaxWidth: CGFloat = 640

    static func makeRootView(for tab: PreferencesTab) -> AnyView {
        let root: AnyView
        switch tab {
        case .general:   root = AnyView(GeneralForm())
        case .capture:   root = AnyView(CaptureForm())
        case .recording: root = AnyView(RecordingForm())
        case .preview:   root = AnyView(PreviewForm())
        case .editor:    root = AnyView(EditorForm())
        case .shortcuts: root = AnyView(ShortcutsForm())
        case .presets:   root = AnyView(PresetsForm())
        case .permissions: root = AnyView(PermissionsForm())
        case .about:     root = AnyView(AboutForm())
        }

        return AnyView(
            PreferencesSection(tab: tab) { root }
                .id(tab.rawValue)
                .kritTheme()
        )
    }

    static func makeView(for tab: PreferencesTab) -> NSView {
        let hosting = NSHostingView(rootView: makeRootView(for: tab))
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }
}

/// Common native shell around every section: a fixed wayfinding header and a
/// grouped, independently scrolling form below it.
private struct PreferencesSection<Content: View>: View {
    let tab: PreferencesTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PreferencesHeader(tab: tab)
            ZStack(alignment: .top) {
                if #available(macOS 14.0, *) {
                    form
                        .contentMargins(.bottom, KritSpacing.xxxl, for: .scrollContent)
                } else {
                    form
                }

                KritEdgeDissolve()
            }
        }
    }

    private var form: some View {
        Form {
            content
            if #unavailable(macOS 14.0) {
                Section {
                    Color.clear
                        .frame(height: 12)
                        .accessibilityHidden(true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, KritSpacing.m)
        .frame(maxWidth: PreferencesContent.formMaxWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PreferencesHeader: View {
    let tab: PreferencesTab

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KritSpacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .kritType(.largeTitle)
                    .foregroundStyle(.primary)
                Text(tab.subtitle)
                    .kritType(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if tab == .capture { CaptureReadinessBadge() }
        }
        .frame(maxWidth: PreferencesContent.formMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, KritSpacing.xxxl)
        .padding(.top, KritSpacing.xxl)
        .padding(.bottom, KritSpacing.m)
    }
}

private struct CaptureReadinessBadge: View {
    @State private var status = PermissionsManager.screenRecordingStatus

    private var isReady: Bool {
        if case .granted = status { return true }
        return false
    }

    var body: some View {
        KritStatusLabel(
            title: isReady ? "Ready" : "Permission needed",
            color: isReady ? .green : .orange
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isReady ? "Capture status, ready" : "Capture status, permission needed")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        status = PermissionsManager.screenRecordingStatus
    }
}

// MARK: - General

private struct GeneralForm: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var playSounds = Settings.playSounds
    @State private var captureSound = Settings.captureSoundStyle
    @State private var showMenuBarIcon = Settings.showMenuBarIcon
    @State private var hideDesktopIcons = Settings.hideDesktopIconsWhileCapturing
    @State private var showDockDuringCapture = Settings.showDockIconDuringCapture
    @State private var copyToClipboard = Settings.afterCaptureCopyToClipboard
    @State private var saveAutomatically = Settings.afterCaptureSaveAutomatically
    @State private var magnifierOnControl = Settings.magnifierRequiresControl
    @State private var zoomFeel = Settings.presentationZoomFeel
    @State private var zoomSmoothness = Settings.presentationZoomSmoothness
    @State private var zoomLevel = Settings.presentationZoomLevel
    @State private var annotationKeepOnExit = Settings.liveAnnotationKeepOnExit
    @State private var aiCloudEnabled = Settings.aiCloudEnabled
    @State private var claudeFound = false
    @State private var appearance = Settings.appearanceMode
    @State private var automationEnabled = Settings.automationEnabled

    var body: some View {
        Section("Appearance") {
            Picker(selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                rowLabel("Theme", "circle.lefthalf.filled", .indigo)
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
                rowLabel("Launch KRIT at login", "power", .green)
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
                rowLabel("Play sounds", "speaker.wave.2.fill", .pink)
                Text("Capture, copy, save, and recording cues.")
            }
            .onChange(of: playSounds) { Settings.playSounds = $0 }

            Picker(selection: $captureSound) {
                ForEach(CaptureSoundStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            } label: {
                rowLabel("Capture sound", "waveform", .purple)
            }
            .onChange(of: captureSound) { newValue in
                Settings.captureSoundStyle = newValue
                // Play the chosen cue so picking is tactile.
                SoundManager.play(newValue == .classic ? .captureClassic : .captureBigSur)
            }
        }

        Section("Menu bar") {
            Toggle(isOn: $showMenuBarIcon) {
                rowLabel("Show menu bar icon", "menubar.rectangle", .blue)
                Text("Hidden? Reopen KRIT from Spotlight or Finder to get back to Preferences.")
            }
            .onChange(of: showMenuBarIcon) { Settings.showMenuBarIcon = $0 }
            Toggle(isOn: $hideDesktopIcons) {
                rowLabel("Hide desktop icons while capturing", "menubar.dock.rectangle", .gray)
            }
            .onChange(of: hideDesktopIcons) { Settings.hideDesktopIconsWhileCapturing = $0 }
            Toggle(isOn: $showDockDuringCapture) {
                rowLabel("Show Dock icon during capture", "dock.rectangle", .teal)
                Text("KRIT briefly appears in the Dock while you pick a capture area. Off keeps it hidden.")
            }
            .onChange(of: showDockDuringCapture) { Settings.showDockIconDuringCapture = $0 }
        }

        Section("After capture") {
            Toggle(isOn: $copyToClipboard) {
                rowLabel("Copy screenshots to clipboard", "doc.on.clipboard.fill", .blue)
                Text("New screenshots are copied automatically.")
            }
            .onChange(of: copyToClipboard) { Settings.afterCaptureCopyToClipboard = $0 }

            Toggle(isOn: $saveAutomatically) {
                rowLabel("Save automatically", "square.and.arrow.down.fill", .green)
                Text("Write each capture to the save location without asking.")
            }
            .onChange(of: saveAutomatically) { Settings.afterCaptureSaveAutomatically = $0 }
        }

        Section("Selection") {
            Toggle(isOn: $magnifierOnControl) {
                rowLabel("Show magnifier only while holding Control", "plus.magnifyingglass", .orange)
                Text("Keeps the crosshair light; hold ⌃ for the zoom loupe and guide lines.")
            }
            .onChange(of: magnifierOnControl) { Settings.magnifierRequiresControl = $0 }
        }

        Section("Presentation zoom") {
            Picker(selection: $zoomFeel) {
                ForEach(PresentationZoomFeel.allCases) { feel in
                    Text(feel.label).tag(feel)
                }
            } label: {
                rowLabel("Feel", "wand.and.stars", .cyan)
                Text("How the zoom settles: Precise stops dead, Natural eases in, Bouncy adds a springy overshoot.")
            }
            .pickerStyle(.segmented)
            .onChange(of: zoomFeel) { Settings.presentationZoomFeel = $0 }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SettingIcon(symbol: "water.waves", color: .cyan)
                    Text("Smoothing")
                    Spacer()
                    Text(String(format: "%.2f s", PresentationZoomController.responseTime(forSmoothness: zoomSmoothness)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $zoomSmoothness, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Snappy").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Glide").font(.caption).foregroundStyle(.secondary)
                }
                .onChange(of: zoomSmoothness) { Settings.presentationZoomSmoothness = $0 }
                Text("How long each move takes. Applies live — adjust it while a zoom is running to feel the difference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SettingIcon(symbol: "plus.magnifyingglass", color: .cyan)
                    Text("Zoom level")
                    Spacer()
                    Text(String(format: "%g×", zoomLevel))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $zoomLevel, in: PresentationZoomController.minLevel...PresentationZoomController.maxLevel, step: 0.25)
                    .onChange(of: zoomLevel) { Settings.presentationZoomLevel = $0 }
                Text("Arming keeps the screen at normal size; the first zoom-in jumps straight to this level. Tap to step ×1.25, hold to ramp continuously; zoom out walks back to normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Screen annotation") {
            Toggle(isOn: $annotationKeepOnExit) {
                rowLabel("Keep drawing after closing", "scribble", .orange)
                Text("Closing the annotation toolbar keeps your marks on screen for next time. Off clears them.")
            }
            .onChange(of: annotationKeepOnExit) { Settings.liveAnnotationKeepOnExit = $0 }
        }

        Section("AI") {
            Toggle(isOn: $aiCloudEnabled) {
                rowLabel("Cloud AI features", "sparkles", .purple)
                Text("On-device AI (text recognition, translation) always works. Turn this on to also use cloud features through your own Claude subscription — KRIT runs the Claude Code app you installed and never stores an API key.")
            }
            .onChange(of: aiCloudEnabled) { Settings.aiCloudEnabled = $0 }

            if aiCloudEnabled && !claudeFound {
                Text("Claude Code not found — install it and run claude setup-token, then reopen this window.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }

        Section("Automation") {
            Toggle(isOn: $automationEnabled) {
                rowLabel("Allow scripting & the krit CLI", "terminal", .teal)
                Text("Off by default. On, KRIT runs a local command port and answers krit:// URLs so the bundled CLI, Shortcuts, and agents can drive it. This lets other apps on this Mac take screenshots and read the accessibility tree through KRIT, so leave it off unless you use the CLI.")
            }
            .onChange(of: automationEnabled) {
                Settings.automationEnabled = $0
                (NSApp.delegate as? AppDelegate)?.refreshAutomationPort()
            }
        }
        .task {
            // Probe for the `claude` binary OFF the main thread: the absolute-path
            // checks are cheap, but the login-shell fallback can block for hundreds
            // of ms, and the default (no-claude) user always reaches it. Running it
            // in a @State default would freeze the General tab on every open.
            let found = await Task.detached { AICapability.claudeCLIPath != nil }.value
            claudeFound = found
        }
    }
}

// MARK: - Capture

private struct CaptureForm: View {
    @State private var format = Settings.screenshotFormat
    @State private var jpegQuality = Settings.jpegQuality
    @State private var countdown = Settings.captureCountdownSeconds
    @State private var saveLocation = Settings.autoSaveLocation
    @State private var windowBackground = Settings.windowCaptureBackground

    var body: some View {
        Section("Export format") {
            Picker(selection: $format) {
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
                Text("WebP").tag("webp")
                Text("PDF").tag("pdf")
            } label: {
                rowLabel("File format", "doc.fill", .blue)
            }
            .onChange(of: format) { Settings.screenshotFormat = $0 }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SettingIcon(symbol: "slider.horizontal.3", color: .indigo)
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
                rowLabel("Self-timer", "timer", .orange)
                Text("Counts 3, 2, 1 before the capture fires. Esc cancels.")
            }
            .onChange(of: countdown) { Settings.captureCountdownSeconds = $0 }
        }

        Section("Window capture") {
            WindowBackgroundPicker(selection: $windowBackground)
            .onChange(of: windowBackground) { Settings.windowCaptureBackground = $0 }
        }

        Section("Save location") {
            HStack(spacing: 10) {
                SettingIcon(symbol: "folder.fill", color: .blue)
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

private struct WindowBackgroundPicker: View {
    @Binding var selection: WindowCaptureBackground

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingIcon(symbol: "macwindow.on.rectangle", color: .teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background")
                    Text("Choose how captured windows open in the editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ForEach(WindowCaptureBackground.allCases, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        VStack(spacing: 7) {
                            WindowBackgroundPreview(option: option)
                                .frame(height: 68)
                            Text(option.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selection == option
                                    ? Color(KritColors.accent).opacity(0.10)
                                    : Color.primary.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    selection == option
                                        ? Color(KritColors.accent)
                                        : Color.primary.opacity(0.10),
                                    lineWidth: selection == option ? 2 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityValue(selection == option ? "Selected" : "Not selected")
                    .help("Use \(option.displayName.lowercased()) for captured windows")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WindowBackgroundPreview: View {
    let option: WindowCaptureBackground

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)

            if option == .none {
                Image(systemName: "rectangle.slash")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 68, height: 42)
                    .overlay(alignment: .top) {
                        HStack(spacing: 3) {
                            Circle().fill(.red.opacity(0.85))
                            Circle().fill(.yellow.opacity(0.85))
                            Circle().fill(.green.opacity(0.85))
                            Spacer()
                        }
                        .frame(height: 5)
                        .padding(5)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var background: some ShapeStyle {
        switch option {
        case .systemWallpaper:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.70), Color.orange.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .savedTemplate:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.indigo.opacity(0.62), Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .none:
            return AnyShapeStyle(Color.primary.opacity(0.045))
        }
    }
}

// MARK: - Recording

private struct RecordingForm: View {
    @StateObject private var devices = PreferencesDeviceModel()
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
                rowLabel("Quality", "video.fill", .red)
                Text("Max keeps more detail for demos but makes larger files.")
            }
            .onChange(of: quality) { Settings.recordingQuality = $0 }

            Picker(selection: $fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            } label: {
                rowLabel("Frame rate", "speedometer", .orange)
            }
            .onChange(of: fps) { Settings.recordingFPS = $0 }

            Toggle(isOn: $showsCursor) {
                rowLabel("Show cursor", "cursorarrow", .gray)
            }
            .onChange(of: showsCursor) { Settings.recordingShowsCursor = $0 }
        }

        Section("Audio") {
            Toggle(isOn: $systemAudio) {
                rowLabel("Record system audio", "speaker.wave.2.fill", .purple)
                Text("Excludes KRIT's own sounds to avoid feedback.")
            }
            .onChange(of: systemAudio) { Settings.recordingSystemAudio = $0 }

            Toggle(isOn: $microphone) {
                rowLabel("Record microphone", "mic.fill", .pink)
            }
            .onChange(of: microphone) { Settings.recordingMicrophone = $0 }

            DevicePicker(
                title: "Microphone",
                symbol: "mic.circle.fill",
                color: .pink,
                options: devices.microphones,
                selection: $micDevice
            )
            .onChange(of: micDevice) { Settings.recordingMicrophoneDeviceID = $0 }
        }

        Section("Webcam") {
            Toggle(isOn: $webcam) {
                rowLabel("Webcam overlay", "camera.fill", .teal)
                Text("Circular picture in picture in the corner. Needs camera permission.")
            }
            .onChange(of: webcam) { Settings.recordingWebcam = $0 }

            DevicePicker(
                title: "Camera",
                symbol: "camera.circle.fill",
                color: .teal,
                options: devices.cameras,
                selection: $webcamDevice
            )
            .onChange(of: webcamDevice) { Settings.recordingWebcamDeviceID = $0 }
        }

        Section("Clicks and keystrokes") {
            Toggle(isOn: $showsClicks) {
                rowLabel("Highlight mouse clicks", "cursorarrow.click", .blue)
            }
            .onChange(of: showsClicks) { Settings.recordingShowsClicks = $0 }

            Toggle(isOn: $showsKeystrokes) {
                rowLabel("Show pressed keys", "keyboard.fill", .indigo)
                Text("Keystroke HUD inside the recording. Needs Accessibility permission.")
            }
            .onChange(of: showsKeystrokes) { Settings.recordingShowsKeystrokes = $0 }
        }

        Section("GIF export") {
            Picker(selection: $gifFPS) {
                Text("10 fps").tag(10)
                Text("15 fps").tag(15)
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
            } label: {
                rowLabel("Frame rate", "speedometer", .orange)
            }
            .onChange(of: gifFPS) { Settings.recordingGIFFPS = $0 }

            Picker(selection: $gifMaxDimension) {
                Text("480 px").tag(480)
                Text("640 px").tag(640)
                Text("800 px").tag(800)
                Text("1024 px").tag(1024)
            } label: {
                rowLabel("Max size", "arrow.up.left.and.arrow.down.right", .green)
                Text("Largest dimension in pixels; frames downscale to fit.")
            }
            .onChange(of: gifMaxDimension) { Settings.recordingGIFMaxDimension = $0 }
        }
        .task { await devices.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            Task { await devices.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            Task { await devices.refresh() }
        }
    }
}

/// Picker over stable device options. The selected unique ID remains compatible
/// with the existing UserDefaults value used by RecordingEngine.
private struct DevicePicker: View {
    let title: String
    var symbol: String = "circle"
    var color: Color = .gray
    let options: [PreferencesDeviceOption]
    @Binding var selection: String

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options) { option in
                Text(option.name).tag(option.id)
            }
        } label: {
            rowLabel(title, symbol, color)
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
            Picker(selection: $size) {
                ForEach(OverlaySize.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                rowLabel("Preview size", "arrow.up.left.and.arrow.down.right", .indigo)
            }
            .onChange(of: size) { Settings.overlaySize = $0 }
        }

        Section("Behavior") {
            Picker(selection: $timeout) {
                Text("3 seconds").tag(3.0)
                Text("6 seconds").tag(6.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("Never").tag(-1.0)
            } label: {
                rowLabel("Auto dismiss", "clock.fill", .orange)
            }
            .onChange(of: timeout) { Settings.overlayTimeout = $0 }

            Picker(selection: $onLeft) {
                Text("Left").tag(true)
                Text("Right").tag(false)
            } label: {
                rowLabel("Screen side", "arrow.left.and.right.square.fill", .teal)
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
                HStack(spacing: 10) {
                    SettingIcon(symbol: "pencil.tip", color: .red)
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
                rowLabel("Default template", "doc.on.doc.fill", .purple)
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
            shortcutRow("All-in-one", "square.dashed.inset.filled", .blue, .allInOne)
            shortcutRow("Capture area", "rectangle.dashed", .blue, .captureArea)
            shortcutRow("Capture window", "macwindow", .teal, .captureWindow)
            shortcutRow("Capture full screen", "rectangle.on.rectangle", .indigo, .captureFullscreen)
            shortcutRow("Repeat last area", "arrow.counterclockwise", .orange, .capturePreviousArea)
            shortcutRow("Snap and paste", "doc.on.clipboard", .green, .snapAndPaste)
            shortcutRow("Toggle capture history", "clock.arrow.circlepath", .purple, .captureHistory)
        }

        Section("Recording") {
            shortcutRow("Record screen", "record.circle", .red, .recordScreen)
        }

        Section("Tools") {
            shortcutRow("Capture text (OCR)", "text.viewfinder", .pink, .ocrCapture)
            shortcutRow("Scrolling capture", "scroll", .brown, .scrollingCapture)
            shortcutRow("Pick color", "eyedropper", .mint, .pickColor)
            shortcutRow("Annotate screen", "scribble", .orange, .liveAnnotation)
        }

        Section("Presentation zoom") {
            shortcutRow("Toggle presentation zoom", "plus.magnifyingglass", .cyan, .presentationZoom)
            shortcutRow("Zoom in", "plus.magnifyingglass", .cyan, .presentationZoomIn)
            shortcutRow("Zoom out", "minus.magnifyingglass", .cyan, .presentationZoomOut)
        }

        Section {
            HStack(spacing: 10) {
                SettingIcon(symbol: "arrow.uturn.backward", color: .gray)
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

    /// One shortcut row: icon chip + title on the left, the recorder field on the
    /// right.
    @ViewBuilder
    private func shortcutRow(_ title: String, _ symbol: String, _ color: Color, _ name: KeyboardShortcuts.Name) -> some View {
        HStack(spacing: 10) {
            rowLabel(title, symbol, color)
            Spacer()
            KeyboardShortcuts.Recorder("", name: name)
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
                rowLabel("New preset from selection", "plus.viewfinder", .green)
            }
            .buttonStyle(.plain)
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

/// A neutral Settings-style glyph. KRIT coral stays reserved for selected rows
/// and actions, not repeated inside every setting row.
private struct SettingIcon: View {
    let symbol: String

    init(symbol: String, color _: Color) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

/// A settings row label with a leading neutral glyph.
@ViewBuilder
private func rowLabel(_ title: String, _ symbol: String, _ color: Color) -> some View {
    Label { Text(title) } icon: { SettingIcon(symbol: symbol, color: color) }
}

private struct AboutForm: View {
    // Info.plist is the single source of truth for the version. The fallback only
    // shows when the raw binary runs outside an .app bundle (dev), so keep it honest
    // instead of a stale real-looking number that drifts every release.
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let repo = "https://github.com/leonardocandiani/krit"

    @State private var autoCheck = UpdaterManager.shared.automaticChecks

    var body: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage
                    ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
                    ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("KRIT")
                        .font(.system(size: 22, weight: .bold))
                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)
                    Text("Screenshots and screen recording for macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }

        Section("Updates") {
            LabeledContent {
                Button("Open Updates") { UpdaterManager.shared.checkForUpdates() }
            } label: {
                Label { Text("Software Updates") } icon: { SettingIcon(symbol: "arrow.triangle.2.circlepath", color: .blue) }
            }

            Toggle(isOn: $autoCheck) {
                Label { Text("Automatically check for updates") } icon: { SettingIcon(symbol: "clock.arrow.circlepath", color: .green) }
            }
            .onChange(of: autoCheck) { UpdaterManager.shared.automaticChecks = $0 }

            Button {
                WhatsNewWindowController.showNow()
            } label: {
                Label { Text("What's New") } icon: { SettingIcon(symbol: "sparkles", color: .pink) }
            }
            .buttonStyle(.plain)
        }

        Section {
            LabeledContent {
                Button("Report") { open("\(repo)/issues/new?labels=bug") }
            } label: {
                Label { Text("Report a Bug") } icon: { SettingIcon(symbol: "ladybug.fill", color: .red) }
            }

            LabeledContent {
                Button("Request") { open("\(repo)/issues/new?labels=enhancement") }
            } label: {
                Label { Text("Request a Feature") } icon: { SettingIcon(symbol: "lightbulb.fill", color: .orange) }
            }

            LabeledContent {
                Button("Star") { open(repo) }
            } label: {
                Label { Text("Star on GitHub") } icon: { SettingIcon(symbol: "star.fill", color: .yellow) }
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Found a bug or have an idea? KRIT is open source, everything goes straight to GitHub.")
        }

        Section("Links") {
            LabeledContent {
                Button("Open") { open(repo) }
            } label: {
                Label { Text("Source on GitHub") } icon: { SettingIcon(symbol: "chevron.left.forwardslash.chevron.right", color: .gray) }
            }
        }

        Section {
            EmptyView()
        } footer: {
            Text("© 2026 Leonardo Candiani. MIT License, free and open source.")
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Permissions

/// One place to see and grant every privacy permission KRIT uses. Each row shows
/// the brand icon chip, the permission name, a live status pill, and a deep link
/// straight to the matching System Settings pane. Status is re-read on appear and
/// whenever the app becomes active again (returning from System Settings).
private struct PermissionsForm: View {
    @State private var screen: PermissionStatus = .denied
    @State private var accessibility: PermissionStatus = .denied
    @State private var camera: PermissionStatus = .notDetermined
    @State private var microphone: PermissionStatus = .notDetermined

    var body: some View {
        Section {
            PermissionRow(
                title: "Screen Recording", detail: "Capture your screen for screenshots and recordings.",
                symbol: "rectangle.dashed.badge.record", color: .red, status: screen
            ) { PermissionsManager.openScreenRecordingSettings() }

            PermissionRow(
                title: "Accessibility", detail: "Lets KRIT run global shortcuts and overlay gestures.",
                symbol: "accessibility", color: .blue, status: accessibility
            ) { PermissionsManager.openAccessibilitySettings() }

            PermissionRow(
                title: "Camera", detail: "Record a camera overlay alongside your screen.",
                symbol: "camera.fill", color: .green, status: camera
            ) { PermissionsManager.openCameraSettings() }

            PermissionRow(
                title: "Microphone", detail: "Capture your voice while recording.",
                symbol: "mic.fill", color: .orange, status: microphone
            ) { PermissionsManager.openMicrophoneSettings() }
        } header: {
            Text("Privacy")
        } footer: {
            Text("KRIT only asks for what a capture tool needs. Use Open Settings to grant a permission in System Settings; the status here refreshes when you come back.")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        screen = PermissionsManager.screenRecordingStatus
        accessibility = PermissionsManager.accessibilityStatus
        camera = PermissionsManager.cameraStatus
        microphone = PermissionsManager.microphoneStatus
    }
}

/// A single permission row: brand icon chip + name/description on the left, a live
/// status pill and an Open Settings button trailing.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let status: PermissionStatus
    let onOpen: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                StatusPill(status: status)
                Button("Open Settings", action: onOpen)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                SettingIcon(symbol: symbol, color: color)
            }
        }
    }
}

/// Compact permission status using one semantic dot instead of a painted badge.
private struct StatusPill: View {
    let status: PermissionStatus

    private var label: String {
        switch status {
        case .granted:       return "Granted"
        case .denied:        return "Denied"
        case .notDetermined: return "Not determined"
        }
    }

    private var tint: Color {
        switch status {
        case .granted:       return .green
        case .denied:        return .red
        case .notDetermined: return .secondary
        }
    }

    var body: some View {
        KritStatusLabel(title: label, color: tint)
    }
}

// MARK: - Device discovery

struct PreferencesDeviceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    static let systemDefault = PreferencesDeviceOption(id: "", name: "System Default")
}

struct PreferencesDeviceCatalog: Equatable, Sendable {
    let microphones: [PreferencesDeviceOption]
    let cameras: [PreferencesDeviceOption]
}

protocol PreferencesDeviceLoading: Sendable {
    func load() async -> PreferencesDeviceCatalog
}

/// AVFoundation discovery can touch hardware services. Keep it off the render
/// path and return only immutable strings across the concurrency boundary.
struct SystemPreferencesDeviceLoader: PreferencesDeviceLoading {
    func load() async -> PreferencesDeviceCatalog {
        await Task.detached(priority: .utility) {
            PreferencesDeviceCatalog(
                microphones: Self.microphones(),
                cameras: Self.cameras()
            )
        }.value
    }

    private static func microphones() -> [PreferencesDeviceOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        return devices(deviceTypes, mediaType: .audio)
    }

    private static func cameras() -> [PreferencesDeviceOption] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            deviceTypes = [.builtInWideAngleCamera, .externalUnknown]
        }
        return devices(deviceTypes, mediaType: .video)
    }

    private static func devices(
        _ types: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType
    ) -> [PreferencesDeviceOption] {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: mediaType,
            position: .unspecified
        )
        .devices
        .sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
        .map { PreferencesDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        return [.systemDefault] + discovered
    }
}

@MainActor
final class PreferencesDeviceModel: ObservableObject {
    @Published private(set) var microphones: [PreferencesDeviceOption] = [.systemDefault]
    @Published private(set) var cameras: [PreferencesDeviceOption] = [.systemDefault]

    private let loader: any PreferencesDeviceLoading
    private var refreshGeneration: UInt64 = 0

    init(loader: any PreferencesDeviceLoading = SystemPreferencesDeviceLoader()) {
        self.loader = loader
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let catalog = await loader.load()
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        microphones = catalog.microphones
        cameras = catalog.cameras
    }
}
