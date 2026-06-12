import AppKit

/// Central UserDefaults store for all user-configurable settings.
enum Settings {

    private static let defaults = UserDefaults.standard
    private static let autoSaveLocationKey = "autoSaveLocation"

    static var defaultAutoSaveLocation: String {
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop.path
        }
        return ("~/Desktop" as NSString).expandingTildeInPath
    }

    // MARK: - First Launch

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    static var didRequestScreenRecordingPermission: Bool {
        get { defaults.bool(forKey: "didRequestScreenRecordingPermission") }
        set { defaults.set(newValue, forKey: "didRequestScreenRecordingPermission") }
    }

    static var didConfirmScreenRecordingPermission: Bool {
        get { defaults.bool(forKey: "didConfirmScreenRecordingPermission") }
        set { defaults.set(newValue, forKey: "didConfirmScreenRecordingPermission") }
    }

    static var didShowReadyToast: Bool {
        get { defaults.bool(forKey: "didShowReadyToast") }
        set { defaults.set(newValue, forKey: "didShowReadyToast") }
    }

    // MARK: - Overlay

    /// Auto-dismiss timeout in seconds. -1 = never dismiss automatically.
    static var overlayTimeout: Double {
        get {
            let v = defaults.double(forKey: "overlayTimeout")
            return v == 0 ? 6 : v
        }
        set { defaults.set(newValue, forKey: "overlayTimeout") }
    }

    /// true = show overlay on the left side (default), false = right side
    static var overlayOnLeft: Bool {
        get {
            if defaults.object(forKey: "overlayOnLeft") == nil { return true }
            return defaults.bool(forKey: "overlayOnLeft")
        }
        set { defaults.set(newValue, forKey: "overlayOnLeft") }
    }

    /// Size of the Quick Access overlay card (Small / Medium / Large). Default .medium.
    static var overlaySize: OverlaySize {
        get { OverlaySize(rawValue: defaults.string(forKey: "overlaySize") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "overlaySize") }
    }

    // MARK: - General

    /// Espessura padrão das anotações (setas etc.); lembra o último valor usado.
    static var annotationLineWidth: Double {
        get {
            let v = defaults.double(forKey: "annotationLineWidth")
            return v == 0 ? 8 : v
        }
        set { defaults.set(newValue, forKey: "annotationLineWidth") }
    }

    static var playSounds: Bool {
        get {
            if defaults.object(forKey: "playSounds") == nil { return true }
            return defaults.bool(forKey: "playSounds")
        }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    static var captureSoundStyle: CaptureSoundStyle {
        get { CaptureSoundStyle(rawValue: defaults.string(forKey: "captureSoundStyle") ?? "") ?? .bigSur }
        set { defaults.set(newValue.rawValue, forKey: "captureSoundStyle") }
    }

    /// Appearance the app forces on every window, independent of the rest of the
    /// system. `.system` follows the OS (no override), matching how Raycast's
    /// "Follow System Appearance" behaves.
    static var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearanceMode") }
    }

    static var showMenuBarIcon: Bool {
        get {
            if defaults.object(forKey: "showMenuBarIcon") == nil { return true }
            return defaults.bool(forKey: "showMenuBarIcon")
        }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }

    static var hideDesktopIconsWhileCapturing: Bool {
        get { defaults.bool(forKey: "hideDesktopIconsWhileCapturing") }
        set { defaults.set(newValue, forKey: "hideDesktopIconsWhileCapturing") }
    }

    // MARK: - After Capture

    static var afterCaptureShowOverlay: Bool {
        get {
            if defaults.object(forKey: "afterCaptureShowOverlay") == nil { return true }
            return defaults.bool(forKey: "afterCaptureShowOverlay")
        }
        set { defaults.set(newValue, forKey: "afterCaptureShowOverlay") }
    }

    static var afterCaptureCopyToClipboard: Bool {
        get {
            if defaults.object(forKey: "afterCaptureCopyToClipboard") == nil { return true }
            return defaults.bool(forKey: "afterCaptureCopyToClipboard")
        }
        set { defaults.set(newValue, forKey: "afterCaptureCopyToClipboard") }
    }

    static var afterCaptureSaveAutomatically: Bool {
        get { defaults.bool(forKey: "afterCaptureSaveAutomatically") }
        set { defaults.set(newValue, forKey: "afterCaptureSaveAutomatically") }
    }

    static var autoSaveLocation: String {
        get {
            let v = defaults.string(forKey: autoSaveLocationKey) ?? ""
            guard !v.isEmpty else { return defaultAutoSaveLocation }
            return normalizedWritableDirectoryPath(v) ?? defaultAutoSaveLocation
        }
        set { _ = setAutoSaveLocation(newValue) }
    }

    @discardableResult
    static func setAutoSaveLocation(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: autoSaveLocationKey)
            return true
        }
        guard let normalized = normalizedWritableDirectoryPath(trimmed) else { return false }
        defaults.set(normalized, forKey: autoSaveLocationKey)
        return true
    }

    private static func normalizedWritableDirectoryPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }

        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url.path
    }

    // MARK: - Screenshots

    static var screenshotFormat: String {
        get { defaults.string(forKey: "screenshotFormat") ?? "png" }
        set { defaults.set(newValue, forKey: "screenshotFormat") }
    }

    static var jpegQuality: Double {
        get {
            let v = defaults.double(forKey: "jpegQuality")
            return v == 0 ? 0.95 : v
        }
        set { defaults.set(newValue, forKey: "jpegQuality") }
    }

    // MARK: - Recording

    static var recordingFPS: Int {
        get {
            let value = defaults.integer(forKey: "recordingFPS")
            return value == 60 ? 60 : 30
        }
        set { defaults.set(newValue == 60 ? 60 : 30, forKey: "recordingFPS") }
    }

    static var recordingQuality: String {
        get {
            let value = defaults.string(forKey: "recordingQuality") ?? "high"
            return ["balanced", "high", "max"].contains(value) ? value : "high"
        }
        set {
            let value = ["balanced", "high", "max"].contains(newValue) ? newValue : "high"
            defaults.set(value, forKey: "recordingQuality")
        }
    }

    static var recordingShowsCursor: Bool {
        get {
            if defaults.object(forKey: "recordingShowsCursor") == nil { return true }
            return defaults.bool(forKey: "recordingShowsCursor")
        }
        set { defaults.set(newValue, forKey: "recordingShowsCursor") }
    }

    static var recordingSystemAudio: Bool {
        get { defaults.bool(forKey: "recordingSystemAudio") }
        set { defaults.set(newValue, forKey: "recordingSystemAudio") }
    }

    static var recordingMicrophone: Bool {
        get { defaults.bool(forKey: "recordingMicrophone") }
        set { defaults.set(newValue, forKey: "recordingMicrophone") }
    }

    static var recordingMicrophoneDeviceID: String {
        get { defaults.string(forKey: "recordingMicrophoneDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "recordingMicrophoneDeviceID") }
    }

    /// Include a circular webcam PiP in the recording. Default false.
    static var recordingWebcam: Bool {
        get { defaults.bool(forKey: "recordingWebcam") }
        set { defaults.set(newValue, forKey: "recordingWebcam") }
    }

    /// Unique ID of the webcam device used for the PiP. Empty = system default.
    static var recordingWebcamDeviceID: String {
        get { defaults.string(forKey: "recordingWebcamDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "recordingWebcamDeviceID") }
    }

    /// Show a ripple highlight on mouse clicks during recording. Default false.
    static var recordingShowsClicks: Bool {
        get { defaults.bool(forKey: "recordingShowsClicks") }
        set { defaults.set(newValue, forKey: "recordingShowsClicks") }
    }

    /// Show a keystroke HUD for pressed keys during recording. Default false.
    static var recordingShowsKeystrokes: Bool {
        get { defaults.bool(forKey: "recordingShowsKeystrokes") }
        set { defaults.set(newValue, forKey: "recordingShowsKeystrokes") }
    }

    /// Target frame rate when downsampling a recording to GIF. Default 15.
    static var recordingGIFFPS: Int {
        get {
            let v = defaults.integer(forKey: "recordingGIFFPS")
            return v == 0 ? 15 : v
        }
        set { defaults.set(newValue, forKey: "recordingGIFFPS") }
    }

    /// Largest dimension (px) of a GIF export; frames downscale to fit. Default 800.
    static var recordingGIFMaxDimension: Int {
        get {
            let v = defaults.integer(forKey: "recordingGIFMaxDimension")
            return v == 0 ? 800 : v
        }
        set { defaults.set(newValue, forKey: "recordingGIFMaxDimension") }
    }

    // MARK: - Capture

    /// Seconds to count down (3-2-1) before firing a capture. 0 = off (default behavior). Clamped 0...10.
    static var captureCountdownSeconds: Int {
        get { defaults.integer(forKey: "captureCountdownSeconds") }
        set { defaults.set(min(max(newValue, 0), 10), forKey: "captureCountdownSeconds") }
    }

    /// Supersampling multiplier applied on top of the display's native pixel
    /// scale when grabbing a screenshot. `.standard` (1×) captures exactly the
    /// screen's physical pixels; `.high` (2×) and `.maximum` (3×) render the grab
    /// into a larger buffer so small captures carry more pixels and stay smooth
    /// when enlarged. Higher settings make bigger files and do NOT invent detail
    /// beyond what the screen shows, they bake in high-quality upscaling.
    static var captureScale: CaptureScale {
        get { CaptureScale(rawValue: defaults.string(forKey: "captureScale") ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "captureScale") }
    }

    /// What the editor opens a window capture with. Defaults to the current
    /// desktop wallpaper so window shots arrive composed out of the box.
    static var windowCaptureBackground: WindowCaptureBackground {
        get { WindowCaptureBackground(rawValue: defaults.string(forKey: "windowCaptureBackground") ?? "") ?? .systemWallpaper }
        set { defaults.set(newValue.rawValue, forKey: "windowCaptureBackground") }
    }

    // MARK: - All-in-One

    /// Last All-in-One selection rect, in AppKit global screen coordinates
    /// (bottom-left, anchored to the primary display). Persisted via
    /// NSStringFromRect so it survives relaunch; the All-in-One controller
    /// revalidates it against the current screens before reusing it.
    static var allInOneRect: CGRect? {
        get {
            guard let raw = defaults.string(forKey: "allInOneRect"), !raw.isEmpty else { return nil }
            let rect = NSRectFromString(raw)
            return rect.isEmpty ? nil : rect
        }
        set {
            if let rect = newValue, !rect.isEmpty {
                defaults.set(NSStringFromRect(rect), forKey: "allInOneRect")
            } else {
                defaults.removeObject(forKey: "allInOneRect")
            }
        }
    }

    // MARK: - Presets

    /// Encoded `[EditTemplate]` blob, owned/serialized by TemplateStore. nil = none saved yet.
    /// The user-facing name for an EditTemplate is "preset"; the storage key keeps its
    /// original spelling so existing saved data decodes unchanged.
    static var editTemplatesData: Data? {
        get { defaults.data(forKey: "editTemplatesData") }
        set { defaults.set(newValue, forKey: "editTemplatesData") }
    }

    /// Name of the preset auto-applied to new captures. Empty = no default preset.
    static var defaultTemplateName: String {
        get { defaults.string(forKey: "defaultTemplateName") ?? "" }
        set { defaults.set(newValue, forKey: "defaultTemplateName") }
    }

    /// Name of the preset currently selected in the background sidebar dropdown.
    /// Empty = no named preset selected (a custom, unsaved background).
    static var activePresetName: String {
        get { defaults.string(forKey: "activePresetName") ?? "" }
        set { defaults.set(newValue, forKey: "activePresetName") }
    }

    /// Encoded `ScreenshotBackgroundOptions` captured right before the last preset
    /// was applied, so "Apply Previous Settings" can restore it. nil = none recorded.
    static var previousBackgroundData: Data? {
        get { defaults.data(forKey: "previousBackgroundData") }
        set { defaults.set(newValue, forKey: "previousBackgroundData") }
    }

    // MARK: - Snap Presets

    /// Encoded `[SnapPreset]` blob, owned/serialized by PresetStore. nil = none saved yet.
    static var snapPresetsData: Data? {
        get { defaults.data(forKey: "snapPresetsData") }
        set { defaults.set(newValue, forKey: "snapPresetsData") }
    }

    // MARK: - Snap and Paste

    /// Whether KRIT has already opened the Accessibility pane for the auto-paste
    /// grant. Lets Snap & Paste nudge once instead of reopening Settings on every
    /// shot while access is missing.
    static var didPromptAccessibilityForPaste: Bool {
        get { defaults.bool(forKey: "didPromptAccessibilityForPaste") }
        set { defaults.set(newValue, forKey: "didPromptAccessibilityForPaste") }
    }
}

/// Screenshot capture density. The multiplier rides on top of the display's
/// native pixel scale (so `.high` on a 2× Retina display grabs at 4× the point
/// size). `.standard` is a pixel-exact native grab; higher tiers supersample so
/// small captures keep more pixels and enlarge cleanly, at the cost of file size.
enum CaptureScale: String, CaseIterable, Identifiable {
    case standard, high, maximum
    var id: String { rawValue }

    /// Factor applied over the native pixel scale during capture.
    var multiplier: CGFloat {
        switch self {
        case .standard: return 1
        case .high:     return 2
        case .maximum:  return 3
        }
    }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .high:     return "High (2×)"
        case .maximum:  return "Maximum (3×)"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Native screen resolution, exact pixels."
        case .high:     return "2× supersampling, sharper when enlarged, larger files."
        case .maximum:  return "3× supersampling, the crispest enlargements, largest files."
        }
    }
}

/// The three appearance choices, mirroring the macOS System Settings control:
/// follow the system, or pin Light / Dark regardless of the OS setting.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// The NSAppearance to force, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the stored preference to the whole app. Setting NSApp.appearance to
    /// nil hands control back to the system. AdaptiveColors reads effectiveAppearance,
    /// so every window restyles on the next draw.
    @MainActor static func applyCurrent() {
        NSApp.appearance = Settings.appearanceMode.nsAppearance
    }
}
