import AppKit
import Sparkle

/// Owns the single Sparkle updater for the app. The feed URL and EdDSA public
/// key live in Info.plist (SUFeedURL / SUPublicEDKey); the appcast is the
/// repo-root appcast.xml served raw from GitHub, and each release's DMG is
/// signed by scripts/release/release.sh. Menu item: "Updates…" in
/// the status bar menu.
@MainActor
final class UpdaterManager: NSObject {

    static let shared = UpdaterManager()

    private var controller: SPUStandardUpdaterController!
    private var updateWindowController: UpdateWindowController?

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

    /// Auto-update preference, surfaced in About so callers never touch Sparkle
    /// types directly.
    var automaticChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// User-initiated update entry point (menu item / Settings).
    func checkForUpdates() {
        presentUpdateWindow()
    }

    /// Manual CTA from KRIT's update window. Sparkle still owns the check,
    /// download and installation UI.
    func performManualUpdateCheck() {
        controller.checkForUpdates(nil)
    }

    private func presentUpdateWindow() {
        let content = UpdateWindowContent.current(automaticChecks: automaticChecks)
        if let existing = updateWindowController {
            existing.update(content: content)
            existing.show()
            return
        }

        let windowController = UpdateWindowController(
            content: content,
            actions: UpdateWindowActions(
                checkNow: { [weak self] in self?.performManualUpdateCheck() },
                setAutomaticChecks: { [weak self] enabled in self?.automaticChecks = enabled },
                showWhatsNew: { WhatsNewWindowController.showNow() }
            )
        )
        windowController.onClose = { [weak self, weak windowController] in
            guard let windowController, self?.updateWindowController === windowController else { return }
            self?.updateWindowController = nil
        }
        updateWindowController = windowController
        windowController.show()
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
