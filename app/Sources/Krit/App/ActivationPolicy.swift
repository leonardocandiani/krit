import AppKit

@MainActor
extension NSApplication {
    /// Windows that must count as "persistent" for activation-policy purposes even
    /// though their style mask is borderless. Held weakly so a closed window drops
    /// out on its own.
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

    func isActivationPersistentWindow(_ window: NSWindow) -> Bool {
        Self.activationOptInWindows.allObjects.contains { $0 === window }
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

            if isActivationPersistentWindow(window) {
                return true
            }

            // AppKit's internal status-bar windows can carry `.resizable` after
            // menu tracking even though they are not user-facing content. Their
            // lifecycle must never keep this accessory app activated. A custom
            // status-level surface that does need that behavior must opt in above.
            if window.level.rawValue >= NSWindow.Level.statusBar.rawValue {
                return false
            }

            let persistentMasks: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
            return !window.styleMask.intersection(persistentMasks).isEmpty
        }
    }
}
