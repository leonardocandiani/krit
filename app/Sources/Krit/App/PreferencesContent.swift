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

    /// Tabs already rebuilt on `KritSettingsGroup`/`KritSettingsRow`. The rest
    /// stay on SwiftUI's grouped `Form` until they are converted, so the two
    /// styles can coexist while the migration runs instead of every tab having
    /// to land in one commit.
    private static let nativeStyled: Set<PreferencesTab> = [
        .general, .capture, .recording, .preview, .editor, .shortcuts,
        .permissions, .about,
    ]

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

        let shell: AnyView = nativeStyled.contains(tab)
            ? AnyView(KritPreferencesShell(tab: tab) { root })
            : AnyView(PreferencesSection(tab: tab) { root })

        return AnyView(shell.id(tab.rawValue).kritTheme())
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

/// The shell for tabs rebuilt on KRIT's own settings vocabulary: the same
/// wayfinding header, then groups drawn with the app's tokens instead of the
/// system's grouped `Form`, which paints over them.
private struct KritPreferencesShell<Content: View>: View {
    let tab: PreferencesTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PreferencesHeader(tab: tab)
            ZStack(alignment: .top) {
                KritSettingsPage { content }
                KritEdgeDissolve()
            }
        }
        .background(Color.kritContent)
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
        KritSettingsGroup("Appearance") {
            KritSettingsRow("Theme",
                            symbol: "circle.lefthalf.filled",
                            tint: Color(.systemIndigo),
                            subtitle: "Match the system, or always use Light or Dark.") {
                Picker("", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: appearance) { newValue in
                    Settings.appearanceMode = newValue
                    AppearanceMode.applyCurrent()
                }
            }
        }

        KritSettingsGroup("Startup") {
            KritSettingsRow("Launch KRIT at login",
                            symbol: "power",
                            tint: Color(.systemGreen),
                            subtitle: "Start the menu bar app automatically.") {
                Toggle("", isOn: $launchAtLogin)
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
        }

        KritSettingsGroup("Sounds") {
            KritSettingsRow("Play sounds",
                            symbol: "speaker.wave.2.fill",
                            tint: Color(.systemPink),
                            subtitle: "Capture, copy, save, and recording cues.") {
                Toggle("", isOn: $playSounds)
                    .onChange(of: playSounds) { Settings.playSounds = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Capture sound",
                            symbol: "waveform",
                            tint: Color(.systemPurple),
                            subtitle: "Shutter cue played on every capture.") {
                Picker("", selection: $captureSound) {
                    ForEach(CaptureSoundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .fixedSize()
                .onChange(of: captureSound) { newValue in
                    Settings.captureSoundStyle = newValue
                    // Play the chosen cue so picking is tactile.
                    SoundManager.play(newValue == .classic ? .captureClassic : .captureBigSur)
                }
            }
        }

        KritSettingsGroup("Menu bar") {
            KritSettingsRow("Show menu bar icon",
                            symbol: "menubar.rectangle",
                            tint: Color(.systemBlue),
                            subtitle: "Hidden? Reopen KRIT from Spotlight or Finder to get back here.") {
                Toggle("", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { Settings.showMenuBarIcon = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Hide desktop icons while capturing",
                            symbol: "menubar.dock.rectangle",
                            tint: Color(.systemGray)) {
                Toggle("", isOn: $hideDesktopIcons)
                    .onChange(of: hideDesktopIcons) { Settings.hideDesktopIconsWhileCapturing = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Show Dock icon during capture",
                            symbol: "dock.rectangle",
                            tint: Color(.systemTeal),
                            subtitle: "KRIT briefly appears in the Dock while you pick an area.") {
                Toggle("", isOn: $showDockDuringCapture)
                    .onChange(of: showDockDuringCapture) { Settings.showDockIconDuringCapture = $0 }
            }
        }

        KritSettingsGroup("After capture") {
            KritSettingsRow("Copy screenshots to clipboard",
                            symbol: "doc.on.clipboard.fill",
                            tint: Color(.systemBlue),
                            subtitle: "New screenshots are copied automatically.") {
                Toggle("", isOn: $copyToClipboard)
                    .onChange(of: copyToClipboard) { Settings.afterCaptureCopyToClipboard = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Save automatically",
                            symbol: "square.and.arrow.down.fill",
                            tint: Color(.systemGreen),
                            subtitle: "Write each capture to the save location without asking.") {
                Toggle("", isOn: $saveAutomatically)
                    .onChange(of: saveAutomatically) { Settings.afterCaptureSaveAutomatically = $0 }
            }
        }

        KritSettingsGroup("Selection") {
            KritSettingsRow("Magnifier only while holding Control",
                            symbol: "plus.magnifyingglass",
                            tint: .kritAccent,
                            subtitle: "Keeps the crosshair light; hold ⌃ for the loupe and guides.") {
                Toggle("", isOn: $magnifierOnControl)
                    .onChange(of: magnifierOnControl) { Settings.magnifierRequiresControl = $0 }
            }
        }

        KritSettingsGroup("Presentation zoom") {
            KritSettingsRow("Feel",
                            symbol: "wand.and.stars",
                            tint: Color(.systemCyan),
                            subtitle: "Precise stops dead, Natural eases in, Bouncy overshoots.") {
                Picker("", selection: $zoomFeel) {
                    ForEach(PresentationZoomFeel.allCases) { feel in
                        Text(feel.label).tag(feel)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: zoomFeel) { Settings.presentationZoomFeel = $0 }
            }
            KritRowDivider()
            KritSliderRow(title: "Smoothing",
                          symbol: "water.waves",
                          tint: Color(.systemCyan),
                          value: $zoomSmoothness,
                          range: 0...1,
                          readout: String(format: "%.2f s",
                                          PresentationZoomController.responseTime(forSmoothness: zoomSmoothness)),
                          caption: "How long each move takes. Applies live while a zoom is running.")
                .onChange(of: zoomSmoothness) { Settings.presentationZoomSmoothness = $0 }
            KritRowDivider()
            KritSliderRow(title: "Zoom level",
                          symbol: "plus.magnifyingglass",
                          tint: Color(.systemCyan),
                          value: $zoomLevel,
                          range: PresentationZoomController.minLevel...PresentationZoomController.maxLevel,
                          step: 0.25,
                          readout: String(format: "%g×", zoomLevel),
                          caption: "The first zoom-in jumps straight to this level.")
                .onChange(of: zoomLevel) { Settings.presentationZoomLevel = $0 }
        }

        KritSettingsGroup("Screen annotation") {
            KritSettingsRow("Keep drawing after closing",
                            symbol: "scribble",
                            tint: Color(.systemOrange),
                            subtitle: "Closing the toolbar keeps your marks on screen. Off clears them.") {
                Toggle("", isOn: $annotationKeepOnExit)
                    .onChange(of: annotationKeepOnExit) { Settings.liveAnnotationKeepOnExit = $0 }
            }
        }

        KritSettingsGroup("AI") {
            KritSettingsRow("Cloud AI features",
                            symbol: "sparkles",
                            tint: Color(.systemPurple),
                            subtitle: "On-device AI always works. This adds cloud features through your own Claude subscription; KRIT never stores an API key.") {
                Toggle("", isOn: $aiCloudEnabled)
                    .onChange(of: aiCloudEnabled) { Settings.aiCloudEnabled = $0 }
            }
            if aiCloudEnabled && !claudeFound {
                KritRowDivider()
                KritSettingsNote("Claude Code not found. Install it, run claude setup-token, then reopen this window.",
                                 symbol: "exclamationmark.triangle.fill",
                                 tint: Color(.systemOrange))
            }
        }

        KritSettingsGroup("Automation") {
            KritSettingsRow("Allow scripting and the krit CLI",
                            symbol: "terminal",
                            tint: Color(.systemTeal),
                            subtitle: "Off by default. On, KRIT answers krit:// URLs and runs a local command port, letting other apps on this Mac capture through it.") {
                Toggle("", isOn: $automationEnabled)
                    .onChange(of: automationEnabled) {
                        Settings.automationEnabled = $0
                        (NSApp.delegate as? AppDelegate)?.refreshAutomationPort()
                    }
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
        KritSettingsGroup("Export format") {
            KritSettingsRow("File format",
                            symbol: "doc.fill",
                            tint: Color(.systemBlue),
                            subtitle: "Applied to every new screenshot.") {
                Picker("", selection: $format) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                    Text("WebP").tag("webp")
                    Text("PDF").tag("pdf")
                }
                .fixedSize()
                .onChange(of: format) { Settings.screenshotFormat = $0 }
            }
            KritRowDivider()
            KritSliderRow(title: "JPEG quality",
                          symbol: "slider.horizontal.3",
                          tint: Color(.systemIndigo),
                          value: $jpegQuality,
                          range: 0.1...1.0,
                          readout: "\(Int(jpegQuality * 100))%")
                .onChange(of: jpegQuality) { Settings.jpegQuality = $0 }
        }

        KritSettingsGroup("Countdown") {
            KritSettingsRow("Self-timer",
                            symbol: "timer",
                            tint: Color(.systemOrange),
                            subtitle: "Counts 3, 2, 1 before the capture fires. Esc cancels.") {
                Picker("", selection: $countdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .fixedSize()
                .onChange(of: countdown) { Settings.captureCountdownSeconds = $0 }
            }
        }

        KritSettingsGroup("Window capture") {
            WindowBackgroundPicker(selection: $windowBackground)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .onChange(of: windowBackground) { Settings.windowCaptureBackground = $0 }
        }

        KritSettingsGroup("Save location") {
            KritSettingsRow("Screenshots folder",
                            symbol: "folder.fill",
                            tint: Color(.systemBlue),
                            subtitle: saveLocation) {
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
        KritSettingsGroup("Video") {
            KritSettingsRow("Quality",
                            symbol: "video.fill",
                            tint: Color(.systemRed),
                            subtitle: "Max keeps more detail for demos but makes larger files.") {
                Picker("", selection: $quality) {
                    Text("Balanced").tag("balanced")
                    Text("High").tag("high")
                    Text("Max").tag("max")
                }
                .fixedSize()
                .onChange(of: quality) { Settings.recordingQuality = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Frame rate", symbol: "speedometer", tint: Color(.systemOrange)) {
                Picker("", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .fixedSize()
                .onChange(of: fps) { Settings.recordingFPS = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Show cursor", symbol: "cursorarrow", tint: Color(.systemGray)) {
                Toggle("", isOn: $showsCursor)
                    .onChange(of: showsCursor) { Settings.recordingShowsCursor = $0 }
            }
        }

        KritSettingsGroup("Audio") {
            KritSettingsRow("Record system audio",
                            symbol: "speaker.wave.2.fill",
                            tint: Color(.systemPurple),
                            subtitle: "Excludes KRIT's own sounds to avoid feedback.") {
                Toggle("", isOn: $systemAudio)
                    .onChange(of: systemAudio) { Settings.recordingSystemAudio = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Record microphone", symbol: "mic.fill", tint: Color(.systemPink)) {
                Toggle("", isOn: $microphone)
                    .onChange(of: microphone) { Settings.recordingMicrophone = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Microphone", symbol: "mic.circle.fill", tint: Color(.systemPink)) {
                DevicePicker(options: devices.microphones, selection: $micDevice)
                    .onChange(of: micDevice) { Settings.recordingMicrophoneDeviceID = $0 }
            }
        }

        KritSettingsGroup("Webcam") {
            KritSettingsRow("Webcam overlay",
                            symbol: "camera.fill",
                            tint: Color(.systemTeal),
                            subtitle: "Circular picture in picture in the corner. Needs camera permission.") {
                Toggle("", isOn: $webcam)
                    .onChange(of: webcam) { Settings.recordingWebcam = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Camera", symbol: "camera.circle.fill", tint: Color(.systemTeal)) {
                DevicePicker(options: devices.cameras, selection: $webcamDevice)
                    .onChange(of: webcamDevice) { Settings.recordingWebcamDeviceID = $0 }
            }
        }

        KritSettingsGroup("Clicks and keystrokes") {
            KritSettingsRow("Highlight mouse clicks",
                            symbol: "cursorarrow.click",
                            tint: Color(.systemBlue)) {
                Toggle("", isOn: $showsClicks)
                    .onChange(of: showsClicks) { Settings.recordingShowsClicks = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Show pressed keys",
                            symbol: "keyboard.fill",
                            tint: Color(.systemIndigo),
                            subtitle: "Keystroke HUD inside the recording. Needs Accessibility permission.") {
                Toggle("", isOn: $showsKeystrokes)
                    .onChange(of: showsKeystrokes) { Settings.recordingShowsKeystrokes = $0 }
            }
        }

        KritSettingsGroup("GIF export") {
            KritSettingsRow("Frame rate", symbol: "speedometer", tint: Color(.systemOrange)) {
                Picker("", selection: $gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                }
                .fixedSize()
                .onChange(of: gifFPS) { Settings.recordingGIFFPS = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Max size",
                            symbol: "arrow.up.left.and.arrow.down.right",
                            tint: Color(.systemGreen),
                            subtitle: "Largest dimension in pixels; frames downscale to fit.") {
                Picker("", selection: $gifMaxDimension) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("1024 px").tag(1024)
                }
                .fixedSize()
                .onChange(of: gifMaxDimension) { Settings.recordingGIFMaxDimension = $0 }
            }
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
///
/// The label lives on the settings row now, so this is only the control: it sits
/// where every other trailing control does instead of carrying its own title.
private struct DevicePicker: View {
    let options: [PreferencesDeviceOption]
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.name).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 190)
        .fixedSize()
    }
}

// MARK: - Preview overlay

private struct PreviewForm: View {
    @State private var size = Settings.overlaySize
    @State private var timeout = Settings.overlayTimeout
    @State private var onLeft = Settings.overlayOnLeft

    var body: some View {
        KritSettingsGroup("Size") {
            KritSettingsRow("Preview size",
                            symbol: "arrow.up.left.and.arrow.down.right",
                            tint: Color(.systemIndigo)) {
                Picker("", selection: $size) {
                    ForEach(OverlaySize.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .fixedSize()
                .onChange(of: size) { Settings.overlaySize = $0 }
            }
        }

        KritSettingsGroup("Behaviour") {
            KritSettingsRow("Auto dismiss", symbol: "clock.fill", tint: Color(.systemOrange)) {
                Picker("", selection: $timeout) {
                    Text("3 seconds").tag(3.0)
                    Text("6 seconds").tag(6.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("Never").tag(-1.0)
                }
                .fixedSize()
                .onChange(of: timeout) { Settings.overlayTimeout = $0 }
            }
            KritRowDivider()
            KritSettingsRow("Screen side",
                            symbol: "arrow.left.and.right.square.fill",
                            tint: Color(.systemTeal)) {
                Picker("", selection: $onLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: onLeft) { Settings.overlayOnLeft = $0 }
            }
        }
    }
}

// MARK: - Editor

private struct EditorForm: View {
    @State private var lineWidth = Settings.annotationLineWidth
    @State private var defaultTemplate = Settings.defaultTemplateName
    @State private var chromeOpacity = Settings.editorChromeOpacity

    private var templateOptions: [(String, String)] {
        var options: [(String, String)] = [("None", "")]
        options += TemplateStore.all().map { ($0.name, $0.name) }
        return options
    }

    var body: some View {
        KritSettingsGroup("Annotations") {
            KritSliderRow(title: "Default thickness",
                          symbol: "pencil.tip",
                          tint: Color(.systemRed),
                          value: $lineWidth,
                          range: 1...20,
                          step: 1,
                          readout: "\(Int(lineWidth)) pt",
                          caption: "New arrows, lines, and shapes start at this stroke width.")
                .onChange(of: lineWidth) { Settings.annotationLineWidth = $0 }
        }

        KritSettingsGroup("Appearance") {
            KritSliderRow(title: "Chrome opacity",
                          symbol: "circle.lefthalf.filled",
                          tint: Color(.systemIndigo),
                          value: $chromeOpacity,
                          range: 0.35...1,
                          step: 0.05,
                          readout: "\(Int((chromeOpacity * 100).rounded()))%",
                          caption: "How solid the editor's panel and stage are. Lower lets your wallpaper read through; over a busy desktop, raise it until the controls are comfortable again.")
                .onChange(of: chromeOpacity) {
                    Settings.editorChromeOpacity = $0
                    // Open editors restyle live; without this the slider only
                    // takes effect the next time one is opened, which reads as
                    // the setting not working.
                    NotificationCenter.default.post(name: Settings.editorChromeOpacityChanged, object: nil)
                }
        }

        KritSettingsGroup("Templates") {
            KritSettingsRow("Default template",
                            symbol: "doc.on.doc.fill",
                            tint: Color(.systemPurple),
                            subtitle: "Applied automatically to new captures.") {
                Picker("", selection: $defaultTemplate) {
                    ForEach(templateOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .fixedSize()
                .onChange(of: defaultTemplate) {
                    TemplateStore.setDefault(name: $0.isEmpty ? nil : $0)
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsForm: View {
    var body: some View {
        KritSettingsGroup("Screenshots") {
            shortcutRow("All-in-one", "square.dashed.inset.filled", Color(.systemBlue), .allInOne)
            KritRowDivider()
            shortcutRow("Capture area", "rectangle.dashed", .kritAccent, .captureArea)
            KritRowDivider()
            shortcutRow("Capture window", "macwindow", Color(.systemTeal), .captureWindow)
            KritRowDivider()
            shortcutRow("Capture full screen", "rectangle.on.rectangle", Color(.systemIndigo), .captureFullscreen)
            KritRowDivider()
            shortcutRow("Repeat last area", "arrow.counterclockwise", Color(.systemOrange), .capturePreviousArea)
            KritRowDivider()
            shortcutRow("Snap and paste", "doc.on.clipboard", Color(.systemGreen), .snapAndPaste)
            KritRowDivider()
            shortcutRow("Toggle capture history", "clock.arrow.circlepath", Color(.systemPurple), .captureHistory)
        }

        KritSettingsGroup("Recording") {
            shortcutRow("Record screen", "record.circle", Color(.systemRed), .recordScreen)
        }

        KritSettingsGroup("Tools") {
            shortcutRow("Capture text (OCR)", "text.viewfinder", Color(.systemPink), .ocrCapture)
            KritRowDivider()
            shortcutRow("Scrolling capture", "scroll", Color(.systemBrown), .scrollingCapture)
            KritRowDivider()
            shortcutRow("Pick colour", "eyedropper", Color(.systemMint), .pickColor)
            KritRowDivider()
            shortcutRow("Annotate screen", "scribble", Color(.systemOrange), .liveAnnotation)
        }

        KritSettingsGroup("Presentation zoom") {
            shortcutRow("Toggle presentation zoom", "plus.magnifyingglass", Color(.systemCyan), .presentationZoom)
            KritRowDivider()
            shortcutRow("Zoom in", "plus.magnifyingglass", Color(.systemCyan), .presentationZoomIn)
            KritRowDivider()
            shortcutRow("Zoom out", "minus.magnifyingglass", Color(.systemCyan), .presentationZoomOut)
        }

        KritSettingsGroup {
            KritSettingsRow("Restore defaults",
                            symbol: "arrow.uturn.backward",
                            tint: Color(.systemGray),
                            subtitle: "Click any shortcut above to change it. They stay global while KRIT runs.") {
                Button("Restore") {
                    KeyboardShortcuts.reset(KeyboardShortcuts.Name.allCapture)
                }
            }
        }
    }

    /// One shortcut row: glyph tile and title on the left, the recorder field on
    /// the right, in the same 44pt rhythm as every other settings row.
    @ViewBuilder
    private func shortcutRow(_ title: String, _ symbol: String, _ tint: Color, _ name: KeyboardShortcuts.Name) -> some View {
        KritSettingsRow(title, symbol: symbol, tint: tint) {
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
/// The macOS Settings glyph tile: a filled rounded square with a white symbol.
///
/// The colour is categorical, not decorative: it is how a row is found again
/// after the first read, the same way System Settings and Shortcuts use it. That
/// is also the line between this and the pastel icon-tile cliché, which tints
/// the glyph in a wash of its own colour and means nothing. Here the fill is
/// full strength and the glyph is always white.
private struct SettingIcon: View {
    let symbol: String
    let color: Color

    init(symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
            // A hairline keeps the tile from bleeding into a same-hue surface
            // and gives the fill an edge instead of a soft stop.
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: KritColors.hairlineWidth)
            )
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
        // The identity block leads: app mark, version, one line on what it is.
        // No group label above it, because a header would only repeat the name
        // sitting right below it in 22pt.
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage
                ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
                ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("KRIT")
                    .kritType(.largeTitle)
                    .foregroundStyle(Color.kritTextStrong)
                Text("Version \(version) (\(build))")
                    .kritType(.body)
                    .foregroundStyle(Color.kritTextSecondary)
                Text("Screenshots and screen recording for macOS.")
                    .kritType(.caption)
                    .foregroundStyle(Color.kritTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .kritCardSurface()

        KritSettingsGroup("Updates") {
            KritSettingsRow("Software updates",
                            symbol: "arrow.triangle.2.circlepath",
                            tint: Color(.systemBlue)) {
                Button("Check") { UpdaterManager.shared.checkForUpdates() }
            }
            KritRowDivider()
            KritSettingsRow("Check automatically",
                            symbol: "clock.arrow.circlepath",
                            tint: Color(.systemGreen)) {
                Toggle("", isOn: $autoCheck)
                    .onChange(of: autoCheck) { UpdaterManager.shared.automaticChecks = $0 }
            }
            KritRowDivider()
            KritSettingsRow("What's new",
                            symbol: "sparkles",
                            tint: Color(.systemPink)) {
                Button("Show") { WhatsNewWindowController.showNow() }
            }
        }

        KritSettingsGroup("Feedback") {
            KritSettingsRow("Report a bug",
                            symbol: "ladybug.fill",
                            tint: Color(.systemRed),
                            subtitle: "Opens a pre-filled issue on GitHub.") {
                Button("Report") { open("\(repo)/issues/new?labels=bug") }
            }
            KritRowDivider()
            KritSettingsRow("Request a feature",
                            symbol: "lightbulb.fill",
                            tint: Color(.systemOrange)) {
                Button("Request") { open("\(repo)/issues/new?labels=enhancement") }
            }
            KritRowDivider()
            KritSettingsRow("Star on GitHub",
                            symbol: "star.fill",
                            tint: Color(.systemYellow)) {
                Button("Star") { open(repo) }
            }
        }

        KritSettingsGroup("Source") {
            KritSettingsRow("KRIT on GitHub",
                            symbol: "chevron.left.forwardslash.chevron.right",
                            tint: Color(.systemGray),
                            subtitle: "© 2026 Leonardo Candiani. MIT licence, free and open source.") {
                Button("Open") { open(repo) }
            }
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
        KritSettingsGroup("Privacy") {
            PermissionRow(
                title: "Screen Recording", detail: "Capture your screen for screenshots and recordings.",
                symbol: "rectangle.dashed.badge.record", color: Color(.systemRed), status: screen
            ) { PermissionsManager.openScreenRecordingSettings() }
            KritRowDivider()
            PermissionRow(
                title: "Accessibility", detail: "Lets KRIT run global shortcuts and overlay gestures.",
                symbol: "accessibility", color: Color(.systemBlue), status: accessibility
            ) { PermissionsManager.openAccessibilitySettings() }
            KritRowDivider()
            PermissionRow(
                title: "Camera", detail: "Record a camera overlay alongside your screen.",
                symbol: "camera.fill", color: Color(.systemGreen), status: camera
            ) { PermissionsManager.openCameraSettings() }
            KritRowDivider()
            PermissionRow(
                title: "Microphone", detail: "Capture your voice while recording.",
                symbol: "mic.fill", color: Color(.systemOrange), status: microphone
            ) { PermissionsManager.openMicrophoneSettings() }
            KritRowDivider()
            KritSettingsNote("KRIT only asks for what a capture tool needs. The status here refreshes when you come back from System Settings.",
                             symbol: "hand.raised.fill",
                             tint: Color(.systemGray))
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
        KritSettingsRow(title, symbol: symbol, tint: color, subtitle: detail) {
            HStack(spacing: 10) {
                StatusPill(status: status)
                Button("Open Settings", action: onOpen)
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
