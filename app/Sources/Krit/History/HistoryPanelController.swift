import AppKit

/// Capture history shown as a full-width band that slides down from the top of
/// the active screen (CleanShot-style "Capture History"): a translucent strip
/// with filter pills and a horizontal row of thumbnail cards. Restore re-floats
/// the capture as a QuickAccessOverlay card; double-click opens the editor.
@MainActor
final class HistoryPanelController: NSObject {

    static let shared = HistoryPanelController()

    /// Band height, measured from the top edge of the active screen.
    private static let bandHeight: CGFloat = 250

    private var window: HistoryBandWindow?
    private weak var historyManager: HistoryManager?

    // MARK: - Toggle

    /// The single entry point: the ⌘⇧H hotkey and the "Open History" menu item
    /// both call this. Re-triggering while open slides the band back up.
    func toggle(historyManager: HistoryManager) {
        if window != nil {
            hide()
        } else {
            show(historyManager: historyManager)
        }
    }

    /// Kept for the existing menu wiring; opens the band (no-op if already open).
    func show(historyManager: HistoryManager) {
        guard window == nil else {
            window?.refresh()
            return
        }
        self.historyManager = historyManager

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
        let band = HistoryBandWindow(
            historyManager: historyManager,
            screen: screen,
            bandHeight: Self.bandHeight,
            onClose: { [weak self] in self?.window = nil }
        )
        window = band
        band.present()
    }

    func hide() {
        window?.dismiss()
    }
}

// MARK: - Filter

private enum HistoryFilter: CaseIterable {
    case all, screenshots, videos, gifs

    var title: String {
        switch self {
        case .all:         return "All"
        case .screenshots: return "Screenshots"
        case .videos:      return "Videos"
        case .gifs:        return "GIFs"
        }
    }

    func matches(_ item: HistoryItem) -> Bool {
        switch self {
        case .all:         return true
        case .screenshots: return item.kind == .screenshot
        case .videos:      return item.kind == .video
        case .gifs:        return item.kind == .gif
        }
    }
}

// MARK: - Band Window

@MainActor
private final class HistoryBandWindow: NSWindow {

    private let historyManager: HistoryManager
    private let bandScreen: NSScreen
    private let bandHeight: CGFloat
    private let onClose: () -> Void

    private var activeFilter: HistoryFilter = .all
    private var items: [HistoryItem] = []
    private var filterButtons: [HistoryFilter: HistoryFilterPill] = [:]
    private var collectionView: NSCollectionView!
    private var emptyLabel: NSTextField!

    private var keyMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var isClosing = false

    init(historyManager: HistoryManager, screen: NSScreen, bandHeight: CGFloat, onClose: @escaping () -> Void) {
        self.historyManager = historyManager
        self.bandScreen = screen
        self.bandHeight = bandHeight
        self.onClose = onClose

        let vf = screen.frame
        let rect = NSRect(x: vf.minX, y: vf.maxY - bandHeight, width: vf.width, height: bandHeight)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        // Sit just under the menu bar so the band reads as a system-level strip.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none  // never leak the band into a capture

        buildContent(width: vf.width)
        reloadItems()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Content

    private func buildContent(width: CGFloat) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: bandHeight))
        root.wantsLayer = true
        // Clip the open/close slide to the band's own bounds so the translated
        // content never paints past the top edge onto a stacked display.
        root.layer?.masksToBounds = true
        contentView = root

        // Native translucent material (glass on macOS 26+, HUD blur fallback).
        // No corner radius on the band itself; it's flush to the screen top.
        let backing = ChromeFactory.backing(frame: root.bounds, cornerRadius: 0, variant: .regular)
        backing.autoresizingMask = [.width, .height]
        root.addSubview(backing)

        // Thin separator hairline along the bottom edge.
        let hairline = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hairline.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(hairline)

        // ── Filter pills, centered near the top ──
        let pillsStack = NSStackView()
        pillsStack.orientation = .horizontal
        pillsStack.spacing = 8
        pillsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pillsStack)

        for filter in HistoryFilter.allCases {
            let pill = HistoryFilterPill(title: filter.title) { [weak self] in
                self?.selectFilter(filter)
            }
            pill.isActive = (filter == activeFilter)
            filterButtons[filter] = pill
            pillsStack.addArrangedSubview(pill)
        }

        NSLayoutConstraint.activate([
            pillsStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            pillsStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
        ])

        // ── Horizontal card row in a native scroll view ──
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 200, height: 158)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)

        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = false
        cv.backgroundColors = [.clear]
        cv.dataSource = self
        cv.delegate = self
        cv.register(HistoryCardItem.self, forItemWithIdentifier: HistoryCardItem.identifier)
        collectionView = cv

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 26, width: width, height: bandHeight - 26 - 64))
        scroll.documentView = cv
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)

        // Empty state, centered in the card area.
        let empty = NSTextField(labelWithString: "No captures yet. Press \u{2318}\u{21E7}4 to take one.")
        empty.font = .systemFont(ofSize: 14, weight: .medium)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(empty)
        emptyLabel = empty
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Data

    private func reloadItems() {
        items = historyManager.items.filter { activeFilter.matches($0) }
        collectionView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        updateFilterVisibility()
    }

    /// Refresh after an external change (e.g. re-show while already open).
    func refresh() { reloadItems() }

    /// Videos / GIFs pills only appear when the history actually holds such items
    /// (future-proof without inventing a new model). All / Screenshots always show.
    private func updateFilterVisibility() {
        let all = historyManager.items
        let hasVideos = all.contains { HistoryFilter.videos.matches($0) }
        let hasGifs = all.contains { HistoryFilter.gifs.matches($0) }
        filterButtons[.videos]?.isHidden = !hasVideos
        filterButtons[.gifs]?.isHidden = !hasGifs
    }

    private func selectFilter(_ filter: HistoryFilter) {
        guard filter != activeFilter else { return }
        activeFilter = filter
        for (f, pill) in filterButtons { pill.isActive = (f == filter) }
        reloadItems()
    }

    private func deleteAndRefresh(_ item: HistoryItem) {
        historyManager.delete(item)
        reloadItems()
    }

    // MARK: - Present / Dismiss

    func present() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The window frame is ALWAYS the on-screen rect and never moves during the
        // animation, so it can never spill onto a display sitting above or beside
        // this one (the multi-monitor leak). The slide is faked by translating the
        // content layer, which the window bounds clip to the band's own rect.
        let onScreen = NSRect(x: bandScreen.frame.minX, y: bandScreen.frame.maxY - bandHeight,
                              width: bandScreen.frame.width, height: bandHeight)

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        setFrame(onScreen, display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)

        if reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.animator().alphaValue = 1
            }
        } else {
            // Start nudged up and clipped, settle down into place while fading in.
            slideContent(translateY: Self.slideDistance)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
                self.slideContent(translateY: 0, animated: true, duration: 0.25,
                                  timing: CAMediaTimingFunction(name: .easeOut))
            }
        }

        installMonitors()
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        removeMonitors()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.onClose()
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: self)
        }

        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            // Slide the content up (clipped to the band) and fade out together. The
            // window frame stays put, so nothing ever crosses onto another monitor.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
                self.slideContent(translateY: Self.slideDistance, animated: true, duration: 0.22,
                                  timing: CAMediaTimingFunction(name: .easeIn))
            }, completionHandler: finish)
        }
    }

    /// Distance the content travels for the open/close slide. Short and always
    /// inside the band, so the motion reads without the window leaving its screen.
    private static let slideDistance: CGFloat = 22

    /// Offset the band's content vertically without moving the window. Positive Y
    /// shifts it up (AppKit layer coordinates), clipped at the top edge by the root
    /// layer's masksToBounds. Uses `sublayerTransform` so AppKit's own layout never
    /// resets it (unlike the contentView layer's own transform), which keeps the
    /// open/close motion strictly inside the target screen on multi-monitor setups.
    private func slideContent(translateY: CGFloat, animated: Bool = false,
                              duration: CFTimeInterval = 0, timing: CAMediaTimingFunction? = nil) {
        guard let layer = contentView?.layer else { return }
        let transform = CATransform3DMakeTranslation(0, translateY, 0)
        if animated {
            let anim = CABasicAnimation(keyPath: "sublayerTransform")
            anim.fromValue = layer.value(forKeyPath: "sublayerTransform")
            anim.toValue = NSValue(caTransform3D: transform)
            anim.duration = duration
            anim.timingFunction = timing
            anim.fillMode = .forwards
            layer.add(anim, forKey: "bandSlide")
        }
        layer.sublayerTransform = transform
    }

    // MARK: - Event monitors (Esc + click-outside)

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }  // Esc
            return event
        }

        // A mouse-down outside the band (in another app or on the desktop) closes it.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isClosing else { return event }
            if !self.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
            return event
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }
}

// MARK: - Collection data source / delegate

extension HistoryBandWindow: NSCollectionViewDataSource {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: HistoryCardItem.identifier, for: indexPath) as! HistoryCardItem
        let item = items[indexPath.item]
        cell.configure(
            item: item,
            historyManager: historyManager,
            onRestore: { [weak self] in
                guard let self else { return }
                self.dismiss()
                QuickAccessOverlay.show(image: item.fullImage, historyItem: item, historyManager: self.historyManager)
            },
            onOpenEditor: { [weak self] in
                guard let self else { return }
                self.dismiss()
                AnnotationWindowController.open(image: item.fullImage, historyItem: item, historyManager: self.historyManager)
            },
            onDelete: { [weak self] in self?.deleteAndRefresh(item) }
        )
        return cell
    }
}

extension HistoryBandWindow: NSCollectionViewDelegate {}

// MARK: - Filter pill (segmented-style button)

@MainActor
private final class HistoryFilterPill: NSButton {

    var isActive = false { didSet { applyStyle() } }
    private let onTap: () -> Void

    init(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .rounded
        focusRingType = .none
        font = .systemFont(ofSize: 12.5, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        // Padding around the title.
        let measured = (title as NSString).size(withAttributes: [.font: font!]).width
        widthAnchor.constraint(equalToConstant: ceil(measured) + 28).isActive = true
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap() }

    private func applyStyle() {
        if isActive {
            layer?.backgroundColor = KritColors.accent.cgColor
            contentTintColor = .white
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white,
                .font: font as Any,
            ])
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            contentTintColor = .labelColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85),
                .font: font as Any,
            ])
        }
    }
}

// MARK: - Card item

@MainActor
private final class HistoryCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("HistoryCardItem")

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        // The app ships in English; pin the locale so timestamps read "1 hour ago"
        // instead of following the system locale.
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private var historyItem: HistoryItem?
    private weak var historyManager: HistoryManager?
    private var onRestore: (() -> Void)?
    private var onOpenEditor: (() -> Void)?
    private var onDelete: (() -> Void)?

    private let thumbView = NSImageView()
    private let ageLabel = NSTextField(labelWithString: "")
    private let restorePill = HistoryRestorePill()
    private let sourceBadge = SourceAppBadge()
    private var trackingArea: NSTrackingArea?
    private var well: NSView!

    override func loadView() {
        let container = ClickThroughCardView(frame: NSRect(x: 0, y: 0, width: 200, height: 158))
        container.wantsLayer = true
        // A plain click restores; double-click opens the editor; a drag past the
        // movement threshold starts a real file-drag of the capture on disk.
        container.onClick = { [weak self] in self?.onRestore?() }
        container.onDoubleClick = { [weak self] in self?.onOpenEditor?() }
        container.onRightClick = { [weak self] event in self?.showMenu(event) }
        // The drag carries the COMPOSED file (presentedFileURL): the image with its
        // preset/background applied, matching what the band shows. Captures taken
        // without a preset fall back to the raw shot. Dragging the raw file when a
        // preset was applied was the bug the owner flagged.
        container.fileURLProvider = { [weak self] in
            guard let item = self?.historyItem else { return nil }
            let url = item.presentedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Composed file not written yet: fall back to the raw shot rather
                // than dragging nothing.
                let raw = URL(fileURLWithPath: item.imagePath)
                return FileManager.default.fileExists(atPath: raw.path) ? raw : nil
            }
            return url
        }
        container.dragImageProvider = { [weak self] in self?.thumbView.image }

        // Thumbnail well: rounded corners + light shadow (Apple-native layer).
        let well = NSView(frame: NSRect(x: 0, y: 28, width: 200, height: 130))
        well.wantsLayer = true
        well.layer?.cornerRadius = 12
        well.layer?.cornerCurve = .continuous
        well.layer?.shadowColor = NSColor.black.cgColor
        well.layer?.shadowOpacity = 0.18
        well.layer?.shadowRadius = 8
        well.layer?.shadowOffset = CGSize(width: 0, height: -2)
        // Accent ring that lights up on hover so the whole card reads as one target.
        well.layer?.borderColor = KritColors.accent.cgColor
        well.layer?.borderWidth = 0
        self.well = well
        container.addSubview(well)

        thumbView.frame = well.bounds
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 12
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = KritColors.canvasBackground.cgColor
        well.addSubview(thumbView)

        // Source-app badge: the icon of the app that was frontmost at capture
        // time, pinned to the thumbnail's bottom-right (CleanShot-style). Always
        // visible when known; hidden when the capture has no recorded source.
        sourceBadge.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(sourceBadge)
        NSLayoutConstraint.activate([
            sourceBadge.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -7),
            sourceBadge.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -7),
        ])

        // Primary-action Restore pill: coral capsule matching the filter pills
        // (26pt tall, radius = height/2), centered on the thumbnail, hidden until
        // hover. Reads as part of the app, not a floating badge.
        restorePill.onTap = { [weak self] in self?.onRestore?() }
        restorePill.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(restorePill)
        NSLayoutConstraint.activate([
            restorePill.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            restorePill.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        restorePill.isHidden = true

        ageLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.alignment = .left
        ageLabel.lineBreakMode = .byTruncatingTail
        ageLabel.frame = NSRect(x: 2, y: 6, width: 196, height: 16)
        container.addSubview(ageLabel)

        view = container
    }

    func configure(
        item: HistoryItem,
        historyManager: HistoryManager,
        onRestore: @escaping () -> Void,
        onOpenEditor: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.historyItem = item
        self.historyManager = historyManager
        self.onRestore = onRestore
        self.onOpenEditor = onOpenEditor
        self.onDelete = onDelete
        thumbView.image = historyManager.cachedThumbnail(for: item) ?? item.thumbnail
        ageLabel.stringValue = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date())
        sourceBadge.icon = item.sourceAppIcon
        setupTracking()
    }

    private func setupTracking() {
        if let old = trackingArea { view.removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Lift the whole card on hover: accent ring, deeper shadow, slight scale, and
    /// the Restore affordance. The card already restores on a plain click, so the
    /// highlight signals the entire thumbnail is the target, not just the pill.
    private func setHovered(_ hovered: Bool) {
        restorePill.isHidden = !hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            well.layer?.borderWidth = hovered ? 2 : 0
            well.layer?.shadowOpacity = hovered ? 0.28 : 0.18
            // Scale from the well's center so the lift stays anchored.
            well.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            well.layer?.position = CGPoint(x: well.frame.midX, y: well.frame.midY)
            well.layer?.transform = hovered
                ? CATransform3DMakeScale(1.03, 1.03, 1)
                : CATransform3DIdentity
        }
    }

    private func showMenu(_ event: NSEvent) {
        guard historyItem != nil else { return }
        let menu = NSMenu()
        menu.addItem(menuItem("Open in Editor", #selector(menuOpen)))
        menu.addItem(menuItem("Copy", #selector(menuCopy)))
        menu.addItem(menuItem("Show in Finder", #selector(menuShowInFinder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Delete", #selector(menuDelete)))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuOpen() { onOpenEditor?() }

    @objc private func menuCopy() {
        guard let item = historyItem else { return }
        ImageExporter.copyToClipboard(image: item.fullImage)
    }

    @objc private func menuShowInFinder() {
        guard let item = historyItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.imagePath)])
    }

    @objc private func menuDelete() { onDelete?() }
}

/// Card background that separates a click from a drag, mirroring the overlay's
/// DraggableImageView. A plain click restores; a double-click opens the editor;
/// a mouse-down that moves past `dragThreshold` becomes a real file-drag of the
/// capture on disk (Finder/apps), so the card no longer restores on every press.
/// Right-click forwards to the context menu. The Restore pill keeps priority:
/// AppKit routes its mouse-down to the pill, so it never reaches this view.
@MainActor
private final class ClickThroughCardView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Concrete file on disk to drag out (the raw capture). Nil suppresses drag.
    var fileURLProvider: (() -> URL?)?
    /// Thumbnail used as the drag image so the user sees what they're carrying.
    var dragImageProvider: (() -> NSImage?)?

    /// 4pt of travel separates an intentional drag from a jittery click, the same
    /// threshold the overlay's DraggableImageView uses.
    private static let dragThreshold: CGFloat = 4
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownPoint = nil
            onDoubleClick?()
            return
        }
        mouseDownPoint = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, !didStartDrag else { return }
        let current = event.locationInWindow
        let dx = abs(current.x - origin.x)
        let dy = abs(current.y - origin.y)
        guard dx > Self.dragThreshold || dy > Self.dragThreshold else { return }

        guard let fileURL = fileURLProvider?() else { return }
        didStartDrag = true
        mouseDownPoint = nil

        let dragImage = dragImageProvider?()
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        // A press that never crossed the drag threshold is a plain click: restore.
        guard !didStartDrag, mouseDownPoint != nil else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Restore pill (primary-action capsule)

/// Coral primary-action pill shown on hover, centered on the thumbnail. Matches
/// the filter pills: 26pt tall, fully rounded (radius = height/2), with a subtle
/// hover lift so it reads as part of the app's pill language.
@MainActor
private final class HistoryRestorePill: NSButton {

    var onTap: (() -> Void)?

    private static let height: CGFloat = 26

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .rounded
        focusRingType = .none
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = KritColors.accent.cgColor

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Restore")?
            .withSymbolConfiguration(symbolConfig)
        contentTintColor = .white
        attributedTitle = NSAttributedString(string: " Restore", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
        ])

        target = self
        action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        let titleWidth = (" Restore" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        ]).width
        // Capsule padding around the icon + title, sized like the filter pills.
        widthAnchor.constraint(equalToConstant: ceil(titleWidth) + 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = (hovered
                ? KritColors.accent.blended(withFraction: 0.12, of: .white) ?? KritColors.accent
                : KritColors.accent).cgColor
        }
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - Source-app badge

/// Small rounded-square badge holding the source app's icon, pinned to the
/// thumbnail's bottom-right (CleanShot-style). A subtle dark backing with a
/// hairline keeps the icon legible over any thumbnail. Hidden when the capture
/// has no recorded source app.
@MainActor
private final class SourceAppBadge: NSView {

    private static let side: CGFloat = 24
    private static let inset: CGFloat = 3

    private let iconView = NSImageView()

    var icon: NSImage? {
        didSet {
            iconView.image = icon
            isHidden = (icon == nil)
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        // Soft drop so the badge lifts off busy thumbnails.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Let clicks fall through to the card underneath so the badge never blocks
    // a restore/drag on the thumbnail it sits on.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
