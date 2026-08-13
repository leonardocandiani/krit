import AppKit
import SwiftUI

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
    case permissions = 8
    case about = 6

    /// Looks a tab up by its lower-cased title, for `krit://preferences/<name>`.
    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.title.lowercased() == name.lowercased() })
        else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .general:     return "General"
        case .capture:     return "Capture"
        case .recording:   return "Recording"
        case .preview:     return "Preview"
        case .editor:      return "Editor"
        case .shortcuts:   return "Shortcuts"
        case .presets:     return "Presets"
        case .permissions: return "Permissions"
        case .about:       return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .capture:     return "camera"
        case .recording:   return "record.circle"
        case .preview:     return "rectangle.on.rectangle"
        case .editor:      return "pencil.tip.crop.circle"
        case .shortcuts:   return "keyboard"
        case .presets:     return "wand.and.stars"
        case .permissions: return "lock.shield"
        case .about:       return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general:     return "Launch, appearance, and capture defaults."
        case .capture:     return "File format, timer, window background, and save location."
        case .recording:   return "Video, audio, camera, cursor, and GIF defaults."
        case .preview:     return "Preview size, timeout, and screen position."
        case .editor:      return "Annotation thickness and capture templates."
        case .shortcuts:   return "Global shortcuts for capture, recording, and tools."
        case .presets:     return "Saved regions, formats, actions, and hotkeys."
        case .permissions: return "Screen, accessibility, camera, and microphone access."
        case .about:       return "Version, updates, license, and project links."
        }
    }

    /// Section this tab belongs to in the sidebar, or nil when it needs no
    /// header above it. Grouping nine flat rows into three named blocks is what
    /// turns a list into a map.
    var group: String? {
        switch self {
        case .general:     return nil
        case .capture:     return "Capture"
        case .editor:      return "Editing"
        case .shortcuts:   return "KRIT"
        default:           return nil
        }
    }
}

/// Native macOS Settings shell: AppKit owns the window and source-list sidebar,
/// while one SwiftUI hosting view renders the selected grouped form. Replacing
/// the hosting root keeps settings fresh without retaining nine UI trees.
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private let windowSize = NSSize(width: 860, height: 620)
    private let sidebarWidth: CGFloat = 196
    private static let fallbackSidebarIconCenterX: CGFloat = 16

    private var sidebar: NativePreferencesSidebar!
    private var contentHostingView: NSHostingView<AnyView>!
    private var selectedTab: PreferencesTab?
    private(set) var uiTestRenderFallbackCount = 0

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KRIT Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Deliberately NOT movable by background. Settings is a form: dragging a
        // slider, a segmented control or a text field would otherwise hand the
        // drag to the window and move the whole thing instead of the control.
        // The transparent titlebar is still there to drag by.
        window.isMovableByWindowBackground = false
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 540)
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

        // The titlebar reports fractional intermediate geometry while AppKit is
        // constructing the full-size chrome. Build on the stable native 16 pt
        // axis so sidebar padding does not depend on that construction timing.
        let sidebarIconCenterX = Self.fallbackSidebarIconCenterX

        // A native source list owns keyboard navigation, selection and VoiceOver.
        // The sidebar material is structural on every supported macOS version;
        // Liquid Glass stays reserved for floating chrome such as HUDs and docks.
        sidebar = NativePreferencesSidebar(
            width: sidebarWidth,
            height: windowSize.height,
            iconCenterX: sidebarIconCenterX
        ) { [weak self] tab in
            self?.select(tab: tab, animated: true)
        }
        let sidebarBacking = NSVisualEffectView()
        sidebarBacking.material = .sidebar
        sidebarBacking.blendingMode = .behindWindow
        sidebarBacking.state = .active
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarBacking.addSubview(sidebar.view)
        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: sidebarBacking.leadingAnchor),
            sidebar.view.trailingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: sidebarBacking.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: sidebarBacking.bottomAnchor),
        ])
        sidebarBacking.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: windowSize.height)
        sidebarBacking.autoresizingMask = [.height]
        root.addSubview(sidebarBacking)

        // Hairline between sidebar and content. A separator color so it reads in
        // both light and dark instead of a fixed white alpha that vanished on light.
        let hairline = PreferencesSeparatorView()
        hairline.frame = NSRect(x: sidebarWidth, y: 0, width: 0.5, height: windowSize.height)
        hairline.autoresizingMask = [.height]
        root.addSubview(hairline)

        // Content pane: a native window-background material so the surface is white
        // in light and dark-grey in dark exactly like System Settings, instead of
        // the editor's fixed dark stage color (which made Settings look non-native).
        let contentBlur = NSVisualEffectView(frame: NSRect(
            x: sidebarWidth + 0.5, y: 0,
            width: windowSize.width - sidebarWidth - 0.5, height: windowSize.height
        ))
        contentBlur.material = .contentBackground
        contentBlur.blendingMode = .behindWindow
        contentBlur.state = .active
        contentBlur.autoresizingMask = [.width, .height]
        root.addSubview(contentBlur)

        contentHostingView = NSHostingView(rootView: PreferencesContent.makeRootView(for: .general))
        contentHostingView.frame = contentBlur.bounds
        contentHostingView.autoresizingMask = [.width, .height]
        contentBlur.addSubview(contentHostingView)
    }

    private static func closeButtonCenterX(in window: NSWindow, relativeTo view: NSView) -> CGFloat? {
        guard let closeButton = window.standardWindowButton(.closeButton) else { return nil }
        let center = NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY)
        return view.convert(center, from: closeButton).x
    }

    // MARK: - Section switching

    private func select(tab: PreferencesTab, animated: Bool, forceReload: Bool = false) {
        guard selectedTab != tab || forceReload else {
            sidebar.setSelected(tab)
            return
        }
        selectedTab = tab
        sidebar.setSelected(tab)
        contentHostingView.rootView = PreferencesContent.makeRootView(for: tab)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        contentHostingView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.Duration.quick
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentHostingView.animator().alphaValue = 1
        }
    }

    // MARK: - Public surface

    func show(tab: PreferencesTab = .general) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        select(tab: tab, animated: false, forceReload: window?.isVisible != true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

// MARK: - Native source-list sidebar

private enum PreferencesSidebarMetrics {
    static let iconSize: CGFloat = 13
    static let iconCenterInRow: CGFloat = 12
    // Auto Layout pixel-aligns the footer's odd-sized NSImageView 0.75 pt to the
    // right. Counter that frame adjustment so its rendered center stays on the
    // same axis as the source-list glyphs above it.
    static let footerIconCenterInRow: CGFloat = iconCenterInRow - 0.75
    static let surfaceHorizontalInset: CGFloat = 0
    static let labelLeading = iconCenterInRow + iconSize / 2 + 10
}

@MainActor
private final class PreferencesSourceListTableView: NSTableView {
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // Source-list style reserves a leading gutter inside every cell. KRIT's
        // icons use the traffic-light axis instead, so the custom cell owns that
        // gutter while the table keeps native selection and keyboard behavior.
        frame.size.width += frame.minX
        frame.origin.x = 0
        return frame
    }
}

/// AppKit's source list supplies the navigation behavior a Settings window is
/// expected to have: arrow keys, selected-row semantics, focus and VoiceOver.
/// KRIT only customizes the selected fill and the compact cell content.
@MainActor
final class NativePreferencesSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let view: NSView

    /// A sidebar line is either a section header or a tab. Nine flat rows read
    /// as a list; the same nine under three headers read as a map, which is the
    /// whole reason the headers exist.
    private enum Row {
        case header(String)
        case tab(PreferencesTab)

        var tab: PreferencesTab? {
            if case .tab(let t) = self { return t }
            return nil
        }
    }

    private let tableView = PreferencesSourceListTableView()
    private var updateButton: SidebarFooterButton!
    private let rows: [Row] = PreferencesTab.allCases.flatMap { tab -> [Row] in
        guard let group = tab.group else { return [.tab(tab)] }
        return [.header(group), .tab(tab)]
    }
    private let onSelect: (PreferencesTab) -> Void
    private var suppressSelectionCallback = false

    /// Row index of a tab, for selection round-trips.
    private func index(of tab: PreferencesTab) -> Int? {
        rows.firstIndex { $0.tab == tab }
    }

    init(
        width: CGFloat,
        height: CGFloat,
        iconCenterX: CGFloat = 16,
        onSelect: @escaping (PreferencesTab) -> Void
    ) {
        let rowHorizontalInset = max(0, iconCenterX - PreferencesSidebarMetrics.iconCenterInRow)
        self.onSelect = onSelect
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preferences.section"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsTypeSelect = true
        tableView.focusRingType = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Preferences sections")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Update check lives at the foot of the sidebar, out of the section
        // list: it is an action, not a destination, and putting it among the
        // tabs would make it read as a tenth place to go.
        updateButton = SidebarFooterButton(title: "Check for updates", symbol: "arrow.trianglehead.2.clockwise") {
            UpdaterManager.shared.checkForUpdates()
        }
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(updateButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: rowHorizontalInset),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -rowHorizontalInset),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 58),
            scrollView.bottomAnchor.constraint(equalTo: updateButton.topAnchor, constant: -10),

            updateButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: rowHorizontalInset),
            updateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -rowHorizontalInset),
            updateButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            updateButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let identifier = NSUserInterfaceItemIdentifier("preferences.sidebar.header")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PreferencesSidebarHeader
                ?? PreferencesSidebarHeader()
            view.identifier = identifier
            view.configure(title: title)
            return view
        case .tab(let tab):
            let identifier = NSUserInterfaceItemIdentifier("preferences.sidebar.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativePreferencesSidebarCell
                ?? NativePreferencesSidebarCell()
            cell.identifier = identifier
            cell.configure(tab: tab, selected: tableView.selectedRowIndexes.contains(row))
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NativePreferencesSidebarRowView()
    }

    /// A header is a label, not a destination: arrow keys and clicks skip it.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].tab != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].tab == nil ? 30 : 36
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshVisibleCells()
        guard !suppressSelectionCallback,
              tableView.selectedRow >= 0,
              let tab = rows[tableView.selectedRow].tab else { return }
        onSelect(tab)
    }

    func setSelected(_ tab: PreferencesTab) {
        guard let row = index(of: tab) else { return }
        if tableView.selectedRow != row {
            suppressSelectionCallback = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            suppressSelectionCallback = false
        }
        refreshVisibleCells()
    }

    private func refreshVisibleCells() {
        for row in rows.indices {
            guard let tab = rows[row].tab,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NativePreferencesSidebarCell else { continue }
            cell.configure(tab: tab, selected: tableView.selectedRowIndexes.contains(row))
        }
    }

    var uiTestTableView: NSTableView { tableView }

    var uiTestSelectedTab: PreferencesTab? {
        guard tableView.selectedRow >= 0 else { return nil }
        return rows[tableView.selectedRow].tab
    }

    var uiTestFirstIconCenterX: CGFloat? {
        uiTestFirstIconFrame?.midX
    }

    var uiTestFirstRowFrame: NSRect? {
        view.layoutSubtreeIfNeeded()
        guard let row = rows.firstIndex(where: { $0.tab != nil }) else { return nil }
        return view.convert(tableView.rect(ofRow: row), from: tableView)
    }

    var uiTestFirstIconFrame: NSRect? {
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        guard let row = rows.firstIndex(where: { $0.tab != nil }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NativePreferencesSidebarCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        return view.convert(cell.uiTestIconFrame, from: cell)
    }

    var uiTestFirstSelectionSurfaceFrame: NSRect? {
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        guard let row = rows.firstIndex(where: { $0.tab != nil }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NativePreferencesSidebarCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        return view.convert(cell.uiTestSelectionSurfaceFrame, from: cell)
    }

    var uiTestFooterIconCenterX: CGFloat {
        view.layoutSubtreeIfNeeded()
        updateButton.layoutSubtreeIfNeeded()
        let center = NSPoint(x: updateButton.uiTestIconCenterX, y: updateButton.bounds.midY)
        return view.convert(center, from: updateButton).x
    }
}

@MainActor
private final class PreferencesSeparatorView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = KritColors.hairline.cgColor
    }
}

/// A soft-tinted action button: accent at low alpha for the fill, accent for
/// the label. Reads as actionable without competing with the primary button in
/// the content pane, which is the only place a solid accent fill belongs.
@MainActor
private final class SidebarFooterButton: NSView {
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = ChromeFactory.Radius.control
        layer?.cornerCurve = .continuous

        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        glyph.contentTintColor = KritColors.accent
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        label.attributedStringValue = KritType.bodyEmphasis.string(title, color: KritColors.accent)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.footerIconCenterInRow
            ),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.labelLeading
            ),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyAppearance() }
    override func mouseDown(with event: NSEvent) { action() }

    private func applyAppearance() {
        let alpha: CGFloat = hovered ? 0.20 : 0.12
        crossfadeBackground(to: KritColors.accent.withAlphaComponent(alpha))
    }

    var uiTestIconCenterX: CGFloat { glyph.frame.midX }
}

/// An all-caps group label above a run of sidebar rows. Tracked wide and set in
/// the tertiary tone so the block recedes while every letter stays legible.
@MainActor
private final class PreferencesSidebarHeader: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.labelLeading
            ),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            // Sits low in its row so the label hugs the group it introduces
            // rather than floating between two groups.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(title: String) {
        label.attributedStringValue = KritType.sectionLabel.string(title, color: KritColors.textTertiary)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }
}

@MainActor
private final class NativePreferencesSidebarRowView: NSTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        // The cell draws KRIT's accent in its own non-vibrant layer. Drawing a
        // custom color here lets source-list vibrancy reinterpret coral as black.
    }
}

@MainActor
private final class NativePreferencesSidebarCell: NSTableCellView {

    private let selectionSurface = NSView()
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isSelected = false
    private var isHovered = false
    private var tracking: NSTrackingArea?
    private var tab: PreferencesTab = .general

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        selectionSurface.wantsLayer = true
        selectionSurface.layer?.cornerRadius = ChromeFactory.Radius.control
        selectionSurface.layer?.cornerCurve = .continuous
        selectionSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionSurface)

        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        imageView = glyph

        NSLayoutConstraint.activate([
            selectionSurface.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.surfaceHorizontalInset
            ),
            selectionSurface.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -PreferencesSidebarMetrics.surfaceHorizontalInset
            ),
            selectionSurface.topAnchor.constraint(equalTo: topAnchor),
            selectionSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyph.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.iconCenterInRow
            ),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: PreferencesSidebarMetrics.iconSize),
            glyph.heightAnchor.constraint(equalToConstant: PreferencesSidebarMetrics.iconSize),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PreferencesSidebarMetrics.labelLeading
            ),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    func configure(tab: PreferencesTab, selected: Bool) {
        self.tab = tab
        isSelected = selected
        glyph.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        label.stringValue = tab.title
        setAccessibilityLabel(tab.title)
        applyAppearance()
    }

    private func applyAppearance() {
        let role: KritType = isSelected ? .bodyEmphasis : .body
        label.attributedStringValue = role.string(
            tab.title,
            color: isSelected ? KritColors.textStrong : KritColors.textPrimary
        )
        glyph.contentTintColor = isSelected
            ? KritColors.accent
            : (isHovered ? KritColors.textPrimary : KritColors.textSecondary)

        if isSelected {
            selectionSurface.layer?.backgroundColor = KritColors.navigationSelectionFill.cgColor
        } else if isHovered {
            selectionSurface.layer?.backgroundColor = KritColors.navigationHoverFill.cgColor
        } else {
            selectionSurface.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    var uiTestIconFrame: NSRect { glyph.frame }
    var uiTestSelectionSurfaceFrame: NSRect { selectionSurface.frame }
}

// MARK: - UI test hooks

extension PreferencesWindowController {

    /// Test-only: forces the window up without changing activation policy.
    func uiTestForceShow() {
        select(tab: .general, animated: false, forceReload: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Switch tabs synchronously so a snapshot catches the settled native form.
    func uiTestSelect(_ tab: PreferencesTab) {
        select(tab: tab, animated: false)
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
        uiTestRenderFallbackCount = 0
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
            ), ScreenshotVisualQuality.hasVisibleContent(cg) {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }

            if data == nil, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let cg = rep.cgImage, ScreenshotVisualQuality.hasVisibleContent(cg) {
                    data = rep.representation(using: .png, properties: [:])
                    uiTestRenderFallbackCount += 1
                }
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

    var uiTestSidebarWidth: CGFloat { sidebarWidth }

    var uiTestSidebarIconCenterX: CGFloat? { sidebar.uiTestFirstIconCenterX }
    var uiTestSidebarRowFrame: NSRect? { sidebar.uiTestFirstRowFrame }
    var uiTestSidebarIconFrame: NSRect? { sidebar.uiTestFirstIconFrame }
    var uiTestSidebarSelectionSurfaceFrame: NSRect? { sidebar.uiTestFirstSelectionSurfaceFrame }
    var uiTestSidebarFooterIconCenterX: CGFloat { sidebar.uiTestFooterIconCenterX }
}
