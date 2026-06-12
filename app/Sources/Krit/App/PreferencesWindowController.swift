import AppKit

/// The Preferences sections, in sidebar order (CaseIterable follows source order,
/// not raw value). Raw values are stable so `show(tab:)` callers (AppDelegate,
/// AboutWindowController) keep working; `.general` and `.about` are referenced
/// externally. `presets` is declared before `about` so it shows above it in the
/// sidebar while keeping `about`'s raw value at 6.
enum PreferencesTab: Int, CaseIterable {
    case general = 0
    case capture = 1
    case recording = 2
    case preview = 3
    case editor = 4
    case shortcuts = 5
    case presets = 7
    case about = 6

    var title: String {
        switch self {
        case .general:   return "General"
        case .capture:   return "Capture"
        case .recording: return "Recording"
        case .preview:   return "Preview Overlay"
        case .editor:    return "Editor"
        case .shortcuts: return "Shortcuts"
        case .presets:   return "Presets"
        case .about:     return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:   return "gearshape"
        case .capture:   return "camera"
        case .recording: return "record.circle"
        case .preview:   return "rectangle.on.rectangle"
        case .editor:    return "pencil.tip.crop.circle"
        case .shortcuts: return "keyboard"
        case .presets:   return "wand.and.stars"
        case .about:     return "info.circle"
        }
    }
}

/// Raycast-style Settings: a single dark surface split into a sidebar of
/// sections and a scrolling content pane. The window chrome (fullSizeContentView,
/// sidebar vibrancy, glass chip rows, coral accent) stays in AppKit so it matches
/// the editor and onboarding windows; each section's body is a grouped SwiftUI
/// `Form` hosted in an `NSHostingView` (see PreferencesContent), giving the
/// native System Settings controls.
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private let windowSize = NSSize(width: 860, height: 620)
    private let sidebarWidth: CGFloat = 230

    private var sidebar: PreferencesSidebar!
    private var contentContainer: NSView!
    private var currentSectionView: NSView?
    private var sectionCache: [PreferencesTab: NSView] = [:]
    private var selectedTab: PreferencesTab = .general

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 860, height: 620)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KRIT Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        // Settings follows the app appearance (System / Light / Dark) like a native
        // macOS settings window, instead of forcing dark. AppearanceMode.applyCurrent
        // sets NSApp.appearance; this window inherits it.

        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        select(tab: .general, animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildLayout(in window: NSWindow) {
        let root = NSView(frame: NSRect(origin: .zero, size: windowSize))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        // Sidebar: behindWindow vibrancy so it reads as part of the window edge,
        // traffic lights floating over it (titlebar is transparent).
        let sidebarBlur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: windowSize.height))
        sidebarBlur.material = .sidebar
        sidebarBlur.blendingMode = .behindWindow
        sidebarBlur.state = .active
        sidebarBlur.autoresizingMask = [.height]
        root.addSubview(sidebarBlur)

        sidebar = PreferencesSidebar(width: sidebarWidth, height: windowSize.height) { [weak self] tab in
            self?.select(tab: tab, animated: true)
        }
        sidebar.view.autoresizingMask = [.height]
        sidebarBlur.addSubview(sidebar.view)

        // Hairline between sidebar and content. A separator color so it reads in
        // both light and dark instead of a fixed white alpha that vanished on light.
        let hairline = NSBox()
        hairline.boxType = .custom
        hairline.borderWidth = 0
        hairline.fillColor = .separatorColor
        hairline.frame = NSRect(x: sidebarWidth, y: 0, width: 1, height: windowSize.height)
        hairline.autoresizingMask = [.height]
        root.addSubview(hairline)

        // Content pane: a native window-background material so the surface is white
        // in light and dark-grey in dark exactly like System Settings, instead of
        // the editor's fixed dark stage color (which made Settings look non-native).
        let contentBlur = NSVisualEffectView(frame: NSRect(
            x: sidebarWidth + 1, y: 0,
            width: windowSize.width - sidebarWidth - 1, height: windowSize.height
        ))
        contentBlur.material = .contentBackground
        contentBlur.blendingMode = .behindWindow
        contentBlur.state = .active
        contentBlur.autoresizingMask = [.width, .height]
        root.addSubview(contentBlur)
        contentContainer = contentBlur
    }

    // MARK: - Section switching

    private func sectionView(for tab: PreferencesTab) -> NSView {
        if let cached = sectionCache[tab] { return cached }
        let view = PreferencesContent.makeView(for: tab)
        sectionCache[tab] = view
        return view
    }

    private func select(tab: PreferencesTab, animated: Bool) {
        selectedTab = tab
        sidebar.setSelected(tab)

        let incoming = sectionView(for: tab)
        incoming.frame = contentContainer.bounds
        incoming.autoresizingMask = [.width, .height]
        let outgoing = currentSectionView
        currentSectionView = incoming

        if animated, !reduceMotion, let outgoing, outgoing !== incoming {
            incoming.alphaValue = 0
            incoming.frame.origin.x = 14
            contentContainer.addSubview(incoming)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                incoming.animator().alphaValue = 1
                incoming.animator().frame.origin.x = 0
                outgoing.animator().alphaValue = 0
            }, completionHandler: {
                outgoing.removeFromSuperview()
                outgoing.alphaValue = 1
            })
        } else {
            outgoing?.removeFromSuperview()
            incoming.alphaValue = 1
            incoming.frame.origin.x = 0
            contentContainer.addSubview(incoming)
        }
    }

    // MARK: - Public surface

    func show(tab: PreferencesTab = .general) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        select(tab: tab, animated: window?.isVisible == true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: - Sidebar

/// Vertical list of section rows: a small glass-tiled icon plus the section
/// name, with a rounded highlight on the selected row.
@MainActor
private final class PreferencesSidebar {

    let view: NSView
    private var rows: [PreferencesTab: PreferencesSidebarRow] = [:]
    private let onSelect: (PreferencesTab) -> Void

    init(width: CGFloat, height: CGFloat, onSelect: @escaping (PreferencesTab) -> Void) {
        self.onSelect = onSelect
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let rowHeight: CGFloat = 38
        let gap: CGFloat = 4
        let horizontalInset: CGFloat = 14
        // Leave room under the traffic lights at the top of the window.
        var y = height - 56

        for tab in PreferencesTab.allCases {
            y -= rowHeight
            let row = PreferencesSidebarRow(tab: tab) { [weak self] in self?.onSelect(tab) }
            row.view.frame = NSRect(
                x: horizontalInset, y: y,
                width: width - horizontalInset * 2, height: rowHeight
            )
            // Anchor to the TOP edge: the frames above are computed from the
            // initial height, and the default mask pins them to the bottom, so
            // any window-height change pushed the first rows under the traffic
            // lights. A flexible bottom margin keeps the 56pt top clearance at
            // every height.
            row.view.autoresizingMask = [.minYMargin]
            view.addSubview(row.view)
            rows[tab] = row
            y -= gap
        }
    }

    func setSelected(_ tab: PreferencesTab) {
        for (key, row) in rows { row.setSelected(key == tab) }
    }
}

@MainActor
private final class PreferencesSidebarRow {

    let view: HoverButtonView
    private let highlight: NSView
    private let iconTile: NSView
    private let icon: NSImageView
    private let label: NSTextField

    init(tab: PreferencesTab, onClick: @escaping () -> Void) {
        view = HoverButtonView(onClick: onClick)
        view.wantsLayer = true

        highlight = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        highlight.isHidden = true
        view.addSubview(highlight)

        let tileSize: CGFloat = 24
        iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 6
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        view.addSubview(iconTile)

        icon = NSImageView()
        icon.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        icon.contentTintColor = .labelColor
        view.addSubview(icon)

        label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        view.addSubview(label)

        view.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.highlight.frame = bounds
            let tileY = (bounds.height - tileSize) / 2
            self.iconTile.frame = NSRect(x: 8, y: tileY, width: tileSize, height: tileSize)
            self.icon.frame = NSRect(x: 8 + (tileSize - 16) / 2, y: tileY + (tileSize - 16) / 2, width: 16, height: 16)
            self.label.frame = NSRect(x: 8 + tileSize + 10, y: (bounds.height - 18) / 2, width: bounds.width - 8 - tileSize - 14, height: 18)
        }
        view.onHover = { [weak self] hovering in
            guard let self, self.highlight.isHidden else { return }
            self.view.layer?.backgroundColor = hovering
                ? NSColor.white.withAlphaComponent(0.04).cgColor
                : NSColor.clear.cgColor
        }
    }

    func setSelected(_ selected: Bool) {
        highlight.isHidden = !selected
        if selected { view.layer?.backgroundColor = NSColor.clear.cgColor }
        icon.contentTintColor = selected ? KritColors.accent : .labelColor
        iconTile.layer?.backgroundColor = selected
            ? KritColors.accent.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(0.07).cgColor
        label.textColor = selected ? .labelColor : .secondaryLabelColor
    }
}

// MARK: - Hover/click view

/// A lightweight clickable, hover-tracking NSView. Reused for sidebar rows and
/// the visual selection cards so we get pointer feedback without NSButton chrome.
@MainActor
final class HoverButtonView: NSView {

    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onLayout: ((NSRect) -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    init(onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { /* swallow so mouseUp lands */ }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - UI test hooks

extension PreferencesWindowController {

    /// Test-only: forces the window up without changing activation policy.
    func uiTestForceShow() {
        select(tab: .general, animated: false)
        window?.makeKeyAndOrderFront(nil)
    }

    var uiTestWindow: NSWindow? { window }
    var uiTestSectionCount: Int { PreferencesTab.allCases.count }

    /// Walks every section (no animation), then snapshots the REAL window as the
    /// WindowServer composites it (sidebar vibrancy, dark mode), cacheDisplay
    /// can't render those. Falls back to cacheDisplay when window capture is
    /// unavailable. One PNG per section in `dir`.
    func uiTestRenderAllSections(toDirectory dir: String) async -> [String] {
        guard let window, let content = window.contentView else { return [] }
        var paths: [String] = []
        for tab in PreferencesTab.allCases {
            select(tab: tab, animated: false)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)

            let winID = CGWindowID(window.windowNumber)
            var data: Data?
            if let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, winID,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            } else if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            let path = (dir as NSString).appendingPathComponent("preferences-\(tab.title.lowercased().replacingOccurrences(of: " ", with: "-")).png")
            if let data, (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                paths.append(path)
            }
        }
        return paths
    }

    /// Test-only teardown.
    func uiTestClose() { window?.close() }
}
