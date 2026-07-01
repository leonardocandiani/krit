import AppKit

/// Coordinate-space conversions shared across the app so every caller agrees on
/// the same math. Screen capture and window automation hand out top-left rects
/// (CoreGraphics display space); AppKit's global space is bottom-left. Keeping the
/// flip in one place stops the two copies in AppDelegate and AutomationService
/// from drifting, which would land captures on the wrong pixels.
enum CoordinateSpace {

    /// Convert a top-left origin rect (CG display space) into AppKit's bottom-left
    /// global space by flipping Y about the primary display's height.
    static func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
        let primaryHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first)?.frame.height ?? rect.maxY
        let appKitY = primaryHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: appKitY, width: rect.width, height: rect.height)
    }
}
