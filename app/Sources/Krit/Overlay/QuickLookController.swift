import AppKit

/// Space-preview companion for the Quick Access overlay (CleanShot "Space" look).
///
/// Pressing Space over a card no longer grows the card itself; it opens a LARGE
/// preview window that floats right next to the card (anchored to the card's
/// screen frame, to its side with a flip when it would clip the screen edge),
/// with a dark "Space" pill below it as the toggle hint, exactly like the Finder
/// Quick Look affordance the owner referenced. Space again, Esc, or the cursor
/// leaving the card closes it; it is a pure toggle.
///
/// The preview is its OWN borderless glass window so it can sit beside the small
/// card without disturbing the card's frame, the gesture machine, or the stack
/// layout. The card stays exactly where it is. `QuickLookController` owns this
/// companion window and tracks which card it belongs to, so the card's
/// hover/key-focus logic and Esc routing keep working through one shared shim.
@MainActor
final class QuickLookController {

    static let shared = QuickLookController()

    /// The card the preview currently belongs to, if any.
    private(set) weak var owner: AnyObject?

    /// The live companion preview window (nil while closed).
    private var previewWindow: SpacePreviewWindow?

    private init() {}

    /// A preview is open right now.
    var isOpen: Bool { owner != nil }

    /// True only when the preview belongs to `card`.
    func isOpen(forOwner card: AnyObject) -> Bool {
        owner != nil && owner === card
    }

    /// Open the Space preview for `card`: a large preview of `image` anchored to
    /// `cardFrame` (global AppKit coords), on `screen`. Idempotent for the same
    /// card; opening for a different card swaps to it.
    func open(owner card: AnyObject, image: NSImage, cardFrame: NSRect, screen: NSScreen?) {
        if owner === card, previewWindow != nil { return }
        close()
        owner = card
        let window = SpacePreviewWindow(image: image, cardFrame: cardFrame, screen: screen)
        window.present()
        previewWindow = window
    }

    /// Close the preview if `card` owns it (no-op otherwise).
    func close(owner card: AnyObject) {
        guard owner === card else { return }
        close()
    }

    /// Toggle the preview for `card`: open if closed (or owned by someone else),
    /// close if `card` already owns it.
    func toggle(owner card: AnyObject, image: NSImage, cardFrame: NSRect, screen: NSScreen?) {
        if isOpen(forOwner: card) {
            close()
        } else {
            open(owner: card, image: image, cardFrame: cardFrame, screen: screen)
        }
    }

    /// Tear the preview down unconditionally.
    func close() {
        previewWindow?.dismiss()
        previewWindow = nil
        owner = nil
    }
}

// MARK: - Companion preview window

/// Borderless glass window that shows a large preview of the card's image with a
/// "Space" pill below it. Positioned beside the card it previews; never takes key
/// (so it can't break the card's keyboard ownership while Space/Esc keep routing
/// through the card's own monitor).
@MainActor
private final class SpacePreviewWindow: NSWindow {

    /// Largest the preview may grow on screen (fraction of the visible frame).
    private static let maxFraction: CGFloat = 0.62
    /// Gap between the card and the preview, and breathing room from screen edges.
    private static let gap: CGFloat = 16
    private static let screenInset: CGFloat = 24
    /// Pill metrics, sized to read like the Finder Quick Look hint.
    private static let pillHeight: CGFloat = 30
    private static let pillGap: CGFloat = 12

    init(image: NSImage, cardFrame: NSRect, screen: NSScreen?) {
        let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? cardFrame
        let imageSize = SpacePreviewWindow.previewSize(for: image, in: vf)
        let origin = SpacePreviewWindow.anchoredOrigin(
            previewSize: imageSize, cardFrame: cardFrame, visibleFrame: vf
        )
        let frame = NSRect(origin: origin, size: imageSize)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar          // above the .floating card and its siblings
        hasShadow = true
        ignoresMouseEvents = true   // a hint, not an interactive surface
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none         // never leak into a capture

        buildContent(image: image, screenVisibleFrame: vf)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Preview image box: image aspect preserved, capped at `maxFraction` of the
    /// visible frame (minus the inset) so a big shot never overflows the screen.
    private static func previewSize(for image: NSImage, in vf: NSRect) -> NSSize {
        let aspect = (image.size.width > 0 && image.size.height > 0)
            ? image.size.width / image.size.height
            : 16.0 / 10.0
        let maxW = (vf.width - 2 * screenInset) * maxFraction
        let maxH = (vf.height - 2 * screenInset) * maxFraction
        var w = maxW
        var h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }
        return NSSize(width: round(w), height: round(h))
    }

    /// Place the preview beside the card: to the side with more room (the card
    /// sits at a screen corner), flipping when it would clip, then clamp to the
    /// screen. Vertically it centers on the card so the small card and the big
    /// preview read as a pair.
    private static func anchoredOrigin(previewSize: NSSize, cardFrame: NSRect, visibleFrame vf: NSRect) -> NSPoint {
        let roomRight = vf.maxX - cardFrame.maxX
        let roomLeft = cardFrame.minX - vf.minX
        var x: CGFloat
        if roomRight >= roomLeft {
            x = cardFrame.maxX + gap                            // preview to the right of the card
            if x + previewSize.width > vf.maxX - screenInset {
                x = cardFrame.minX - gap - previewSize.width    // flip to the left
            }
        } else {
            x = cardFrame.minX - gap - previewSize.width        // preview to the left of the card
            if x < vf.minX + screenInset {
                x = cardFrame.maxX + gap                        // flip to the right
            }
        }
        x = min(max(x, vf.minX + screenInset), vf.maxX - screenInset - previewSize.width)

        // Center vertically on the card, then keep room below for the pill.
        var y = cardFrame.midY - previewSize.height / 2
        let bottomFloor = vf.minY + screenInset + pillGap + pillHeight
        y = min(max(y, bottomFloor), vf.maxY - screenInset - previewSize.height)
        return NSPoint(x: round(x), y: round(y))
    }

    private func buildContent(image: NSImage, screenVisibleFrame vf: NSRect) {
        let radius = ChromeFactory.Radius.panel

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = radius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.55
        container.layer?.shadowRadius = 40
        container.layer?.shadowOffset = CGSize(width: 0, height: -12)
        contentView = container

        // Rounded image fill (aspect-fit; the window is already image-shaped so
        // there is no letterbox, the .resizeAspect just guards odd rounding).
        let imageView = NSView(frame: container.bounds)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = radius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = KritColors.overlayContainerFill.cgColor
        imageView.layer?.contents = image.bestCGImage
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        container.addSubview(imageView)

        // Hairline so the preview reads against bright wallpapers (the card uses
        // the same border treatment).
        let border = NSView(frame: container.bounds)
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1.0
        border.layer?.borderColor = KritColors.overlayBorder.cgColor
        container.addSubview(border)

        // "Space" pill, centered under the preview. Lives in its OWN tiny window so
        // it can sit below the image window's bottom edge (a subview can't escape
        // the parent window's frame). Tracked + torn down with this window.
        spawnPill(belowPreviewFrame: frame, screenVisibleFrame: vf)

        alphaValue = 0
    }

    /// The "Space" hint pill. A separate borderless window placed just below the
    /// preview, so the pill can sit OUTSIDE the image window's bounds (as in the
    /// reference). Centered on the preview, clamped to the screen.
    private var pillWindow: NSWindow?
    private func spawnPill(belowPreviewFrame previewFrame: NSRect, screenVisibleFrame vf: NSRect) {
        let text = "Space"
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        // Size from the field's own fitting size: measuring via NSString.size
        // under-counted and clipped the last glyph ("Spac").
        let sizer = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attrs))
        sizer.sizeToFit()
        let textW = ceil(sizer.frame.width)
        let textH = ceil(sizer.frame.height)
        let padX: CGFloat = 18
        let pillW = textW + padX * 2
        let pillH = Self.pillHeight

        var pillX = previewFrame.midX - pillW / 2
        pillX = min(max(pillX, vf.minX + Self.screenInset), vf.maxX - Self.screenInset - pillW)
        var pillY = previewFrame.minY - Self.pillGap - pillH
        if pillY < vf.minY + Self.screenInset { pillY = vf.minY + Self.screenInset }

        let win = NSWindow(
            contentRect: NSRect(x: round(pillX), y: round(pillY), width: round(pillW), height: pillH),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.sharingType = .none

        // Glass pill (HUD blur pre-26) instead of a flat black slab, matching the
        // capsule the system's own Quick Look chrome shows.
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: pillW, height: pillH))
        let glass = ChromeFactory.backing(frame: pill.bounds, cornerRadius: pillH / 2)
        pill.addSubview(glass)

        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attrs))
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.frame = NSRect(x: padX, y: (pillH - textH) / 2, width: textW, height: textH)
        pill.addSubview(label)
        win.contentView = pill
        win.alphaValue = 0
        win.orderFrontRegardless()
        pillWindow = win
    }

    /// Fade the preview (and its pill) in beside the card.
    func present() {
        orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.12 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.pillWindow?.animator().alphaValue = 1
        }
    }

    /// Fade out and tear down both windows.
    func dismiss() {
        let pill = pillWindow
        pillWindow = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            pill?.animator().alphaValue = 0
        }, completionHandler: {
            pill?.orderOut(nil)
            self.orderOut(nil)
        })
    }
}
