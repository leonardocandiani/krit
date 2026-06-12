import AppKit
import CoreImage
import QuartzCore

/// Post-capture floating thumbnail with quick action buttons.
/// Position and dismiss timeout are controlled via Preferences → Settings.
@MainActor
final class QuickAccessOverlay {

    /// `screen` is the display the capture happened on; the card stacks, peeks and
    /// parks on THAT screen, not `NSScreen.main`. Pass nil only from contexts with
    /// no capture screen (falls back to the main display).
    /// How a new card enters the screen.
    /// - slide: slides in from the stack's screen edge (default; restore flows).
    /// - handoff: born invisible at its slot so the capture-flash "fly to tray"
    ///   ghost can land EXACTLY on it; `revealPendingHandoff(after:)` then fades
    ///   the card in under the ghost's fade-out. One continuous motion, the
    ///   ghost landing on top of an already-visible sliding card was the
    ///   "grows a little then snaps back" flicker.
    enum EntranceStyle { case slide, handoff }

    /// Shows a card and returns its settled slot frame (global AppKit coords),
    /// so the capture flash can target the real landing spot.
    @discardableResult
    static func show(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager,
                     screen: NSScreen? = nil, entrance: EntranceStyle = .slide) -> NSRect {
        let window = QuickAccessWindow(image: image, historyItem: historyItem, historyManager: historyManager,
                                       screen: screen, entrance: entrance)
        window.show()
        // For .handoff the card is parked invisible exactly at its slot, so the
        // frame IS the landing target. (.slide callers ignore the return.)
        return window.frame
    }

    /// Reveals the most recent handoff card once the fly-to-tray ghost lands.
    static func revealPendingHandoff(after delay: TimeInterval) {
        QuickAccessWindow.revealPendingHandoff(after: delay)
    }

    /// Shows a finished recording as a card in the same tray as screenshots. The
    /// card carries the real video file (drag-out, open, copy), a play badge + a
    /// mm:ss duration pill so it reads as video, and routes "Edit recording" back
    /// to `actions` (the engine's GIF/trim window). It shares the stack and the
    /// single standby handle with the screenshot cards. Recordings do NOT enter the
    /// screenshot history, so this path takes no HistoryItem.
    static func showVideo(url: URL, duration: Double, thumbnail: NSImage, isTemporary: Bool,
                          actions: RecordingResultActions?, screen: NSScreen? = nil) {
        let payload = VideoCardPayload(
            url: url, duration: max(duration, 0), thumbnail: thumbnail,
            isTemporary: isTemporary, actions: actions
        )
        let window = QuickAccessWindow(videoPayload: payload, screen: screen)
        window.show()
    }

    /// Tears down every open card (including parked ones, whose handle windows
    /// would otherwise outlive the session). Call on app termination so a parked
    /// card the user never restored doesn't leak its window + handle.
    static func tearDownAll() {
        QuickAccessWindow.tearDownAll()
    }
}

/// Everything a video card needs that a screenshot card doesn't: the real clip
/// on disk (dragged/opened/copied directly), its duration for the mm:ss badge,
/// the poster frame, whether the file is throwaway (so delete removes it), and a
/// link back to the recording engine for the GIF/trim editor.
@MainActor
struct VideoCardPayload {
    let url: URL
    let duration: Double
    let thumbnail: NSImage
    /// True only when the clip lives in a temp dir (delete should remove the file).
    /// Recordings auto-save into the user's folder, so this is false for them and
    /// delete only dismisses the card, leaving the saved file on disk.
    let isTemporary: Bool
    weak var actions: RecordingResultActions?
}

/// Card metrics derived from `Settings.overlaySize`. Every literal that drives
/// the overlay layout reads from here so all three sizes scale proportionally.
private struct OverlayMetrics {
    let thumbW, thumbH, progressH: CGFloat
    let cornerRadius: CGFloat
    let buttonSize, buttonMargin: CGFloat
    let pillHeight, pillGap, pillPadding: CGFloat
    let pillFontSize, cornerSymbolPointSize: CGFloat
    let shadowRadius: CGFloat

    static func make(for size: OverlaySize) -> OverlayMetrics {
        switch size {
        case .small:
            return OverlayMetrics(
                thumbW: 180, thumbH: 112, progressH: 2.0, cornerRadius: 10,
                buttonSize: 24, buttonMargin: 7,
                pillHeight: 24, pillGap: 8, pillPadding: 24,
                pillFontSize: 12, cornerSymbolPointSize: 11, shadowRadius: 24)
        case .medium:
            return OverlayMetrics(
                thumbW: 240, thumbH: 150, progressH: 2.0, cornerRadius: 12,
                buttonSize: 28, buttonMargin: 8,
                pillHeight: 28, pillGap: 8, pillPadding: 28,
                pillFontSize: 13, cornerSymbolPointSize: 12, shadowRadius: 30)
        case .large:
            return OverlayMetrics(
                thumbW: 320, thumbH: 200, progressH: 2.0, cornerRadius: 14,
                buttonSize: 32, buttonMargin: 9,
                pillHeight: 32, pillGap: 8, pillPadding: 32,
                pillFontSize: 14, cornerSymbolPointSize: 13, shadowRadius: 36)
        }
    }
}

@MainActor
private final class QuickAccessWindow: NSWindow {

    /// Keep strong refs so ARC doesn't deallocate while visible.
    fileprivate static var openWindows: [QuickAccessWindow] = []

    /// SP1: registered once. When the display arrangement or resolution changes
    /// (NSApplication.didChangeScreenParametersNotification) every visible stack
    /// and every parked handle gets reflowed onto valid positions of the new
    /// screens, so a resolution switch can't strand a card off-screen.
    private static var screenObserver: NSObjectProtocol?
    private static func registerScreenObserverIfNeeded() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { QuickAccessWindow.reflowForScreenChange() }
        }
    }

    /// SP1: reflow visible stacks and re-anchor parked handles after the screens
    /// change. Visible cards spring to their recomputed slots (reflowStack); parked
    /// cards get their handle moved to the bottom edge of a still-valid screen.
    fileprivate static func reflowForScreenChange() {
        reflowStack()
        for card in openWindows where card.isParked {
            card.repositionParkedHandle()
        }
    }

    // MARK: - B4 active-monitor follow
    //
    // The card (and the standby handle) should migrate to the monitor the user is
    // actually using, not stay on the one the shot happened on. We watch the global
    // mouse position; when the NSScreen under the cursor changes and STAYS there for
    // a debounce (so a quick pass across a monitor doesn't drag the stack along), we
    // re-point every open card's `cardScreen` and reflow onto the new display.
    //
    // A global mouse-move monitor needs no Accessibility permission. It exists only
    // while at least one card is open: installed on the first show, removed when the
    // last card closes (leaving it registered would leak a live monitor forever).

    private static var followMouseGlobalMonitor: Any?
    private static var followMouseLocalMonitor: Any?
    /// Pending migration target: the screen the cursor entered, waiting out the
    /// debounce. nil when the cursor sits on the stack's current screen.
    private static var pendingFollowScreen: NSScreen?
    private static var followDebounceTimer: Timer?
    /// How long the cursor must rest on a new monitor before the stack follows. Long
    /// enough that crossing a monitor on the way somewhere else doesn't migrate.
    private static let followDebounce: TimeInterval = 1.5

    /// Install the active-monitor follow monitors once, when the first card opens.
    /// Idempotent: a second card opening is a no-op.
    private static func installFollowMonitorIfNeeded() {
        guard followMouseGlobalMonitor == nil, followMouseLocalMonitor == nil else { return }
        followMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            MainActor.assumeIsolated { QuickAccessWindow.handleFollowMouseMoved() }
        }
        // Local monitor covers the case where KRIT itself is the active app (a card
        // borrowed the keyboard on hover), since the global monitor won't fire for
        // events already delivered to this process.
        followMouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            QuickAccessWindow.handleFollowMouseMoved()
            return event
        }
    }

    /// Remove the follow monitors and cancel any pending migration. Called when the
    /// last card closes so the monitor never outlives the cards it serves.
    private static func removeFollowMonitorIfIdle() {
        guard openWindows.isEmpty else { return }
        if let m = followMouseGlobalMonitor { NSEvent.removeMonitor(m); followMouseGlobalMonitor = nil }
        if let m = followMouseLocalMonitor { NSEvent.removeMonitor(m); followMouseLocalMonitor = nil }
        followDebounceTimer?.invalidate()
        followDebounceTimer = nil
        pendingFollowScreen = nil
    }

    /// The display the live stack currently lives on (any open card's screen). Used
    /// as the "from" side of a migration: if the cursor's screen already matches it,
    /// there's nothing to follow.
    private static func currentStackScreen() -> NSScreen? {
        openWindows.first?.overlayScreen
    }

    private static func handleFollowMouseMoved() {
        guard !openWindows.isEmpty else { return }
        let cursor = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) else { return }

        // Already on the stack's screen (or heading back to it): cancel any pending
        // migration and bail.
        if let current = currentStackScreen(),
           ObjectIdentifier(cursorScreen) == ObjectIdentifier(current) {
            if pendingFollowScreen != nil {
                pendingFollowScreen = nil
                followDebounceTimer?.invalidate()
                followDebounceTimer = nil
            }
            return
        }

        // Cursor is on a different screen than the stack. (Re)arm the debounce
        // toward THIS screen; a fresh target restarts the clock so only a screen the
        // cursor settles on triggers the move.
        if pendingFollowScreen.map({ ObjectIdentifier($0) }) != ObjectIdentifier(cursorScreen) {
            pendingFollowScreen = cursorScreen
            followDebounceTimer?.invalidate()
            followDebounceTimer = Timer.scheduledTimer(withTimeInterval: followDebounce, repeats: false) { _ in
                MainActor.assumeIsolated { QuickAccessWindow.commitFollowMigration() }
            }
        }
    }

    /// Debounce fired: migrate the stack to the screen the cursor settled on, unless
    /// a gesture is mid-flight (then retry once the gesture ends) or the cursor has
    /// since moved off that screen.
    private static func commitFollowMigration() {
        followDebounceTimer = nil
        guard let target = pendingFollowScreen, !openWindows.isEmpty else {
            pendingFollowScreen = nil
            return
        }
        // Confirm the cursor is still on the target before committing (it may have
        // moved on during the debounce).
        let cursor = NSEvent.mouseLocation
        guard target.frame.contains(cursor) else {
            pendingFollowScreen = nil
            return
        }
        // Never yank the stack mid-gesture: a live drag, an open zoom, or the
        // entrance slide owns the frame. Defer and re-arm a short retry so the
        // migration lands the moment the gesture settles.
        if openWindows.contains(where: { $0.isInteractionInFlight }) {
            followDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                MainActor.assumeIsolated { QuickAccessWindow.commitFollowMigration() }
            }
            return
        }
        guard let current = currentStackScreen(),
              ObjectIdentifier(target) != ObjectIdentifier(current) else {
            pendingFollowScreen = nil
            return
        }
        pendingFollowScreen = nil
        migrateAllCards(to: target)
    }

    /// Re-point every open card to `target` and reflow: visible cards spring to the
    /// new screen's slots, parked handles re-anchor on the new screen's bottom edge.
    private static func migrateAllCards(to target: NSScreen) {
        for card in openWindows where !card.isClosing {
            card.cardScreen = target
        }
        reflowStack()
        for card in openWindows where card.isParked {
            card.repositionParkedHandle(animated: true)
        }
    }

    private var dismissTimer: Timer?
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var scrollMonitor: Any?
    /// Screenshot cards carry both; video cards carry neither (a recording never
    /// enters the screenshot history). `videoPayload` is the discriminator: nil for
    /// a screenshot card, set for a video card.
    private let historyItem: HistoryItem?
    private let historyManager: HistoryManager?
    private let videoPayload: VideoCardPayload?
    private var isVideoCard: Bool { videoPayload != nil }
    private var image: NSImage
    /// The display the card lives on: resolved at creation to the monitor the MOUSE
    /// is on (NSEvent.mouseLocation), falling back to the capture's display, then
    /// the main display. The card positions, cascades, peeks and parks on this
    /// screen, so with multiple monitors the card always shows up where the user is
    /// looking, not stranded on the screen the shot happened to be taken on.
    /// Mutable so the active-monitor follow (B4) can migrate the whole stack to the
    /// display the user moved to; every geometry read goes through `overlayScreen`,
    /// which reads this, so re-pointing it and reflowing re-lays everything out.
    private var cardScreen: NSScreen?
    private var controlsOverlay: NSView?
    private weak var timeoutProgressLayer: CALayer?
    private weak var thumbView: DraggableImageView?
    private weak var backdropDimView: NSView?
    private var isHovered = false
    private var mouseInsideOverlay = false
    private var swipeAccumX: CGFloat = 0

    // O5 in-place zoom state. Named `isPreviewZoomed` because NSWindow already
    // declares a read-only `isZoomed` (window maximize state) we must not shadow.
    private var isPreviewZoomed = false
    private var preZoomFrame: NSRect?
    /// O5': global click monitor live only while zoomed, so a click anywhere
    /// outside the preview collapses it (a click on the preview is handled by the
    /// window's own mouseDown). Torn down in collapseZoom.
    private var zoomOutsideClickMonitor: Any?

    /// P1: small "Space" affordance pill shown near the card on hover (a hint that
    /// Space opens the big companion preview). Its own borderless window so it can
    /// sit just below the card; torn down with the card.
    private var spaceHintWindow: NSWindow?

    /// Layout metrics for the current size (A4). Set in init before super.init.
    private var metrics: OverlayMetrics

    // O4/O1 card-drag state (mouse-drag of the card background).
    private var cardDragStartMouse: NSPoint?
    private var cardDragStartOrigin: NSPoint?
    private var isCardDragging = false
    /// Live gesture mode for the harness probe (uiTestGestureState). Set by the
    /// continuous classifier while a card-owned drag runs; back to .none on release.
    /// The card is pinned to the anchor line, so there is no free-move mode here.
    private enum CardGestureMode: String { case none, deleting, standby, filedrag }
    private var currentGestureMode: CardGestureMode = .none

    /// True while this card owns the frame for a gesture or transition the B4
    /// monitor-follow migration must not interrupt: a live card drag, an in-place
    /// pinch/Space zoom, the entrance slide, or a tear-down. The migration defers
    /// while any open card reports this and retries once it clears.
    fileprivate var isInteractionInFlight: Bool {
        isCardDragging || isPreviewZoomed || isEntering || isClosing
            || cardDragStartMouse != nil
    }

    /// G1 directional drag feedback. The card signals where a release WOULD land
    /// (delete toward the edge, standby downward) while the drag is live, with a
    /// progress ramp so the user sees how close they are to confirming. nil while
    /// no drag is in flight.
    private enum DragIntent { case delete, standby }
    /// Distance the card must travel to CONFIRM a gesture on release. Delete needs
    /// ~40% of the card width toward the stack's edge; standby needs ~50pt down.
    /// Below these the gesture cancels and the card springs back to its slot.
    private var deleteConfirmDistance: CGFloat { metrics.thumbW * 0.40 }
    private let standbyConfirmDistance: CGFloat = 50
    /// How far INTO the screen (away from the anchor edge) the cursor must pull
    /// before a card-pinned gesture converts to a file-drag-out. Small, so a clear
    /// inward intent leaves the anchor line quickly while a tiny wobble stays put.
    private let fileDragConvertDistance: CGFloat = 10
    /// Lazily built tint + icon shown over the thumbnail during a delete/standby
    /// drag. Alpha ramps with gesture progress; torn down on drag end.
    private weak var dragHintTint: NSView?
    private weak var dragHintIcon: NSImageView?

    // O1 standby state.
    private var isParked = false
    private var parkedHandle: NSWindow?

    /// M1' entrance state: true while the slide-in spring runs, so the initial
    /// reflowStack (fired by show()) doesn't double-animate this fresh card off its
    /// in-flight position.
    private var isEntering = false
    private let entrance: QuickAccessOverlay.EntranceStyle
    /// The card waiting for the fly-to-tray ghost to land (handoff entrance).
    private static weak var pendingHandoffCard: QuickAccessWindow?

    init(image: NSImage, historyItem: HistoryItem, historyManager: HistoryManager, screen: NSScreen?,
         entrance: QuickAccessOverlay.EntranceStyle = .slide) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager
        self.videoPayload = nil
        self.cardScreen = Self.resolveActiveScreen(captureScreen: screen)
        self.entrance = entrance

        let metrics = OverlayMetrics.make(for: Settings.overlaySize)
        self.metrics = metrics
        // Use an integer value so the controls overlay placed above it sits on an integer pixel boundary
        // This prevents CoreAnimation from subpixel blending straight edges against the frosted glass.
        let totalH = metrics.thumbH + metrics.progressH

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: metrics.thumbW, height: totalH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none  // overlay must never leak into a capture

        buildContent()
        positionOverlay()
        installEventMonitors()
    }

    /// Video-card init: same window plumbing as the screenshot card, but the
    /// payload is a recording on disk instead of a HistoryItem. The poster frame
    /// stands in for `image` so zoom, the blurred backdrop and the drag-out ghost
    /// all work with no extra branching.
    init(videoPayload: VideoCardPayload, screen: NSScreen?,
         entrance: QuickAccessOverlay.EntranceStyle = .slide) {
        self.image = videoPayload.thumbnail
        self.historyItem = nil
        self.historyManager = nil
        self.videoPayload = videoPayload
        self.cardScreen = Self.resolveActiveScreen(captureScreen: screen)
        self.entrance = entrance

        let metrics = OverlayMetrics.make(for: Settings.overlaySize)
        self.metrics = metrics
        let totalH = metrics.thumbH + metrics.progressH

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: metrics.thumbW, height: totalH),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none

        buildContent()
        positionOverlay()
        installEventMonitors()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Keyboard
    //
    // Space/⌘C/⌘S/⌘E/Esc run through a LOCAL keyDown monitor. A local monitor only
    // sees keyDown when this process owns a key window, and a GLOBAL keyDown monitor
    // is a silent no-op without Accessibility/Input Monitoring (which KRIT doesn't
    // request), so the keystroke is unreachable while another app is key. The fix
    // (CleanShot's hover model): the card takes key ONLY while the cursor is over it
    // and gives focus back on exit. Hover is detected by a global MOUSE monitor,
    // which needs no permission. So focus is borrowed during a deliberate hover, not
    // stolen passively on appearance (the appearance-time activation was the real
    // bug, it yanked focus right after every capture).

    // MARK: - Event Monitors (bypass view hierarchy entirely)

    private func installEventMonitors() {
        // Keyboard: reached because the card is key while hovered (see grabKey()).
        // Consumes the event (returns nil) so it isn't double-handled.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            // O5': while zoomed the card owns the keyboard regardless of where the
            // cursor sits, so Space/Esc always collapse it (the hover gate would
            // otherwise drop the key the moment the mouse left the preview).
            guard self.isPreviewZoomed || (self.mouseInsideOverlay && self.cursorOwnsThisCard()) else { return event }
            return self.handleKey(event) ? nil : event
        }

        // Global mouse: detects hover crossings even while another app is active
        // (needs no permission, unlike a global key monitor). Hover-enter borrows
        // the keyboard; hover-exit returns it.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            guard inside != self.mouseInsideOverlay else { return }
            self.mouseInsideOverlay = inside
            DispatchQueue.main.async { self.updateHoverFocus(inside) }
        }

        // Local mouse: same hover tracking while the app IS active (global monitor
        // doesn't fire for events already delivered to this process).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            let inside = self.frame.contains(NSEvent.mouseLocation)
            if inside != self.mouseInsideOverlay {
                self.mouseInsideOverlay = inside
                self.updateHoverFocus(inside)
            }
            return event
        }

        // Swipe-to-dismiss: trackpad swipe toward nearest screen edge closes overlay
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            // A swipe is one continuous trackpad gesture: reset the accumulator at
            // its boundaries so leftovers from a short, sub-threshold flick never
            // carry into the next gesture. Without this the running total could sit
            // just under 60 and make the next scroll fire (or feel) wrong.
            if event.phase.contains(.began) || event.phase.contains(.ended)
                || event.momentumPhase.contains(.ended) {
                self.swipeAccumX = 0
            }
            guard self.cursorOwnsThisCard() else { return event }

            self.swipeAccumX += event.scrollingDeltaX
            let threshold: CGFloat = 60
            if abs(self.swipeAccumX) > threshold {
                let direction = self.swipeAccumX > 0 ? CGFloat(1) : CGFloat(-1)
                self.swipeAccumX = 0
                self.swipeDismiss(direction: direction)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    /// Hover changed: update the hover visuals/timer and borrow or return the
    /// keyboard. The card takes key only while the cursor sits on it (front-most),
    /// so Space/⌘-keys reach the local monitor without passively stealing focus on
    /// appearance. On exit the focus goes back to whoever was frontmost.
    private func updateHoverFocus(_ inside: Bool) {
        let owns = inside && cursorOwnsThisCard()
        setHovered(owns)
        // P1: the Space hint pill follows hover; the big companion preview closes
        // the moment the cursor leaves this card (toggle parity with the reference).
        setSpaceHintVisible(owns)
        if owns {
            grabKey()
        } else {
            QuickLookController.shared.close(owner: self)
            if isKeyWindow { releaseKey() }
        }
    }

    /// Borrow keyboard focus for this card. Escalates the LSUIElement app to
    /// .accessory and activates so the local keyDown monitor starts receiving keys.
    private func grabKey() {
        guard !isClosing, !isParked, !isKeyWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(self)
    }

    /// Return focus when the cursor leaves: resign key so the user's app regains
    /// the keyboard. The Space companion preview never takes key (it ignores mouse
    /// events), so there is nothing to keep alive here, hover-exit already closed it.
    private func releaseKey() {
        resignKey()
        // Only hand the app back when the cursor isn't on another card, moving
        // between overlapping cards (A6 cascade) just shifts key, no deactivate
        // flicker. Defer so a sibling's grabKey (fired from its own monitor) lands
        // first; if a card still owns the cursor, keep the app active.
        DispatchQueue.main.async {
            guard QuickAccessWindow.openWindows.allSatisfy({ !$0.cursorOwnsThisCard() }) else { return }
            NSApp.deactivate()
        }
    }

    /// Keyboard dispatch for the local keyDown monitor. Returns true when the key
    /// was handled (so the monitor consumes it). The caller gates on hover +
    /// front-most ownership.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 49 { togglePreview(); return true }  // Space → companion preview (P1)
        // Enter opens the recording in the default player (video cards only); on a
        // screenshot card it stays unhandled so the key falls through.
        if isVideoCard, !isPreviewZoomed, event.keyCode == 36 { openVideoAction(); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers, flags) {
        case ("c", .command):  copyAction();  return true
        case ("s", .command):  saveAction();  return true
        case ("e", .command):  editAction();  return true
        default: break
        }
        if event.keyCode == 53 { dismissAction(); return true }  // Esc
        return false
    }

    /// True when the cursor is over this card AND no other open card sits above it
    /// in z-order at that point. With the cascade overlap (A6) several frames can
    /// contain the same point; only the front-most one should react to mouse /
    /// keyboard, so a drag never moves or keys the wrong card.
    private func cursorOwnsThisCard() -> Bool {
        let cursor = NSEvent.mouseLocation
        guard frame.contains(cursor) else { return false }
        // NSApp.orderedWindows is front-to-back; the first overlay card under the
        // cursor is the visible (top) one.
        for window in NSApp.orderedWindows {
            guard let card = window as? QuickAccessWindow,
                  !card.isClosing, !card.isParked,
                  card.frame.contains(cursor) else { continue }
            return card === self
        }
        return true
    }

    /// Context-menu item helper: titled, targeted at this card.
    private func contextItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // Manual enabling: "Show in Finder"/"Open With" gray out until the
        // async history write lands on disk. Everything else stays enabled
        // (NSMenuItem defaults to isEnabled = true).
        menu.autoenablesItems = false

        if let payload = videoPayload {
            buildVideoMenuTop(menu, payload: payload)
        } else {
            buildScreenshotMenuTop(menu)
        }

        menu.addItem(.separator())
        // Size submenu (A4), switches the card size in place, persists in Settings.
        let sizeMenu = NSMenu()
        for size in OverlaySize.allCases {
            let mi = NSMenuItem(title: size.displayName, action: #selector(setOverlaySize(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = size.rawValue
            mi.state = (size == Settings.overlaySize ? .on : .off)
            sizeMenu.addItem(mi)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        // O1 standby for THIS card, then the O3 stack-wide toggle: send the
        // whole stack to standby or restore it, depending on whether anything
        // on this screen is parked.
        menu.addItem(contextItem("Temporarily Hide", #selector(temporarilyHideAction)))
        if QuickAccessWindow.hasParked(on: overlayScreen) {
            menu.addItem(contextItem("Restore all from standby", #selector(restoreAllAction)))
        } else {
            menu.addItem(contextItem("Send all to standby", #selector(standbyAllAction)))
        }

        menu.addItem(.separator())
        menu.addItem(contextItem("Delete", #selector(deleteAction)))
        menu.addItem(contextItem("Close", #selector(dismissAction)))

        guard let view = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Screenshot card context menu (top section above the shared size/standby/delete
    /// tail): annotate, pin, rotate, copy/save image, share, Finder/Open With.
    private func buildScreenshotMenuTop(_ menu: NSMenu) {
        menu.addItem(contextItem("Open Annotation Tool…", #selector(editAction), key: "e"))
        menu.addItem(contextItem("Pin to the Screen", #selector(pinAction)))
        menu.addItem(contextItem("Rotate Left", #selector(rotateLeftAction)))
        menu.addItem(contextItem("Rotate Right", #selector(rotateRightAction)))

        menu.addItem(.separator())
        // In-place zoom (O5), same as pressing Space, NOT QLPreviewPanel.
        menu.addItem(contextItem("Quick Look", #selector(quickLookAction)))

        menu.addItem(.separator())
        menu.addItem(contextItem("Copy", #selector(copyAction), key: "c"))
        menu.addItem(contextItem("Save", #selector(saveAction), key: "s"))
        menu.addItem(contextItem("Share…", #selector(shareAction)))

        menu.addItem(.separator())
        let imagePath = historyItem?.imagePath
        let fileOnDisk = imagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let finderItem = contextItem("Show in Finder", #selector(showInFinderAction))
        finderItem.isEnabled = fileOnDisk
        menu.addItem(finderItem)
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        if fileOnDisk, let imagePath {
            let submenu = openWithSubmenu(for: URL(fileURLWithPath: imagePath))
            openWithItem.submenu = submenu
            openWithItem.isEnabled = !submenu.items.isEmpty
        } else {
            openWithItem.isEnabled = false
        }
        menu.addItem(openWithItem)
    }

    /// Video card context menu (top section). Mirrors what the RecordingResultWindow
    /// offered (open, edit/GIF/trim, reveal) plus the card affordances (zoom, copy
    /// file, copy path), so nothing the result window reached is lost.
    private func buildVideoMenuTop(_ menu: NSMenu, payload: VideoCardPayload) {
        menu.addItem(contextItem("Open", #selector(openVideoAction)))
        menu.addItem(contextItem("Edit recording…", #selector(editAction), key: "e"))

        menu.addItem(.separator())
        // In-place zoom (O5) of the poster frame, same as pressing Space.
        menu.addItem(contextItem("Quick Look", #selector(quickLookAction)))

        menu.addItem(.separator())
        menu.addItem(contextItem("Copy", #selector(copyAction), key: "c"))
        menu.addItem(contextItem("Copy Path", #selector(copyVideoPathAction)))
        menu.addItem(contextItem("Save As…", #selector(saveAction), key: "s"))
        menu.addItem(contextItem("Share…", #selector(shareAction)))

        menu.addItem(.separator())
        let fileOnDisk = FileManager.default.fileExists(atPath: payload.url.path)
        let finderItem = contextItem("Show in Finder", #selector(showInFinderAction))
        finderItem.isEnabled = fileOnDisk
        menu.addItem(finderItem)
        let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        if fileOnDisk {
            let submenu = openWithSubmenu(for: payload.url)
            openWithItem.submenu = submenu
            openWithItem.isEnabled = !submenu.items.isEmpty
        } else {
            openWithItem.isEnabled = false
        }
        menu.addItem(openWithItem)
    }

    /// "Open With" submenu: every app the system registers for this file type,
    /// small icon + name, opened via NSWorkspace.
    private func openWithSubmenu(for fileURL: URL) -> NSMenu {
        let submenu = NSMenu()
        var seen = Set<String>()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted {
                FileManager.default.displayName(atPath: $0.path)
                    .localizedCaseInsensitiveCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
            }
        for appURL in apps {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: appURL.path),
                action: #selector(openWithAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = appURL
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Card gesture machine (DOCUMENTED STATE MAP)
    //
    // The card has ONE opaque hit area: DraggableImageView (the thumb) covers the
    // whole card, plus the corner buttons / center pills on the controls overlay
    // (only when hovered, and only over their own small rects). Everything the user
    // does by mouse on the card body therefore enters through the thumb.
    //
    // CANONICAL MODEL (owner-defined): the card is PINNED to the ANCHOR LINE, the
    // vertical edge on the stack side of the screen (left when overlayOnLeft, right
    // otherwise) where cards spawn and stack. There is NO free move: you cannot drop
    // the card in the middle of the screen. A drag is only ever one of three pinned
    // gestures, classified CONTINUOUSLY by the direction the cursor pulls from the
    // grab, and re-evaluated every event:
    //   - toward the screen EDGE (out of the anchor line)  -> DELETE (exclusion).
    //   - INTO the screen (away from the edge, > fileDragConvertDistance and that
    //     axis dominates)                                  -> FILE DRAG (drag-out).
    //   - DOWNWARD dominant                                -> STANDBY (minimize).
    // Returning toward the anchor without releasing CANCELS the live card gesture:
    // the card springs back to its slot and stays floating (the file drag, once
    // converted, is owned by AppKit; dropping on nothing returns the card via the
    // existing regret path).
    //
    // WHO receives the mouse:
    //   - thumb (DraggableImageView): the whole card body. Consumes its own
    //     mouseDown (does NOT call super, does NOT forward to the window), so the
    //     window-level mouseDown below NEVER fires over the card body. It only fires
    //     for a click that lands on bare window (it shouldn't, given the thumb fills
    //     the frame) and is kept as a defensive collapse-zoom + drag-begin hook.
    //   - corner buttons / pills: consume clicks for their action (acceptsFirstMouse).
    //   - frost / glass backing: OverlayControlsView.hitTest returns nil for the
    //     frost itself, so a mouseDown on empty frost falls THROUGH to the thumb.
    //
    // GESTURE ROUTER (DraggableImageView.mouseDragged -> onCardGesture -> handleThumbDrag):
    //   The thumb hands the WHOLE drag to handleThumbDrag (no thumb-side branch). It
    //   runs ONE tracking loop until mouse-up:
    //     - toward edge -> DELETE: the card follows the cursor with the trash tint
    //       (dragClassify .delete + cardDragUpdate); release past ~40% width deletes,
    //       returning toward the anchor cancels (snap-back).
    //     - into screen (> fileDragConvertDistance, inward axis dominant) -> FILE
    //       DRAG: convert now, snap the card home, beginFileDrag(lastEvent). The file
    //       travels, not the card; the drag session owns the rest.
    //     - downward -> STANDBY: chevron + descend (cardDragUpdate); release past
    //       ~50pt down parks the whole stack, returning up cancels (snap-back).
    //   double-click -> annotate/open; click-while-zoomed -> collapse.
    //
    // WHY "moving the card" was reworked into this:
    //   An earlier pass added a free MOVE (near = move, far = file). The owner tested
    //   it and rejected free move ("I dragged the overlay to the middle of the
    //   screen"); the card must stay pinned. Free move is GONE: no movedSlotOffset, no
    //   drop-where-you-let-go. The thumb no longer decides anything; the card's
    //   continuous direction classifier owns delete/file/standby/cancel as above.
    //
    // STATE x GESTURE x TRANSITION (resting states the machine acts in):
    //   resting/hover  : delete ok | file-out ok | standby ok | zoom(Space) ok | swipe ok | dbl-click ok
    //   zoom ACTIVE    : any mouseDown/drag collapses zoom first (no delete/file/standby)
    //   parked         : only the handle reacts (click restores); card ignores mouse
    //   entering slide : cardDragBegin clears isEntering + kills the in-flight anim,
    //                    so a grab during entrance takes the frame cleanly
    //   closing        : all gesture entry points bail (guards on isClosing)
    //   isCardDragging : reflowStack / animateToStackSlot skip this card so the
    //                    reflow spring never fights the per-event setFrameOrigin
    //
    // CANCEL semantics (the owner's "give it back and it floats normally"):
    //   delete/standby follow the cursor live; cardDragEnd confirms only past the
    //   calibrated distance, anything short or returned springs back to the anchor
    //   slot (snapBackToSlot). File drag, once converted, returns the card on an
    //   empty drop through the existing onDragEnded regret path.

    override func mouseDown(with event: NSEvent) {
        // A click on the zoomed preview collapses it (O5), it doesn't start a drag.
        if isPreviewZoomed { collapseZoom(); return }
        cardDragBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        cardDragUpdate()
    }

    override func mouseUp(with event: NSEvent) {
        cardDragEnd()
    }

    /// Latch the card-drag origin. Safe to call from the window override or from
    /// the thumb once it decides the gesture is a downward card drag.
    func cardDragBegin() {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        // A drag that starts while ANY frame animation is in flight (the 0.35s
        // entrance slide, a reflow spring, a snap-back, a zoom collapse) fights it:
        // both write the frame, so the drag's setFrameOrigin and the animator's
        // setFrame ping-pong the card and it "won't move". Clear the entrance latch
        // and replace whatever animation is running with a zero-duration one at the
        // current frame, so the drag owns the window from the first event.
        isEntering = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.animator().setFrame(self.frame, display: true)
        }
        cardDragStartMouse = NSEvent.mouseLocation
        cardDragStartOrigin = frame.origin
        isCardDragging = false
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
    }

    func cardDragUpdate() {
        guard let m0 = cardDragStartMouse, let o0 = cardDragStartOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - m0.x
        let dy = now.y - m0.y
        // 4pt threshold so a tiny accidental press doesn't move/delete.
        if !isCardDragging && (abs(dx) + abs(dy) < 4) { return }
        isCardDragging = true
        setFrameOrigin(NSPoint(x: o0.x + dx, y: o0.y + dy))
        updateDragHint(dx: dx, dy: dy)
    }

    /// G1: classify the live drag and how close it is to confirming, so the card
    /// can signal the outcome before release. Delete is a horizontal pull toward
    /// the stack's edge (left when overlayOnLeft, right otherwise); standby is a
    /// downward pull. Returns nil when the drag is closer to its origin than the
    /// signal floor, so a small jiggle shows nothing and a return-to-origin cancels.
    private func dragClassify(dx: CGFloat, dy: CGFloat) -> (intent: DragIntent, progress: CGFloat)? {
        let signalFloor: CGFloat = 8  // ignore the tiny initial wobble
        let towardEdge = Settings.overlayOnLeft ? -dx : dx  // positive = toward delete edge
        let downward = -dy                                   // positive = downward
        // One axis must dominate (1.15x) so an ambiguous diagonal sits in a small
        // dead zone and snaps back instead of firing the wrong action by accident.
        // The factor stays just above the router's own handoff bias in
        // DraggableImageView, so anything the router sent here as down/edgeward
        // still gets live feedback. Delete = clear horizontal pull toward the
        // stack's edge; standby = clear downward pull. Upward / into-the-screen
        // falls through to nil (snap back; the file-drag-out is routed earlier).
        if towardEdge > signalFloor && towardEdge > 1.15 * abs(downward) {
            return (.delete, min(towardEdge / deleteConfirmDistance, 1))
        }
        if downward > signalFloor && downward > 1.15 * abs(towardEdge) {
            return (.standby, min(downward / standbyConfirmDistance, 1))
        }
        return nil
    }

    /// Drive the directional feedback for the live drag: a trash tint + icon that
    /// deepens as the card nears the delete threshold, or a downward chevron that
    /// brightens as it nears standby. Returning the cursor toward the origin ramps
    /// the signal back to zero (visible cancel) before the release decides.
    private func updateDragHint(dx: CGFloat, dy: CGFloat) {
        guard let result = dragClassify(dx: dx, dy: dy) else { clearDragHint(); return }
        ensureDragHint()
        let icon = result.intent == .delete ? "trash.fill" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        dragHintIcon?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        // Delete tints red and dims the card toward "gone"; standby stays neutral
        // dark (it's hiding, not destroying) and only nudges its chevron in.
        let p = result.progress
        if result.intent == .delete {
            dragHintTint?.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.20 + 0.35 * p).cgColor
            // Fade the whole card toward the edge so a confirm reads as leaving.
            alphaValue = 1 - 0.30 * p
        } else {
            dragHintTint?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10 + 0.35 * p).cgColor
            alphaValue = 1
        }
        dragHintTint?.alphaValue = 0.35 + 0.65 * p
        dragHintIcon?.alphaValue = 0.35 + 0.65 * p
        // Controls would compete with the hint; keep them hidden during the gesture.
        controlsOverlay?.alphaValue = 0
    }

    /// Build the tint + icon overlay once, sized to the thumbnail, above the
    /// thumb so the signal reads on top of the image.
    private func ensureDragHint() {
        guard dragHintTint == nil, let clip = contentView?.subviews.first else { return }
        let tint = PassthroughView(frame: clip.bounds)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = metrics.cornerRadius
        tint.layer?.cornerCurve = .continuous
        tint.layer?.masksToBounds = true
        tint.alphaValue = 0
        clip.addSubview(tint)
        dragHintTint = tint

        let iconSize: CGFloat = 36
        let icon = NSImageView(frame: NSRect(
            x: (clip.bounds.width - iconSize) / 2,
            y: (clip.bounds.height - iconSize) / 2,
            width: iconSize, height: iconSize
        ))
        icon.contentTintColor = .white
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        icon.alphaValue = 0
        clip.addSubview(icon)
        dragHintIcon = icon
    }

    /// Remove the drag feedback overlay. `restoreAlpha` is true on cancel/snap-back
    /// (the card stays, so its opacity returns to full) and false when a delete is
    /// confirming, so the exit slide-out keeps owning alpha from where the drag dim
    /// left it instead of popping back to 1 first.
    private func clearDragHint(restoreAlpha: Bool = true) {
        dragHintTint?.removeFromSuperview()
        dragHintIcon?.removeFromSuperview()
        dragHintTint = nil
        dragHintIcon = nil
        if restoreAlpha && alphaValue < 1 { alphaValue = 1 }
    }

    func cardDragEnd() {
        defer { cardDragStartMouse = nil; cardDragStartOrigin = nil }
        // The card followed the cursor through the whole drag, so by release the
        // cursor has wandered off the card's resting slot while mouseInsideOverlay /
        // isHovered still read the grab-time "inside" state. Any path that LEAVES
        // the card visible (a press that never crossed the move threshold, or a
        // gesture that snaps back) must re-sync that input state from the cursor's
        // real position, or the hover monitors stay latched and the NEXT drag never
        // borrows key, so the central classifier sees no events until the user
        // crosses out and back in. Same staleness collapseZoom fixes after a zoom.
        guard isCardDragging else {
            clearDragHint(); resumeDismissIfNeeded()
            resyncHoverAndTracking()
            return
        }
        isCardDragging = false

        // Decide off the SAME displacement the live feedback read, so release does
        // exactly what the card signaled. The card frame already moved with the
        // cursor, so origin displacement equals cursor displacement.
        let dy = cardDragStartOrigin.map { frame.origin.y - $0.y } ?? 0
        let dx = cardDragStartOrigin.map { frame.origin.x - $0.x } ?? 0
        let classified = dragClassify(dx: dx, dy: dy)

        // Confirm a gesture only past its calibrated distance (the feedback's full
        // ramp). Anything short, or a return toward the origin, cancels and the card
        // springs back, the hysteresis the user feels as "I changed my mind".
        // Delete: ~40% of the card width toward the stack's edge. Standby: ~50pt
        // down, parking the WHOLE stack of this screen under one handle.
        switch classified {
        case (.delete, let p)? where p >= 1:
            // Keep the dimmed alpha from the drag so the slide-out fades from there
            // (no pop back to full first), then off the edge.
            clearDragHint(restoreAlpha: false)
            throwOffEdgeAndDelete()
        case (.standby, let p)? where p >= 1:
            clearDragHint()
            QuickAccessWindow.parkAll(on: overlayScreen)
        default:
            clearDragHint()
            snapBackToSlot()
            resumeDismissIfNeeded()
            // Cancel/snap-back keeps the card alive: re-sync hover/key from the
            // cursor's real position so a SECOND gesture right after (the owner's
            // "hide then delete") classifies without needing a cross-out-and-back.
            resyncHoverAndTracking()
        }
    }

    /// The card's CONTINUOUS direction classifier. The card is PINNED to the anchor
    /// line (the stack edge), so there is no free move: a drag is only ever one of
    /// three pinned gestures, decided live from the grab and re-evaluated every event:
    ///   - toward the screen EDGE (out of the line): DELETE. The card follows the
    ///     cursor with the trash tint (dragClassify .delete / cardDragUpdate); release
    ///     past the threshold deletes, returning toward the anchor cancels (snap-back,
    ///     the card stays floating).
    ///   - INTO the screen (away from the edge, > fileDragConvertDistance and that axis
    ///     dominates): FILE DRAG. Convert now: the card springs home and the file
    ///     travels (beginFileDrag with the latest event). The drag session then owns
    ///     the rest; dropping on nothing returns the card via the existing regret path.
    ///   - DOWNWARD dominant: STANDBY/minimize, same chevron + cancel-on-return as
    ///     cardDragUpdate/cardDragEnd already implement.
    /// Returns true when the card kept the gesture (delete/standby/cancel); false when
    /// it converted to a file drag (the thumb is done either way). `initialEvent` is
    /// the thumb's first past-threshold drag; `beginFileDrag` starts the drag-out.
    @discardableResult
    func handleThumbDrag(initialEvent: NSEvent, beginFileDrag: (NSEvent) -> Bool) -> Bool {
        guard !isClosing, !isParked, !isPreviewZoomed else { return false }
        // Latch the grab; the card already follows the cursor on the first frame for
        // delete/standby feedback. cardDragBegin kills any in-flight frame animation.
        cardDragBegin()
        cardDragUpdate()

        var lastEvent = initialEvent
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            lastEvent = next

            // Displacement from the grab. towardEdge>0 pulls out of the anchor line;
            // intoScreen>0 pulls into the screen; downward>0 pulls down.
            let now = NSEvent.mouseLocation
            let dx = now.x - (cardDragStartMouse?.x ?? now.x)
            let dy = now.y - (cardDragStartMouse?.y ?? now.y)
            let towardEdge = Settings.overlayOnLeft ? -dx : dx
            let intoScreen = -towardEdge
            let downward = -dy

            // INTO the screen, past the convert distance, and the inward pull beats
            // the downward pull -> file drag. The card is pinned, so an inward pull
            // means "take the file out", not "move the card inward". (intoScreen is
            // -towardEdge, so comparing the two is meaningless; only the down axis
            // can compete with an inward pull, and down dominant is standby instead.)
            if intoScreen > fileDragConvertDistance && intoScreen > abs(downward) {
                currentGestureMode = .filedrag
                isCardDragging = false
                clearDragHint()
                snapBackToSlot()
                cardDragStartMouse = nil
                cardDragStartOrigin = nil
                _ = beginFileDrag(lastEvent)
                return false
            }

            // Toward edge = delete, downward = standby: let the card follow the cursor
            // with the matching trash/chevron feedback. dragClassify drives the mode
            // label so the harness can read which pinned gesture is live.
            currentGestureMode = dragClassify(dx: dx, dy: dy).map {
                $0.intent == .delete ? CardGestureMode.deleting : .standby
            } ?? .none
            cardDragUpdate()
        }

        // Release: cardDragEnd confirms delete (past edge threshold) or standby (past
        // down threshold), else snaps back to the anchor line. Returning toward the
        // anchor without releasing already canceled via the dead zone, so the card is
        // back floating in its slot.
        currentGestureMode = .none
        cardDragEnd()
        return true
    }

    private func buildContent() {
        let thumbW = metrics.thumbW
        let thumbH = metrics.thumbH
        let progressH = metrics.progressH
        let totalH = thumbH + progressH

        let container = OverlayContentView(frame: NSRect(x: 0, y: 0, width: thumbW, height: totalH))
        container.wantsLayer = true
        container.layer?.cornerRadius = metrics.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.55
        container.layer?.shadowRadius = metrics.shadowRadius
        container.layer?.shadowOffset = CGSize(width: 0, height: -10)
        contentView = container

        // Autoresizing so the visual layers grow with the window during the O5
        // zoom (the window frame animates; subviews follow without a rebuild).
        container.autoresizingMask = [.width, .height]

        // Clip subviews so content respects corner radius while shadow remains visible
        let clipView = NSView(frame: container.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = metrics.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.masksToBounds = true
        clipView.autoresizingMask = [.width, .height]
        // Subtle dark tint, frames content, visible at rounded corners and behind image
        clipView.layer?.backgroundColor = KritColors.overlayTint.cgColor
        container.addSubview(clipView)

        // White border, primary edge definition on light wallpapers (shadow handles dark)
        let borderView = PassthroughView(frame: container.bounds)
        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = metrics.cornerRadius
        borderView.layer?.cornerCurve = .continuous
        borderView.layer?.borderWidth = 1.5
        borderView.layer?.borderColor = KritColors.overlayBorder.cgColor
        borderView.autoresizingMask = [.width, .height]
        container.addSubview(borderView)

        // Draggable thumbnail, drag to Finder/apps, double-click to annotate.
        // Dark container fill goes on the thumb's own layer so letterbox bars
        // read as a proper container without inserting an extra opaque subview
        // that can interfere with hit-testing on the controls overlay above.
        let thumbFrame = NSRect(x: 0, y: progressH, width: thumbW, height: thumbH)

        let backdrop = PassthroughView(frame: thumbFrame)
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.layer?.backgroundColor = KritColors.overlayContainerFill.cgColor
        if let cgImage = image.bestCGImage {
            backdrop.layer?.contents = cgImage
            backdrop.layer?.contentsGravity = .resizeAspectFill
            backdrop.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(18, forKey: kCIInputRadiusKey)
                backdrop.layer?.filters = [blur]
            }
            backdrop.layer?.opacity = 0.26
        }
        clipView.addSubview(backdrop)

        let backdropDim = PassthroughView(frame: thumbFrame)
        backdropDim.wantsLayer = true
        backdropDim.autoresizingMask = [.width, .height]
        backdropDim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        clipView.addSubview(backdropDim)
        backdropDimView = backdropDim

        let thumb = DraggableImageView(frame: thumbFrame)
        // Aspect-FILL via the layer (user rule: the shot always covers the whole
        // card, never letterbox bars). NSImageView only aspect-fits, so the image
        // is rendered by the layer and the view keeps drag/click behavior. The
        // zoom paths flip this to .resizeAspect so the zoomed preview shows the
        // full shot, then restore the fill on collapse.
        thumb.autoresizingMask = [.width, .height]
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.clear.cgColor
        thumb.layer?.contents = image.bestCGImage
        thumb.layer?.contentsGravity = .resizeAspectFill
        thumb.layer?.masksToBounds = true
        thumb.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        thumb.dragImage = image
        // Video: drag the real clip on disk (mp4/mov), double-click opens it in the
        // default player. Screenshot: drag a temp PNG, double-click annotates.
        if let payload = videoPayload {
            thumb.fileURLOverride = { payload.url }
            thumb.onDoubleClick = { [weak self] in self?.openVideoAction() }
        } else {
            thumb.onDoubleClick = { [weak self] in self?.editAction() }
        }
        thumb.onDragStarted = { [weak self] in self?.dismissTimer?.invalidate() }
        thumb.onDragEnded = { [weak self] accepted in
            guard let self else { return }
            if accepted {
                self.animatedClose()
            } else {
                self.recoverFromCancelledFileDrag()
            }
        }
        // Continuous direction classifier: toward edge = delete, into screen = file
        // drag, downward = standby. Card-pinned, no free move. The card starts the
        // file drag through the supplied callback at the conversion point.
        thumb.onCardGesture = { [weak self] event, beginFileDrag in
            self?.handleThumbDrag(initialEvent: event, beginFileDrag: beginFileDrag) ?? false
        }
        thumb.onClickWhileZoomed = { [weak self] in
            guard let self, self.isPreviewZoomed else { return false }
            self.collapseZoom()
            return true
        }
        clipView.addSubview(thumb)
        thumbView = thumb

        // Video badge: a centered play glyph + a mm:ss duration pill at the bottom
        // edge, so a card reads as a recording at a glance. Sits above the thumb,
        // below the hover controls (which fade in on top). PassthroughView so it
        // never intercepts drags/clicks meant for the thumb.
        if let payload = videoPayload {
            addVideoBadge(to: clipView, thumbFrame: thumbFrame, duration: payload.duration)
        }

        // Controls overlay, glass backing + corner circles + center pills
        let controls = OverlayControlsView(frame: NSRect(x: 0, y: progressH, width: thumbW, height: thumbH))
        controls.wantsLayer = true

        // Liquid Glass (or HUD blur on pre-26) backing for the controls layer.
        // The frost is flush with the card on its top and side edges (only the
        // 2pt progress strip insets the bottom, which has no visible round corner),
        // so it carries the card radius directly. A concentric (radius - inset)
        // would shrink the top corners away from the clip and open a hairline gap.
        let frost = ChromeFactory.backing(frame: controls.bounds, cornerRadius: metrics.cornerRadius)
        controls.glassBacking = frost
        controls.addSubview(frost)

        // ── Corner circles (glass buttons, all 4 corners) ──
        let cSize = metrics.buttonSize
        let cMargin = metrics.buttonMargin
        let cConfig = NSImage.SymbolConfiguration(pointSize: metrics.cornerSymbolPointSize, weight: .medium)

        // CleanShot corner map: close top-left, pin top-right, edit bottom-left,
        // save bottom-right. Delete keeps living in the context menu and the
        // drag-past-edge gesture (O4'), it no longer occupies a corner. Video swaps
        // pin (no sense for a clip) for Open in the player, and the annotate pencil
        // for the GIF/trim editor.
        let corners: [(String, String, Selector, CGFloat, CGFloat)] = isVideoCard
            ? [
                ("xmark",                 "Close",          #selector(dismissAction),     cMargin,                   thumbH - cSize - cMargin),
                ("play.fill",             "Open",           #selector(openVideoAction),   thumbW - cSize - cMargin,  thumbH - cSize - cMargin),
                ("scissors",              "Edit recording", #selector(editAction),        cMargin,                   cMargin),
                ("square.and.arrow.down", "Save As",        #selector(saveAction),        thumbW - cSize - cMargin,  cMargin),
            ]
            : [
                ("xmark",                 "Close", #selector(dismissAction), cMargin,                   thumbH - cSize - cMargin),
                ("pin",                   "Pin",   #selector(pinAction),     thumbW - cSize - cMargin,  thumbH - cSize - cMargin),
                ("pencil",                "Edit",  #selector(editAction),    cMargin,                   cMargin),
                ("square.and.arrow.down", "Save",  #selector(saveAction),    thumbW - cSize - cMargin,  cMargin),
            ]
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        for (icon, tip, sel, cx, cy) in corners {
            let btn = OverlayCornerButton(frame: NSRect(x: cx, y: cy, width: cSize, height: cSize))
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tip)?.withSymbolConfiguration(cConfig)
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.toolTip = tip
            btn.target = self
            btn.action = sel
            btn.imageScaling = .scaleNone
            // CleanShot look: translucent white circle, dark symbol (the pill
            // palette already encodes exactly that, adaptively).
            btn.contentTintColor = KritColors.pillButtonText
            btn.wantsLayer = true
            btn.layer?.contentsScale = screenScale
            btn.layer?.cornerRadius = cSize / 2
            btn.layer?.cornerCurve = .continuous
            btn.layer?.backgroundColor = KritColors.pillButtonBackground.cgColor
            controls.addSubview(btn)
        }

        // ── Center pills (tight-fit white capsules) ──
        let pillH = metrics.pillHeight
        let pillGap = metrics.pillGap
        let pillPadding = metrics.pillPadding  // total horizontal padding
        let pillFont = NSFont.systemFont(ofSize: metrics.pillFontSize, weight: .medium)
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            .font: pillFont,
        ]

        let pills: [(String, Selector)] = [
            ("Copy", #selector(copyAction)),
            ("Save", #selector(saveAction)),
        ]

        // Measure each pill to fit text snugly
        let pillWidths = pills.map { title, _ in
            ceil((title as NSString).size(withAttributes: pillAttrs).width) + pillPadding
        }
        let totalPillW = pillWidths.reduce(0, +) + CGFloat(pills.count - 1) * pillGap
        let pillY = round((thumbH - pillH) / 2)
        var pillCursorX = round((thumbW - totalPillW) / 2)

        let retinaScale = NSScreen.main?.backingScaleFactor ?? 2.0
        for (i, (title, sel)) in pills.enumerated() {
            let pw = pillWidths[i]
            let pill = OverlayPillButton(frame: NSRect(x: pillCursorX, y: pillY, width: pw, height: pillH))
            pill.attributedTitle = NSAttributedString(string: title, attributes: pillAttrs)
            pill.target = self
            pill.action = sel
            pill.layer?.contentsScale = retinaScale
            pill.layer?.cornerRadius = pillH / 2
            pill.layer?.cornerCurve = .continuous
            pill.layer?.backgroundColor = KritColors.pillButtonBackground.cgColor
            controls.addSubview(pill)
            pillCursorX += pw + pillGap
        }

        controls.alphaValue = 0
        clipView.addSubview(controls)
        controlsOverlay = controls

        // Progress bar at the very bottom, thin, bright accent line. The
        // auto-dismiss timer is NOT armed here: callers (positionOverlay on first
        // build, rebuildAtCurrentSize on resize) arm it once via restartDismissTimer
        // so there's never a stray second timer racing the first.
        let timeout = Settings.overlayTimeout
        if timeout > 0 {
            let progressBg = NSView(frame: NSRect(x: 0, y: 0, width: thumbW, height: progressH))
            progressBg.wantsLayer = true
            progressBg.layer?.backgroundColor = KritColors.progressBackground.cgColor
            clipView.addSubview(progressBg)

            let progressFill = NSView(frame: progressBg.bounds)
            progressFill.wantsLayer = true
            progressFill.layer?.backgroundColor = KritColors.accent.cgColor
            progressFill.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
            progressFill.layer?.position = CGPoint(x: 0, y: progressH / 2)
            progressBg.addSubview(progressFill)
            timeoutProgressLayer = progressFill.layer
        }
    }

    /// Video affordance: a centered play disc + a mm:ss duration pill pinned to the
    /// bottom-left of the thumbnail. PassthroughView so the badge never eats a drag
    /// or click the thumb below it should handle.
    private func addVideoBadge(to clip: NSView, thumbFrame: NSRect, duration: Double) {
        let badge = PassthroughView(frame: thumbFrame)
        badge.wantsLayer = true
        badge.autoresizingMask = [.width, .height]

        let discSize = max(metrics.thumbH * 0.30, 34)
        let disc = NSView(frame: NSRect(
            x: (thumbFrame.width - discSize) / 2,
            y: (thumbFrame.height - discSize) / 2,
            width: discSize, height: discSize
        ))
        disc.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        disc.wantsLayer = true
        disc.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        disc.layer?.cornerRadius = discSize / 2
        disc.layer?.cornerCurve = .continuous

        let play = NSImageView(frame: disc.bounds.insetBy(dx: discSize * 0.28, dy: discSize * 0.28))
        play.autoresizingMask = [.width, .height]
        let playConfig = NSImage.SymbolConfiguration(pointSize: discSize * 0.4, weight: .semibold)
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(playConfig)
        play.contentTintColor = .white
        play.imageScaling = .scaleProportionallyUpOrDown
        disc.addSubview(play)
        badge.addSubview(disc)

        let durationText = Self.durationLabel(duration)
        let font = NSFont.systemFont(ofSize: metrics.pillFontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        // NSTextField lays text slightly wider than NSString.size reports (cell
        // insets, glyph bearing), and a label defaults to truncating-tail. Sizing
        // the field to the bare measured width clipped the last digit, so "0:08"
        // rendered "0:0". Round up + a small slack and disable truncation so the
        // whole stamp always fits.
        let textW = ceil((durationText as NSString).size(withAttributes: attrs).width) + 2
        let pad: CGFloat = 8
        let pillH = metrics.pillHeight * 0.74
        let pill = NSView(frame: NSRect(
            x: metrics.buttonMargin,
            y: metrics.buttonMargin,
            width: textW + pad * 2, height: pillH
        ))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: durationText, attributes: attrs))
        label.lineBreakMode = .byClipping
        label.cell?.truncatesLastVisibleLine = false
        label.frame = NSRect(x: pad, y: (pillH - font.pointSize - 4) / 2, width: textW, height: font.pointSize + 4)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        pill.addSubview(label)
        badge.addSubview(pill)

        clip.addSubview(badge)
    }

    /// mm:ss for the duration pill (clamps to whole seconds; hours roll into the
    /// minutes field, a recording long enough to need an hours slot is rare).
    private static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func setHovered(_ hovered: Bool) {
        // While zoomed (O5) the chrome stays hidden behind the big preview.
        guard hovered != isHovered, !isParked, !isPreviewZoomed else { return }
        isHovered = hovered

        // Pause/resume auto-dismiss timer on hover (like CleanShot X)
        if hovered {
            dismissTimer?.invalidate()
            timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        } else {
            restartDismissTimer()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            controlsOverlay?.animator().alphaValue = hovered ? 1 : 0
        }
    }

    /// Restart the auto-dismiss countdown + coral progress from the configured
    /// timeout. Shared by hover-exit, A2 snap-back, A3 Quick Look close, A5
    /// un-park, and A7 picker close so the resume logic lives in one place.
    private func restartDismissTimer() {
        guard !isClosing, !isParked else { return }
        let remaining = Settings.overlayTimeout
        guard remaining > 0 else { return }
        animateTimeoutProgress(duration: remaining)
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.animatedClose() }
        }
    }

    /// Resume the timer only when the cursor isn't over the card (so a release
    /// inside the card keeps it paused until the mouse actually leaves).
    private func resumeDismissIfNeeded() {
        guard !isHovered else { return }
        restartDismissTimer()
    }

    private func animateTimeoutProgress(duration: TimeInterval) {
        guard let layer = timeoutProgressLayer else { return }
        layer.removeAnimation(forKey: "timeoutProgress")
        layer.transform = CATransform3DIdentity
        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = 1.0
        shrink.toValue = 0.0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "timeoutProgress")
    }

    /// The screen this card lives on: the capture's display when known, else the
    /// main display. Cascade, peek, park and edge tests all key off this.
    private var overlayScreen: NSScreen? {
        cardScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// B3: pick the display the card should live on. The product rule is "the
    /// active monitor, where the mouse is": find the NSScreen whose frame contains
    /// the current cursor, and only fall back to the capture's display (then the
    /// main display) when no screen claims the point. Resolved once at creation and
    /// frozen in `cardScreen` so the card's geometry never drifts as the mouse later
    /// moves between monitors.
    private static func resolveActiveScreen(captureScreen: NSScreen?) -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        if let underCursor = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) {
            return underCursor
        }
        return captureScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// O2 stacking gap between adjacent cards (≈10pt). Tightens to `stackGapMin`
    /// only when the stack would otherwise overflow the screen top.
    private static let stackGap: CGFloat = 10
    private static let stackGapMin: CGFloat = 6
    /// Compression scale applied to older cards when the full-size stack would
    /// exceed the screen top (O2): never overflow, shrink instead.
    private static let stackCompressScale: CGFloat = 0.85
    private static let stackMargin: CGFloat = 36

    /// Full target frame (origin + size) for this card's slot in the stack (O2).
    /// The card is PINNED to the anchor line: the newest card sits at the bottom
    /// corner full-size, older cards stack UP with a 10pt gap and never overlap.
    /// There is no user move offset; a drag only deletes, files out or minimizes,
    /// and any of those that cancels springs the card right back to this slot. If
    /// the full-size column would clear the screen top, older cards scale to 0.85
    /// and gaps tighten so the stack never overflows the visible frame.
    private func slotFrame() -> NSRect {
        let stack = QuickAccessWindow.orderedStack(on: overlayScreen)
        guard let pos = stack.firstIndex(where: { $0 === self }) else {
            // Not yet in the stack (first build): treat as the lone bottom card.
            return Self.layout(for: [self], screen: overlayScreen)[0]
        }
        return Self.layout(for: stack, screen: overlayScreen)[pos]
    }

    /// Origin half of `slotFrame()` (callers that only re-position, never resize).
    private func slotOrigin() -> NSPoint { slotFrame().origin }

    /// Computes a frame per card for the whole ordered stack (oldest→newest).
    /// The newest (last) card anchors at the bottom corner; older cards march up.
    private static func layout(for stack: [QuickAccessWindow], screen: NSScreen?) -> [NSRect] {
        let vf = screen?.visibleFrame ?? .zero
        let onLeft = Settings.overlayOnLeft
        let count = stack.count
        guard count > 0 else { return [] }

        // Natural card size (newest, full scale). Sizes can differ per card (A4),
        // but the cascade reads cleanest sized off the bottom card's metrics.
        let cardSizes = stack.map { NSSize(width: $0.metrics.thumbW, height: $0.metrics.thumbH + $0.metrics.progressH) }

        // Does the full-size column fit under the screen top? If not, compress the
        // older cards (all but the newest) to keep the stack inside the frame.
        func columnHeight(scale: CGFloat, gap: CGFloat) -> CGFloat {
            var h: CGFloat = 0
            for (i, s) in cardSizes.enumerated() {
                let cardH = i == count - 1 ? s.height : s.height * scale
                h += cardH
                if i < count - 1 { h += gap }
            }
            return h
        }
        let available = vf.height - 2 * stackMargin
        var scale: CGFloat = 1.0
        var gap = stackGap
        if columnHeight(scale: 1.0, gap: stackGap) > available {
            scale = stackCompressScale
            gap = stackGapMin
        }

        // Lay out bottom-up: newest card (last) sits at the corner, older march up.
        var frames = [NSRect](repeating: .zero, count: count)
        var y = vf.minY + stackMargin
        for i in stride(from: count - 1, through: 0, by: -1) {
            let s = cardSizes[i]
            let isNewest = i == count - 1
            let cardScale = isNewest ? 1.0 : scale
            let w = s.width * cardScale
            let h = s.height * cardScale
            let x = onLeft ? vf.minX + stackMargin : vf.maxX - w - stackMargin
            frames[i] = NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
            y += h + gap
        }
        return frames
    }

    /// Visible (un-parked) cards on `screen`, ordered oldest→newest by creation
    /// order (their order in `openWindows`). Drives the O2 stack layout.
    fileprivate static func orderedStack(on screen: NSScreen?) -> [QuickAccessWindow] {
        let key = screen.map { ObjectIdentifier($0) }
        return openWindows.filter { card in
            guard !card.isParked, !card.isClosing else { return false }
            return card.overlayScreen.map { ObjectIdentifier($0) } == key
        }
    }

    private func positionOverlay() {
        guard let screen = overlayScreen else { return }
        let slot = slotFrame()

        // Handoff entrance: the card parks INVISIBLE exactly at its slot and
        // waits for revealPendingHandoff (the fly-to-tray ghost lands on it,
        // then the card fades in under the ghost's fade-out). No slide.
        if entrance == .handoff {
            setFrame(NSRect(origin: slot.origin, size: frame.size), display: false)
            alphaValue = 0
            NSApp.setActivationPolicy(.accessory)
            orderFrontRegardless()
            Self.pendingHandoffCard = self
            return
        }

        // M1': enter by sliding in from the screen edge the stack lives on (left
        // when overlayOnLeft, right otherwise) with a soft spring (~0.35s), no
        // instant pop. Start fully off that edge; the window-frame spring carries
        // it to its slot. Reduce Motion → plain crossfade in place.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let vf = screen.visibleFrame
        let offEdgeX = Settings.overlayOnLeft
            ? vf.minX - slot.width - 20
            : vf.maxX + 20
        if reduceMotion {
            setFrameOrigin(slot.origin)
        } else {
            setFrameOrigin(NSPoint(x: offEdgeX, y: slot.origin.y))
        }
        alphaValue = 0

        // Show the card WITHOUT passively stealing focus on appearance, that was
        // the root of the dead-interaction bug: the old code activated the app and
        // forced key on appearance (and again on a 100/300ms timer), yanking focus
        // right after every capture. orderFrontRegardless surfaces the floating card
        // without activation. Focus is borrowed only on a real hover (grabKey), so
        // the buttons (acceptsFirstMouse) and file-drag work on a non-key window and
        // Space starts working the moment the cursor is over the card.
        NSApp.setActivationPolicy(.accessory)
        orderFrontRegardless()

        // Slide to the slot with a spring (off-edge → slot). The hover/focus check
        // below uses the FINAL slot frame, not the off-screen start, so a cursor
        // sitting on the landing spot still borrows the keyboard.
        if !reduceMotion {
            isEntering = true
            // animator().setFrame, NOT setFrameOrigin: NSWindow only animates the
            // whole "frame" key, animator().setFrameOrigin is a silent no-op, which
            // stranded entering cards off-screen at the slide start position.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                self.animator().setFrame(NSRect(origin: slot.origin, size: self.frame.size), display: true)
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async { self?.isEntering = false }
            })
        }

        let underCursor = slot.contains(NSEvent.mouseLocation)
        mouseInsideOverlay = underCursor
        // If the cursor is already on the card (e.g. user released an area-capture
        // drag right here), borrow the keyboard so Space works immediately.
        updateHoverFocus(underCursor)
        // Arm auto-dismiss once on first build (buildContent no longer does it).
        // While hovered the timer stays paused; hover-exit restarts it.
        if !underCursor { restartDismissTimer() }

        // Fade in (the slide spring carries the motion when enabled).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Swipe-dismiss: slide overlay off-screen toward the swipe direction
    private func swipeDismiss(direction: CGFloat) {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()
        // Reflow now (this card is already isClosing → excluded) so survivors
        // close the gap in step with the slide-out instead of after cleanup.
        QuickAccessWindow.reflowStack()

        let slideDistance: CGFloat = frame.width + 40
        let targetX = frame.origin.x + (direction * slideDistance)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.animator().setFrame(
                NSRect(origin: NSPoint(x: targetX, y: self.frame.origin.y), size: self.frame.size),
                display: true
            )
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    // MARK: - O4 drag-off-edge → delete

    /// O4': slide the card out toward the delete edge (the side the stack lives on),
    /// fade out, then delete the capture. The delete is what makes this distinct
    /// from the trackpad swipe. If auto-copy is on, the print stays in the clipboard,
    /// so a discreet toast reassures the user the capture isn't fully lost (M1'
    /// micro-feedback: slide-out toward the delete edge + fade).
    private func throwOffEdgeAndDelete() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        // Reflow now (this card is already isClosing → excluded) so survivors
        // close the gap in step with the throw-off animation.
        QuickAccessWindow.reflowStack()

        // Continue off the delete edge (left when overlayOnLeft, right otherwise).
        var target = frame.origin
        if Settings.overlayOnLeft {
            target.x -= frame.width + 60
        } else {
            target.x += frame.width + 60
        }

        // Screenshot-only reassurance: the print is still on the clipboard. A video
        // card has its own delete semantics (file kept unless it was a temp clip).
        let stillInClipboard = !isVideoCard && Settings.afterCaptureCopyToClipboard

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            if !reduceMotion {
                self.animator().setFrame(NSRect(origin: target, size: self.frame.size), display: true)
            }
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let payload = self.videoPayload {
                    // The recording is auto-saved to the user's folder, so delete
                    // only dismisses the card and leaves the file on disk. A throwaway
                    // temp clip (isTemporary) is the one case we remove from disk.
                    if payload.isTemporary {
                        try? FileManager.default.removeItem(at: payload.url)
                    }
                } else if let historyItem = self.historyItem {
                    self.historyManager?.delete(historyItem)
                }
                self.forceCleanup()
                if stillInClipboard {
                    ToastWindow.show(message: "Deleted. Still in your clipboard")
                }
            }
        })
    }

    /// Spring the card back to its stack slot when a drag ends short of an edge.
    private func snapBackToSlot() {
        let target = slotFrame()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.22
            ctx.timingFunction = reduceMotion
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(target, display: true)
        }
    }

    /// Regret path: the user started a file-drag-out (drag into the screen toward
    /// another app), changed their mind and let go over nothing (operation == []).
    /// Instead of closing, bring the card home and make it usable again: spring back
    /// to the live slot, drop any drag hint, restore full opacity, re-sync hover/key
    /// from the cursor (the file-drag swallowed the hover crossings, same staleness
    /// the zoom collapse hits), and re-arm auto-dismiss when the cursor is off it.
    private func recoverFromCancelledFileDrag() {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        clearDragHint()
        snapBackToSlot()
        let inside = frame.contains(NSEvent.mouseLocation)
        mouseInsideOverlay = inside
        updateHoverFocus(inside)
        if !inside { restartDismissTimer() }
    }

    // MARK: - O1 standby (park / restore)

    /// Slide the card down into the bottom edge and replace it with a small glass
    /// handle (~22pt visible, up-chevron). Auto-dismiss pauses while parked (the
    /// timer stays invalidated). `silentReflow` lets O3 (standby-all) park every
    /// card and reflow once at the end instead of per-card. `handleIndex`, when
    /// set, rows the handles from the corner so an all-park doesn't stack every
    /// handle on the same X.
    /// Parks this card. `createHandle: false` parks silently with no handle of
    /// its own (group standby: one anchor card carries THE handle for everyone).
    /// `onRestoreOverride` lets that group handle restore the whole stack.
    private func park(silentReflow: Bool = false, handleIndex: Int? = nil,
                      createHandle: Bool = true, onRestoreOverride: (() -> Void)? = nil) {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        isParked = true
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? frame
        let handleW: CGFloat = 70
        let handleH: CGFloat = 22  // ~22pt visible glass handle (O1)
        let handleY = vf.minY
        // Handles center on the STACK REGION (where the cards live and will
        // reappear), not wherever the drag happened to drop the card, the
        // user reads the chevron as "your stack is tucked right here". Extra
        // handles row outward from that center, 8pt apart, respecting side.
        let step = handleW + 8
        // Standby is always a group action: ONE handle, centered on the stack
        // region. idx stays for the (unused today) multi-handle layout math.
        let idx = CGFloat(handleIndex ?? 0)
        let columnCenterX = Settings.overlayOnLeft
            ? vf.minX + Self.stackMargin + metrics.thumbW / 2
            : vf.maxX - Self.stackMargin - metrics.thumbW / 2
        let handleX = Settings.overlayOnLeft
            ? columnCenterX - handleW / 2 + idx * step
            : columnCenterX - handleW / 2 - idx * step

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // M1' park micro-feedback: a subtle vertical squash as the card descends,
        // like it's being tucked under the bottom edge. Layered animation so it
        // rides alongside the frame slide-down. Skipped under Reduce Motion.
        if !reduceMotion, let layer = contentView?.layer {
            let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
            squash.values = [1.0, 0.88, 0.78]
            squash.keyTimes = [0, 0.5, 1.0]
            squash.duration = 0.22
            squash.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(squash, forKey: "parkSquash")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            if !reduceMotion {
                self.animator().setFrame(
                    NSRect(origin: NSPoint(x: self.frame.origin.x, y: vf.minY - self.frame.height),
                           size: self.frame.size),
                    display: true
                )
            }
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isParked else { return }
                self.contentView?.layer?.removeAnimation(forKey: "parkSquash")
                self.orderOut(nil)  // parked, not closed, stays in openWindows
                if createHandle {
                    let handle = ParkedHandleWindow(
                        frame: NSRect(x: handleX, y: handleY, width: handleW, height: handleH),
                        onRestore: onRestoreOverride ?? { [weak self] in self?.restore() })
                    self.parkedHandle = handle
                    handle.orderFrontRegardless()
                }
                // Parking removes this card from the stack (O2): survivors re-flow
                // to close the gap. Skipped for standby-all (all leave at once).
                if !silentReflow { QuickAccessWindow.reflowStack() }
            }
        })
    }

    // MARK: - O3 standby-all

    /// Park every visible card on `screen` at once (drag any card down, or the
    /// "Send all to standby" context-menu item). The whole stack tucks under ONE
    /// group handle, centered on the stack region; clicking it restores everyone.
    fileprivate static func parkAll(on screen: NSScreen?) {
        let stack = orderedStack(on: screen)
        guard !stack.isEmpty else { return }
        for (i, card) in stack.enumerated() {
            card.park(
                silentReflow: true,
                handleIndex: 0,
                createHandle: i == 0,
                onRestoreOverride: { QuickAccessWindow.restoreAll(on: screen) }
            )
        }
    }

    /// Fades the waiting handoff card in once the fly-to-tray ghost lands on it
    /// (delay ≈ ghost settling − crossfade). With no ghost (Reduce Motion, no
    /// image) the delay is 0 and the card simply fades in at its slot.
    fileprivate static func revealPendingHandoff(after delay: TimeInterval) {
        guard let card = pendingHandoffCard else { return }
        pendingHandoffCard = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) { [weak card] in
            guard let card, !card.isClosing, !card.isParked else { return }
            let underCursor = card.frame.contains(NSEvent.mouseLocation)
            card.mouseInsideOverlay = underCursor
            card.updateHoverFocus(underCursor)
            if !underCursor { card.restartDismissTimer() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 1
            }
        }
    }

    /// Restore every parked card on `screen` (the inverse of `parkAll`).
    fileprivate static func restoreAll(on screen: NSScreen?) {
        let key = screen.map { ObjectIdentifier($0) }
        for card in openWindows where card.isParked {
            guard card.overlayScreen.map({ ObjectIdentifier($0) }) == key else { continue }
            card.restore()
        }
    }

    /// True when any card on `screen` is currently parked (drives the
    /// context-menu toggle between "send all" and "restore all").
    fileprivate static func hasParked(on screen: NSScreen?) -> Bool {
        let key = screen.map { ObjectIdentifier($0) }
        return openWindows.contains { $0.isParked && $0.overlayScreen.map { ObjectIdentifier($0) } == key }
    }

    /// SP1: move this card's parked handle to a valid spot on its (possibly new)
    /// screen. Handles are rowed from the stack corner by their position among the
    /// screen's parked cards, mirroring the layout in park(handleIndex:).
    /// Move the parked handle to its slot on the (possibly new) screen. SP1
    /// (resolution change) snaps instantly; B4 (monitor follow) animates so the
    /// handle glides to the new display alongside the visible cards' spring.
    private func repositionParkedHandle(animated: Bool = false) {
        guard isParked, let handle = parkedHandle else { return }
        let key = overlayScreen.map { ObjectIdentifier($0) }
        let parkedHere = QuickAccessWindow.openWindows.filter {
            $0.isParked && $0.overlayScreen.map { ObjectIdentifier($0) } == key
        }
        let idx = CGFloat(parkedHere.firstIndex(where: { $0 === self }) ?? 0)
        let vf = (overlayScreen ?? NSScreen.main)?.visibleFrame ?? handle.frame
        let handleW: CGFloat = 70
        let handleH: CGFloat = 22
        let step = handleW + 8
        // Same stack-region-centered math as park() so SP1 reflows land handles
        // on the spot where the stack reappears.
        let columnCenterX = Settings.overlayOnLeft
            ? vf.minX + Self.stackMargin + metrics.thumbW / 2
            : vf.maxX - Self.stackMargin - metrics.thumbW / 2
        let handleX = Settings.overlayOnLeft
            ? columnCenterX - handleW / 2 + idx * step
            : columnCenterX - handleW / 2 - idx * step
        let target = NSRect(x: handleX, y: vf.minY, width: handleW, height: handleH)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                handle.animator().setFrame(target, display: true)
            }
        } else {
            handle.setFrame(target, display: true)
        }
    }

    /// Bring the card back up into its slot and resume auto-dismiss.
    private func restore() {
        guard isParked else { return }
        isParked = false
        parkedHandle?.orderOut(nil)
        parkedHandle = nil

        // Re-enter the stack at full card size (park may have scaled it). slotFrame
        // now counts this card (isParked cleared) so it gets its place; slide up
        // from just below the slot.
        let target = slotFrame()
        let cardSize = NSSize(width: metrics.thumbW, height: metrics.thumbH + metrics.progressH)
        alphaValue = 0
        setFrame(NSRect(x: target.minX, y: target.minY - cardSize.height, width: target.width, height: target.height), display: false)
        orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.24
            ctx.timingFunction = reduceMotion
                ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 1
            self.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Reflow accommodates the reinsertion (other cards settle around it).
                QuickAccessWindow.reflowStack()
                // The card was orderOut while parked, so mouseInsideOverlay /
                // isHovered / key window are stale from before the park. Re-sync from
                // the cursor (same fix collapseZoom applies) so a gesture right after
                // restoring borrows key and the central classifier sees its events.
                self.resyncHoverAndTracking()
                self.restartDismissTimer()
            }
        })
    }

    // MARK: - O2 stack re-flow

    /// Re-flow every per-screen stack after a card joins/leaves, springing the
    /// survivors to their new slots (O2). Parked and zoomed cards keep their own
    /// geometry and are skipped. Runs per display via slotFrame()'s ordered stack.
    fileprivate static func reflowStack() {
        for w in openWindows where !w.isParked && !w.isClosing && !w.isPreviewZoomed {
            w.animateToStackSlot()
        }
    }

    /// Force-cleans every card (parked or visible) so no card or parked handle
    /// window outlives app termination.
    fileprivate static func tearDownAll() {
        for w in openWindows { w.forceCleanup() }
    }

    private func animateToStackSlot() {
        // Skip a card still playing its M1' slide-in: it's already heading to its
        // slot, and re-animating would jerk it off the in-flight position. Skip a
        // card the user is actively dragging too: the reflow's animator().setFrame
        // would fight the drag's per-event setFrameOrigin and yank the card back to
        // its slot mid-gesture, which reads as "the card won't move anymore".
        guard !isClosing, !isParked, !isPreviewZoomed, !isEntering, !isCardDragging else { return }
        let target = slotFrame()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(target, display: true)
            }
            return
        }
        // Spring (stiffness ~300, damping ~20) via implicit window-frame animation.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(target, display: true)
        }
    }

    // MARK: - A4 resize in place

    @objc private func setOverlaySize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = OverlaySize(rawValue: raw) else { return }
        Settings.overlaySize = size
        // SZ1: applying a new size hits ALL open cards, not just the one whose
        // menu was used, so the whole stack stays one consistent size; reflow once
        // afterwards so the resized cards settle into recomputed slots.
        QuickAccessWindow.applyOverlaySizeToAll()
    }

    /// SZ1: rebuild every open card at the current Settings.overlaySize, then reflow
    /// the visible stacks. Visible cards rebuild their content in place; parked cards
    /// only re-derive metrics (their geometry is recomputed on restore()).
    fileprivate static func applyOverlaySizeToAll() {
        for card in openWindows where !card.isClosing {
            if card.isParked {
                card.metrics = OverlayMetrics.make(for: Settings.overlaySize)
            } else {
                card.rebuildAtCurrentSize()
            }
        }
        reflowStack()
    }

    /// Re-derive metrics, resize the window, and rebuild the content in place.
    private func rebuildAtCurrentSize() {
        guard !isClosing, !isParked else { return }
        let wasHovered = isHovered
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")

        // Kill any in-flight frame animation (entrance/reflow) first: rebuilding
        // while one runs makes two writers fight over the frame, visible flicker.
        isEntering = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.animator().setFrame(self.frame, display: true)
        }

        metrics = OverlayMetrics.make(for: Settings.overlaySize)
        // ONE frame mutation (the old setContentSize → rebuild → setFrameOrigin
        // triple flushed three frames and flickered): anchor the stack-side edge,
        // resize, then rebuild the content at the final size. reflowStack (caller)
        // settles the exact slot with its own animation.
        let newSize = NSSize(width: metrics.thumbW, height: metrics.thumbH + metrics.progressH)
        let newX = Settings.overlayOnLeft ? frame.minX : frame.maxX - newSize.width
        setFrame(NSRect(x: newX, y: frame.minY, width: newSize.width, height: newSize.height), display: false)
        buildContent()
        if alphaValue < 1 { alphaValue = 1 }

        isHovered = false
        setHovered(wasHovered || frame.contains(NSEvent.mouseLocation))
        if !isHovered { restartDismissTimer() }
    }

    // MARK: - P1 Space companion preview (CleanShot "Space" look)
    //
    // Space over a hovered card opens a LARGE preview window beside the card with a
    // "Space" pill below it (QuickLookController + SpacePreviewWindow); Space again,
    // Esc, or leaving the card closes it. This does NOT grow the card and does NOT
    // touch the card's gesture machine, frame, or stack slot: the preview is a
    // separate companion window anchored to this card's on-screen frame.

    /// Toggle the big companion preview anchored to this card. Reads the card's
    /// current on-screen frame and screen so the preview lands right beside it.
    private func togglePreview() {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        QuickLookController.shared.toggle(
            owner: self, image: image, cardFrame: frame, screen: overlayScreen
        )
        // The big preview carries its own "Space" pill, so hide the small hint while
        // it is open and bring it back when the preview closes (cursor still here).
        setSpaceHintVisible(mouseInsideOverlay && cursorOwnsThisCard())
    }

    /// Show or hide the small "Space" hint pill near the card on hover. Built lazily
    /// the first time the card is hovered; positioned just below the card, centered.
    /// While the big preview is open the hint stays hidden (the preview has its own
    /// "Space" pill). Hidden whenever the card isn't hovered.
    private func setSpaceHintVisible(_ visible: Bool) {
        let shouldShow = visible && !isPreviewZoomed
            && !QuickLookController.shared.isOpen(forOwner: self)
        if shouldShow {
            ensureSpaceHint()
            positionSpaceHint()
            spaceHintWindow?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.spaceHintWindow?.animator().alphaValue = 1
            }
        } else {
            guard let hint = spaceHintWindow, hint.alphaValue > 0 else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                hint.animator().alphaValue = 0
            }, completionHandler: { hint.orderOut(nil) })
        }
    }

    /// Build the "Space" hint pill window once (a small dark capsule with white
    /// text). It mirrors the preview's own pill so the affordance reads the same.
    private func ensureSpaceHint() {
        guard spaceHintWindow == nil else { return }
        let text = "Space"
        let font = NSFont.systemFont(ofSize: metrics.pillFontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textW = ceil((text as NSString).size(withAttributes: attrs).width)
        let padX: CGFloat = 14
        let pillW = textW + padX * 2
        let pillH = metrics.pillHeight

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: round(pillW), height: pillH),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.sharingType = .none

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: round(pillW), height: pillH))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attrs))
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.frame = NSRect(x: padX, y: (pillH - font.pointSize - 6) / 2, width: textW, height: font.pointSize + 6)
        pill.addSubview(label)
        win.contentView = pill
        win.alphaValue = 0
        spaceHintWindow = win
    }

    /// Place the hint pill centered just below the card's current frame, clamped to
    /// the screen so it never falls off the bottom edge.
    private func positionSpaceHint() {
        guard let hint = spaceHintWindow else { return }
        let vf = overlayScreen?.visibleFrame ?? frame
        let pillW = hint.frame.width
        let pillH = hint.frame.height
        let gap: CGFloat = 8
        var x = frame.midX - pillW / 2
        x = min(max(x, vf.minX + 8), vf.maxX - 8 - pillW)
        var y = frame.minY - gap - pillH
        if y < vf.minY + 8 { y = frame.maxY + gap }  // flip above if no room below
        hint.setFrame(NSRect(x: round(x), y: round(y), width: pillW, height: pillH), display: false)
    }

    // MARK: - O5 in-place zoom (NOT macOS Quick Look)

    /// Space over a card springs its OWN window up to a centered preview (O5': the
    /// smaller of 50% of the visible frame or 2.5× the card, image aspect preserved)
    /// and back. No QLPreviewPanel: the card window itself grows, so it reads as the
    /// card zooming. Space/Esc collapse it regardless of where the cursor sits, and a
    /// click anywhere outside also collapses (see handleKey / expandZoom monitors).
    private func toggleZoom() {
        if isPreviewZoomed { collapseZoom() } else { expandZoom() }
    }

    /// O5': centered preview sized to min(50% of the visible frame, 2.5× the card),
    /// image aspect preserved so it never letterboxes against the window edge. The
    /// 2.5× cap keeps the zoom proportional to the card (the old 70% felt oversized).
    private func zoomTargetFrame() -> NSRect {
        let vf = overlayScreen?.visibleFrame ?? frame
        let cardW = metrics.thumbW
        let cardH = metrics.thumbH + metrics.progressH
        let maxW = min(vf.width * 0.50, cardW * 2.5)
        let maxH = min(vf.height * 0.50, cardH * 2.5)
        let aspect = image.size.width > 0 && image.size.height > 0
            ? image.size.width / image.size.height
            : cardW / cardH
        var w = maxW
        var h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }
        let x = vf.minX + (vf.width - w) / 2
        let y = vf.minY + (vf.height - h) / 2
        return NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }

    private func expandZoom() {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        isPreviewZoomed = true
        preZoomFrame = frame
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        // The resting card aspect-FILLS (no letterbox); the zoom is a content
        // preview, so show the WHOLE shot while expanded.
        thumbView?.layer?.contentsGravity = .resizeAspect
        // Float above sibling cards while zoomed; explicit user action so taking
        // key/activation here is fine (Space must keep reaching the local monitor).
        level = .statusBar
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        // O5': a click anywhere outside the preview collapses it. A local monitor
        // catches clicks inside the app; a global one catches clicks on other apps'
        // windows (no permission needed for mouse events). Clicks on the preview
        // itself are handled by the window/thumb mouseDown, so we only act when the
        // point lands outside this (zoomed) frame.
        let outsideCollapse: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isPreviewZoomed else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.collapseZoom() }
        }
        let localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isPreviewZoomed else { return event }
            if !self.frame.contains(NSEvent.mouseLocation) { self.collapseZoom(); return nil }
            return event
        }
        let globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outsideCollapse)
        // Box both into one token so teardown removes whichever is set.
        zoomOutsideClickMonitor = [localClick, globalClick].compactMap { $0 }

        let target = zoomTargetFrame()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.32
            ctx.timingFunction = reduceMotion
                ? CAMediaTimingFunction(name: .easeInEaseOut)
                : CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)  // spring-like overshoot
            ctx.allowsImplicitAnimation = true
            // Lift the thumbnail dim so the full preview reads clean.
            backdropDimView?.animator().alphaValue = 0
            controlsOverlay?.animator().alphaValue = 0
            self.animator().setFrame(target, display: true)
        }
    }

    /// Tear down the O5' outside-click monitors (an array of tokens from the
    /// local + global registrations). Safe to call when none are set.
    private func removeZoomOutsideClickMonitor() {
        if let tokens = zoomOutsideClickMonitor as? [Any] {
            for token in tokens { NSEvent.removeMonitor(token) }
        }
        zoomOutsideClickMonitor = nil
    }

    private func collapseZoom() {
        guard isPreviewZoomed else { return }
        isPreviewZoomed = false
        removeZoomOutsideClickMonitor()
        // Card size from metrics (frame currently holds the zoomed size); origin
        // from the live slot so it collapses into where the stack now sits.
        let cardSize = NSSize(width: metrics.thumbW, height: metrics.thumbH + metrics.progressH)
        let target = preZoomFrame ?? NSRect(origin: slotOrigin(), size: cardSize)
        preZoomFrame = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.backdropDimView?.animator().alphaValue = 1
            self.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.level = .floating
                // Settle exactly on the live slot (the stack may have reflowed
                // while zoomed) and re-sync hover/key from the cursor's real
                // position. The frame just jumped back to the small slot under a
                // (possibly) still cursor, so without this resync mouseInsideOverlay
                // stays stale and the keyDown gate + key window desync, which is the
                // root of "Space and drag stop working after a zoom".
                self.setFrameOrigin(self.slotOrigin())
                // Back to the resting rule: the card fills edge to edge.
                self.thumbView?.layer?.contentsGravity = .resizeAspectFill
                self.resyncHoverAndTracking()
            }
        })
    }

    /// Re-arm hover after the O5 zoom toggles the frame. The zoom hides the chrome
    /// (alpha 0) and grows the window 2.5x without ever clearing `isHovered`, so on
    /// collapse the plain `updateHoverFocus(true)` hit the `hovered != isHovered`
    /// guard as a no-op and the controls stayed invisible/unresponsive until the
    /// cursor left and re-entered. Force `isHovered` back to false, recompute the
    /// corner/pill tracking areas (their bounds moved with the frame), then re-read
    /// the cursor and synthesize the hover-enter so the frost, buttons and pills
    /// light up immediately while the mouse is still on the card.
    private func resyncHoverAndTracking() {
        guard !isClosing, !isParked, !isPreviewZoomed else { return }
        recomputeControlTrackingAreas()
        let inside = frame.contains(NSEvent.mouseLocation)
        mouseInsideOverlay = inside
        // Clear the stale latch so setHovered actually runs for the real state.
        isHovered = false
        updateHoverFocus(inside)
        if !inside { restartDismissTimer() }
    }

    /// Force every control's NSTrackingArea to rebuild against its current bounds.
    /// The corner buttons and pills track hover with their own areas; after the
    /// zoom frame churn those areas can hold stale rects, so their hover tint stops
    /// firing until the next layout pass. updateTrackingAreas rebuilds them now.
    private func recomputeControlTrackingAreas() {
        guard let controls = controlsOverlay else { return }
        for view in controls.subviews { view.updateTrackingAreas() }
    }

    // MARK: - A7 Share

    @objc private func shareAction() {
        guard let view = contentView else { return }
        dismissTimer?.invalidate()  // resume on next hover-exit (already wired)
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        // Video shares the clip file; screenshot shares the image.
        let items: [Any] = videoPayload.map { [$0.url] } ?? [image]
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: - A8 drag payload refresh (one-line setter; no caller yet)

    /// Replace the displayed/dragged image so a future "edit returns to overlay"
    /// flow can refresh the drag-out payload. Not wired now (editing dismisses
    /// the overlay), so the drag always carries the freshest image we hold.
    func updateImage(_ newImage: NSImage) {
        image = newImage
        thumbView?.layer?.contents = newImage.bestCGImage
        thumbView?.dragImage = newImage
    }

    private var isClosing = false
    private var skipPolicyReset = false

    private func animatedClose() {
        guard !isClosing else { return }
        isClosing = true
        dismissTimer?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.forceCleanup()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            
            if let layer = self.contentView?.layer {
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                scaleAnim.toValue = 0.95
                scaleAnim.duration = 0.12
                scaleAnim.fillMode = .forwards
                scaleAnim.isRemovedOnCompletion = false
                layer.add(scaleAnim, forKey: "exitScale")
            }
            
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.forceCleanup() }
        })
    }

    private var didCleanup = false

    private func forceCleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        // Release O5 zoom ownership if this card closes while zoomed.
        if isPreviewZoomed { isPreviewZoomed = false }
        // P1: tear down the Space companion preview if this card owned it, and
        // remove the hint pill window so neither outlives the card.
        QuickLookController.shared.close(owner: self)
        spaceHintWindow?.orderOut(nil)
        spaceHintWindow = nil
        removeZoomOutsideClickMonitor()
        removeEventMonitors()
        parkedHandle?.orderOut(nil)  // don't leak the O1 handle on close/quit
        parkedHandle = nil
        orderOut(nil)
        QuickAccessWindow.openWindows.removeAll { $0 === self }
        // Re-flow the survivors to close the gap this card leaves (A6).
        QuickAccessWindow.reflowStack()
        // B4: the active-monitor follow monitor exists only while cards are open;
        // tear it down with the last card so it never leaks.
        QuickAccessWindow.removeFollowMonitorIfIdle()
        // Restore background-only policy so app doesn't appear in Cmd-Tab
        // (skip when transitioning to another window like editor or pin)
        if QuickAccessWindow.openWindows.isEmpty && !skipPolicyReset {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
        }
    }

    // MARK: - Actions

    @objc private func copyAction() {
        if let payload = videoPayload {
            // Copy the clip itself (a file ref apps and Finder can paste), not the
            // poster image.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([payload.url as NSURL])
        } else {
            ImageExporter.copyToClipboard(image: image)
        }
        pulseCard()  // M1' micro-feedback: quick pulse + the checkmark flash below
        showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
    }

    /// M1' copy micro-feedback: a quick scale pulse on the card so the copy reads
    /// as a tactile confirmation alongside the checkmark flash. No-op under Reduce
    /// Motion (the checkmark crossfade carries the confirmation there).
    private func pulseCard() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = contentView?.layer else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.05, 1.0]
        pulse.keyTimes = [0, 0.45, 1.0]
        pulse.duration = 0.24
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "copyPulse")
    }

    @objc private func saveAction() {
        if let payload = videoPayload {
            saveVideoAs(payload.url)
            return
        }
        let dir = Settings.autoSaveLocation
        let name = ImageExporter.timestampedName
        let ext = Settings.screenshotFormat
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("\(name).\(ext)")

        guard ImageExporter.save(image: image, to: url) != nil else {
            ToastWindow.show(message: "Could not save screenshot")
            return
        }

        showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
    }

    /// "Save As" for the video card: a save panel so the user picks where the clip
    /// lands, then copies the recording there. The original stays put (auto-saved
    /// recordings already live in the user's folder; this is an extra copy).
    private func saveVideoAs(_ source: URL) {
        dismissTimer?.invalidate()
        timeoutProgressLayer?.removeAnimation(forKey: "timeoutProgress")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let dest = panel.url else {
            if !isHovered { restartDismissTimer() }
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
            showConfirmation(icon: "checkmark") { [weak self] in self?.animatedClose() }
        } catch {
            ToastWindow.show(message: "Could not save recording")
            if !isHovered { restartDismissTimer() }
        }
    }

    /// Open the recording in the default player (double-click, Enter, the corner
    /// Open button, and the context menu all land here).
    @objc private func openVideoAction() {
        guard let payload = videoPayload else { return }
        NSWorkspace.shared.open(payload.url)
        animatedClose()
    }

    /// Copy the clip's path as text (context menu "Copy path").
    @objc private func copyVideoPathAction() {
        guard let payload = videoPayload else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload.url.path, forType: .string)
        ToastWindow.show(message: "Copied path")
    }

    /// Flash a confirmation icon over the thumbnail before closing
    private func showConfirmation(icon: String, then completion: @escaping () -> Void) {
        guard let clip = contentView?.subviews.first else { completion(); return }
        let size: CGFloat = 36
        let badge = NSImageView(frame: NSRect(
            x: (clip.bounds.width - size) / 2,
            y: (clip.bounds.height - size) / 2,
            width: size, height: size
        ))
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        badge.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        badge.layer?.cornerRadius = size / 2
        badge.layer?.cornerCurve = .continuous
        badge.alphaValue = 0
        badge.layer?.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        clip.addSubview(badge)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            badge.animator().alphaValue = 1
            
            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.7
            scaleAnim.toValue = 1.0
            scaleAnim.duration = 0.12
            badge.layer?.add(scaleAnim, forKey: "pop")
            badge.layer?.transform = CATransform3DIdentity
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion()
            }
        })
    }

    @objc private func editAction() {
        // Video: hand off to the recording's GIF/trim editor (the RecordingResult
        // window) instead of the screenshot annotation tool.
        if let payload = videoPayload {
            let actions = payload.actions
            let url = payload.url
            let duration = payload.duration
            skipPolicyReset = true
            animatedClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                actions?.reopenResultWindow(url: url, duration: duration)
            }
            return
        }
        guard let historyItem, let historyManager else { return }
        skipPolicyReset = true
        animatedClose()
        // Open after a short delay so cleanup doesn't kill activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image] in
            // The card shows the PRESENTED image (already composed onto the
            // default template or wallpaper). The editor must start from the
            // RAW capture in the history file, or it applies the background a
            // second time and the shot opens with two stacked wallpapers.
            let raw = NSImage(contentsOfFile: historyItem.imagePath) ?? image
            AnnotationWindowController.open(image: raw, historyItem: historyItem, historyManager: historyManager)
        }
    }

    @objc private func pinAction() {
        skipPolicyReset = true
        showConfirmation(icon: "pin") { [weak self] in
            guard let self else { return }
            self.animatedClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [image = self.image] in
                PinnedWindow.pin(image: image)
            }
        }
    }

    @objc private func deleteAction() {
        // M1': the trash button deletes with the same slide-out-toward-the-delete-
        // edge + fade as the O4' drag-off gesture (and the same clipboard toast).
        throwOffEdgeAndDelete()
    }

    @objc private func dismissAction() {
        // When THIS card is zoomed, Esc collapses the zoom, not the card (O5).
        if isPreviewZoomed { collapseZoom(); return }
        // P1: with the Space companion preview open, Esc closes the preview first.
        if QuickLookController.shared.isOpen(forOwner: self) {
            QuickLookController.shared.close(owner: self); return
        }
        animatedClose()
    }

    @objc private func standbyAllAction() {
        QuickAccessWindow.parkAll(on: overlayScreen)
    }

    @objc private func restoreAllAction() {
        QuickAccessWindow.restoreAll(on: overlayScreen)
    }

    /// Context-menu "Quick Look": the O5 in-place zoom, same as pressing Space.
    @objc private func quickLookAction() {
        toggleZoom()
    }

    /// Context-menu "Temporarily Hide": standby is ALWAYS a group action (user
    /// rule: "I always send every print to standby"), one handle, whole stack.
    @objc private func temporarilyHideAction() {
        QuickAccessWindow.parkAll(on: overlayScreen)
    }

    @objc private func showInFinderAction() {
        let url = videoPayload?.url ?? historyItem.map { URL(fileURLWithPath: $0.imagePath) }
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openWithAction(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let fileURL = videoPayload?.url ?? historyItem.map { URL(fileURLWithPath: $0.imagePath) }
        guard let fileURL else { return }
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Rotation (context menu)

    @objc private func rotateLeftAction()  { rotateImage(clockwise: false) }
    @objc private func rotateRightAction() { rotateImage(clockwise: true) }

    /// Rotate the capture 90°, refresh the card thumbnail in place, rewrite the
    /// HistoryItem PNG (+ thumbnail) on disk and re-copy to the clipboard when
    /// auto-copy is on, so every surface shows the same orientation.
    private func rotateImage(clockwise: Bool) {
        // Rotation rewrites the HistoryItem PNGs; it is a screenshot-only action and
        // the menu item never appears on a video card.
        guard let historyItem else { return }
        guard !isClosing, !isParked else { return }
        if isPreviewZoomed { collapseZoom() }
        guard let cg = image.bestCGImage,
              let rotatedCG = Self.rotated90(cg, clockwise: clockwise) else { return }
        // Swap the logical (point) size so the Retina backing keeps its scale.
        let rotatedImage = NSImage(
            cgImage: rotatedCG,
            size: NSSize(width: image.size.height, height: image.size.width)
        )

        image = rotatedImage
        // Rebuild so the thumb, drag payload and blurred backdrop all pick up
        // the rotated image (buildContent reads `image` for every layer).
        rebuildAtCurrentSize()

        if Settings.afterCaptureCopyToClipboard {
            ImageExporter.copyToClipboard(image: rotatedImage)
        }

        // Serve the rotated image from memory right away (history panel reads
        // through the cache), then rewrite the PNGs off the main thread,
        // mirroring the HistoryManager.add persistence pattern.
        HistoryImageCache.primeFull(rotatedImage, for: historyItem.imagePath)
        HistoryImageCache.primeThumbnail(rotatedImage, for: historyItem.thumbnailPath)
        let imagePath = historyItem.imagePath
        let thumbPath = historyItem.thumbnailPath
        let rect = historyItem.captureRect?.cgRect
        Task.detached(priority: .userInitiated) {
            guard let fullCG = rotatedImage.bestCGImage,
                  let png = ImageExporter.pngData(from: fullCG) else {
                print("[KRIT] Rotate persist failed: unable to encode rotated image")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
                HistoryManager.applyScreenshotMetadata(to: imagePath, rect: rect)
            } catch {
                print("[KRIT] Rotate persist failed at \(imagePath): \(error)")
                return
            }
            if let thumbCG = Self.downsampled(fullCG, maxDimension: 240),
               let thumbPNG = ImageExporter.pngData(from: thumbCG) {
                try? thumbPNG.write(to: URL(fileURLWithPath: thumbPath), options: .atomic)
            }
        }
    }

    /// Rotate a CGImage by 90°. CG positive angles run counterclockwise, so
    /// clockwise (Rotate Right) uses -π/2.
    nonisolated private static func rotated90(_ cg: CGImage, clockwise: Bool) -> CGImage? {
        let w = cg.width
        let h = cg.height
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: h,
            height: w,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// Downsample so the longest edge fits `maxDimension` (history thumbnail,
    /// same 240pt budget HistoryManager uses for its own thumbnails).
    nonisolated private static func downsampled(_ cg: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cg }
        let scale = maxDimension / longest
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    func show() {
        // SP1: ensure the screen-parameters observer is live (registered once).
        QuickAccessWindow.registerScreenObserverIfNeeded()
        // B4: start following the active monitor while any card is open (removed
        // when the last card closes).
        QuickAccessWindow.installFollowMonitorIfNeeded()
        // Newest card joins at the bottom corner; existing cards on this screen
        // spring UP to make room (O2). The stack is per-display: a shot on
        // monitor B starts a fresh column instead of offsetting from monitor A.
        let hadSiblings = !QuickAccessWindow.orderedStack(on: overlayScreen).isEmpty
        QuickAccessWindow.openWindows.append(self)
        if hadSiblings {
            // This card was placed by positionOverlay at the lone-card slot; reflow
            // settles it and pushes the older cards up to their new slots.
            QuickAccessWindow.reflowStack()
        }
    }
}

// MARK: - Draggable thumbnail (drag-and-drop to Finder/apps like CleanShot X)

@MainActor
// NSView on purpose: the thumb renders through layer.contents (aspect-fill),
// and an NSImageView with a nil `image` would repaint its own empty content
// over that CGImage on any redraw, blanking the card. Drag and click handling
// is all custom here, nothing from NSImageView was used.
private final class DraggableImageView: NSView, NSDraggingSource {

    var dragImage: NSImage?
    var onDoubleClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    /// File-drag-out finished. `accepted` is true when some target took the drop
    /// (operation != []); false when the user let go over nothing or the target
    /// refused, so the card can spring back instead of closing (the regret path).
    var onDragEnded: ((_ accepted: Bool) -> Void)?
    /// Hand the whole drag to the card's continuous direction classifier (the card
    /// is pinned to the anchor line, so there is no free move). The card decides by
    /// direction: toward the screen edge = delete, into the screen = file drag,
    /// downward = standby. It calls back through the supplied closure to start the
    /// file drag with the latest event at the moment it converts to a file drag.
    /// Returns true when the gesture was a card-owned gesture (delete/standby/cancel,
    /// the thumb does nothing more); false when it converted to a file drag (the card
    /// already invoked the begin-file-drag callback, so the thumb is done too).
    var onCardGesture: ((_ initialEvent: NSEvent, _ beginFileDrag: (NSEvent) -> Bool) -> Bool)?
    /// A click while the card is zoomed (O5) collapses the preview instead of
    /// editing/dragging. Returns true when it consumed the click.
    var onClickWhileZoomed: (() -> Bool)?
    /// Video card: drag the real clip on disk instead of materializing a temp PNG.
    /// When set, the file-drag carries this URL directly (no promise, no cleanup,
    /// the file is the user's saved recording, not a throwaway export).
    var fileURLOverride: (() -> URL?)?

    private var dragOrigin: NSPoint?
    private var activeDragFileURL: URL?
    private static var retainedDragFiles: Set<URL> = []
    private static let dragFileCleanupDelay: TimeInterval = 300

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Click on the zoomed preview collapses it (O5) before any drag/edit.
        if onClickWhileZoomed?() == true { return }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        let current = event.locationInWindow
        let dx = abs(current.x - (dragOrigin?.x ?? current.x))
        let dy = abs(current.y - (dragOrigin?.y ?? current.y))
        guard dx > 3 || dy > 3 else { return }
        dragOrigin = nil

        // The card is PINNED to the anchor line; there is no free move. Hand the
        // whole gesture to the card's continuous direction classifier, which decides
        // by where the cursor pulls from the grab: toward the screen edge = delete,
        // into the screen = file drag, downward = standby. The classifier calls back
        // through beginFileDrag(with:) the moment it converts to a file drag, so the
        // NSDraggingSession still originates here on the thumb. If no handler is wired
        // (shouldn't happen on a live card) fall back to an immediate file drag so the
        // gesture is never dead.
        if let handler = onCardGesture {
            _ = handler(event) { [weak self] ev in
                guard let self else { return false }
                self.beginFileDrag(with: ev)
                return true
            }
            return
        }
        beginFileDrag(with: event)
    }

    /// Start the file-drag-out session for this card. Called either directly (when no
    /// move machine is wired or the card declined a down-drag) or as the MOVE->FILE
    /// conversion callback once the cursor leaves the card. Video cards drag the real
    /// clip; screenshot cards drag a temp PNG with a promise fallback.
    func beginFileDrag(with event: NSEvent) {
        guard let dragImg = dragImage else { return }

        // Video: drag the real recording on disk (the file lives in the user's
        // folder, so no temp materialization, no cleanup, no promise fallback).
        if let videoURL = fileURLOverride?() {
            guard FileManager.default.fileExists(atPath: videoURL.path) else { return }
            onDragStarted?()
            let item = NSDraggingItem(pasteboardWriter: videoURL as NSURL)
            item.setDraggingFrame(bounds, contents: dragImg)
            beginDraggingSession(with: [item], event: event, source: self)
            return
        }

        guard let png = ImageExporter.pngData(from: dragImg),
              let fileURL = Self.makeTemporaryDragFile(data: png) else { return }

        onDragStarted?()

        activeDragFileURL = fileURL
        Self.retainedDragFiles.insert(fileURL)

        // Plain file URL covers Finder and apps that read a concrete file.
        let fileItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        fileItem.setDraggingFrame(bounds, contents: dragImg)

        // File-promise fallback for apps (Slack, Mail, VS Code, browsers) that
        // request a promised file instead of reading the URL directly. Mirrors
        // the canonical promise path in HistoryPanelController.
        let promise = NSFilePromiseProvider(
            fileType: "public.png",
            delegate: OverlayImageFilePromiseDelegate(image: dragImg)
        )
        let promiseItem = NSDraggingItem(pasteboardWriter: promise)
        promiseItem.setDraggingFrame(bounds, contents: dragImg)

        beginDraggingSession(with: [fileItem, promiseItem], event: event, source: self)
    }

    private static func makeTemporaryDragFile(data: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KritDrag", isDirectory: true)
        let filename = "\(ImageExporter.timestampedName)-\(UUID().uuidString.prefix(8)).png"
        let url = directory.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[KRIT] Drag export failed at \(url.path): \(error)")
            return nil
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // An empty operation mask means nothing accepted the drop (dropped over
        // empty space, or the target refused). Anything else is a real accept.
        let accepted = operation != []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduleActiveDragFileCleanup()
            // Releasing PAST the screen edge with no taker is the "throw it
            // away" gesture, so the card closes instead of springing back.
            // Releasing over empty space INSIDE the screen stays the regret
            // path: the card returns to its slot.
            let offscreen = !NSScreen.screens.contains { $0.frame.contains(screenPoint) }
            self.onDragEnded?(accepted || offscreen)
        }
    }

    private func scheduleActiveDragFileCleanup() {
        guard let url = activeDragFileURL else { return }
        activeDragFileURL = nil
        Self.scheduleDragFileCleanup(url)
    }

    private static func scheduleDragFileCleanup(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + dragFileCleanupDelay) {
            try? FileManager.default.removeItem(at: url)
            retainedDragFiles.remove(url)
        }
    }
}

// MARK: - File-promise delegate (A8 fallback for promise-requesting apps)

private final class OverlayImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Krit.OverlayFilePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let image: NSImage

    init(image: NSImage) {
        self.image = image
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "\(ImageExporter.timestampedName).png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            guard let png = ImageExporter.pngData(from: image) else {
                handler(ImageExporter.ExportError.pngEncodingFailed)
                return
            }
            try png.write(to: url, options: .atomic)
            handler(nil)
        } catch {
            handler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }
}

// MARK: - Content view that accepts first mouse + right-click

@MainActor
private final class OverlayContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class OverlayControlsView: NSView {
    // Backing view reference so hitTest can pass through it regardless of
    // its concrete type (NSGlassEffectView on 26+, NSVisualEffectView before).
    var glassBacking: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self || hit === glassBacking { return nil }
        return hit
    }
}

// MARK: - Corner button (glass circle, secondary action)

@MainActor
private final class OverlayCornerButton: NSButton {

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    // Let the first click land on the button even if the overlay window
    // isn't key yet, otherwise the first click just activates the window
    // and the user has to click twice for anything to happen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Suppress the default AppKit focus-ring line that paints under the
    // button when it becomes first responder.
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = KritColors.pillButtonHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = KritColors.pillButtonBackground.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = KritColors.pillButtonPressed.cgColor
        let scale = CATransform3DMakeScale(0.92, 0.92, 1)
        layer?.transform = scale
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.92
        spring.toValue = 1.0
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 15
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "bounceBack")
        layer?.transform = CATransform3DIdentity
        layer?.backgroundColor = isHovered
            ? KritColors.pillButtonHover.cgColor
            : KritColors.pillButtonBackground.cgColor
        super.mouseUp(with: event)
    }
}

@MainActor
private final class OverlayPillButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        alignment = .center
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = KritColors.pillButtonHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = KritColors.pillButtonBackground.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = KritColors.pillButtonPressed.cgColor
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        super.mouseDown(with: event)
        layer?.backgroundColor = isHovered
            ? KritColors.pillButtonHover.cgColor
            : KritColors.pillButtonBackground.cgColor
    }
}

// MARK: - Parked handle (A5): small glass tab with an up-chevron at the bottom edge

@MainActor
private final class ParkedHandleWindow: NSWindow {

    private let onRestore: () -> Void

    init(frame: NSRect, onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar  // sit above the overlay's own .floating level
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none

        let content = ParkedHandleView(frame: NSRect(origin: .zero, size: frame.size))
        content.onClick = { [weak self] in self?.onRestore() }

        // Liquid Glass backing (NSGlassEffectView on 26+, HUD blur before).
        // Pill scale: a 70x22 tab is the smallest glass in the app, radius 6.
        let glass = ChromeFactory.backing(frame: content.bounds, cornerRadius: ChromeFactory.Radius.pill)
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass, positioned: .below, relativeTo: nil)

        let chevron = NSImageView(frame: content.bounds)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Restore")?
            .withSymbolConfiguration(config)
        chevron.contentTintColor = .white
        chevron.imageScaling = .scaleNone
        chevron.imageAlignment = .alignCenter
        content.addSubview(chevron)

        // Hover is visual feedback ONLY (coral tint). Restore is strictly
        // click-driven: hover-restore meant the cursor, which rests exactly
        // where the handle spawns right after the park gesture, yanked the
        // card straight back up, reading as "standby only works once".
        content.onHoverChanged = { hovering in
            chevron.contentTintColor = hovering ? KritColors.accent : .white
        }

        contentView = content
    }

    override var canBecomeKey: Bool { false }
}

@MainActor
private final class ParkedHandleView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - UITestRunner probes (read-only state, no behavior)

// Exposição mínima pro UITestRunner validar o overlay por ESTADO real (janelas
// abertas, quem está em standby, se há zoom ativo). Só leitura: não dispara
// gesto nem muda nada, o runner sintetiza os eventos e afere o resultado aqui.
extension QuickAccessOverlay {
    /// Open card windows (parked cards included; their window object survives).
    @MainActor static var uiTestWindows: [NSWindow] {
        QuickAccessWindow.uiTestOpenWindows
    }

    /// Standby flag per open card, in the same order as `uiTestWindows`.
    @MainActor static func uiTestStandbyStates() -> [Bool] {
        QuickAccessWindow.uiTestOpenWindows.map { ($0 as? QuickAccessWindow)?.uiTestIsParked ?? false }
    }

    /// True when any card is currently in the O5 in-place zoom.
    @MainActor static func uiTestZoomActive() -> Bool {
        QuickAccessWindow.uiTestOpenWindows.contains { ($0 as? QuickAccessWindow)?.uiTestIsZoomed ?? false }
    }

    /// Tears down ONLY the newest card (the one a test scenario just spawned),
    /// leaving any real user cards untouched.
    @MainActor static func uiTestCloseNewest() {
        (QuickAccessWindow.uiTestOpenWindows.last as? QuickAccessWindow)?.uiTestForceCleanup()
    }

    /// Gesture-machine state of the newest card, for the harness to assert which
    /// pinned gesture a synthesized drag took. One of: "none" (no card), "closing",
    /// "zoom", "parked", "entering", "deleting" (toward the edge, trash), "standby"
    /// (downward minimize), "filedrag" (converted to a drag-out), or "resting".
    @MainActor static func uiTestGestureState() -> String {
        (QuickAccessWindow.uiTestOpenWindows.last as? QuickAccessWindow)?.uiTestGestureState ?? "none"
    }
}

private extension QuickAccessWindow {
    static var uiTestOpenWindows: [NSWindow] { openWindows }
    var uiTestIsParked: Bool { isParked }
    var uiTestIsZoomed: Bool { isPreviewZoomed }
    func uiTestForceCleanup() { forceCleanup() }
    /// Read-only snapshot of the gesture machine's current state for the harness.
    /// Transition states (closing/zoom/parked/entering) win over an in-flight pinned
    /// gesture; the live pinned mode (deleting/standby/filedrag) is reported next.
    var uiTestGestureState: String {
        if isClosing { return "closing" }
        if isPreviewZoomed { return "zoom" }
        if isParked { return "parked" }
        if isEntering { return "entering" }
        if currentGestureMode != .none { return currentGestureMode.rawValue }
        if isCardDragging { return "dragging" }
        return "resting"
    }
}
