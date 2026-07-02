import AppKit

/// Temporarily hides/shows desktop icons by toggling Finder's CreateDesktop preference.
enum DesktopIconsManager {

    private static var isHidden = false
    private static let finderAppID = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString

    static var desktopIconsVisible: Bool {
        guard let value = CFPreferencesCopyAppValue(createDesktopKey, finderAppID) else { return true }
        return (value as? Bool) ?? true
    }

    static func toggle() {
        desktopIconsVisible ? hide() : show()
    }

    // Capture-scoped icon hiding no longer paints anything on screen: every
    // capture path excludes Finder's windows from the SCK grab itself
    // (CaptureEngine.captureContentFilter), so the icons vanish from the SHOT
    // while the real desktop stays untouched. The old per-screen wallpaper
    // cover window is gone: on an aerial dark wallpaper its source image was
    // the LIGHT poster variant, so every fullscreen/OCR/QR/scrolling capture
    // visibly flipped the desktop's theme for the duration of the grab.

    static func hide() {
        setCreateDesktop(false)
        isHidden = true
    }

    static func show() {
        setCreateDesktop(true)
        isHidden = false
    }

    private static func setCreateDesktop(_ value: Bool) {
        // Use native CFPreferences instead of 'defaults write' shell script
        CFPreferencesSetValue(createDesktopKey, value as CFPropertyList, finderAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(finderAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        // Gently restart Finder natively
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            // terminate() asks politely, allowing Finder to finish file copies.
            // If it fails to terminate, forceTerminate() kills it instantly.
            if !finder.terminate() {
                finder.forceTerminate()
            }
            
            // Wait slightly and relaunch Finder so the desktop reappears
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                    let config = NSWorkspace.OpenConfiguration()
                    config.promptsUserIfNeeded = false
                    NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
            }
        }
    }
}
