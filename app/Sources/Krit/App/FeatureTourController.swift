import AppKit
import TourKit

/// Six-slide "Feature Tour" built on the TourKit package. It is ADDITIVE: it
/// complements, never replaces, `WelcomeWindowController` (which polls the
/// Screen Recording permission, logic a plain slideshow can't host) and
/// `WhatsNewWindowController` (which covers app updates, not the tour).
///
/// Follows the style of `WhatsNewWindowController` / `WelcomeWindowController`:
/// a strong reference is held while the tour window is up (TourKit's window
/// has no other owner and would deallocate otherwise), released on finish
/// or close; the app's dynamic activation policy is flipped to `.accessory`
/// before presenting and restored after, the same dance the welcome wizard does.
@MainActor
final class FeatureTourController {

    private var tourWindowController: TourKitWindowController?
    private var presentedWindow: NSWindow?

    /// Resolve the tour artwork from the SAME bundle the rest of the app trusts,
    /// NOT `Bundle.module`. SPM's synthesized `Bundle.module` only probes the
    /// `.app` root (where `build-app.sh` does NOT place the resource bundle — it
    /// copies it into `Contents/Resources/`) and the original `/tmp` build path,
    /// so it `fatalError`s on every end-user install and after any reboot that
    /// wipes `/tmp`. `CaptureEngine.resourceBundle` documents that exact hazard
    /// and resolves from `Contents/Resources/Krit_KritKit.bundle` first, where the
    /// processed Tour PNGs actually live.
    private static let imageBundle = CaptureEngine.resourceBundle

    private static let pages: [TourPage] = [
        TourPage(
            imageName: "tour-capture", imageBundle: FeatureTourController.imageBundle,
            title: "Capture anything",
            description: "Grab an area, a window, or the full screen instantly, with the shortcuts you already know."
        ),
        TourPage(
            imageName: "tour-annotate", imageBundle: FeatureTourController.imageBundle,
            title: "Annotate like a pro",
            description: "Arrows, text, numbered steps, and blur, right in the built-in editor."
        ),
        TourPage(
            imageName: "tour-record", imageBundle: FeatureTourController.imageBundle,
            title: "Record your screen",
            description: "Screen recordings with a camera bubble, click ripples, and a keystroke HUD."
        ),
        TourPage(
            imageName: "tour-zoom", imageBundle: FeatureTourController.imageBundle,
            title: "Zoom while you present",
            description: "Live presentation zoom that follows your cursor. Toggle it with ⌘⇧8."
        ),
        TourPage(
            imageName: "tour-draw", imageBundle: FeatureTourController.imageBundle,
            title: "Draw on your screen",
            description: "Live annotation over anything on your screen while you present. Toggle it with ⌘⇧D."
        ),
        TourPage(
            imageName: "tour-history", imageBundle: FeatureTourController.imageBundle,
            title: "Everything in one place",
            description: "History and Quick Access keep every capture within reach."
        ),
    ]

    /// Presents the tour unconditionally. The menu's "Feature Tour" item
    /// calls this, regardless of `Settings.hasSeenFeatureTour`.
    func show() {
        present()
    }

    /// Presents the tour once per install, gated on `Settings.hasSeenFeatureTour`.
    func showOnFirstRunIfNeeded() {
        guard !Settings.hasSeenFeatureTour else { return }
        present()
    }

    private func present() {
        // Already up: bring it forward instead of stacking a second
        // TourKitWindowController/window.
        if let presentedWindow {
            presentedWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let controller = TourKitWindowController()
        tourWindowController = controller
        let window = controller.present(
            pages: Self.pages,
            onFinish: { [weak self] in self?.finish() },
            onClose: { [weak self] in self?.finish() }
        )
        presentedWindow = window
        // TourKit builds a borderless card window, invisible to the app's
        // "is a real window still open" heuristic. Opt it in so an unrelated
        // window closing while the tour is up (notably the welcome wizard on the
        // first-run chain) can't drop the app to `.prohibited` and pull the Dock
        // icon out from under a visible tour.
        NSApp.addActivationPersistentWindow(window)
    }

    /// Runs on both the finish button (last page) and the close (checkmark)
    /// button; TourKit invokes whichever fires before the window is dismissed,
    /// so the window is still visible here and must be passed as the excluded
    /// window to the activation-policy check.
    private func finish() {
        Settings.hasSeenFeatureTour = true
        let closingWindow = presentedWindow
        presentedWindow = nil
        if let closingWindow {
            NSApp.removeActivationPersistentWindow(closingWindow)
        }
        // Close the window ourselves BEFORE releasing the controller. TourKit runs
        // this callback *before* its own `dismiss` (`{ [weak self] in self?.close() }`),
        // so dropping our only strong reference first would let ARC deallocate the
        // controller synchronously and turn that weak `self?.close()` into a no-op,
        // stranding the borderless tour window on screen (it has no OS close box).
        tourWindowController?.close()
        tourWindowController = nil
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: closingWindow)
    }
}
