import AppKit

@MainActor
extension NSApplication {
    /// Windows that must count as "persistent" for activation-policy purposes even
    /// though their style mask is borderless. The only opt-in today is the TourKit
    /// tour window, a borderless card with none of the titled/closable masks the
    /// heuristic below keys off. Held weakly so a closed window drops out on its own.
    private static let activationOptInWindows = NSHashTable<NSWindow>.weakObjects()

    /// Opt a non-standard (borderless) window into the "still open" heuristic, so
    /// an unrelated window closing while it is visible does not flip the app to
    /// `.prohibited` under it.
    func addActivationPersistentWindow(_ window: NSWindow) {
        Self.activationOptInWindows.add(window)
    }

    func removeActivationPersistentWindow(_ window: NSWindow) {
        Self.activationOptInWindows.remove(window)
    }

    func restoreBackgroundOnlyActivationPolicyIfNeeded(excluding closingWindow: NSWindow? = nil) {
        guard !hasVisiblePersistentWindow(excluding: closingWindow) else {
            return
        }

        setActivationPolicy(.prohibited)
    }

    private func hasVisiblePersistentWindow(excluding closingWindow: NSWindow?) -> Bool {
        windows.contains { window in
            if let closingWindow, window === closingWindow {
                return false
            }

            guard window.isVisible, !window.isMiniaturized else {
                return false
            }

            if window is PinnedWindow {
                return true
            }

            if Self.activationOptInWindows.allObjects.contains(where: { $0 === window }) {
                return true
            }

            let persistentMasks: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
            return !window.styleMask.intersection(persistentMasks).isEmpty
        }
    }
}
