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

    var title: String {
        switch self {
        case .general:     return "General"
        case .capture:     return "Capture"
        case .recording:   return "Recording"
        case .preview:     return "Preview Overlay"
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
        case .general:     return "Make KRIT feel at home on this Mac."
        case .capture:     return "Screenshots that land exactly where you need them."
        case .recording:   return "Crisp screen recordings with the right inputs."
        case .preview:     return "Choose how completed captures stay within reach."
        case .editor:      return "Set the defaults for fast, focused annotation."
        case .shortcuts:   return "Keep every capture tool one keystroke away."
        case .presets:     return "Turn repeated capture workflows into one action."
        case .permissions: return "See what KRIT can access and why it needs it."
        case .about:       return "Version, updates, support, and project links."
        }
    }
}

/// Native macOS Settings shell: AppKit owns the window and source-list sidebar,
/// while one SwiftUI hosting view renders the selected grouped form. Replacing
/// the hosting root keeps settings fresh without retaining nine UI trees.
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private let windowSize = NSSize(width: 980, height: 680)
    private let sidebarWidth: CGFloat = 220

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
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 620)
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

        // A native source list owns keyboard navigation, selection and VoiceOver.
        // The sidebar material is structural on every supported macOS version;
        // Liquid Glass stays reserved for floating chrome such as HUDs and docks.
        sidebar = NativePreferencesSidebar(width: sidebarWidth, height: windowSize.height) { [weak self] tab in
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

    // MARK: - Section switching

    private func select(tab: PreferencesTab, animated _: Bool, forceReload: Bool = false) {
        guard selectedTab != tab || forceReload else {
            sidebar.setSelected(tab)
            return
        }
        selectedTab = tab
        sidebar.setSelected(tab)
        contentHostingView.rootView = PreferencesContent.makeRootView(for: tab)
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

/// AppKit's source list supplies the navigation behavior a Settings window is
/// expected to have: arrow keys, selected-row semantics, focus and VoiceOver.
/// KRIT only customizes the selected fill and the compact cell content.
@MainActor
final class NativePreferencesSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let view: NSView

    private let tableView = NSTableView()
    private let tabs = PreferencesTab.allCases
    private let onSelect: (PreferencesTab) -> Void
    private var suppressSelectionCallback = false

    init(width: CGFloat, height: CGFloat, onSelect: @escaping (PreferencesTab) -> Void) {
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

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 58),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("preferences.sidebar.cell")
        let cell: NativePreferencesSidebarCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NativePreferencesSidebarCell {
            cell = reused
        } else {
            cell = NativePreferencesSidebarCell()
            cell.identifier = identifier
        }
        cell.configure(tab: tabs[row], selected: tableView.selectedRowIndexes.contains(row))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NativePreferencesSidebarRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshVisibleCells()
        guard !suppressSelectionCallback,
              tableView.selectedRow >= 0,
              tableView.selectedRow < tabs.count else { return }
        onSelect(tabs[tableView.selectedRow])
    }

    func setSelected(_ tab: PreferencesTab) {
        guard let row = tabs.firstIndex(of: tab) else { return }
        if tableView.selectedRow != row {
            suppressSelectionCallback = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            suppressSelectionCallback = false
        }
        refreshVisibleCells()
    }

    private func refreshVisibleCells() {
        for row in 0..<tabs.count {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NativePreferencesSidebarCell else { continue }
            cell.configure(tab: tabs[row], selected: tableView.selectedRowIndexes.contains(row))
        }
    }

    var uiTestTableView: NSTableView { tableView }

    var uiTestSelectedTab: PreferencesTab? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < tabs.count else { return nil }
        return tabs[tableView.selectedRow]
    }
}

@MainActor
private final class PreferencesSeparatorView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor
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

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        imageView = glyph

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 17),
            glyph.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(tab: PreferencesTab, selected: Bool) {
        layer?.backgroundColor = selected ? KritColors.accent.cgColor : NSColor.clear.cgColor
        glyph.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        glyph.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        label.stringValue = tab.title
        label.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        setAccessibilityLabel(tab.title)
    }
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
}
