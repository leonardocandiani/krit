// Deprecated on 2026-07-10.
// Reason: replaced by an NSTableView source list so Preferences inherits native
// keyboard navigation, VoiceOver selection semantics, appearance handling and
// row reuse. Kept outside Sources as an implementation record, not compiled.

import AppKit

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
        var y = height - 56

        for tab in PreferencesTab.allCases {
            y -= rowHeight
            let row = PreferencesSidebarRow(tab: tab) { [weak self] in self?.onSelect(tab) }
            row.view.frame = NSRect(
                x: horizontalInset,
                y: y,
                width: width - horizontalInset * 2,
                height: rowHeight
            )
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
        view = HoverButtonView(onClick: onClick, accessibilityLabel: tab.title)
        view.setAccessibilityIdentifier("settings.sidebar.\(tab.rawValue)")
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
            self.icon.frame = NSRect(x: 12, y: tileY + 4, width: 16, height: 16)
            self.label.frame = NSRect(
                x: 8 + tileSize + 10,
                y: (bounds.height - 18) / 2,
                width: bounds.width - 8 - tileSize - 14,
                height: 18
            )
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

@MainActor
final class HoverButtonView: NSButton {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onLayout: ((NSRect) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    init(onClick: (() -> Void)? = nil, accessibilityLabel: String) {
        self.onClick = onClick
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .default
        target = self
        action = #selector(handlePress)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp("Open \(accessibilityLabel) settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    @objc private func handlePress() { onClick?() }
}
