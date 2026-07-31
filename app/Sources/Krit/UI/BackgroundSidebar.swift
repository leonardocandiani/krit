import AppKit

// CleanShot-style background panel: an INTEGRATED window column (titlebar to footer,
// flush to the left edge) with preset thumbnail grids (gradients, wallpapers, blurred,
// plain colors) on top and the layout controls (padding, inset, auto-balance, shadow,
// corners, alignment grid, aspect ratio) below.
//
// ES1: this is NOT a floating glass panel, it owns no corners/shadow. The window owns
// the chrome; the sidebar draws a quiet sidebar material plus a single hairline on its
// trailing edge, so it reads as one column of the editor window.
//
// Standalone component. The host embeds it and wires `onChange`.
final class BackgroundSidebar: NSView {

    struct BlurSelectionRequestGate {
        typealias Token = UInt

        private var generation: UInt = 0

        mutating func begin() -> Token {
            generation &+= 1
            return generation
        }

        mutating func externalOptionsAssigned() {
            generation &+= 1
        }

        mutating func commitIntent() {
            generation &+= 1
        }

        func accepts(_ token: Token) -> Bool {
            token == generation
        }
    }

    var options: ScreenshotBackgroundOptions {
        didSet {
            blurSelectionRequestGate.externalOptionsAssigned()
            guard options != oldValue else { return }
            syncControls()
        }
    }

    var onChange: ((ScreenshotBackgroundOptions) -> Void)?

    static let preferredWidth: CGFloat = KritMetrics.Panel.width

    /// Only the never-touched editor state gets a branded seed in the blur grid.
    /// Any user choice, including a same-palette enabled gradient, owns its source.
    static func shouldSeedDefaultBlurWallpaper(for options: ScreenshotBackgroundOptions) -> Bool {
        options == .editorDefault
    }

    static func blurSelectionOptions(
        from options: ScreenshotBackgroundOptions,
        level: CGFloat,
        defaultWallpaperData: Data?
    ) -> ScreenshotBackgroundOptions {
        var selected = options
        if shouldSeedDefaultBlurWallpaper(for: options),
           let defaultWallpaperData,
           NSImage(data: defaultWallpaperData) != nil {
            selected.presetName = SystemWallpaperSource.defaultBlurWallpaperName
            selected.customImageName = SystemWallpaperSource.defaultBlurWallpaperName
            selected.customImageData = defaultWallpaperData
            selected.tracksDesktopWallpaper = nil
        }
        selected.isEnabled = true
        selected.style = .blurredImage
        selected.blurIntensity = level
        return selected
    }

    // MARK: Style tokens

    // ES2: one rhythm for the whole column. The thumb size is derived so a 5-col
    // grid with `thumbSpacing` exactly fills the inner width, no ragged right edge,
    // no per-section drift. Sections share `sectionGap`; the column clears the
    // titlebar by `topInset`.
    private enum Style {
        /// Four across, 4pt apart: the reference's icon grid, not a 5-column
        /// guess. Every number below now comes from `KritMetrics` for the same
        /// reason, so no section can quietly drift onto its own ruler.
        static let thumbColumns = KritMetrics.Grid.cellColumns
        static let thumbSpacing = KritMetrics.Grid.cellGap
        static let sidePadding = KritMetrics.Panel.bodyInsets.left
        /// Card to card.
        static let sectionGap = KritMetrics.cardGap
        /// Caption to the grid it names.
        static let headerGap = KritMetrics.headerGap
        static let topInset = KritMetrics.Panel.bodyInsets.top
        /// The header row that holds the traffic lights and the panel's own
        /// actions. Tall enough that a 12pt light centred in it clears both
        /// edges, and that the row still reads as a row rather than a strip.
        static let headerHeight: CGFloat = 40
        /// Where the panel's own controls start, measured from its leading edge:
        /// past the three window buttons.
        static let trafficLightWidth: CGFloat = 72
        static let bottomInset = KritMetrics.Panel.bodyInsets.bottom
        static let pairedControlSpacing = KritMetrics.controlGap
        static var innerWidth: CGFloat { BackgroundSidebar.preferredWidth - sidePadding * 2 }
        /// Usable width INSIDE a section card, which is the column minus the
        /// body inset minus the card's own horizontal padding. Grids measured
        /// against `innerWidth` overflow their card by exactly `cardPadX * 2`.
        static var contentWidth: CGFloat { innerWidth - KritMetrics.cardPadX * 2 }
        static var pairedControlWidth: CGFloat { BackgroundSidebar.pairedControlWidth(innerWidth: innerWidth, spacing: pairedControlSpacing) }
        static var thumbSize: CGFloat {
            (contentWidth - thumbSpacing * CGFloat(thumbColumns - 1)) / CGFloat(thumbColumns)
        }

    }

    // Gradient presets: a thin view over the curated mesh palettes in
    // ScreenshotBackgroundComposer, so the sidebar and the composer share one
    // source of truth.
    private struct GradientPreset {
        let name: String
        let startHex: String
        let endHex: String
        let accents: [String]
    }

    private var gradientPresets: [GradientPreset] {
        ScreenshotBackgroundOptions.imagePresets.map {
            GradientPreset(name: $0.name, startHex: $0.startHex, endHex: $0.endHex, accents: $0.accentHexes)
        }
    }

    // Real Apple desktop pictures installed on this Mac (read at runtime, never
    // bundled). Empty on systems we can't read, the grid then falls back to the
    // gradient palettes so the section is never blank.
    private var systemWallpapers = SystemWallpaperSource.all
    private var hasSystemWallpapers: Bool { !systemWallpapers.isEmpty }
    private var pendingWallpaperName: String?
    private var wallpaperSection: NSView?
    private var gradientSection: NSView?

    private let plainColors: [String] = [
        "#ffffff", "#f2f2f2", "#d8d8d8", "#9b9b9b", "#3a3a3a",
        "#1c1c1e", "#ff6b6b", "#ff9f43", "#feca57", "#48dbaa",
        "#1dd1a1", "#54a0ff", "#5f6cff", "#a55eea", "#ff6bcb"
    ]

    private var thumbnailButtons: [BackgroundThumbnailButton] = []
    private var colorSwatches: [BackgroundColorSwatch] = []
    private var noneButton: NSButton?

    // "Blurred" section (CleanShot reference): three live thumbs of the CURRENT
    // background at light/medium/strong gaussian levels.
    private let blurLevels: [CGFloat] = [10, 22, 40]
    private var blurPreviewCache: [String: NSImage] = [:]
    private var blurSelectionRequestGate = BlurSelectionRequestGate()
    /// Identity of the background the blur tiles currently preview; when it
    /// changes the three thumbs re-render.
    private var lastBlurIdentity: String?

    // Controls
    private let paddingSlider = KritSlider()
    private let insetSlider = KritSlider()
    private let shadowSlider = KritSlider()
    private let cornerSlider = KritSlider()
    private let paddingValue = makeValueLabel()
    private let insetValue = makeValueLabel()
    private let shadowValue = makeValueLabel()
    private let cornerValue = makeValueLabel()
    private let autoBalanceSwitch = NSSwitch()
    /// The floating glass the column's controls sit on.
    private var glassBacking: KritGlassBacking?
    private let blurCheckbox = NSButton()
    private let ratioPopup = NSPopUpButton()
    private var alignmentButtons: [NSButton] = []

    /// Right-aligned mono value readout next to each slider (e.g. "48", "70%").
    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return label
    }

    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()

    // Presets: a CleanShot-style named dropdown at the top of the column. The popup
    // shows the active preset (swatch + name) and lists every saved preset plus the
    // previous, built-in background and add-preset actions. Removal stays in the
    // menu so it can target one saved preset ID and ask for confirmation first.
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    struct PresetManagementState: Equatable {
        let title: String
        let titleBackground: ScreenshotBackgroundOptions?
        let saveChangesPresetID: UUID?
        let defaultPresetID: UUID?
        let removePresetID: UUID?
        let isDefault: Bool
    }

    static func pairedControlWidth(innerWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        max(0, (innerWidth - spacing) / 2)
    }

    static func presetMenuTitle(name: String, isDefault: Bool) -> String {
        isDefault ? "\(name) (default)" : name
    }

    static func presetManagementState(
        options: ScreenshotBackgroundOptions,
        active: EditTemplate?,
        editingBase: EditTemplate?,
        isDefault: (UUID) -> Bool
    ) -> PresetManagementState {
        if let active {
            return PresetManagementState(
                title: active.name,
                titleBackground: active.background,
                saveChangesPresetID: nil,
                defaultPresetID: active.id,
                removePresetID: active.id,
                isDefault: isDefault(active.id)
            )
        }

        if let editingBase, editingBase.background != options {
            return PresetManagementState(
                title: "\(editingBase.name) (edited)",
                titleBackground: options,
                saveChangesPresetID: editingBase.id,
                defaultPresetID: nil,
                removePresetID: nil,
                isDefault: false
            )
        }

        if let editingBase, editingBase.background == options {
            return PresetManagementState(
                title: editingBase.name,
                titleBackground: editingBase.background,
                saveChangesPresetID: nil,
                defaultPresetID: editingBase.id,
                removePresetID: editingBase.id,
                isDefault: isDefault(editingBase.id)
            )
        }

        return PresetManagementState(
            title: "Custom",
            titleBackground: nil,
            saveChangesPresetID: nil,
            defaultPresetID: nil,
            removePresetID: nil,
            isDefault: false
        )
    }

    // MARK: Init

    init(options: ScreenshotBackgroundOptions) {
        self.options = options
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 600))
        wantsLayer = true
        // The inspector is an opaque column, not a vibrant one. It sits beside
        // the artwork rather than over it, and a material here would let the
        // screenshot's colours bleed under the controls that are supposed to be
        // judging that screenshot. One hairline on the leading edge separates
        // the column from the stage.
        // The panel floats: it keeps a margin from the window on every side and
        // carries the reference's 20.5pt panel radius, rather than running edge
        // to edge as a docked column. The controller insets its frame; the glass
        // fills whatever it is given.
        let backing = KritGlassBacking(style: .panel, cornerRadius: KritMetrics.Radius.panel)
        backing.frame = bounds
        backing.autoresizingMask = [.width, .height]
        addSubview(backing, positioned: .below, relativeTo: nil)
        glassBacking = backing
        buildLayout()
        rebuildThumbnails()
        syncControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: NSView.noIntrinsicMetric)
    }

    override var wantsUpdateLayer: Bool { true }

    /// Resolves the column's colours against the *current* appearance. Assigning
    /// `cgColor` once at init bakes in whichever theme happened to be active
    /// then, which is why the column came out dark under the light theme.
    override func updateLayer() {
        // The glass backing paints the surface; the column itself stays clear so
        // the panel's rounded corners are not squared off by an opaque layer.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Layout

    private func buildLayout() {
        widthAnchor.constraint(equalToConstant: Self.preferredWidth).isActive = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        // ES1/ES2: coluna lisa (sem cantos próprios), respiro igual em cima e
        // embaixo. O fio de separação fica na borda direita; o scroll para 1pt
        // antes dele.
        scrollView.contentInsets = NSEdgeInsets(top: Style.topInset, left: 0, bottom: Style.bottomInset, right: 0)
        addSubview(scrollView)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = Style.sectionGap
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: Style.sidePadding, bottom: 0, right: Style.sidePadding)

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        // A header row of its own, the way the reference does it: the panel runs
        // to the top of the window and the traffic lights sit INSIDE it, sharing
        // one line with the panel's own actions. Without this line the lights
        // land on top of whatever control happened to be first.
        let header = makeHeaderRow()
        addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Style.headerHeight),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])

        // A barra de presets subiu pro header (linha dos traffic lights), então o
        // scroll começa direto no None.
        contentStack.addArrangedSubview(makeNoneButton())
        gradientSection = makeSection(title: "Gradients", grid: gradientGrid(), accessory: makeGradientsToggle())
        contentStack.addArrangedSubview(gradientSection!)
        wallpaperSection = makeSection(title: "Wallpapers", grid: wallpaperGrid(), accessory: makeImportButton())
        contentStack.addArrangedSubview(wallpaperSection!)
        contentStack.addArrangedSubview(makeSection(title: "Blurred", grid: blurredGrid()))
        contentStack.addArrangedSubview(makeSection(title: "Plain color", grid: plainColorGrid()))
        contentStack.addArrangedSubview(makeDivider())
        contentStack.addArrangedSubview(makeControls())
        reloadPresetBar()

        // Harness compatibility bridge: UITestRunner locates an NSButton titled
        // "Blur background" inside the sidebar and performClicks it to assert
        // blurTogglePass. The visible control became the three "Blurred" thumbs,
        // so this button stays in the hierarchy but invisible; clicking it
        // applies the medium blur level.
        blurCheckbox.setButtonType(.switch)
        blurCheckbox.title = "Blur background"
        blurCheckbox.target = self
        blurCheckbox.action = #selector(blurToggled(_:))
        blurCheckbox.isHidden = true
        blurCheckbox.frame = .zero
        addSubview(blurCheckbox)
    }

    // MARK: Presets bar (named dropdown, like CleanShot)

    /// The preset dropdown row at the top of the column: a pull-down NSPopUpButton
    /// showing the active preset (swatch + name) and a "+" that saves the current
    /// canvas config under a name.
    /// The popup's menu is rebuilt on every change by `reloadPresetBar`.
    /// The panel's top line: window buttons on the left (drawn by the system,
    /// we only leave room), the panel's own controls on the right.
    ///
    /// This is what the reference does, and it is the only arrangement that
    /// works once the panel runs to the top of the window: the lights have to
    /// live *in* a row of the panel, not on top of one.
    private func makeHeaderRow() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let bar = makePresetBar()
        header.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor,
                                         constant: Style.trafficLightWidth),
            bar.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                          constant: -Style.sidePadding),
            bar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func makePresetBar() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        presetPopup.pullsDown = true
        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.controlSize = .regular
        presetPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        presetPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addButton = NSButton(title: "", target: self, action: #selector(addPresetTapped))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add preset")
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "Save the current background as a new preset"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(presetPopup)
        row.addArrangedSubview(addButton)

        return row
    }

    /// Rebuilds the popup's menu from the saved presets plus the standard actions,
    /// and reflects the currently selected preset (swatch + name + checkmark).
    private func reloadPresetBar() {
        let menu = NSMenu()
        // Manage item enablement by hand so "Apply previous settings" can read as
        // disabled when there is nothing to restore (NSMenu's auto-enabling would
        // otherwise force every item with a valid target on).
        menu.autoenablesItems = false
        let active = TemplateStore.activePreset
        let base = TemplateStore.editingBase
        let state = Self.presetManagementState(
            options: options,
            active: active,
            editingBase: base,
            isDefault: { TemplateStore.isDefault(id: $0) }
        )
        // The pull-down's title item (index 0) is what shows when the menu is shut:
        // the active preset's swatch + name, "<name> (edited)" with the live swatch
        // when tweaked, or a neutral "Custom" when there's no base at all.
        let titleItem = NSMenuItem()
        titleItem.title = state.title
        titleItem.image = state.titleBackground.map { swatchImage(for: $0) }
        titleItem.isEnabled = true
        menu.addItem(titleItem)

        // Save the hand-edits back into the preset they came from. Top of the menu so
        // "I tweaked my preset, now save it" is the first thing the user sees.
        if let saveChangesPresetID = state.saveChangesPresetID,
           let base = TemplateStore.all().first(where: { $0.id == saveChangesPresetID }) {
            menu.addItem(.separator())
            // No key equivalent: the editor already owns Cmd+S for saving the image
            // to disk, so this stays a click-only action to avoid a clash.
            let save = NSMenuItem(title: "Save changes to \u{201C}\(base.name)\u{201D}",
                                  action: #selector(saveChangesToBaseTapped(_:)), keyEquivalent: "")
            save.target = self
            save.representedObject = saveChangesPresetID
            save.isEnabled = true
            menu.addItem(save)
        }

        let presets = TemplateStore.all()
        for preset in presets {
            // A pin glyph marks the preset that auto-applies to every new capture,
            // so "which one is the default" reads at a glance; the checkmark stays
            // reserved for the currently-selected preset.
            let isDefault = TemplateStore.isDefault(id: preset.id)
            let item = NSMenuItem(title: Self.presetMenuTitle(name: preset.name, isDefault: isDefault),
                                  action: #selector(selectPresetMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.image = swatchImage(for: preset.background)
            item.toolTip = isDefault ? "Default preset" : nil
            item.state = (preset.id == active?.id) ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
        }
        if !presets.isEmpty { menu.addItem(.separator()) }

        // Management actions only receive an explicit preset ID. An edited base can
        // be saved back, but it cannot be removed or pinned from that ambiguous state.
        let setDefault = NSMenuItem(
            title: state.isDefault ? "Unset as default" : "Set as default for new captures",
            action: #selector(toggleActivePresetDefaultMenu(_:)), keyEquivalent: "")
        setDefault.target = self
        setDefault.representedObject = state.defaultPresetID
        setDefault.isEnabled = state.defaultPresetID != nil
        setDefault.state = state.isDefault ? .on : .off
        menu.addItem(setDefault)

        let removeItem = NSMenuItem(title: "Remove preset", action: #selector(deletePresetMenu(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = state.removePresetID
        removeItem.isEnabled = state.removePresetID != nil
        menu.addItem(removeItem)

        menu.addItem(.separator())

        let previous = NSMenuItem(title: "Apply previous settings", action: #selector(applyPreviousSettingsMenu), keyEquivalent: "")
        previous.target = self
        previous.isEnabled = TemplateStore.previousOptions != nil
        menu.addItem(previous)

        let defaultPreset = NSMenuItem(title: "Apply built-in background", action: #selector(applyDefaultPresetMenu), keyEquivalent: "")
        defaultPreset.target = self
        defaultPreset.isEnabled = true
        menu.addItem(defaultPreset)

        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add new preset\u{2026}", action: #selector(addPresetTapped), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = true
        menu.addItem(addItem)

        presetPopup.menu = menu
        presetPopup.selectItem(at: 0)
    }

    /// Test hook: rebuild the preset dropdown from the live state and return its
    /// item titles, so a scenario can assert the "(edited)" badge and the
    /// "Save changes to <name>" action appear when a saved preset is hand-edited.
    func uiTestPresetMenuTitles() -> [String] {
        reloadPresetBar()
        return presetPopup.menu?.items.map { $0.title } ?? []
    }

    /// A small rounded swatch image for a preset, rendering the ACTUAL background
    /// (gradient, wallpaper or solid color) in miniature, so the dropdown shows the
    /// real fundo the preset applies, not a flat representative color. Falls back to
    /// the representative color only when the background can't be rendered.
    private func swatchImage(for background: ScreenshotBackgroundOptions) -> NSImage {
        let side: CGFloat = 14
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        path.addClip()
        if background.isEnabled {
            let preview = ScreenshotBackgroundComposer.previewImage(options: background, size: rect.size)
            preview.draw(in: rect)
        } else {
            presetSwatchColor(for: background).setFill()
            path.fill()
        }
        NSGraphicsContext.current?.cgContext.resetClip()
        NSColor(calibratedWhite: 0, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        image.unlockFocus()
        return image
    }

    /// The single color that best represents a preset's background for the swatch:
    /// the solid color, the gradient's bright end, or a neutral tile for None.
    private func presetSwatchColor(for background: ScreenshotBackgroundOptions) -> NSColor {
        guard background.isEnabled else { return NSColor(calibratedWhite: 0.6, alpha: 1) }
        switch background.style {
        case .solid:
            return ScreenshotBackgroundComposer.color(from: background.colorHex)
        case .gradient:
            return ScreenshotBackgroundComposer.color(from: background.gradientEndHex)
        case .image, .blurredImage:
            if let first = background.accentHexes.first {
                return ScreenshotBackgroundComposer.color(from: first)
            }
            return ScreenshotBackgroundComposer.color(from: background.gradientEndHex)
        }
    }

    // MARK: Preset actions

    /// The background config behind "Apply built-in background": the brand gradient KRIT ships
    /// with (Sunset Coral), enabled, with the editor's default framing.
    private var defaultPresetOptions: ScreenshotBackgroundOptions {
        var options = ScreenshotBackgroundOptions.editorDefault
        options.isEnabled = true
        return options
    }

    @objc private func selectPresetMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = TemplateStore.all().first(where: { $0.id == id }) else { return }
        TemplateStore.recordPrevious(options)
        TemplateStore.setActive(name: preset.name)
        // Remember this preset as the edit base so later hand-edits can be saved
        // back into it ("Save changes to <name>"), not only forked into a copy.
        TemplateStore.setEditingBase(name: preset.name)
        commit(preset.background)
        reloadPresetBar()
    }

    @objc private func applyPreviousSettingsMenu() {
        guard let previous = TemplateStore.previousOptions else { return }
        // Swap previous <-> current so a second tap toggles back, matching how a
        // user expects "previous" to behave.
        TemplateStore.recordPrevious(options)
        TemplateStore.setActive(name: nil)
        TemplateStore.setEditingBase(name: nil)
        commit(previous)
        reloadPresetBar()
    }

    @objc private func applyDefaultPresetMenu() {
        TemplateStore.recordPrevious(options)
        TemplateStore.setActive(name: nil)
        TemplateStore.setEditingBase(name: nil)
        commit(defaultPresetOptions)
        reloadPresetBar()
    }

    /// "+" / "Add new preset...": names the current canvas config and saves it as a
    /// new preset, which becomes the selected one.
    @objc private func addPresetTapped() {
        let suggested = "Preset \(TemplateStore.all().count + 1)"
        guard let name = promptForName(
            title: "Add new preset",
            message: "Name this preset. It saves the current background settings.",
            placeholder: suggested,
            initial: ""
        ) else { return }
        // add() overwrites an existing preset that already carries this exact name
        // (case-insensitive), so saving twice under one name updates instead of
        // duplicating.
        TemplateStore.add(name: name, background: options)
        TemplateStore.setActive(name: name)
        TemplateStore.setEditingBase(name: name)
        reloadPresetBar()
    }

    /// "Save changes to <name>": writes the current (hand-edited) background back
    /// into the preset the user started from, so editing a preset updates it in
    /// place. Only shown while editing a saved preset; a built-in gradient has no
    /// template to update and saves via "Add new preset" instead.
    @objc private func saveChangesToBaseTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let base = TemplateStore.all().first(where: { $0.id == id }) else { return }
        _ = TemplateStore.update(id: base.id, background: options)
        // Options now match the saved config, so the dropdown re-selects the preset
        // and the "(edited)" state clears.
        TemplateStore.setActive(name: base.name)
        reloadPresetBar()
    }

    /// "Remove preset": deletes only the explicitly selected preset ID.
    @objc private func deletePresetMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = TemplateStore.all().first(where: { $0.id == id }),
              confirmPresetDeletion(preset) else { return }
        TemplateStore.delete(id: id)
        TemplateStore.setEditingBase(name: nil)
        reloadPresetBar()
    }

    private func confirmPresetDeletion(_ preset: EditTemplate) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove preset?"
        alert.informativeText = "This removes \u{201C}\(preset.name)\u{201D} from saved background presets."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Pins the selected preset as the default applied to every new capture, or
    /// clears the default when it is already the one pinned. Mirrors the Default
    /// template picker in Preferences (same `Settings.defaultTemplateName`).
    @objc private func toggleActivePresetDefaultMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = TemplateStore.all().first(where: { $0.id == id }) else { return }
        let alreadyDefault = TemplateStore.isDefault(id: id)
        TemplateStore.setDefault(name: alreadyDefault ? nil : preset.name)
        reloadPresetBar()
    }

    /// "Show more/less" dos gradientes: colapsado mostra 2 fileiras (10).
    private var gradientsCollapsed = true
    private func makeGradientsToggle() -> NSButton {
        let button = NSButton(title: "Show more", target: self, action: #selector(gradientsToggleTapped(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func gradientsToggleTapped(_ sender: NSButton) {
        gradientsCollapsed.toggle()
        sender.title = gradientsCollapsed ? "Show more" : "Show less"
        guard let section = gradientSection as? NSStackView,
              section.arrangedSubviews.count >= 2 else { return }
        let oldGrid = section.arrangedSubviews[1]
        thumbnailButtons.removeAll { $0.action == #selector(selectGradient(_:)) }
        oldGrid.removeFromSuperview()
        section.addArrangedSubview(gradientGrid())
        rebuildThumbnails()
        updateSelectionHighlight()
    }

    /// Native single-field name prompt. Returns the trimmed name, or nil on
    /// cancel / empty.
    private func promptForName(title: String, message: String, placeholder: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// "None" disables the background. A native full-width push-on/push-off
    /// NSButton: AppKit draws the pressed (on) bezel for the selected state
    /// (background disabled), with a coral tint, matching the editor toolbar's
    /// native toggles. Clicking it routes through the same commit path as before.
    private func makeNoneButton() -> NSView {
        // Push-on/off with a system bezel paints the ON state in the SYSTEM
        // accent (blue on a default Mac), which is the one colour this app never
        // uses. Selection here speaks the same coral as every other selected
        // state in the editor.
        let button = SelectableRowButton(title: "None", target: self, action: #selector(selectNone))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Style.innerWidth).isActive = true
        noneButton = button
        return button
    }

    private func makeSection(title: String, grid: NSView, accessory: NSView? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.headerGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let accessory {
            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .centerY
            header.distribution = .fill
            header.translatesAutoresizingMaskIntoConstraints = false
            let label = makeSectionLabel(title)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            header.addArrangedSubview(label)
            header.addArrangedSubview(accessory)
            stack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalToConstant: Style.contentWidth).isActive = true
        } else {
            stack.addArrangedSubview(makeSectionLabel(title))
        }
        stack.addArrangedSubview(grid)
        return Self.card(wrapping: stack)
    }

    /// The reference's section card, at its literal values:
    ///
    ///     borderRadius: 10
    ///     padding: "12px 14px"          (cardPadY / cardPadX)
    ///     border: "0.5px solid var(--border)"
    ///
    /// Sections drawn as bare stacks read as one long strip; the card is what
    /// makes "Gradients" and "Wallpapers" look like two things rather than two
    /// headings over the same wall of thumbnails.
    private static func card(wrapping content: NSView) -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            // Every card spans the column. Left to hug its contents, a section
            // with three thumbnails draws a visibly narrower card than one with
            // ten, and the stack of cards reads as ragged rather than as a list.
            card.widthAnchor.constraint(equalToConstant: Style.innerWidth),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: KritMetrics.cardPadX),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -KritMetrics.cardPadX),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: KritMetrics.cardPadY),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -KritMetrics.cardPadY),
        ])
        return card
    }

    /// "+" no header da seção Wallpapers: importa qualquer imagem (os wallpapers
    /// que o usuário baixar da Apple, por exemplo) pra biblioteca do KRIT.
    private func makeImportButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(importWallpapersTapped))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add wallpapers")
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Add wallpapers (imported into KRIT's library)"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Group header in the app's section voice: 11pt semibold, upper-cased,
    /// tracked +0.6. Sentence-case at 10pt read as a stray line of body text and
    /// left the four groups looking like one long list.
    private func makeSectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: KritMetrics.sectionCaption(text))
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeDivider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = KritColors.divider.cgColor
        // Half a point: one physical line on Retina. A full point reads as a
        // drawn rule instead of a seam between groups.
        line.heightAnchor.constraint(equalToConstant: KritColors.hairlineWidth).isActive = true
        line.widthAnchor.constraint(equalToConstant: Style.innerWidth).isActive = true
        return line
    }

    // MARK: Thumbnail grids

    private func gradientGrid() -> NSView {
        // Colapsado = 2 fileiras (referência CleanShot); expandido = todos.
        let visible = gradientsCollapsed ? min(Style.thumbColumns * 2, gradientPresets.count) : gradientPresets.count
        var buttons: [NSView] = []
        for index in 0..<visible {
            buttons.append(makeThumbnail(tag: index, action: #selector(selectGradient(_:))))
        }
        return makeMatrix(from: buttons)
    }

    private func wallpaperGrid() -> NSView {
        let count = hasSystemWallpapers ? systemWallpapers.count : ScreenshotBackgroundOptions.imagePresets.count
        var buttons: [NSView] = []
        // Lead with "Current desktop": applies the wallpaper of the screen the shot
        // lands on NOW and flags tracksDesktopWallpaper, so a template saved from
        // this state follows the user's wallpaper wherever they are (a template made
        // at home must not paint the home wallpaper at work).
        let currentTile = makeThumbnail(tag: 0, action: #selector(selectCurrentDesktop(_:)))
        currentTile.toolTip = "Current desktop wallpaper (follows wherever you are)"
        buttons.append(currentTile)
        for index in 0..<count {
            buttons.append(makeThumbnail(tag: index, action: #selector(selectWallpaper(_:))))
        }
        return makeMatrix(from: buttons)
    }

    /// One row of three thumbs (light / medium / strong) sharing the wallpaper
    /// thumb metrics. Previews are real mini-renders of the selected background,
    /// produced by refreshBlurPreviewsIfNeeded().
    private func blurredGrid() -> NSView {
        let tooltips = ["Light blur", "Medium blur", "Strong blur"]
        var buttons: [NSView] = []
        for index in 0..<blurLevels.count {
            let button = makeThumbnail(tag: index, action: #selector(selectBlurLevel(_:)))
            button.toolTip = tooltips[safe: index]
            buttons.append(button)
        }
        return makeMatrix(from: buttons)
    }

    private func plainColorGrid() -> NSView {
        var swatches: [NSView] = []
        for (index, hex) in plainColors.enumerated() {
            let swatch = BackgroundColorSwatch()
            swatch.tag = index
            swatch.fillColor = ScreenshotBackgroundComposer.color(from: hex)
            swatch.target = self
            swatch.action = #selector(selectPlainColor(_:))
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 30).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 30).isActive = true
            colorSwatches.append(swatch)
            swatches.append(swatch)
        }
        return makeMatrix(from: swatches)
    }

    private func makeMatrix(from views: [NSView]) -> NSGridView {
        // Pad the last row so every grid has the SAME number of columns. Without
        // this, a section with three thumbnails builds a three-column grid whose
        // columns are wider than the four-column grid above it, and the two
        // sections visibly fail to line up.
        var padded = views
        let remainder = padded.count % Style.thumbColumns
        if remainder != 0 {
            for _ in 0..<(Style.thumbColumns - remainder) {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.widthAnchor.constraint(equalToConstant: Style.thumbSize).isActive = true
                padded.append(spacer)
            }
        }

        let rows = chunk(padded, into: Style.thumbColumns)
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Style.thumbSpacing
        grid.columnSpacing = Style.thumbSpacing
        grid.xPlacement = .leading
        grid.yPlacement = .top
        // Fixed column width: left to size themselves, columns take the width of
        // their widest cell, so one section's tiles drift out of step with the
        // next one's.
        for index in 0..<grid.numberOfColumns {
            grid.column(at: index).width = Style.thumbSize
        }
        return grid
    }

    private func chunk(_ views: [NSView], into columns: Int) -> [[NSView]] {
        var rows: [[NSView]] = []
        var current: [NSView] = []
        for view in views {
            current.append(view)
            if current.count == columns {
                rows.append(current)
                current = []
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func makeThumbnail(tag: Int, action: Selector) -> BackgroundThumbnailButton {
        let button = BackgroundThumbnailButton()
        button.tag = tag
        button.target = self
        button.action = action
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        if action == #selector(selectCurrentDesktop(_:)) {
            button.identifier = NSUserInterfaceItemIdentifier("background-current-desktop")
            button.setAccessibilityLabel("Current desktop wallpaper")
        } else if action == #selector(selectWallpaper(_:)) {
            button.identifier = NSUserInterfaceItemIdentifier("background-wallpaper-\(tag)")
            button.setAccessibilityLabel("Wallpaper \(tag + 1)")
        } else if action == #selector(selectGradient(_:)) {
            button.identifier = NSUserInterfaceItemIdentifier("background-gradient-\(tag)")
            button.setAccessibilityLabel("Gradient \(tag + 1)")
        } else if action == #selector(selectBlurLevel(_:)) {
            button.identifier = NSUserInterfaceItemIdentifier("background-blur-\(tag)")
            button.setAccessibilityLabel(["Light blur", "Medium blur", "Strong blur"][safe: tag] ?? "Blur")
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Style.thumbSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Style.thumbSize).isActive = true
        thumbnailButtons.append(button)
        return button
    }

    // MARK: Controls

    private func makeControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        paddingSlider.minValue = 0
        paddingSlider.maxValue = 240
        configureSlider(paddingSlider)

        insetSlider.minValue = 0
        insetSlider.maxValue = 120
        configureSlider(insetSlider)

        shadowSlider.minValue = 0
        shadowSlider.maxValue = 1
        configureSlider(shadowSlider)

        cornerSlider.minValue = 0
        cornerSlider.maxValue = 36
        configureSlider(cornerSlider)

        // Native macOS switch (the one the Settings panes use); flips on, fires
        // the one-shot rebalance and syncControls rests it back to off.
        autoBalanceSwitch.controlSize = .mini
        autoBalanceSwitch.toolTip = "Rebalance the framing (padding, inset, shadow, corners) around the screenshot. Leaves the background unchanged."
        autoBalanceSwitch.target = self
        autoBalanceSwitch.action = #selector(autoBalanceToggled(_:))
        autoBalanceSwitch.translatesAutoresizingMaskIntoConstraints = false

        // Pairs, as before: Padding full width; Inset + Auto-balance; Shadow +
        // Corners; Alignment + Ratio. This is the arrangement that fits the
        // column, and splitting it into one control per line was a regression.
        stack.addArrangedSubview(labeledControl("Padding", paddingSlider, value: paddingValue))
        stack.addArrangedSubview(pairRow(
            labeledControl("Inset", insetSlider, value: insetValue),
            checkboxColumn(autoBalanceRow())
        ))
        stack.addArrangedSubview(pairRow(
            labeledControl("Shadow", shadowSlider, value: shadowValue),
            labeledControl("Corners", cornerSlider, value: cornerValue)
        ))
        stack.addArrangedSubview(pairRow(
            columnWith(header: "Alignment", makeAlignmentGrid()),
            columnWith(header: "Ratio", makeRatioPopup())
        ))

        stack.widthAnchor.constraint(equalToConstant: Style.innerWidth).isActive = true
        return stack
    }

    /// Dois controles lado a lado dividindo a largura da coluna.
    private func pairRow(_ left: NSView, _ right: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = Style.pairedControlSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(left)
        row.addArrangedSubview(right)
        row.widthAnchor.constraint(equalToConstant: Style.innerWidth).isActive = true
        return row
    }

    private func columnWith(header: String, _ control: NSView) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(makeSectionHeader(header))
        column.addArrangedSubview(control)
        return column
    }

    /// Controle alinhado verticalmente com o slider vizinho do par.
    private func checkboxColumn(_ control: NSView) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        column.addArrangedSubview(spacer)
        column.addArrangedSubview(control)
        return column
    }

    /// O switch nativo com o rótulo ao lado; o NSSwitch não carrega título.
    private func autoBalanceRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Auto-balance")
        label.font = .systemFont(ofSize: 11)
        label.toolTip = autoBalanceSwitch.toolTip
        row.addArrangedSubview(autoBalanceSwitch)
        row.addArrangedSubview(label)
        return row
    }

    private func configureSlider(_ slider: NSSlider) {
        slider.target = self
        slider.action = #selector(slidersChanged(_:))
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Section header for the controls column: matches the thumbnail-section
    /// label weight so the whole panel reads as one document.
    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A slider row with a title on the left and a live mono value on the right,
    /// then the regular-size slider below, CleanShot-grade, not a dev panel.
    private func labeledControl(_ title: String, _ control: NSView, value: NSTextField) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(label)
        header.addArrangedSubview(value)

        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(header)
        row.addArrangedSubview(control)
        // No fixed width: these rows sit two per line, so each takes whatever
        // half of the column its pair gives it.
        header.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func makeAlignmentGrid() -> NSView {
        let order = BackgroundAlignment.allCases
        var rows: [[NSView]] = []
        var current: [NSView] = []
        for (index, _) in order.enumerated() {
            let button = NSButton()
            button.title = ""
            if #available(macOS 26.0, *) {
                button.bezelStyle = .glass
            } else {
                button.bezelStyle = .smallSquare
            }
            button.setButtonType(.toggle)
            button.tag = index
            button.target = self
            button.action = #selector(alignmentChanged(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            alignmentButtons.append(button)
            current.append(button)
            if current.count == 3 {
                rows.append(current)
                current = []
            }
        }
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        return grid
    }

    private func makeRatioPopup() -> NSView {
        ratioPopup.translatesAutoresizingMaskIntoConstraints = false
        ratioPopup.controlSize = .small
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged(_:))
        ratioPopup.removeAllItems()
        ratioPopup.addItem(withTitle: "Auto")
        for preset in BackgroundAspectPreset.allCases {
            ratioPopup.addItem(withTitle: preset.displayName)
        }
        ratioPopup.widthAnchor.constraint(equalToConstant: Style.pairedControlWidth).isActive = true
        return ratioPopup
    }

    // MARK: Actions

    @objc private func selectNone() {
        var next = options
        next.isEnabled = false
        commit(next)
    }

    @objc private func selectGradient(_ sender: NSControl) {
        let preset = gradientPresets[min(sender.tag, gradientPresets.count - 1)]
        var next = options
        next.isEnabled = true
        next.style = .gradient
        next.presetName = preset.name
        next.gradientStartHex = preset.startHex
        next.gradientEndHex = preset.endHex
        next.accentHexes = preset.accents
        next.customImageData = nil
        next.customImageName = nil
        next.tracksDesktopWallpaper = nil
        // A built-in gradient is a fresh starting point, not a saved preset to
        // update; clear the edit base so saving forks a new preset.
        TemplateStore.setEditingBase(name: nil)
        commit(next)
    }

    @objc private func selectWallpaper(_ sender: NSControl) {
        if hasSystemWallpapers {
            guard let wallpaper = systemWallpapers[safe: sender.tag] else { return }
            // Optimistic highlight now, real image data lands a moment later.
            pendingWallpaperName = wallpaper.name
            updateSelectionHighlight()
            SystemWallpaperSource.backgroundData(for: wallpaper) { [weak self] data in
                guard let self, self.pendingWallpaperName == wallpaper.name else { return }
                self.pendingWallpaperName = nil
                // "Current" pode apontar pra um wallpaper dinâmico/aerial cujo
                // arquivo não decoda (macOS 27 devolve URLs assim): cai pro grab
                // vivo do desktop, que captura o que o WindowServer pinta de
                // fato. Falhou tudo, AVISA; o clique silenciosamente morto era o
                // "clico no wallpaper e fica bugado" do relato.
                var resolved = data
                if resolved == nil, wallpaper.name.hasPrefix("Current") {
                    resolved = SystemWallpaperSource.currentDesktopBackgroundData(for: self.window?.screen)
                }
                guard let resolved else {
                    ToastWindow.show(message: "Couldn't load this wallpaper")
                    self.updateSelectionHighlight()
                    return
                }
                var next = self.options
                next.isEnabled = true
                next.style = .image
                next.presetName = wallpaper.name
                next.customImageName = wallpaper.name
                next.customImageData = resolved
                next.tracksDesktopWallpaper = nil
                TemplateStore.setEditingBase(name: nil)
                self.commit(next)
            }
            return
        }

        let preset = ScreenshotBackgroundOptions.imagePresets[min(sender.tag, ScreenshotBackgroundOptions.imagePresets.count - 1)]
        var next = options
        next.isEnabled = true
        next.style = .image
        next.presetName = preset.name
        next.accentHexes = preset.accentHexes
        next.customImageData = nil
        next.customImageName = nil
        next.tracksDesktopWallpaper = nil
        TemplateStore.setEditingBase(name: nil)
        commit(next)
    }

    /// "Current desktop": resolve the wallpaper the user is looking at RIGHT NOW
    /// (the screen the shot lives on, or the main display) and apply it, with
    /// tracksDesktopWallpaper set so saving this as a template re-resolves the
    /// wallpaper on every future shot instead of freezing today's image. Resolved
    /// synchronously on the main thread, the same source the window-shot path uses.
    @objc private func selectCurrentDesktop(_ sender: NSControl) {
        guard let data = SystemWallpaperSource.currentDesktopBackgroundData(for: nil) else { return }
        var next = options
        next.isEnabled = true
        next.style = .image
        next.presetName = "Current desktop"
        next.customImageName = "Current wallpaper"
        next.customImageData = data
        next.tracksDesktopWallpaper = true
        TemplateStore.setEditingBase(name: nil)
        commit(next)
    }

    /// Harness bridge only (see buildLayout): the old "Blur background" toggle
    /// became the three Blurred thumbs, so a performClick on the invisible
    /// button applies the medium level, same effect as clicking thumb #1.
    @objc private func blurToggled(_ sender: NSButton) {
        selectBlur(level: blurLevels[1])
    }

    /// Clicking a Blurred thumb keeps the current image/gradient source and
    /// switches the style to .blurredImage at that gaussian level. Picking a
    /// sharp wallpaper/gradient afterwards routes through the regular handlers,
    /// which set the style back to .image/.gradient.
    @objc private func selectBlurLevel(_ sender: NSControl) {
        let level = blurLevels[min(sender.tag, blurLevels.count - 1)]
        selectBlur(level: level)
    }

    private func selectBlur(level: CGFloat) {
        let requestToken = blurSelectionRequestGate.begin()
        let snapshot = options
        guard Self.shouldSeedDefaultBlurWallpaper(for: snapshot) else {
            commit(Self.blurSelectionOptions(from: snapshot, level: level, defaultWallpaperData: nil))
            return
        }

        let identity = Self.blurPreviewIdentity(for: snapshot)
        SystemWallpaperSource.defaultBlurBackgroundData { [weak self] data in
            guard let self,
                  self.blurSelectionRequestGate.accepts(requestToken),
                  self.options == snapshot,
                  Self.blurPreviewIdentity(for: self.options) == identity else { return }
            self.commit(Self.blurSelectionOptions(from: snapshot, level: level, defaultWallpaperData: data))
        }
    }

    @objc private func importWallpapersTapped() {
        let panel = NSOpenPanel()
        panel.title = "Add Wallpapers"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.heic, .jpeg, .png, .heif]
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            let imported = SystemWallpaperSource.importWallpapers(from: panel.urls)
            if imported > 0 {
                self.systemWallpapers = SystemWallpaperSource.all
                self.rebuildWallpaperGrid()
            }
        }
    }

    /// Recria só o grid de wallpapers (após um import) preservando a seção.
    private func rebuildWallpaperGrid() {
        guard let section = wallpaperSection as? NSStackView,
              section.arrangedSubviews.count >= 2 else { return }
        let oldGrid = section.arrangedSubviews[1]
        // Remove os botões antigos do registro antes de recriar (a tile "Current
        // desktop" também, que usa um action próprio).
        thumbnailButtons.removeAll {
            $0.action == #selector(selectWallpaper(_:)) || $0.action == #selector(selectCurrentDesktop(_:))
        }
        oldGrid.removeFromSuperview()
        section.addArrangedSubview(wallpaperGrid())
        rebuildThumbnails()
        updateSelectionHighlight()
    }

    @objc private func selectPlainColor(_ sender: NSControl) {
        let hex = plainColors[min(sender.tag, plainColors.count - 1)]
        var next = options
        next.isEnabled = true
        next.style = .solid
        next.colorHex = hex
        next.customImageData = nil
        next.customImageName = nil
        next.tracksDesktopWallpaper = nil
        commit(next)
    }

    @objc private func slidersChanged(_ sender: NSSlider) {
        var next = options
        if sender === paddingSlider { next.padding = CGFloat(sender.doubleValue.rounded()) }
        if sender === insetSlider { next.inset = CGFloat(sender.doubleValue.rounded()) }
        if sender === shadowSlider { next.shadow = CGFloat(sender.doubleValue) }
        if sender === cornerSlider { next.cornerRadius = CGFloat(sender.doubleValue.rounded()) }
        // Update the readout from the in-flight value: a continuous drag fires
        // before options.didSet, so the label must not wait on the round-trip.
        updateValueLabels(for: next)
        commit(next)
    }

    @objc private func autoBalanceToggled(_ sender: NSSwitch) {
        guard sender.state == .on else { return }
        // Auto-balance reorganizes the LAYOUT around the print (padding, inset,
        // shadow, corners), it never touches the background's style or colors. The
        // host refines these against the live screenshot via
        // ScreenshotBackgroundComposer.autoBalancedOptions(for:base:); here we apply
        // tidy, image-agnostic layout values so the rebalance is felt immediately
        // while the backdrop the user picked stays exactly as is.
        var next = options
        next.isEnabled = true
        next.padding = 72
        next.inset = 12
        next.cornerRadius = 18
        next.shadow = 0.42
        next.shadowStrength = 1
        commit(next)
    }

    @objc private func alignmentChanged(_ sender: NSButton) {
        let order = BackgroundAlignment.allCases
        var next = options
        next.alignment = order[min(sender.tag, order.count - 1)]
        commit(next)
    }

    @objc private func ratioChanged(_ sender: NSPopUpButton) {
        var next = options
        let index = sender.indexOfSelectedItem
        if index <= 0 {
            next.aspectPreset = nil
        } else {
            let presets = BackgroundAspectPreset.allCases
            next.aspectPreset = presets[min(index - 1, presets.count - 1)]
        }
        commit(next)
    }

    private func commit(_ next: ScreenshotBackgroundOptions) {
        blurSelectionRequestGate.commitIntent()
        guard next != options else { return }
        options = next
        onChange?(next)
    }

    // MARK: Sync

    private func syncControls() {
        paddingSlider.doubleValue = Double(options.padding)
        insetSlider.doubleValue = Double(options.inset)
        shadowSlider.doubleValue = Double(options.shadow)
        cornerSlider.doubleValue = Double(options.cornerRadius)
        updateValueLabels(for: options)
        autoBalanceSwitch.state = .off
        // Os thumbs da seção Blurred espelham o fundo selecionado no momento.
        refreshBlurPreviewsIfNeeded()

        let order = BackgroundAlignment.allCases
        for button in alignmentButtons {
            let selected = order[min(button.tag, order.count - 1)] == options.alignment
            button.state = selected ? .on : .off
            // O bezel glass não diferencia on/off sobre fundo escuro; o tint
            // coral é quem marca a célula ativa.
            button.bezelColor = selected ? KritColors.accent : nil
        }

        if let preset = options.aspectPreset,
           let idx = BackgroundAspectPreset.allCases.firstIndex(of: preset) {
            ratioPopup.selectItem(at: idx + 1)
        } else {
            ratioPopup.selectItem(at: 0)
        }

        syncActivePreset()
        updateSelectionHighlight()
    }

    /// Keeps the dropdown honest as the user edits by hand: when the live
    /// background no longer matches the selected preset's saved config, the
    /// selection drops back to "Custom". Only rebuilds the popup when the selected
    /// state actually changes, so a continuous slider drag stays cheap.
    private func syncActivePreset() {
        if let active = TemplateStore.activePreset {
            guard active.background != options else { return }
            // Diverged from the saved preset: drop to the "(edited)" state, which
            // reloadPresetBar renders from the retained edit base.
            TemplateStore.setActive(name: nil)
            reloadPresetBar()
            return
        }
        // No active preset. If the live background drifted back to exactly the base
        // preset being edited, re-select it so the "(edited)" badge clears on its own.
        if let base = TemplateStore.editingBase, base.background == options {
            TemplateStore.setActive(name: base.name)
            reloadPresetBar()
        }
    }

    private func updateValueLabels(for opts: ScreenshotBackgroundOptions) {
        paddingValue.stringValue = "\(Int(opts.padding))"
        insetValue.stringValue = "\(Int(opts.inset))"
        shadowValue.stringValue = "\(Int((opts.shadow * 100).rounded()))%"
        cornerValue.stringValue = "\(Int(opts.cornerRadius))"
    }

    private func updateSelectionHighlight() {
        // Background disabled == None selected: light the native toggle's pressed
        // bezel and coral tint, the same accent cue the editor toolbar toggles use.
        let noneSelected = !options.isEnabled
        // The row restyles itself from `state`; a contentTintColor here would
        // only fight it.
        noneButton?.state = noneSelected ? .on : .off

        for button in thumbnailButtons {
            button.isSelectedThumbnail = isThumbnailSelected(button)
        }
        for swatch in colorSwatches {
            let hex = plainColors[min(swatch.tag, plainColors.count - 1)]
            swatch.isSelectedSwatch = options.isEnabled
                && options.style == .solid
                && hex.caseInsensitiveCompare(options.colorHex) == .orderedSame
        }
    }

    private func isThumbnailSelected(_ button: BackgroundThumbnailButton) -> Bool {
        guard options.isEnabled, let action = button.action else { return false }
        switch action {
        case #selector(selectCurrentDesktop(_:)):
            // The desktop-tracking image is the one selected state for this tile;
            // picking any fixed source clears the flag (handled in those actions).
            return options.style == .image && options.tracksDesktopWallpaper == true
        case #selector(selectGradient(_:)):
            guard options.style == .gradient else { return false }
            return gradientPresets[safe: button.tag]?.name == options.presetName
        case #selector(selectWallpaper(_:)):
            // A desktop-tracking image is owned by the Current desktop tile, never
            // a fixed-wallpaper thumb.
            if options.tracksDesktopWallpaper == true { return false }
            if hasSystemWallpapers {
                guard let wallpaper = systemWallpapers[safe: button.tag] else { return false }
                if pendingWallpaperName == wallpaper.name { return true }
                return options.style == .image
                    && options.customImageData != nil
                    && options.presetName == wallpaper.name
            }
            guard options.style == .image, options.customImageData == nil else { return false }
            return ScreenshotBackgroundOptions.imagePresets[safe: button.tag]?.name == options.presetName
        case #selector(selectBlurLevel(_:)):
            guard options.style == .blurredImage, let level = blurLevels[safe: button.tag] else { return false }
            return abs(options.blurIntensity - level) < 0.5
        default:
            return false
        }
    }

    // MARK: Thumbnail rendering

    private func rebuildThumbnails() {
        for button in thumbnailButtons {
            guard let action = button.action else { continue }
            // Blurred tiles depend on the selected background, not on a fixed
            // preset; refreshBlurPreviewsIfNeeded() owns their rendering.
            if action == #selector(selectBlurLevel(_:)) { continue }
            // Current desktop: preview the live wallpaper of this Mac so the tile
            // looks like what it will apply.
            if action == #selector(selectCurrentDesktop(_:)) {
                button.previewImage = currentDesktopThumbnail()
                continue
            }
            // Real wallpapers decode off the main thread; the rest render inline.
            if action == #selector(selectWallpaper(_:)), hasSystemWallpapers {
                guard let wallpaper = systemWallpapers[safe: button.tag] else { continue }
                SystemWallpaperSource.thumbnail(for: wallpaper, maxPixel: Style.thumbSize * 3) { [weak button] image in
                    button?.previewImage = image
                }
                continue
            }
            button.previewImage = thumbnailPreview(for: action, tag: button.tag)
        }
    }

    /// Square thumbnail of the live desktop wallpaper, aspect-filled. Falls back to
    /// a neutral tile when no wallpaper is readable so the tile never looks broken.
    private func currentDesktopThumbnail() -> NSImage {
        let size = NSSize(width: Style.thumbSize, height: Style.thumbSize)
        guard let data = SystemWallpaperSource.currentDesktopBackgroundData(for: nil),
              let source = NSImage(data: data) else {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            return image
        }
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let src = source.size
        let scale = max(size.width / max(src.width, 1), size.height / max(src.height, 1))
        let drawn = NSSize(width: src.width * scale, height: src.height * scale)
        let origin = NSPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        source.draw(in: NSRect(origin: origin, size: drawn))
        thumb.unlockFocus()
        return thumb
    }

    private func thumbnailPreview(for action: Selector, tag: Int) -> NSImage {
        let size = NSSize(width: Style.thumbSize, height: Style.thumbSize)
        var opts = ScreenshotBackgroundOptions.editorDefault
        opts.isEnabled = true
        switch action {
        case #selector(selectGradient(_:)):
            guard let preset = gradientPresets[safe: tag] else { return NSImage(size: size) }
            opts.style = .gradient
            opts.gradientStartHex = preset.startHex
            opts.gradientEndHex = preset.endHex
            opts.accentHexes = preset.accents
        case #selector(selectWallpaper(_:)):
            guard let preset = ScreenshotBackgroundOptions.imagePresets[safe: tag] else { return NSImage(size: size) }
            opts.style = .image
            opts.presetName = preset.name
            opts.accentHexes = preset.accentHexes
        default:
            return NSImage(size: size)
        }
        return ScreenshotBackgroundComposer.previewImage(options: opts, size: size, scale: 2)
    }

    // MARK: Blurred previews

    /// Identity of the blur tiles' SOURCE background. Switching between a sharp
    /// background and its own blurred version keeps the same identity (the tiles
    /// preview the same source), so only a genuine background change re-renders.
    static func blurPreviewIdentity(for opts: ScreenshotBackgroundOptions) -> String {
        let sourceMode = shouldSeedDefaultBlurWallpaper(for: opts) ? "seed-default" : "selected"
        let style = opts.style == .blurredImage ? ScreenshotBackgroundOptions.Style.image.rawValue : opts.style.rawValue
        let customName = opts.customImageName ?? "none"
        let customData = opts.customImageData.map { "\($0.count)-\($0.hashValue)" } ?? "none"
        let accents = opts.accentHexes.joined(separator: ",")
        let desktopTracking = opts.tracksDesktopWallpaper.map { $0 ? "tracking" : "fixed" } ?? "unspecified"
        return [
            sourceMode, style, opts.presetName, opts.colorHex,
            opts.gradientStartHex, opts.gradientEndHex, accents,
            customName, customData, desktopTracking,
        ].joined(separator: "|")
    }

    /// Re-renders the three Blurred tiles when the selected background changes.
    /// Renders are cached per (background identity, level); wallpaper data
    /// decodes off the main thread, same pattern as the wallpaper grid.
    private func refreshBlurPreviewsIfNeeded() {
        let identity = Self.blurPreviewIdentity(for: options)
        guard identity != lastBlurIdentity else { return }
        lastBlurIdentity = identity
        // Unbounded growth guard: identities embed wallpaper names, so a long
        // session could pile up; resetting is cheap (thumbs re-render lazily).
        if blurPreviewCache.count > 60 { blurPreviewCache.removeAll() }

        let snapshot = options
        let size = NSSize(width: Style.thumbSize, height: Style.thumbSize)
        if Self.shouldSeedDefaultBlurWallpaper(for: snapshot) {
            SystemWallpaperSource.defaultBlurBackgroundData(maxPixel: Style.thumbSize * 6) { [weak self] data in
                guard let self, self.lastBlurIdentity == identity else { return }
                var previewSnapshot = snapshot
                if let data, NSImage(data: data) != nil {
                    previewSnapshot.style = .image
                    previewSnapshot.presetName = SystemWallpaperSource.defaultBlurWallpaperName
                    previewSnapshot.customImageData = data
                    previewSnapshot.customImageName = SystemWallpaperSource.defaultBlurWallpaperName
                    previewSnapshot.tracksDesktopWallpaper = nil
                }
                self.renderBlurPreviews(snapshot: previewSnapshot, identity: identity, size: size)
            }
            return
        }

        renderBlurPreviews(snapshot: snapshot, identity: identity, size: size)
    }

    private func renderBlurPreviews(snapshot: ScreenshotBackgroundOptions, identity: String, size: NSSize) {
        for button in thumbnailButtons where button.action == #selector(selectBlurLevel(_:)) {
            guard let level = blurLevels[safe: button.tag] else { continue }
            let key = "\(identity)|\(level)"
            if let cached = blurPreviewCache[key] {
                button.previewImage = cached
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak button] in
                let image = ScreenshotBackgroundComposer.blurredPreviewImage(
                    options: snapshot, blurIntensity: level, size: size, scale: 2
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.blurPreviewCache[key] = image
                    // Stale render: the background changed again mid-flight.
                    guard self.lastBlurIdentity == identity else { return }
                    button?.previewImage = image
                }
            }
        }
    }
}

// MARK: - Thumbnail button

private final class BackgroundThumbnailButton: NSControl {

    override var mouseDownCanMoveWindow: Bool { false }

    var previewImage: NSImage? { didSet { needsDisplay = true } }
    var isSelectedThumbnail = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let corner: CGFloat = 8
        let inset: CGFloat = isSelectedThumbnail ? 1.5 : 0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        if let previewImage {
            previewImage.draw(in: rect)
        } else {
            NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
            rect.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        if hovering && !isSelectedThumbnail {
            NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
            path.fill()
        }
        if isSelectedThumbnail {
            let strokePath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: corner, yRadius: corner)
            KritColors.accent.setStroke()
            strokePath.lineWidth = 2
            strokePath.stroke()
        }
    }
}

/// A section card. Its border resolves per appearance, so it cannot be a plain
/// `NSView` with a `cgColor` assigned once at build time.
private final class CardView: NSView {

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = KritMetrics.Radius.card
        layer?.cornerCurve = .continuous
        layer?.borderWidth = KritColors.hairlineWidth
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.borderColor = KritColors.hairline.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Color swatch

private final class BackgroundColorSwatch: NSControl {

    override var mouseDownCanMoveWindow: Bool { false }

    var fillColor: NSColor = .white { didSet { needsDisplay = true } }
    var isSelectedSwatch = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if let action, let target { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Reference geometry:
        //   idle      inset 0 0 0 .5px rgba(0,0,0,.10), 0 1px 2px rgba(0,0,0,.08)
        //   selected  inset 0 0 0 1.5px <surface>, inset 0 0 0 3px <accent>
        //   hover     scale(1.12)
        // The selected ring is drawn as surface-then-accent so the accent reads
        // as a ring *around* the swatch. A single accent stroke disappears the
        // moment the swatch itself is a warm colour.
        let inset: CGFloat = hovering ? 1 : 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let circle = NSBezierPath(ovalIn: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fillColor.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard isSelectedSwatch else {
            NSColor.black.withAlphaComponent(0.10).setStroke()
            circle.lineWidth = KritColors.hairlineWidth
            circle.stroke()
            return
        }

        let gap = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        KritColors.sidebarBackground.setStroke()
        gap.lineWidth = 1.5
        gap.stroke()

        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.25, dy: 2.25))
        KritColors.accent.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


/// Top-anchored scroll content: without isFlipped the sidebar opens scrolled
/// to the bottom of the stack.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
