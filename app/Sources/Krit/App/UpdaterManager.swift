import AppKit
import Sparkle

/// Owns the single Sparkle updater for the app. The feed URL and EdDSA public
/// key live in Info.plist (SUFeedURL / SUPublicEDKey); the appcast is the
/// repo-root appcast.xml served raw from GitHub, and each release's DMG is
/// signed by scripts/release/release.sh. Menu item: "Check for Updates…" in
/// the status bar menu.
@MainActor
final class UpdaterManager: NSObject {

    static let shared = UpdaterManager()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        // startingUpdater: true arms the scheduled background checks
        // (SUEnableAutomaticChecks in Info.plist suppresses the opt-in prompt).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    /// User-initiated check (menu item). Shows Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension UpdaterManager: SPUUpdaterDelegate {
    /// Test hook: scripts/release/test-update-local.sh points the updater at a
    /// localhost appcast by writing the KritFeedURLOverride default. Production
    /// never sets it, so the Info.plist SUFeedURL wins.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "KritFeedURLOverride")
    }
}
