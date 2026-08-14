import AppKit
import UniformTypeIdentifiers

/// Manages the full annotation editor window.
@MainActor
final class AnnotationWindowController: NSWindowController {

    /// Conservative window-width floor before the live toolbar `fittingWidth`
    /// is available at init time. The header is now a single full-width row, so
    /// its own conservative content width is the floor (no separate left-group /
    /// dock terms to sum).
    private static let minimumEditorWidth = AnnotationToolbar.requiredWidth + 20
    private static let initialScreenWidthFraction: CGFloat = 0.90
    private static let initialScreenHeightFraction: CGFloat = 0.84
    private static let initialScreenEdgeInset: CGFloat = 24

    // Shared stage metrics. The editor is a single uninterrupted stage with
    // chrome floating *over* it, not a canvas boxed in by bands: the only
    // reserved strip is the titlebar the traffic lights live in. Everything
    // else (tools, actions) is a glass pill the stage shows through.
    //
    // Band at the top of the window where the system draws the traffic lights.
    // The STAGE runs under it, so there is no dead strip; the PANELS stop below
    // it, because the window buttons are system-placed and cannot be moved out
    // of a panel's way. Whoever wants that corner loses it, and it should be the
    // panel, not the buttons the whole OS relies on.
    private static let trafficLightBand: CGFloat = 28
    private static let titlebarHeight: CGFloat = 38
    /// Breathing room between a floating pill and the edge of the stage.
    private static let stagePadding: CGFloat = 22
    private static let stageInset: CGFloat = 18
    /// Height of the floating tool pill: 5pt of padding around a 32pt control.
    private static let toolbarHeight: CGFloat = AnnotationToolbar.totalHeight
    /// Height of the floating action pill (zoom · mode · drag · share/pin/copy).
    private static let bottomBarHeight: CGFloat = EditorBottomBar.pillHeight
    /// Canvas height the sidebar needs to show its scrolling control column
    /// comfortably; the window minimum is derived from this so opening the
    /// sidebar never crams the editor.
    private static let minimumCanvasHeight: CGFloat = 420

    private let canvas: AnnotationCanvas
    private let toolbar: AnnotationToolbar
    private var backgroundSidebar: BackgroundSidebar?
    private var bottomBar: EditorBottomBar?
    private var editorScrollView: NSScrollView?
    private var sidebarVisible = false
    // ES1: the sidebar is an integrated window column flush to the left edge
    // (x:0), so opening it slides the canvas right by exactly its width, no gap.
    private static let sidebarWidth: CGFloat = BackgroundSidebar.preferredWidth
    private static let sidebarGap: CGFloat = 0
    private let historyItem: HistoryItem?
    private let historyManager: HistoryManager?
    private var image: NSImage
    private var backgroundOptions = ScreenshotBackgroundOptions.editorDefault
    /// Set only when the user changes the background through the toolbar/sidebar.
    /// The auto-applied default template (E2) opens with a non-default
    /// backgroundOptions but is NOT a user edit, so the close warning keys off
    /// this flag rather than comparing against editorDefault.
    private var hasUserBackgroundEdit = false
    private var hasUserCropEdit = false
    private var cleanUndoDepth = 0
    private var documentRevision: UInt64 = 0 {
        didSet {
            bottomBar?.invalidatePreparedDragFile()
            scheduleDragExportPreparation()
        }
    }
    private var dragSnapshotRevision: UInt64?
    private var dragExportPreparationTask: Task<Void, Never>?
    private var hasUnsavedChanges: Bool {
        canvas.undoDepth != cleanUndoDepth || hasUserBackgroundEdit || hasUserCropEdit
    }
    // R1: distingue resize programático (auto-fit) de resize manual do usuário.
    private var isProgrammaticResize = false
    private var userManuallyResized = false
    // Fit-to-stage: por padrão o editor mantém o canvas inteiro encaixado no
    // palco visível. Mudar padding/inset/background/aspect/crop NÃO cresce a
    // janela: o canvas re-escala (fit) pra caber, e o label de zoom reflete.
    // Sai do modo quando o usuário escolhe um zoom manual no popup; volta ao
    // escolher "Fit". A janela é sempre do usuário (abertura + resize manual).
    private var fitMode = true
    private var sidebarWasVisibleBeforePreview = false
    private var sidebarAnimationGeneration: UInt = 0

    // Strong references so controllers aren't deallocated while their window is open
    private static var openControllers: [AnnotationWindowController] = []

    static var hasOpenEditors: Bool {
        !openControllers.isEmpty
    }

    static func bringOpenEditorsToFront() {
        guard hasOpenEditors else { return }
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        for controller in openControllers {
            controller.bringEditorToFront()
        }
    }

    /// Dev affordance: opens the editor pre-populated with one of every
    /// annotation element, for programmatic visual verification.
    @discardableResult
    static func openDemo(image: NSImage) -> AnnotationWindowController {
        let controller = AnnotationWindowController(image: image, historyItem: nil, historyManager: nil)
        openControllers.append(controller)

        let canvas = controller.canvas
        let arrow = ArrowAnnotation(start: CGPoint(x: 60, y: 420), end: CGPoint(x: 280, y: 300))
        arrow.lineWidth = 6
        let curved = ArrowAnnotation(start: CGPoint(x: 80, y: 500), end: CGPoint(x: 360, y: 480))
        curved.lineWidth = 10
        curved.controlPoint = CGPoint(x: 220, y: 380)
        curved.color = .systemPink
        let box = RectangleAnnotation(rect: CGRect(x: 420, y: 90, width: 220, height: 120))
        box.lineWidth = 4
        let circle = EllipseAnnotation(rect: CGRect(x: 680, y: 80, width: 140, height: 140))
        circle.color = .systemYellow
        circle.lineWidth = 4
        let text = TextAnnotation(origin: CGPoint(x: 430, y: 250))
        text.text = "Click here"
        text.fontSize = 30
        text.backplate = .pill
        text.color = .systemPink
        let plainText = TextAnnotation(origin: CGPoint(x: 430, y: 320))
        plainText.text = "Plain bold label"
        plainText.fontSize = 26
        plainText.color = .white
        let s1 = NumberedStepAnnotation(center: CGPoint(x: 80, y: 120), number: 1)
        let s2 = NumberedStepAnnotation(center: CGPoint(x: 150, y: 160), number: 2)
        let s3 = NumberedStepAnnotation(center: CGPoint(x: 220, y: 120), number: 3)
        canvas.objects = [arrow, curved, box, circle, text, plainText, s1, s2, s3]
        canvas.setSelection([curved])

        // Showcase the backgrounds pipeline: apply a gradient and open the sidebar.
        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = true
        bg.style = .gradient
        bg.gradientStartHex = "#050816"
        bg.gradientEndHex = "#67d7ff"
        bg.accentHexes = ["#7c3aed", "#38f8d4", "#d8f7ff"]
        bg.padding = 48
        bg.cornerRadius = 14
        bg.shadow = 0.7
        controller.toolbar.setBackgroundOptionsExternally(bg)
        controller.applyBackgroundOptions(bg)
        controller.toggleBackgroundSidebar()

        // Demo must surface over whatever Space is active (incl. another app's
        // fullscreen Space) so it can be screenshotted on headless/remote hosts.
        // screenSaver level is what the selection overlay uses to float above
        // fullscreen apps.
        controller.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        controller.window?.level = .screenSaver
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.bringEditorToFront()
        controller.zoomToFitOnAppear()
        return controller
    }

    static func open(image: NSImage, historyItem: HistoryItem? = nil, historyManager: HistoryManager? = nil) {
        let controller = AnnotationWindowController(image: image, historyItem: historyItem, historyManager: historyManager)
        openControllers.append(controller)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if let win = controller.window {
            win.alphaValue = 0
            controller.bringEditorToFront()
            Motion.animate(0.2, timing: .easeOut) { _ in
                win.animator().alphaValue = 1
            }
        }
        // ES7: open at zoom-to-fit once the scroll view has its real viewport size.
        controller.zoomToFitOnAppear()
    }

    init(image: NSImage, historyItem: HistoryItem?, historyManager: HistoryManager?) {
        self.image = image
        self.historyItem = historyItem
        self.historyManager = historyManager
        self.canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        self.toolbar = AnnotationToolbar()

        // User rule: with no default template the editor opens with the RAW shot,
        // no background, no checkerboard, just the print on the dark stage. Opening
        // the sidebar doesn't auto-apply anything either. Once the user marks a
        // template as default, every new common shot opens already composed with
        // that config, "bonito" out of the gate. Window captures are the separate
        // case: they follow the "Window capture background" preference (system
        // wallpaper, saved template, or none), which takes precedence for windows.
        let isWindowShot = historyItem?.isWindowCapture == true
        let initialBackground: ScreenshotBackgroundOptions
        // The named preset the editor opens with, so the dropdown shows it SELECTED
        // (and as the edit base). A shot composed from the user's default preset must
        // read as that preset, not "Custom", or editing it forks a new template
        // instead of offering "Save Changes to <name>" (the dono's bug).
        let openingPresetName: String?
        if isWindowShot {
            initialBackground = Self.windowShotBackground(for: image, captureRect: historyItem?.captureRect?.cgRect)
            openingPresetName = nil
        } else if let defaultTemplate = TemplateStore.defaultTemplate, defaultTemplate.background.isEnabled {
            initialBackground = defaultTemplate.background
                .resolvingDesktopWallpaper(for: Self.screenContaining(historyItem?.captureRect?.cgRect))
            openingPresetName = defaultTemplate.name
        } else {
            initialBackground = .editorDefault   // isEnabled == false: raw shot
            openingPresetName = nil
        }
        let canvasSize = ScreenshotBackgroundComposer.outputPointSize(for: image.size, options: initialBackground)

        // Open the window sized to the image (scaled to fit), not to a fraction of
        // the screen. Limiting width and height independently broke the aspect for
        // extreme ratios: a wide shot in a tall window left a sea of black stage
        // below it (the bug the owner saw). Instead, scale the canvas to fit a
        // moderate envelope and size the window to canvas*scale + chrome, so the
        // stage padding stays uniform and the window never opens near-fullscreen
        // (standardWindowSize, shared with the background on/off resize).
        let windowSize = Self.standardWindowSize(forCanvas: canvasSize, on: NSScreen.main)
        let winW = windowSize.width
        let winH = windowSize.height

        let win = EditorKeyWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // No empty unified toolbar any more: it existed to centre the traffic
        // lights inside the old 52pt command band, and that band is gone. Left
        // in, it pushes the lights down to the middle of a band nothing draws,
        // which is deeper into the panel's content.
        win.isReleasedWhenClosed = false
        // A behind-window material samples the DESKTOP, and it can only do that
        // through a window that is not opaque. Without these two lines the stage
        // vibrancy renders as flat grey and the opacity preference does nothing
        // visible.
        win.isOpaque = false
        win.backgroundColor = .clear
        // Janela normal de documento: .floating prendia o editor acima de TODOS
        // os apps (clicar num app abaixo não o trazia pra frente).
        win.level = .normal
        win.minSize = Self.minimumWindowSize(on: NSScreen.main)
        win.center()

        super.init(window: win)

        // Set before the sidebar/canvas are built (the sidebar reads it for its
        // initial `options`); the canvas is resized to the composed size below,
        // after the view hierarchy exists.
        backgroundOptions = initialBackground

        // Reflect what the editor opened with in the preset dropdown: a shot composed
        // from the default preset opens with that preset SELECTED and as the edit
        // base, so tweaking it offers "Save Changes to <name>"; a raw or window shot
        // clears the selection so it reads as "Custom".
        TemplateStore.setActive(name: openingPresetName)
        TemplateStore.setEditingBase(name: openingPresetName)

        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: canvasSize)

        // Scroll view for canvas. It owns the whole stage under the titlebar, no
        // inset band and no border of its own: a second frame floating inside
        // would read as a detached panel with the stage colour leaking around
        // it. Breathing room around the document comes from the window sizing
        // formulas (stageInset) via the centering clip view, not from chrome.
        let scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: winW,
            height: winH
        ))
        // Center canvas when viewport is larger than the image (eliminates blank side areas)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // Laid out manually by layoutStage so the canvas reflows in lockstep with
        // the sidebar; autoresizing margins can't express "shrink only on the
        // sidebar side".
        scrollView.autoresizingMask = []
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.wantsLayer = true
        // No scroll edge effect here: `scrollEdgeEffectStyle` is a SwiftUI-only
        // modifier in the macOS 26 SDK; AppKit's NSScrollView exposes no equivalent
        // property, so there is nothing to guard with #available.

        // Tool pill: intrinsically sized glass, centred over the stage. The
        // toolbar sizes itself; the controller only places it.
        toolbar.frame = Self.toolbarPillFrame(stageX: 0, stageWidth: winW, winH: winH, toolbar: toolbar)
        // Manual layout on resize (layoutStage) so the pill tracks the stage.
        toolbar.autoresizingMask = []

        toolbar.onToolChanged     = { [weak self] tool in
            self?.canvas.activeTool = tool
            // Clear crop state when switching away from crop tool
            if tool != .crop {
                self?.canvas.cropRect = nil
                self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
                self?.toolbar.setCropApplyVisible(false)
            }
            // The text tool swaps in the font row, which is wider than the width
            // row it replaces; on a narrow window the toolbar overflowed past the
            // chrome as a broken black strip. Widen to fit whenever a tool swap
            // reshapes the toolbar.
            self?.ensureWindowFitsToolbar()
        }
        toolbar.onColorChanged    = { [weak self] color in self?.canvas.setActiveColor(color) }
        toolbar.onLineWidthChanged = { [weak self] w in
            guard let self else { return }
            // Only the arrow drives the persisted global default (its bold weight is
            // the editor's signature). Store the DE-SCALED base: divide the slider's
            // scaled value by the capture factor so the chosen visual thickness
            // sticks across captures of the same size instead of re-inflating.
            if self.canvas.activeTool == .arrow {
                let factor = max(self.canvas.captureThicknessFactor, 0.0001)
                Settings.annotationLineWidth = Double(w) / Double(factor)
            }
            self.canvas.setActiveLineWidth(w)
        }
        toolbar.onFontFamilyChanged = { [weak self] family in
            self?.canvas.activeFontFamily = family
            self?.applyToSelectedTexts { $0.fontFamily = family }
        }
        toolbar.onFontSizeChanged = { [weak self] size in
            self?.canvas.activeFontSize = size
            self?.applyToSelectedTexts { $0.fontSize = size }
        }
        toolbar.onBackplateChanged = { [weak self] plate in
            self?.canvas.activeBackplate = plate
            self?.applyToSelectedTexts { $0.backplate = plate }
        }
        toolbar.onSecureBlurChanged = { [weak self] secure in
            self?.canvas.activeBlurSecure = secure
            self?.applyToSelectedBlurs { $0.secure = secure }
        }
        toolbar.onRedactStrengthChanged = { [weak self] strength in
            guard let self else { return }
            // The active tool decides which redaction kind the slider drives; the
            // canvas remembers it for new strokes, and any selected one updates now.
            if self.canvas.activeTool == .pixelate {
                self.canvas.activePixelateScale = strength
                self.applyToSelectedPixelates { $0.scale = strength }
            } else {
                self.canvas.activeBlurRadius = strength
                self.applyToSelectedBlurs { $0.radius = strength }
            }
        }
        toolbar.onStylePresetChanged = { [weak self] preset in
            guard let self else { return }
            // The preset becomes the default for new text and applies to any
            // currently selected text (font weight, italic, backplate, outline).
            self.canvas.activeFontWeight = preset.weight
            self.canvas.activeItalic = preset.italic
            self.canvas.activeBackplate = preset.backplate
            self.canvas.activeOutline = preset.outline
            self.applyToSelectedTexts {
                $0.fontWeight = preset.weight
                $0.italic = preset.italic
                $0.backplate = preset.backplate
                $0.outline = preset.outline
            }
            // Keep the quick backplate toggle's pressed state in sync.
            self.toolbar.setBackplateActive(preset.backplate == .pill)
        }
        toolbar.onSaveAs          = { [weak self] in self?.saveAs() }
        toolbar.onDone            = { [weak self] in self?.copyAndClose() }
        toolbar.onApplyCrop       = { [weak self] in self?.applyCrop() }
        toolbar.onCancelCrop      = { [weak self] in
            // Same path as Esc inside the crop tool: drop the staged region,
            // restore the delivery actions, stay on the crop tool.
            self?.canvas.cropRect = nil
            self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
            self?.toolbar.setCropApplyVisible(false)
        }
        toolbar.onUndo            = { [weak self] in self?.canvas.performUndo() }
        toolbar.onRedo            = { [weak self] in self?.canvas.performRedo() }
        toolbar.onBackgroundOptionsChanged = { [weak self] options in
            guard let self else { return }
            self.documentRevision &+= 1
            self.hasUserBackgroundEdit = true
            self.pushBackgroundUndoIfNeeded()
            self.applyBackgroundOptions(options)
        }
        toolbar.onBackgroundPanelToggle = { [weak self] in self?.toggleBackgroundSidebar() }
        toolbar.onSmartRedact = { [weak self] in self?.runSmartRedactFlow() }
        canvas.onSmartRedactStateChanged = { [weak self] hasPreview in
            self?.toolbar.setSmartRedactPreviewActive(hasPreview)
        }

        // Sync tool changes from canvas keyboard shortcuts back to toolbar
        canvas.onToolChanged = { [weak self] tool in
            self?.toolbar.selectToolExternally(tool)
            if tool != .crop {
                self?.canvas.cropRect = nil
                self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
                self?.toolbar.setCropApplyVisible(false)
            }
        }

        // Item 4: per-tool thickness. Switching tools moves the active line width
        // to that tool's remembered default; mirror it on the slider so the
        // control shows the size new shapes will actually use.
        canvas.onActiveLineWidthChanged = { [weak self] width in
            self?.toolbar.setLineWidthExternally(width)
        }

        // Keep the style popover's active swatch truthful: when a text is selected,
        // ring the preset matching it; otherwise ring the active default. Reads the
        // first selected text so a multi-select shows the lead object's style.
        canvas.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            if let text = selection.compactMap({ $0 as? TextAnnotation }).first {
                self.toolbar.currentStylePreset = TextStylePreset.matching(text)
            }
        }

        // Show Crop check button only when a crop region is drawn
        canvas.onCropChanged = { [weak self] rect in
            guard let self else { return }
            let hasCrop = rect != nil && !(rect?.isEmpty ?? true)
            self.toolbar.setCropApplyVisible(!self.canvas.isPreviewMode && hasCrop)
        }

        // Return/Enter or double-click inside the region commits the crop,
        // same path as the toolbar check button.
        canvas.onCropCommit = { [weak self] in self?.applyCrop() }

        // Item 1: undo/redo. Mirror the canvas stacks on the header buttons and
        // resync the document when an undo/redo restores a different image/size
        // (crop and background changes), then refit the window to it.
        canvas.onUndoStateChanged = { [weak self] canUndo, canRedo in
            guard let self else { return }
            self.documentRevision &+= 1
            self.toolbar.setUndoRedoEnabled(canUndo: canUndo, canRedo: canRedo)
            if self.canvas.undoDepth == self.cleanUndoDepth {
                self.hasUserBackgroundEdit = false
                self.hasUserCropEdit = false
            }
        }
        canvas.onDocumentRestored = { [weak self] in self?.syncDocumentFromCanvas() }

        // Build hierarchy FIRST, then configure layers (layers don't exist until views are in a window)
        let container = PremiumEditorStageView(frame: NSRect(origin: .zero, size: windowSize))

        // Stage first, chrome over it. There is no backdrop behind the canvas any
        // more: the editor is one uninterrupted stage, and every piece of chrome
        // is a glass pill floating on it. Order here is z-order.
        container.addSubview(scrollView)
        container.addSubview(toolbar)

        // The leading actions ([undo/redo][crop][backgrounds][redact]) are now the
        // first members of the toolbar's single internal row, so there is no
        // separate left-group view to parent or frame here.

        // Backgrounds sidebar (CleanShot "B" panel), an integrated left column
        // (ES1): x:0, full height between the bottom bar and the floating dock.
        // Hidden until toggled.
        let sidebar = BackgroundSidebar(options: backgroundOptions)
        sidebar.frame = Self.sidebarRect(winW: winW, winH: winH, visible: false)
        // Owned by layoutStage; height tracks the content band, width is fixed.
        sidebar.autoresizingMask = []
        sidebar.isHidden = true
        sidebar.onChange = { [weak self] options in
            guard let self else { return }
            self.documentRevision &+= 1
            self.hasUserBackgroundEdit = true
            self.pushBackgroundUndoIfNeeded()
            self.toolbar.setBackgroundOptionsExternally(options)
            self.applyBackgroundOptions(options)
        }
        container.addSubview(sidebar)
        backgroundSidebar = sidebar

        editorScrollView = scrollView

        // ES4: editor action pill with zoom, preview, drag-out, Share and Pin.
        let bar = EditorBottomBar()
        bar.frame = Self.actionPillFrame(stageX: 0, stageWidth: winW, winH: winH, bar: bar)
        bar.autoresizingMask = []
        bar.onZoomChanged = { [weak self] mag in
            // Zoom manual: o usuário assume o controle, o auto-fit para de mexer
            // na escala. Aqui o canvas pode passar do palco e ganhar scroll.
            self?.fitMode = false
            self?.canvas.applyZoom(mag)
        }
        bar.onZoomFit = { [weak self] in
            guard let self else { return }
            // Volta pro modo fit: o canvas re-escala pra caber e segue caber em
            // toda mudança de tamanho daqui pra frente.
            self.fitMode = true
            let level = self.canvas.fitToWindow()
            self.bottomBar?.setZoomLabel(for: level)
        }
        bar.onPreviewModeChanged = { [weak self] preview in
            guard let self else { return }
            self.canvas.isPreviewMode = preview
            self.toolbar.setPreviewMode(preview)
            let hasCrop = self.canvas.cropRect.map { !$0.isEmpty } ?? false
            self.toolbar.setCropApplyVisible(!preview && hasCrop)
            if preview {
                self.sidebarWasVisibleBeforePreview = self.sidebarVisible
                if self.sidebarVisible { self.toggleBackgroundSidebar() }
            } else if self.sidebarWasVisibleBeforePreview, !self.sidebarVisible {
                self.sidebarWasVisibleBeforePreview = false
                self.toggleBackgroundSidebar()
            }
        }
        bar.onCreateDragExportSnapshot = { [weak self] in
            guard let self else { return nil }
            let snapshot = self.canvas.makeExportSnapshot()
            self.dragSnapshotRevision = self.documentRevision
            return snapshot
        }
        bar.onRequestDragPreview = { [weak self] in self?.image }
        bar.onRequestImmediateDragExport = { [weak self] in self?.exportImage() }
        bar.onDragDelivered = { [weak self] in
            guard let self else { return }
            self.canvas.commitTextField()
            let shouldClose = self.dragSnapshotRevision == self.documentRevision
            self.dragSnapshotRevision = nil
            guard shouldClose else { return }
            self.markCurrentDocumentClean()
            self.window?.performClose(nil)
        }
        bar.onShare = { [weak self] in self?.shareFromBottomBar() }
        bar.onPin = { [weak self] in self?.pin() }
        bar.onCopy = { [weak self] in self?.copyToClipboard() }
        container.addSubview(bar)
        bottomBar = bar
        scheduleDragExportPreparation()

        // ES7: keep the bottom-bar zoom label in sync when the user pinches/⌘± on
        // the canvas, so the popup always reflects the live magnification.
        canvas.onMagnificationChanged = { [weak self] mag in self?.bottomBar?.setZoomLabel(for: mag) }
        // Any user-driven zoom (pinch, Cmd+scroll, Cmd+plus/minus) takes over from
        // auto-fit, otherwise the next window resize silently re-fits over the
        // zoom the user just chose. Cmd+0 hands control back to fit mode.
        canvas.onUserZoom = { [weak self] in self?.fitMode = false }
        canvas.onUserFit = { [weak self] in
            guard let self else { return }
            self.fitMode = true
            let level = self.canvas.fitToWindow()
            self.bottomBar?.setZoomLabel(for: level)
        }

        win.contentView = container
        win.delegate = self

        // Item 1: route ⌘Z / ⇧⌘Z through the window so undo/redo fire whenever the
        // editor is key, regardless of which control holds first responder (a
        // toolbar button or slider would otherwise swallow the focus and the
        // canvas's own keyDown would never see the shortcut).
        win.onUndoKey = { [weak self] in self?.canvas.performUndo() }
        win.onRedoKey = { [weak self] in self?.canvas.performRedo() }
        win.onSaveKey = { [weak self] in self?.quickSave() }

        // NOW layers exist, set masksToBounds on the clip view (the actual clipping mechanism)
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true

        // E2: composite the default template's background now that the canvas exists,
        // so the editor opens already styled (no flash of the unstyled capture) with
        // the toolbar Background button tinted. Mirrors the openDemo apply path.
        if backgroundOptions.isEnabled {
            toolbar.setBackgroundOptionsExternally(backgroundOptions)
            applyBackgroundOptions(backgroundOptions)
        }
        updateCheckerboard()

        win.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The background a window capture opens with, per the "Window capture
    /// background" preference. `.systemWallpaper` (default) composes the current
    /// desktop wallpaper of the capture's screen behind the shot, centered with a
    /// balanced frame and shadow, ready out of the box. `.savedTemplate` keeps the
    /// legacy behavior (default template, else a seeded enabled background).
    /// `.none` opens raw. The wallpaper case falls back to the saved-template path
    /// when no readable wallpaper exists, so a window shot is never left unstyled
    /// while the preference asks for a background.
    static func windowShotBackground(for image: NSImage, captureRect: CGRect?) -> ScreenshotBackgroundOptions {
        switch Settings.windowCaptureBackground {
        case .none:
            return .editorDefault
        case .systemWallpaper:
            let screen = screenContaining(captureRect)
            if let data = SystemWallpaperSource.currentDesktopBackgroundData(for: screen) {
                var options = ScreenshotBackgroundOptions.editorDefault
                options.isEnabled = true
                options.style = .image
                options.customImageData = data
                options.customImageName = "Current wallpaper"
                // Saving these options as a template keeps following the desktop
                // wallpaper instead of freezing today's image into the template.
                options.tracksDesktopWallpaper = true
                // autoBalancedOptions only reflows the framing (padding/inset/
                // corners/shadow) and leaves the wallpaper image untouched.
                var balanced = ScreenshotBackgroundComposer.autoBalancedOptions(for: image, base: options)
                // A window shot already carries its own window shape and shadow;
                // the inset frame (median border color) reads as a strange
                // colored ring around the window. No inset for window shots.
                balanced.inset = 0
                return balanced
            }
            return savedTemplateBackground(for: screen)
        case .savedTemplate:
            return savedTemplateBackground(for: screenContaining(captureRect))
        }
    }

    private static func savedTemplateBackground(for screen: NSScreen?) -> ScreenshotBackgroundOptions {
        if let saved = TemplateStore.defaultTemplate?.background, saved.isEnabled {
            return saved.resolvingDesktopWallpaper(for: screen)
        }
        var seeded = ScreenshotBackgroundOptions.editorDefault
        seeded.isEnabled = true
        return seeded
    }

    /// Screen whose frame contains the capture rect's center (capture rects are in
    /// AppKit global coordinates), falling back to the main display. Drives which
    /// desktop wallpaper a window shot composes against on a multi-display setup.
    private static func screenContaining(_ rect: CGRect?) -> NSScreen? {
        guard let rect, !rect.isEmpty else { return NSScreen.main }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    /// Widens the window when the toolbar's fitting width outgrows it (the
    /// font row that the text tool swaps in is wider than the width row, and a
    /// clipped toolbar paints as a broken black overflow strip). Same growth
    /// rules as the sidebar path: grow rightward, nudge left at the screen edge.
    private func ensureWindowFitsToolbar() {
        guard let window else { return }
        toolbar.layoutSubtreeIfNeeded()
        let needed = Self.minimumWindowWidth(
            toolbarWidth: toolbar.fittingWidth,
            sidebarVisible: sidebarVisible
        )
        guard window.frame.width < needed else { return }
        var frame = window.frame
        let screenMaxX = (window.screen ?? NSScreen.main)?.visibleFrame.maxX ?? frame.maxX
        let delta = needed - frame.width
        frame.size.width = needed
        if frame.maxX > screenMaxX { frame.origin.x = max(0, frame.origin.x - delta) }
        window.setFrame(frame, display: true, animate: false)
    }

    private func bringEditorToFront() {
        guard let window else { return }
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.level = .normal
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    // MARK: - Actions

    /// ES4 primary Save (coral): writes straight to the configured Save Location
    /// with the current export format, no panel, the fast path. "Save as…" (ES6)
    /// covers picking a name/format/folder.
    private func quickSave() {
        canvas.commitTextField()
        let flat = exportImage()
        let dir = Settings.autoSaveLocation
        let name = ImageExporter.timestampedName
        let ext = Settings.screenshotFormat
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("\(name).\(ext)")
        guard ImageExporter.save(image: flat, to: url, collisionPolicy: .uniquify) != nil else {
            ToastWindow.show(message: "Could not save screenshot")
            return
        }
        // Non-destructive edits also land in Capture History as their own entry.
        historyManager?.add(image: flat, rect: historyItem?.captureRect?.cgRect)
        markCurrentDocumentClean()
        ToastWindow.show(message: Self.savedScreenshotMessage(for: url), duration: 3.0)
    }

    /// Smart Redact entry point: commit any pending text, flip the toolbar button
    /// into a busy spinner, run the local detection pass off the main thread, then
    /// stage the preview (or toast "nothing found"). The detection itself lives on
    /// the canvas (OCR + classifier + coordinate mapping); this only drives the UI
    /// around it and never blocks the main thread waiting on Vision.
    private func runSmartRedactFlow() {
        // A second tap while a preview is already staged just confirms it, so the
        // button doubles as Apply once findings are showing.
        if canvas.hasSmartRedactPreview {
            canvas.applySmartRedact()
            return
        }
        canvas.commitTextField()
        toolbar.setSmartRedactBusy(true)
        Task { [weak self] in
            guard let self else { return }
            // The canvas banner is the feedback now (count + Redact all/Cancel
            // buttons, or the self-dismissing "nothing found" notice); a toast
            // on top of it would just say the same thing twice.
            _ = await self.canvas.runSmartRedact()
            self.toolbar.setSmartRedactBusy(false)
        }
    }

    /// ES6: "Save as…", NSSavePanel with PNG/JPEG/WebP choice. Also the toolbar's
    /// Save button target, preserving the original editor Save behavior.
    private func saveAs() {
        canvas.commitTextField()
        let flat = exportImage()
        ImageExporter.saveWithPanel(image: flat, suggestedName: ImageExporter.timestampedName, presentingWindow: window) { [weak self] result in
            guard let self else { return }
            self.bringEditorToFront()
            guard case .saved(let url) = result else { return }
            self.historyManager?.add(image: flat, rect: self.historyItem?.captureRect?.cgRect)
            self.markCurrentDocumentClean()
            ToastWindow.show(message: Self.savedScreenshotMessage(for: url), duration: 3.0)
        }
    }

    /// ES4: pin the flattened result to the desktop as a floating window.
    private func pin() {
        canvas.commitTextField()
        PinnedWindow.pin(image: exportImage())
    }

    private func copyToClipboard() {
        canvas.commitTextField()
        let flat = exportImage()
        ImageExporter.copyToClipboard(image: flat)
        SoundManager.play(.copy)
        ToastWindow.show(message: "Copied to clipboard")
    }

    /// The primary completion action has concrete delivery semantics. It copies
    /// exactly what Preview shows, records that state as handled, then closes
    /// without presenting a contradictory unsaved-changes alert.
    private func copyAndClose() {
        copyToClipboard()
        markCurrentDocumentClean()
        window?.performClose(nil)
    }

    private func markCurrentDocumentClean() {
        cleanUndoDepth = canvas.undoDepth
        hasUserBackgroundEdit = false
        hasUserCropEdit = false
    }

    /// ES4: Share from the bottom-bar cluster. Prefers a real file URL (AirDrop/
    /// Mail/Photos keep filename + metadata), falling back to the raw image.
    private func shareFromBottomBar() {
        canvas.commitTextField()
        let flat = exportImage()
        let items: [Any]
        if let export = ImageExporter.encodedForExport(flat),
           let url = DragFileVault.makeFile(data: export.data, ext: export.ext) {
            DragFileVault.scheduleCleanup(url)
            items = [url]
        } else {
            items = [flat]
        }
        NSApp.activate(ignoringOtherApps: true)
        bottomBar?.presentSharePicker(items: items)
    }

    private func exportImage() -> NSImage {
        canvas.commitTextField()
        return canvas.flatten()
    }

    private func scheduleDragExportPreparation() {
        dragExportPreparationTask?.cancel()
        guard bottomBar != nil else { return }
        dragExportPreparationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            _ = await self.bottomBar?.prepareConcreteDragFile()
        }
    }

    /// ES5: the stage checkerboard shows only when no background is enabled.
    private func updateCheckerboard() {
        // User rule: a raw shot sits on the plain dark stage, the checkerboard
        // read as "transparent/broken", so it never shows.
        (editorScrollView?.contentView as? CenteringClipView)?.drawsCheckerboard = false
    }

    /// ES7: fit the whole composition in the viewport at open, then seed the
    /// bottom-bar zoom popup with the resulting level. Deferred so the scroll view
    /// has laid out its real viewport before fitToWindow measures it.
    private func zoomToFitOnAppear() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fitMode else { return }
            let level = self.canvas.fitToWindow()
            self.bottomBar?.setZoomLabel(for: level)
            // The window can still be reshaped after this first pass (sidebar
            // opening, large-shot window sizing), which leaves the early fit
            // stale and a big window shot opening at the wrong zoom. One more
            // pass against the settled viewport covers that case.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.fitMode else { return }
                let settled = self.canvas.fitToWindow()
                self.bottomBar?.setZoomLabel(for: settled)
            }
        }
    }


    private func toggleBackgroundSidebar() {
        guard let sidebar = backgroundSidebar, let window else { return }
        sidebarAnimationGeneration &+= 1
        let animationGeneration = sidebarAnimationGeneration
        let showing = !sidebarVisible
        sidebarVisible = showing

        // User rule: opening the panel never auto-applies a background, the
        // shot stays raw until the user explicitly picks one in the sidebar.
        sidebar.options = backgroundOptions
        toolbar.setBackgroundPanelOpen(showing)   // ES3: icon button selected state

        // Fase 1 (rara, janela estreita): alarga a janela AINDA FECHADA e
        // re-assenta todo o chrome no tamanho novo num passo seco. Misturar o
        // resize da janela com a moção das views era a raiz do "componentes se
        // movem diferente do fundo": o autoresize do setFrame assentava tudo no
        // estado final e os animators não tinham mais o que animar (jump cut).
        if showing {
            let needed = Self.minimumWindowWidth(
                toolbarWidth: toolbar.fittingWidth,
                sidebarVisible: true
            )
            if window.frame.width < needed {
                var frame = window.frame
                let screenMaxX = (window.screen ?? NSScreen.main)?.visibleFrame.maxX ?? frame.maxX
                let delta = needed - frame.width
                frame.size.width = needed
                // Grow rightward, then nudge left only if it would run off-screen.
                if frame.maxX > screenMaxX { frame.origin.x = max(0, frame.origin.x - delta) }
                window.setFrame(frame, display: true, animate: false)
                layoutStage(sidebarVisible: false, animated: false)
            }
        }

        // Fase 2: a moção em si, SÓ views (janela parada): a coluna desliza do
        // off-screen (x:-width) pra x:0 enquanto o canvas reflui ao lado; fechar
        // desliza de volta. Fechar derruba a parede esquerda do chrome já no
        // início (a coluna sai com o próprio material por cima do palco); abrir
        // pousa a parede no fim, debaixo da coluna assentada.
        sidebar.isHidden = false
        if showing {
            sidebar.frame = Self.sidebarRect(winW: window.frame.width, winH: window.frame.height, visible: false)
            // Commita o estado seed (recém des-hidden, fora da tela) no render
            // server ANTES do grupo animado: sem isso o animator não tem estado
            // de partida apresentado e a coluna teleporta pra x:0 (o slide nunca
            // rodou de fato).
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduced ? 0 : Motion.Duration.standard
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            layoutStage(sidebarVisible: showing, animated: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sidebarAnimationGeneration == animationGeneration else { return }
                if !showing { self.backgroundSidebar?.isHidden = true }
                self.canvas.setNeedsDisplay(self.canvas.bounds)
            }
        })
    }

    // MARK: - Stage layout (dock + canvas + sidebar + bottom bar in lockstep)

    /// Re-lays out the floating dock, the canvas scroll view, the integrated
    /// sidebar column and the bottom bar from the current window size. The dock
    /// always clears the traffic lights (R6) and the open sidebar; the canvas
    /// takes whatever horizontal space is left so the art is never crammed.
    private func layoutStage(sidebarVisible: Bool, animated: Bool, targetSize: NSSize? = nil) {
        guard let container = window?.contentView, let scrollView = editorScrollView else { return }
        // Durante um resize animado da janela os bounds do contentView ainda
        // estão no valor velho; o chamador passa o tamanho ALVO pros frames
        // finais saírem certos e tudo pousar junto.
        let winW = targetSize?.width ?? container.bounds.width
        let winH = targetSize?.height ?? container.bounds.height

        // The stage runs the full height under the titlebar and stops only where
        // the inspector begins. Nothing is subtracted for the tool or action
        // pills: they float on top, and the artwork is free to pass beneath them.
        // The stage stops where the floating panel's margin begins, not where the
        // panel does: otherwise the artwork slides under the panel's shadow.
        let panelSpan = Self.sidebarWidth + KritMetrics.Panel.margin * 2
        let stageWidth = max(1, winW - (sidebarVisible ? panelSpan : 0))
        // Full height, titlebar included. Reserving a strip for the titlebar left
        // a dead band across the top of the window that the reference does not
        // have: there the surfaces run to the top edge and the traffic lights
        // simply float over the stage.
        //
        // The panel is on the LEADING edge, so the stage starts after it.
        let stageX = sidebarVisible ? panelSpan : 0
        let canvasRect = NSRect(x: stageX, y: 0, width: stageWidth, height: max(1, winH))
        let sidebarRect = Self.sidebarRect(winW: winW, winH: winH, visible: sidebarVisible)
        let headerRect = Self.toolbarPillFrame(stageX: stageX, stageWidth: stageWidth, winH: winH, toolbar: toolbar)
        let barRect = Self.actionPillFrame(stageX: stageX, stageWidth: stageWidth, winH: winH, bar: bottomBar)

        if animated {
            scrollView.animator().frame = canvasRect
            backgroundSidebar?.animator().frame = sidebarRect
            toolbar.animator().frame = headerRect
            bottomBar?.animator().frame = barRect
        } else {
            scrollView.frame = canvasRect
            backgroundSidebar?.frame = sidebarRect
            toolbar.frame = headerRect
            bottomBar?.frame = barRect
        }
    }

    /// Inspector column frame: docked to the *trailing* edge and full height
    /// under the titlebar when visible; parked just past the right edge when
    /// hidden, so opening and closing reads as a slide in from the side the
    /// controls actually live on.
    private static func sidebarRect(winW: CGFloat, winH: CGFloat, visible: Bool) -> NSRect {
        // The panel floats rather than docking: it keeps `Panel.margin` from the
        // window on all sides, which is what lets its 20.5pt corners read as
        // corners instead of being clipped by the window edge.
        let margin = KritMetrics.Panel.margin
        return NSRect(
            x: visible ? margin : -sidebarWidth,
            y: margin,
            width: sidebarWidth,
            height: max(1, winH - margin * 2 - trafficLightBand)
        )
    }

    /// The tool pill: intrinsically sized, centred over the stage, at the TOP.
    /// Centring is on the *stage*, not the window, so opening the inspector
    /// shifts the pill along with the artwork it belongs to.
    private static func toolbarPillFrame(stageX: CGFloat, stageWidth: CGFloat, winH: CGFloat, toolbar: AnnotationToolbar) -> NSRect {
        let width = min(toolbar.fittingWidth, stageWidth - stagePadding * 2)
        return NSRect(
            x: (stageX + (stageWidth - width) / 2).rounded(),
            y: max(1, winH - stagePadding - toolbarHeight),
            width: max(1, width),
            height: toolbarHeight
        )
    }

    /// The view pill: bottom-trailing corner of the stage. It holds how you LOOK
    /// at the shot (zoom, annotate/preview, drag it out) as opposed to what you
    /// do to it, which is the tool pill's job at the top.
    private static func actionPillFrame(stageX: CGFloat, stageWidth: CGFloat, winH: CGFloat, bar: EditorBottomBar?) -> NSRect {
        let width = min(bar?.fittingWidth ?? 320, stageWidth - stagePadding * 2)
        return NSRect(
            // Centred on the stage, like the tool pill above it. Pinned to the
            // trailing edge it read as an afterthought hugging the corner while
            // its twin sat centred at the top.
            x: (stageX + (stageWidth - width) / 2).rounded(),
            y: stagePadding,
            width: max(1, width),
            height: bottomBarHeight
        )
    }

    /// Window width that keeps the full header row visible (its fitting width,
    /// which already includes the leading inset past the traffic lights and the
    /// trailing breathing room) and a usable canvas beside the sidebar when open.
    /// Uses the toolbar's measured content width, never a stale constant.
    private static func minimumWindowWidth(toolbarWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        // The tool pill must fit on the STAGE, which is the window minus the
        // inspector, minus a margin on each side. Sizing to the toolbar alone
        // (as the old full-width band did) leaves the pill short by exactly the
        // inspector's width once it opens, and the first thing that gives is the
        // size slider, which collapses to its thumb.
        let panelSpan = sidebarWidth + KritMetrics.Panel.margin * 2
        let stageNeed = toolbarWidth + stagePadding * 2 + (sidebarVisible ? panelSpan : 0)
        guard sidebarVisible else { return stageNeed }
        // ...and the canvas must stay usable beside the open inspector.
        let canvasNeed = panelSpan + minimumCanvasWidth + stageInset
        return max(stageNeed, canvasNeed)
    }

    private static let minimumCanvasWidth: CGFloat = 360

    /// Live-restyles any selected text annotations when a font control changes.
    private func applyToSelectedTexts(_ mutate: (TextAnnotation) -> Void) {
        let texts = canvas.selectedObjects.compactMap { $0 as? TextAnnotation }
        guard !texts.isEmpty else { return }
        canvas.pushUndo()
        texts.forEach(mutate)
        canvas.setNeedsDisplay(canvas.bounds)
    }

    private func applyToSelectedBlurs(_ mutate: (BlurAnnotation) -> Void) {
        let blurs = canvas.selectedObjects.compactMap { $0 as? BlurAnnotation }
        guard !blurs.isEmpty else { return }
        canvas.pushUndo()
        blurs.forEach(mutate)
        canvas.setNeedsDisplay(canvas.bounds)
    }

    private func applyToSelectedPixelates(_ mutate: (PixelateAnnotation) -> Void) {
        let pixelates = canvas.selectedObjects.compactMap { $0 as? PixelateAnnotation }
        guard !pixelates.isEmpty else { return }
        canvas.pushUndo()
        pixelates.forEach(mutate)
        canvas.setNeedsDisplay(canvas.bounds)
    }

    private func applyBackgroundOptions(_ options: ScreenshotBackgroundOptions) {
        canvas.commitTextField()

        // Annotations are positioned in canvas space; when the background slot
        // moves (padding/inset/aspect/alignment), shift them by the slot-origin
        // delta so they stay registered with the screenshot they annotate.
        let oldOrigin = imageSlotOrigin(for: backgroundOptions)
        let newOrigin = imageSlotOrigin(for: options)
        let backgroundToggled = options.isEnabled != backgroundOptions.isEnabled
        backgroundOptions = options

        canvas.backgroundOptions = options
        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: previewSize(for: options))
        canvas.offsetContent(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
        canvas.setNeedsDisplay(canvas.bounds)
        updateCheckerboard()

        if backgroundToggled {
            // Ligar/desligar o fundo muda a NATUREZA do documento (canvas ganha
            // moldura + padding): a janela adota o tamanho padrão que teria se
            // tivesse ABERTO já com esse canvas, senão o wallpaper entra num
            // palco dimensionado pro shot cru e o layout fica torto (relato do
            // dono). Ajustes subsequentes (padding/ratio/alinhamento) mantêm a
            // regra fit-to-stage: janela parada, conteúdo re-escala.
            resizeWindowToStandard()
        } else {
            // Fit-to-stage: padding/ratio mudam o canvas; a janela NÃO cresce,
            // o canvas re-escala (fit) pra caber no palco visível.
            refitCanvasToStage()
        }
    }

    /// Re-dimensiona a janela pro tamanho padrão de abertura do canvas atual
    /// (mesma matemática do init), somando a sidebar visível, preservando o
    /// centro e clampando à tela. Chamado quando o background liga/desliga.
    private func resizeWindowToStandard() {
        guard let window else { return }
        var size = Self.standardWindowSize(forCanvas: canvas.frame.size, on: window.screen)
        if backgroundSidebar?.isHidden == false { size.width += Self.sidebarWidth }
        let vf = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        size.width = min(size.width, vf.width)
        size.height = min(size.height, vf.height)

        var frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        frame.origin.x = max(vf.minX, min(frame.origin.x, vf.maxX - size.width))
        frame.origin.y = max(vf.minY, min(frame.origin.y, vf.maxY - size.height))
        window.setFrame(frame, display: true, animate: true)
        refitCanvasToStage()
    }

    /// Floor for the editor window (toolbar fits, canvas has working room),
    /// clamped to the screen envelope. Shared by minSize and standardWindowSize.
    private static func minimumWindowSize(on screen: NSScreen?) -> NSSize {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let minimumEditorHeight = Self.minimumCanvasHeight + Self.toolbarHeight + Self.stageInset + Self.bottomBarHeight
        let maxWindowWidth = min(screenFrame.width - Self.initialScreenEdgeInset * 2,
                                 screenFrame.width * Self.initialScreenWidthFraction)
        let maxWindowHeight = min(screenFrame.height - Self.initialScreenEdgeInset * 2,
                                  screenFrame.height * Self.initialScreenHeightFraction)
        return NSSize(width: min(Self.minimumEditorWidth, maxWindowWidth),
                      height: min(minimumEditorHeight, maxWindowHeight))
    }

    /// Standard window size for a composed-canvas size: envelope = fraction of
    /// the screen, chrome added, content scaled to fit (never upscaled). The
    /// editor opens with this and re-adopts it when the background toggles.
    private static func standardWindowSize(forCanvas canvasSize: NSSize, on screen: NSScreen?) -> NSSize {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let toolbarHeight = Self.toolbarHeight
        let stageInset = Self.stageInset
        let minimumEditorHeight = Self.minimumCanvasHeight + toolbarHeight + stageInset + Self.bottomBarHeight
        let chromeW = stageInset * 2
        let chromeH = toolbarHeight + stageInset + Self.bottomBarHeight
        let maxWindowWidth = min(screenFrame.width - Self.initialScreenEdgeInset * 2,
                                 screenFrame.width * Self.initialScreenWidthFraction)
        let maxWindowHeight = min(screenFrame.height - Self.initialScreenEdgeInset * 2,
                                  screenFrame.height * Self.initialScreenHeightFraction)
        let effectiveMinimumWidth = min(Self.minimumEditorWidth, maxWindowWidth)
        let effectiveMinimumHeight = min(minimumEditorHeight, maxWindowHeight)
        // Canvas room inside the envelope, then the largest scale that fits both
        // axes (never upscaling past 100%). The window follows that scaled size.
        let availW = max(1, maxWindowWidth - chromeW)
        let availH = max(1, maxWindowHeight - chromeH)
        let fitScale = min(1, min(availW / max(canvasSize.width, 1), availH / max(canvasSize.height, 1)))
        let shownCanvas = NSSize(width: canvasSize.width * fitScale, height: canvasSize.height * fitScale)
        return NSSize(width: max(shownCanvas.width + chromeW, effectiveMinimumWidth),
                      height: max(shownCanvas.height + chromeH, effectiveMinimumHeight))
    }

    /// Fit-to-stage: re-encaixa o canvas inteiro dentro do palco visível atual
    /// SEM mexer no tamanho da janela. Quando padding/inset/background/aspect/crop
    /// crescem o canvas, é a escala da imagem que reduz pra caber (fit), não a
    /// janela que cresce. `fitToWindow()` (no canvas) só REDUZ: imagem menor que o
    /// palco fica em 100%, nunca há upscale automático. Diferido um runloop porque
    /// o caller acabou de trocar `canvas.frame`; o scroll view precisa relayoutar
    /// pro `fitToWindow` medir o viewport real. Quando fora do modo fit (zoom
    /// manual escolhido no popup), não toca na escala.
    private func refitCanvasToStage() {
        guard fitMode else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let level = self.canvas.fitToWindow()
            self.bottomBar?.setZoomLabel(for: level)
        }
    }

    /// Canvas point-size for `options`: the composer's output size (honors inset,
    /// padding and aspect) so the flattened export matches the on-screen canvas
    /// exactly and the art is never stretched.
    private func previewSize(for options: ScreenshotBackgroundOptions) -> NSSize {
        guard options.isEnabled else { return image.size }
        return ScreenshotBackgroundComposer.outputPointSize(for: image.size, options: options)
    }

    /// Top-left origin (flipped canvas coords) of the screenshot slot inside the
    /// composed canvas, mirroring the composer's alignment math.
    private func imageSlotOrigin(for options: ScreenshotBackgroundOptions) -> CGPoint {
        guard options.isEnabled else { return .zero }
        let canvasSize = ScreenshotBackgroundComposer.outputPointSize(for: image.size, options: options)
        return ScreenshotBackgroundComposer.imageSlotOrigin(
            imageSize: image.size, canvasSize: canvasSize, options: options
        )
    }

    private func applyCrop() {
        // The canvas crops the BASE screenshot and already translated/filtered
        // the annotations; here we swap the image in, keep the current
        // background options so the composition re-renders at the new size,
        // and let the window follow the canvas (same R1 path as padding/ratio).
        guard let cropped = canvas.applyCrop() else { return }
        documentRevision &+= 1
        hasUserCropEdit = true
        image = cropped
        canvas.backgroundImage = cropped
        canvas.frame = NSRect(origin: .zero, size: previewSize(for: backgroundOptions))
        canvas.setNeedsDisplay(canvas.bounds)
        updateCheckerboard()
        toolbar.setCropApplyVisible(false)
        refitCanvasToStage()
    }

    /// Item 1: coalesce background-option undo snapshots. A slider drag fires many
    /// onChange events; without this each micro-step would become its own undo. We
    /// snapshot the pre-change state once per burst (gap >= 0.6s), so one ⌘Z undoes
    /// the whole adjustment instead of crawling back one pixel at a time.
    private var lastBackgroundUndoTime: TimeInterval = 0
    private func pushBackgroundUndoIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastBackgroundUndoTime > 0.6 {
            canvas.pushUndo()
        }
        lastBackgroundUndoTime = now
    }

    /// Item 1: an undo/redo restored a different document (crop or background
    /// change) inside the canvas. Pull the canvas's restored image/options back
    /// into the controller's own state, sync the toolbar/sidebar and refit the
    /// window so the editor matches the rolled-back document exactly.
    private func syncDocumentFromCanvas() {
        if let restored = canvas.backgroundImage { image = restored }
        backgroundOptions = canvas.backgroundOptions
        toolbar.setBackgroundOptionsExternally(backgroundOptions)
        backgroundSidebar?.options = backgroundOptions
        updateCheckerboard()
        refitCanvasToStage()
    }

    private static func savedScreenshotMessage(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let destination = folderName.isEmpty ? folder.lastPathComponent : folderName
        return "Saved to \(destination): \(url.lastPathComponent)"
    }
}

extension AnnotationWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        // Resize vindo do usuário (não programático) vira preferência dele: a
        // janela é sempre dele, o conteúdo é que se acomoda dentro.
        if !isProgrammaticResize { userManuallyResized = true }
        // Re-derive dock/canvas/sidebar from the new size so the dock keeps
        // clearing the traffic lights and the canvas reflows beside the sidebar.
        layoutStage(sidebarVisible: sidebarVisible, animated: false)
        // No modo fit, recalcula a escala ao vivo pra manter o canvas inteiro
        // dentro do novo palco; em zoom manual, respeita a escala escolhida.
        if fitMode {
            let level = canvas.fitToWindow()
            bottomBar?.setZoomLabel(for: level)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A user background/template change is a real exportable edit even with no
        // annotations, so a styled-then-undrawn editor still warns. The auto-applied
        // default template does NOT count (hasUserBackgroundEdit stays false).
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "This screenshot has changes that have not been saved or copied. Close anyway?"
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        AnnotationWindowController.openControllers.removeAll { $0 === self }
        if AnnotationWindowController.openControllers.isEmpty {
            NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
        }
    }
}


// MARK: - Centering Clip View

/// Centers the document view when the scroll view viewport is larger than the
/// content, and (ES5) paints a subtle checkerboard in the stage area around the
/// shot when no background is enabled, mirroring the reference editor.
@MainActor
final class CenteringClipView: NSClipView {
    /// ES5: drives the checkerboard behind/around the canvas. Set by the canvas
    /// whenever its background-enabled state changes.
    var drawsCheckerboard = false {
        didSet { if drawsCheckerboard != oldValue { needsDisplay = true } }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }
        let docFrame = documentView.frame
        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsCheckerboard, let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.drawCheckerboard(in: ctx, rect: bounds)
    }

    /// A flat two-tone checkerboard, the universal "transparent / no background"
    /// motif. Kept low-contrast so it reads as a backdrop, not foreground noise.
    static func drawCheckerboard(in ctx: CGContext, rect: CGRect) {
        let tile: CGFloat = 12
        let light = NSColor(calibratedWhite: 0.26, alpha: 1).cgColor
        let dark = NSColor(calibratedWhite: 0.21, alpha: 1).cgColor
        ctx.saveGState()
        ctx.setFillColor(light)
        ctx.fill(rect)
        ctx.setFillColor(dark)
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : tile)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
                x += tile * 2
            }
            y += tile
            row += 1
        }
        ctx.restoreGState()
    }
}

@MainActor
private final class PremiumEditorStageView: NSView {

    /// Blurred desktop behind the stage. What makes the editor sit *on* the
    /// desktop rather than hide it, and what the opacity preference dials.
    private let vibrancy = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        vibrancy.material = .underWindowBackground
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        vibrancy.frame = bounds
        vibrancy.autoresizingMask = [.width, .height]
        addSubview(vibrancy, positioned: .below, relativeTo: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(opacityChanged),
            name: Settings.editorChromeOpacityChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func opacityChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // The stage tint is laid OVER the vibrancy at the user's opacity, so at
        // 1 it reads as the flat neutral void it always was, and as it drops the
        // wallpaper comes through instead of a grey slab.
        KritColors.editorStageTop
            .withAlphaComponent(CGFloat(Settings.editorChromeOpacity))
            .setFill()
        bounds.fill()
    }
}

// MARK: - Editor window (window-level undo/redo shortcut)

/// Item 1: the editor window intercepts ⌘Z / ⇧⌘Z in performKeyEquivalent, which
/// the window runs while it is key BEFORE the first responder gets the event. So
/// undo/redo fire even when a toolbar button or the sidebar slider holds focus,
/// not just when the canvas is first responder.
@MainActor
final class EditorKeyWindow: NSWindow {
    var onUndoKey: (() -> Void)?
    var onRedoKey: (() -> Void)?
    var onSaveKey: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // keyCode 6 is "z"; only act on a bare ⌘ (plus optional ⇧), so other
        // chords (⌥⌘Z, ⌃⌘Z) fall through to the normal responder chain.
        if event.keyCode == 6, flags.contains(.command),
           flags.isSubset(of: [.command, .shift]) {
            // A text field being edited owns ⌘Z for its own field editor undo;
            // don't steal it there.
            if !(firstResponder is NSText) {
                if flags.contains(.shift) { onRedoKey?() } else { onUndoKey?() }
                return true
            }
        }
        // keyCode 1 is "s": bare ⌘S quick-saves, the native shortcut that replaces
        // the footer Save button (removed to match CleanShot's icon-only footer).
        if event.keyCode == 1, flags == .command, !(firstResponder is NSText) {
            onSaveKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Toolbar

@MainActor
final class AnnotationToolbar: NSView {

    // The toolbar is a floating glass pill over the stage, not a band across the
    // window. Its geometry is the reference app's: 5pt of padding around a row
    // of 32pt controls, capsule corners, 3pt between neighbours.
    //
    /// Padding between the pill's edge and the controls inside it.
    static let pillPadding: CGFloat = 5
    /// Edge length of a control inside the pill. Circular, so this is both.
    static let controlSize: CGFloat = 32
    /// Gap between adjacent controls.
    static let controlGap: CGFloat = 3
    /// Total pill height: padding, control, padding.
    static let totalHeight: CGFloat = controlSize + pillPadding * 2
    /// Conservative floor before the live fitting width exists.
    static let requiredWidth: CGFloat = 560

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onFontFamilyChanged: ((AnnotationFontFamily) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onBackplateChanged: ((TextBackplate) -> Void)?
    /// Fired when the secure-blur toggle flips (blur tool only). On = new blurs
    /// are an irreversible mosaic instead of a recoverable gaussian.
    var onSecureBlurChanged: ((Bool) -> Void)?
    /// Fired when the redaction Strength slider moves (blur/pixelate tools). The
    /// value is the blur radius or the pixelate block size for the active tool.
    var onRedactStrengthChanged: ((Double) -> Void)?
    /// Fired when a style preset is chosen in the text style popover (regular,
    /// bold, italic, bold+italic, backplate, outlined).
    var onStylePresetChanged: ((TextStylePreset) -> Void)?
    /// The preset to ring as active when the style popover opens. Read at present
    /// time so the popover reflects the current text (or the active default).
    var currentStylePreset: TextStylePreset = .regular
    /// Top toolbar carries "Save as…" and the primary "Copy & Close". Share and
    /// Pin live in the action pill, one place per action.
    var onSaveAs: (() -> Void)?
    var onDone: (() -> Void)?
    var onApplyCrop: (() -> Void)?
    /// Fired by the contextual Cancel while a crop region is staged.
    var onCancelCrop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onBackgroundOptionsChanged: ((ScreenshotBackgroundOptions) -> Void)?
    var onBackgroundPanelToggle: (() -> Void)?
    /// Fired when the Smart Redact button is tapped (auto-detect sensitive
    /// content and stage a redaction preview).
    var onSmartRedact: (() -> Void)?

    /// Direct tools stay one click away. Related shape, drawing and privacy tools
    /// live in three native menus so the image remains the visual priority.
    private var toolButtons: [AnnotationTool: FlatToolButton] = [:]
    private var toolFamilyButtons: [ToolFamilyButton] = []
    private var selectedTool: AnnotationTool = .arrow
    private var colorWell: ColorWellButton?
    private var colorPopover: NSPopover?
    /// The current annotation color, mirrored on the header swatch and used as
    /// the picker's initial color each time the popover opens.
    private var currentColor: NSColor = KritColors.accent
    private var saveAsButton: NSButton?
    private var doneButton: NSButton?
    private var cropCancelButton: NSButton?
    private var cropApplyButton: NSButton?
    private var backgroundButton: NSButton?
    private var smartRedactButton: ChromeToggleButton?
    private var smartRedactSpinner: NSProgressIndicator?
    private var widthLabel: NSTextField?
    private var widthSlider: NSSlider?
    private var fontFamilyPopup: NSPopUpButton?
    private var fontSizeField: NSTextField?
    private var fontSizeStepper: NSStepper?
    private var backplateButton: NSButton?
    private var styleButton: NSButton?
    private var stylePopover: NSPopover?
    private var currentBackplate: TextBackplate = .none
    private var backgroundOptions = ScreenshotBackgroundOptions.editorDefault
    /// Horizontal flow for canvas commands, tools, contextual properties and
    /// delivery actions.
    private var rootStack: NSStackView?
    /// The glass capsule the row sits in. Held so the tint can follow the shot.
    private var pillGlass: NSView?
    /// Rule between the tool properties and the delivery actions.
    private var actionsDivider: NSView?
    private var propertiesStack: NSStackView?
    private var propertiesDivider: NSView?
    private var contextWidthRow: NSView?
    private var contextFontRow: NSView?
    private var secureBlurButton: NSButton?
    private var strengthLabel: NSTextField?
    private var strengthSlider: NSSlider?
    // Toolbar-held redaction strength per kind, so switching tools restores the
    // last value the user set (mirrors how the secure toggle keeps its own state).
    private var blurRadius: Double = 12
    private var pixelateScale: Double = 10
    private var toolStripView: NSView?
    private var headerDivider: NSView?
    /// The leading canvas group (crop · background · redact). Held so buildUI can
    /// set the post-group spacing against a stable view instead of guessing.
    private var canvasGroup: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // A capsule of glass floating over the stage, holding one row: canvas
        // commands, the tools, then the active tool's properties. Delivery
        // actions are NOT here; they live in their own pill so that reaching for
        // "copy and close" can never be a slip of the hand away from picking a
        // brush.
        wantsLayer = true

        let main = NSStackView()
        main.orientation = .horizontal
        main.alignment = .centerY
        main.distribution = .fill
        main.spacing = Self.controlGap
        main.translatesAutoresizingMaskIntoConstraints = false

        // The glass owns the row; the pill sizes itself to whatever the row
        // needs, which is what lets the controller centre it on the stage.
        let glass = KritGlassBacking(style: .bar, cornerRadius: Self.totalHeight / 2)
        glass.setContent(main)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            main.heightAnchor.constraint(equalToConstant: Self.controlSize),
        ])
        // ChromeFactory pins content to its own edges, so the padding has to come
        // from the row's own insets rather than from the constraints above.
        main.edgeInsets = NSEdgeInsets(top: Self.pillPadding, left: Self.pillPadding,
                                       bottom: Self.pillPadding, right: Self.pillPadding)
        pillGlass = glass
        rootStack = main

        // Canvas group right after the traffic lights: crop, backgrounds toggle,
        // smart redact, bordered chrome buttons like CleanShot's leading group.
        appendCanvasGroup(to: main)
        if let group = canvasGroup { main.setCustomSpacing(10, after: group) }
        let leadingDivider = makeHeaderDivider()
        main.addArrangedSubview(leadingDivider)
        headerDivider = leadingDivider

        let strip = makeIntentToolStrip()
        main.addArrangedSubview(strip)
        toolStripView = strip

        let contextDivider = makeHeaderDivider()
        main.addArrangedSubview(contextDivider)
        propertiesDivider = contextDivider

        let properties = makePropertiesControls()
        main.addArrangedSubview(properties)
        propertiesStack = properties

        // No flexible gap: a pill is sized by its contents, not stretched to the
        // window. What used to be a shock absorber is now the stage showing
        // through on both sides.
        let actionDivider = makeHeaderDivider()
        main.addArrangedSubview(actionDivider)
        actionsDivider = actionDivider

        // Delivery actions close the row: Save as… then the emphasized Copy &
        // Close. While a crop region is staged the pair swaps for Cancel/Apply.
        let saveBtn = makeActionButton(title: "Save as\u{2026}", action: #selector(saveAsTapped))
        main.addArrangedSubview(saveBtn)
        saveAsButton = saveBtn
        let doneBtn = makeActionButton(title: "Copy & Close", action: #selector(doneTapped), isPrimary: true)
        main.addArrangedSubview(doneBtn)
        doneButton = doneBtn

        let cancelBtn = makeActionButton(title: "Cancel", action: #selector(cancelCropTapped))
        cancelBtn.isHidden = true
        main.addArrangedSubview(cancelBtn)
        cropCancelButton = cancelBtn
        let cropBtn = makeActionButton(title: "Apply", action: #selector(cropTapped), isPrimary: true)
        cropBtn.isHidden = true
        main.addArrangedSubview(cropBtn)
        cropApplyButton = cropBtn

        // The pill's own rim is the edge now, so there is no dissolve to fade
        // one band into another.
        selectTool(.arrow)
    }

    /// Width the pill needs to fit its visible controls. Unlike the old band,
    /// this is the *actual* width the toolbar is given: a pill that is wider
    /// than its contents is just a gap with a border around it.
    var fittingWidth: CGFloat {
        rootStack?.layoutSubtreeIfNeeded()
        return max(Self.requiredWidth, rootStack?.fittingSize.width ?? Self.requiredWidth)
    }

    /// The vertical rule that splits the command band into groups. Half a point
    /// and short: it exists to say "these belong together, those don't", and a
    /// full-point rule at full height turns a toolbar into a table.
    private func makeHeaderDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        // On dark glass the group rule is a light hairline, not the app's dark
        // one: KritColors.divider is meant for light surfaces and vanishes here.
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: KritColors.hairlineWidth).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return divider
    }

    /// Builds the compact properties island inserted in the command band. It is
    /// removed entirely for tools with no configurable property.
    private func makePropertiesControls() -> NSStackView {
        let props = NSStackView()
        props.orientation = .horizontal
        props.alignment = .centerY
        props.spacing = 8
        props.detachesHiddenViews = true
        props.translatesAutoresizingMaskIntoConstraints = false

        // Color well: the CleanShot closed swatch + chevron, opens the embedded
        // ColorPickerPanel popover.
        let well = ColorWellButton(color: currentColor, target: self, action: #selector(colorWellTapped(_:)))
        well.toolTip = "Color"
        well.widthAnchor.constraint(equalToConstant: 34).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        props.addArrangedSubview(well)
        colorWell = well

        // Stroke and font rows live side by side; selectTool toggles visibility
        // and detachesHiddenViews collapses whichever is off.
        let (widthRow, fontRow) = makeContextRows()
        props.addArrangedSubview(widthRow)
        props.addArrangedSubview(fontRow)
        return props
    }

    /// Appends the canvas group (crop, backgrounds toggle, smart redact) as the
    /// first members of the header flow, right after the traffic lights. CleanShot
    /// draws these as bordered chrome buttons (a pad even when inactive), set apart
    /// from the flat tool strip by spacing alone, no plate, no dividers. Crop stays
    /// a registered tool (so its keyboard shortcut and the cross-strip exclusivity
    /// still reach it) but renders with the bordered chrome look here.
    private func appendCanvasGroup(to root: NSStackView) {
        let group = NSStackView()
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false

        // Crop: a bordered tool button in the canvas group (CleanShot's leading
        // crop). It is still registered in the tool strip's exclusive selection,
        // so selectTool / selectToolExternally / the C shortcut light it up and
        // clear the strip exactly like any other tool.
        let cropTool = makeBorderedToolButton(.crop)
        group.addArrangedSubview(cropTool)

        // Backgrounds toggle: a bordered button whose ON state fills coral while
        // the sidebar is open (CleanShot tints this blue). setBackgroundPanelOpen
        // drives the fill.
        let backgroundBtn = makeChromeToggleButton(symbol: "photo.on.rectangle", action: #selector(backgroundTapped(_:)))
        backgroundBtn.toolTip = "Background"
        backgroundBtn.setAccessibilityLabel("Background")
        group.addArrangedSubview(backgroundBtn)
        backgroundButton = backgroundBtn

        // Smart Redact: KRIT's own auto-detect of sensitive content. Same bordered
        // chrome look; its ON state (coral) tracks a staged preview. A spinner
        // overlays the glyph while the local detection pass runs.
        let redactBtn = makeChromeToggleButton(symbol: "eye.slash", action: #selector(smartRedactTapped(_:)))
        redactBtn.toolTip = "Smart redact (auto-detect sensitive content)"
        redactBtn.setAccessibilityLabel("Smart redact")
        group.addArrangedSubview(redactBtn)
        smartRedactButton = redactBtn

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        redactBtn.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: redactBtn.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: redactBtn.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        smartRedactSpinner = spinner

        root.addArrangedSubview(group)
        canvasGroup = group
    }

    /// Common tasks remain direct. Less frequent variants are grouped by intent,
    /// but keyboard shortcuts continue to select every tool immediately.
    private func makeIntentToolStrip() -> NSStackView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 4
        strip.translatesAutoresizingMaskIntoConstraints = false

        strip.addArrangedSubview(makeFlatToolButton(.select))
        strip.addArrangedSubview(makeFlatToolButton(.arrow))
        strip.addArrangedSubview(makeToolFamilyButton(
            symbol: "square.on.circle",
            label: "Shapes",
            tools: [.rectangle, .filledRectangle, .ellipse, .line]
        ))
        strip.addArrangedSubview(makeToolFamilyButton(
            symbol: "pencil.and.outline",
            label: "Draw",
            tools: [.freehand, .highlighter]
        ))
        strip.addArrangedSubview(makeFlatToolButton(.text))
        strip.addArrangedSubview(makeFlatToolButton(.numberedStep))
        strip.addArrangedSubview(makeToolFamilyButton(
            symbol: "eye.slash",
            label: "Privacy",
            tools: [.blur, .pixelate]
        ))
        strip.addArrangedSubview(makeFlatToolButton(.eyedropper))
        return strip
    }

    private func makeToolFamilyButton(
        symbol: String,
        label: String,
        tools: [AnnotationTool]
    ) -> ToolFamilyButton {
        let button = ToolFamilyButton(symbol: symbol, label: label, tools: tools)
        button.onSelect = { [weak self] tool in
            guard let self else { return }
            self.selectTool(tool)
            self.onToolChanged?(tool)
        }
        toolFamilyButtons.append(button)
        return button
    }

    /// A flat tool button for the strip (bare glyph, mono pad when selected).
    private func makeFlatToolButton(_ tool: AnnotationTool) -> FlatToolButton {
        let button = FlatToolButton(tool: tool, target: self, action: #selector(toolButtonTapped(_:)))
        button.isBorderedTool = false
        toolButtons[tool] = button
        return button
    }

    /// A bordered tool button for the canvas group (crop): same selection wiring as
    /// the flat strip, but it draws a chrome pad even when inactive so it reads as
    /// part of the bordered canvas group, not the flat strip.
    private func makeBorderedToolButton(_ tool: AnnotationTool) -> FlatToolButton {
        let button = FlatToolButton(tool: tool, target: self, action: #selector(toolButtonTapped(_:)))
        button.isBorderedTool = true
        toolButtons[tool] = button
        return button
    }

    /// Builds the stroke-size row and the font row for inline properties.
    /// They sit side by side as arranged views; selectTool toggles visibility
    /// and the band's detachesHiddenViews collapses the hidden one. No fixed
    /// width container anymore: the band has the whole window width to itself.
    private func makeContextRows() -> (widthRow: NSView, fontRow: NSView) {
        // Stroke size (drawing tools).
        let label = NSTextField(labelWithString: "Size")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        widthLabel = label
        let slider = KritSlider()
        slider.minValue = 1
        slider.maxValue = 20
        slider.doubleValue = Settings.annotationLineWidth
        slider.target = self
        slider.action = #selector(lineWidthChanged)
        // A slider is the one control that becomes useless rather than merely
        // cramped when squeezed: below this width the thumb has nowhere to
        // travel, so the pill gives up other slack first. Strong but breakable:
        // on a display too small to grow the window, a squeezed slider beats a
        // constraint conflict, which AppKit resolves by breaking something at
        // random.
        let minTrack = slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        minTrack.priority = .defaultHigh
        minTrack.isActive = true
        widthSlider = slider
        // Secure blur toggle: only revealed for the blur tool (selectTool hides it
        // for every other drawing tool). On = new blurs are an irreversible mosaic.
        let secureBtn = NSButton(image: NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: "Secure blur")!,
                                 target: self, action: #selector(secureBlurTapped(_:)))
        secureBtn.setButtonType(.pushOnPushOff)
        secureBtn.bezelStyle = .texturedRounded
        secureBtn.imagePosition = .imageOnly
        secureBtn.toolTip = "Secure blur (irreversible)"
        secureBtn.translatesAutoresizingMaskIntoConstraints = false
        secureBtn.widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        secureBtn.isHidden = true
        secureBlurButton = secureBtn

        // Strength (blur radius / pixelate block size): swaps in for the Size
        // slider on the blur/pixelate tools, which have no stroke width. Its range
        // and value are set per-tool in selectTool; hidden until a redact tool.
        let strengthCaption = NSTextField(labelWithString: "Strength")
        strengthCaption.font = .systemFont(ofSize: 11)
        strengthCaption.textColor = .secondaryLabelColor
        strengthCaption.isHidden = true
        strengthLabel = strengthCaption
        let strength = KritSlider()
        strength.minValue = 4
        strength.maxValue = 40
        strength.doubleValue = blurRadius
        strength.target = self
        strength.action = #selector(redactStrengthChanged)
        strength.isHidden = true
        strength.widthAnchor.constraint(equalToConstant: 104).isActive = true
        strengthSlider = strength

        let widthRow = NSStackView(views: [label, slider, strengthCaption, strength, secureBtn])
        widthRow.orientation = .horizontal
        widthRow.alignment = .centerY
        widthRow.spacing = 8
        widthRow.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 104).isActive = true

        // Font controls (text tool).
        let familyPopup = NSPopUpButton()
        familyPopup.addItems(withTitles: AnnotationFontFamily.allCases.map(\.displayName))
        familyPopup.font = .systemFont(ofSize: 11)
        familyPopup.target = self
        familyPopup.action = #selector(fontFamilyChanged(_:))
        familyPopup.translatesAutoresizingMaskIntoConstraints = false
        familyPopup.widthAnchor.constraint(equalToConstant: 80).isActive = true
        fontFamilyPopup = familyPopup

        let sizeField = NSTextField(labelWithString: "24")
        sizeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeField.alignment = .right
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 22).isActive = true
        fontSizeField = sizeField

        let sizeStepper = NSStepper()
        sizeStepper.minValue = 10; sizeStepper.maxValue = 96; sizeStepper.increment = 2; sizeStepper.doubleValue = 24
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeChanged(_:))
        fontSizeStepper = sizeStepper

        // Text backplate: an independent on/off toggle (pill behind text on/off),
        // so it uses a native push-on/push-off NSButton like the other toggles.
        let plateButton = NSButton(image: NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Text background")!,
                                   target: self, action: #selector(backplateTapped(_:)))
        plateButton.setButtonType(.pushOnPushOff)
        plateButton.bezelStyle = .texturedRounded
        plateButton.imagePosition = .imageOnly
        plateButton.toolTip = "Text backplate"
        plateButton.translatesAutoresizingMaskIntoConstraints = false
        plateButton.widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        backplateButton = plateButton

        // Style presets: opens the rich popover of WYSIWYG style swatches (regular,
        // bold, italic, bold+italic, backplate, outlined).
        let styleBtn = NSButton(image: NSImage(systemSymbolName: "textformat", accessibilityDescription: "Text styles")!,
                                target: self, action: #selector(styleButtonTapped(_:)))
        styleBtn.bezelStyle = .texturedRounded
        styleBtn.imagePosition = .imageOnly
        styleBtn.toolTip = "Text styles"
        styleBtn.translatesAutoresizingMaskIntoConstraints = false
        styleBtn.widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        styleButton = styleBtn

        let fontRow = NSStackView(views: [familyPopup, sizeField, sizeStepper, plateButton, styleBtn])
        fontRow.orientation = .horizontal
        fontRow.alignment = .centerY
        fontRow.spacing = 6
        fontRow.translatesAutoresizingMaskIntoConstraints = false
        fontRow.isHidden = true

        contextFontRow = fontRow
        contextWidthRow = widthRow
        return (widthRow, fontRow)
    }

    /// A native rounded AppKit push button for a window-level header action
    /// (Save as…, Done, Crop). Native bezel = one Apple ruler: the system sizes
    /// the height and centers the label, so the three buttons share a baseline
    /// automatically instead of hand-tuned frames. `isPrimary` makes it the
    /// default button (Return) and tints the bezel coral (QRCodeResultWindow
    /// pattern), keeping the brand accent on the one emphasized action.
    private func makeActionButton(title: String, action: Selector, isPrimary: Bool = false) -> NSButton {
        let btn = GlassPillButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.emphasis = isPrimary ? .brand : .plain
        // White on glass for the secondary action, white on coral for the
        // primary: both read against the pill, neither needs a bezel.
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .kern: -0.1,
        ])
        btn.attributedTitle = label
        btn.translatesAutoresizingMaskIntoConstraints = false
        // Width measured from the text rather than left to the intrinsic size of
        // a borderless button, which under-reports and lets the stack ellipsise
        // "Save as…" to "Sav…" while the pill still has room to spare.
        let padding: CGFloat = 15
        let width = btn.widthAnchor.constraint(equalToConstant: (label.size().width + padding * 2).rounded(.up))
        // Breakable: on a display too small to grow the editor window, a button
        // that gives up a few points beats a constraint conflict, which AppKit
        // resolves by dropping a constraint of its own choosing.
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: Self.controlSize),
            width,
        ])
        if isPrimary { btn.keyEquivalent = "\r" }
        return btn
    }

    /// A native push-on/push-off NSButton for an independent toolbar toggle
    /// (text backplate). AppKit owns the pressed (on) bezel and state; the
    /// controller flips `state` and the coral tint.
    private func makeToggleButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                           target: self, action: action)
        btn.setButtonType(.pushOnPushOff)
        btn.bezelStyle = .texturedRounded
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = NSColor.labelColor.withAlphaComponent(0.86)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return btn
    }

    /// A bordered chrome toggle for the canvas group (background panel, smart
    /// redact). It always draws a button pad (CleanShot's bordered canvas group);
    /// its ON state fills coral with a white glyph (CleanShot's blue active fill),
    /// driven by setBackgroundPanelOpen / setSmartRedactPreviewActive.
    private func makeChromeToggleButton(symbol: String, action: Selector) -> ChromeToggleButton {
        let btn = ChromeToggleButton(symbol: symbol, target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        btn.heightAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        return btn
    }

    /// ES3: reflects whether the background sidebar is open on the canvas group's
    /// toggle (coral fill + white glyph when open). Called by the controller.
    func setBackgroundPanelOpen(_ open: Bool) {
        (backgroundButton as? ChromeToggleButton)?.isActive = open
    }

    @objc private func toolButtonTapped(_ sender: FlatToolButton) {
        let tool = sender.tool
        selectTool(tool)
        onToolChanged?(tool)
    }

    private func selectTool(_ tool: AnnotationTool) {
        let isText = tool == .text
        let isRedact = tool == .blur || tool == .pixelate
        let usesStroke = [
            AnnotationTool.arrow, .rectangle, .filledRectangle, .ellipse,
            .line, .freehand, .highlighter,
        ].contains(tool)
        let usesColor = usesStroke || isText || tool == .numberedStep
        let hasProperties = usesColor || isRedact

        propertiesStack?.isHidden = !hasProperties
        propertiesDivider?.isHidden = !hasProperties
        colorWell?.isHidden = !usesColor
        contextWidthRow?.isHidden = !(usesStroke || isRedact)
        contextFontRow?.isHidden = !isText
        secureBlurButton?.isHidden = (tool != .blur)
        widthLabel?.isHidden = !usesStroke
        widthSlider?.isHidden = !usesStroke
        strengthLabel?.isHidden = !isRedact
        strengthSlider?.isHidden = !isRedact
        if isRedact {
            strengthSlider?.doubleValue = (tool == .pixelate) ? pixelateScale : blurRadius
        }
        selectedTool = tool
        for (candidate, button) in toolButtons {
            button.isSelectedTool = (candidate == tool)
        }
        for button in toolFamilyButtons {
            button.setSelectedTool(tool)
        }
    }

    /// Preview mode hides every editing control, keeping only delivery actions,
    /// so the header reads
    /// as plain chrome while the user inspects the final result.
    func setPreviewMode(_ on: Bool) {
        Motion.animate(0.15) { context in
            context.allowsImplicitAnimation = true
            canvasGroup?.animator().isHidden = on
            headerDivider?.animator().isHidden = on
            toolStripView?.animator().isHidden = on
            propertiesStack?.animator().isHidden = on
            propertiesDivider?.animator().isHidden = on
        }
        if !on { selectTool(selectedTool) }
    }

    /// Contextual action slot: while a crop region is staged, delivery actions fade
    /// out and Cancel/Apply fade in (NSStackView collapses the hidden pair).
    func setCropApplyVisible(_ visible: Bool) {
        Motion.animate(0.15) { context in
            context.allowsImplicitAnimation = true
            saveAsButton?.animator().isHidden = visible
            doneButton?.animator().isHidden = visible
            cropCancelButton?.animator().isHidden = !visible
            cropApplyButton?.animator().isHidden = !visible
        }
    }

    /// Undo/redo left the header (CleanShot keeps them on \u{2318}Z / \u{21E7}\u{2318}Z,
    /// not the toolbar). The API stays so the canvas's onUndoStateChanged caller
    /// keeps working, but there is no longer a control to enable/disable; the
    /// keyboard shortcuts (routed through EditorKeyWindow) carry undo/redo.
    func setUndoRedoEnabled(canUndo: Bool, canRedo: Bool) {}

    func selectToolExternally(_ tool: AnnotationTool) {
        selectTool(tool)
    }

    /// Item 4: reflect the per-tool default thickness on the slider when the
    /// canvas switches tools. Does NOT persist to Settings or re-fire
    /// onLineWidthChanged (the canvas already moved its own activeLineWidth).
    func setLineWidthExternally(_ width: CGFloat) {
        widthSlider?.doubleValue = Double(width)
    }

    func setBackgroundOptionsExternally(_ options: ScreenshotBackgroundOptions) {
        backgroundOptions = options
        // ES3: the icon button's tint now tracks the sidebar's open/closed state
        // (setBackgroundPanelOpen), not the enabled flag, so it doesn't fight the
        // selected-state coloring.
    }

    @objc private func colorWellTapped(_ sender: ColorWellButton) {
        // Reuse one popover; tapping again while open just closes it.
        if let popover = colorPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let panel = ColorPickerPanel(initialColor: currentColor)
        panel.onColorChanged = { [weak self] color in
            guard let self else { return }
            self.currentColor = color
            self.colorWell?.setColor(color)
            self.onColorChanged?(color)
        }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        colorPopover = popover
    }

    /// Reflects an externally chosen color on the header swatch (kept symmetric
    /// with the toolbar's other setExternally methods).
    func setColorExternally(_ color: NSColor) {
        currentColor = color
        colorWell?.setColor(color)
    }

    @objc private func lineWidthChanged(_ sender: NSSlider) {
        // The controller owns persistence: it has the canvas (and its capture
        // thickness factor) so it can store the DE-SCALED base, which the toolbar
        // can't see from here.
        onLineWidthChanged?(CGFloat(sender.doubleValue))
    }
    @objc private func redactStrengthChanged(_ sender: NSSlider) {
        // Remember the value per kind so switching blur<->pixelate restores it.
        if selectedTool == .pixelate { pixelateScale = sender.doubleValue }
        else { blurRadius = sender.doubleValue }
        onRedactStrengthChanged?(sender.doubleValue)
    }
    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        let family = AnnotationFontFamily.allCases[max(0, sender.indexOfSelectedItem)]
        onFontFamilyChanged?(family)
    }
    @objc private func fontSizeChanged(_ sender: NSStepper) {
        fontSizeField?.stringValue = "\(Int(sender.doubleValue))"
        onFontSizeChanged?(CGFloat(sender.doubleValue))
    }
    @objc private func backplateTapped(_ sender: NSButton) {
        // Native push-on/push-off: the bezel already shows on/off; map state -> plate.
        currentBackplate = sender.state == .on ? .pill : .none
        sender.contentTintColor = sender.state == .on ? KritColors.accent : nil
        onBackplateChanged?(currentBackplate)
    }
    @objc private func secureBlurTapped(_ sender: NSButton) {
        sender.contentTintColor = sender.state == .on ? KritColors.accent : nil
        onSecureBlurChanged?(sender.state == .on)
    }
    @objc private func styleButtonTapped(_ sender: NSButton) {
        // Reuse one popover instance; opening it again just re-targets the anchor.
        if let popover = stylePopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let panel = TextStylePanel()
        panel.activePreset = currentStylePreset
        panel.onSelectPreset = { [weak self] preset in
            self?.currentStylePreset = preset
            self?.onStylePresetChanged?(preset)
        }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        stylePopover = popover
    }
    /// Reflects the backplate on/off state on the quick toggle (its bezel + tint),
    /// so picking a style preset that flips the backplate keeps the toggle truthful.
    func setBackplateActive(_ active: Bool) {
        currentBackplate = active ? .pill : .none
        backplateButton?.state = active ? .on : .off
        backplateButton?.contentTintColor = active ? KritColors.accent : nil
    }
    @objc private func backgroundTapped(_ sender: NSButton) {
        // Toggles the CleanShot-style sidebar; the old popover path is retired.
        onBackgroundPanelToggle?()
    }
    @objc private func smartRedactTapped(_ sender: NSButton) {
        onSmartRedact?()
    }

    /// Spinner over the redact glyph while detection runs; the glyph hides so the
    /// two never overlap. Re-enabled by the controller once the pass returns.
    func setSmartRedactBusy(_ busy: Bool) {
        smartRedactButton?.isEnabled = !busy
        smartRedactButton?.hidesGlyph = busy
        if busy { smartRedactSpinner?.startAnimation(nil) } else { smartRedactSpinner?.stopAnimation(nil) }
    }

    /// Coral-fills the redact toggle while a preview is staged, mirroring the
    /// background toggle's active state, so the staged preview reads in the canvas group.
    func setSmartRedactPreviewActive(_ active: Bool) {
        smartRedactButton?.isActive = active
    }

    @objc private func cropTapped()       { onApplyCrop?() }
    @objc private func cancelCropTapped() { onCancelCrop?() }
    @objc private func saveAsTapped()     { onSaveAs?() }
    @objc private func doneTapped()       { onDone?() }
}

// MARK: - Editor chrome pointer feedback

/// Shared pointer contract for the editor's compact controls. The editor chrome
/// is structural rather than floating glass, but its tools still need the same
/// immediate hover and press acknowledgement as the recording controls.
@MainActor
class EditorChromeButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?
    fileprivate private(set) var isPointerInside = false
    fileprivate private(set) var isPointerPressed = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    override func mouseDown(with event: NSEvent) {
        setPointerPressed(true)
        super.mouseDown(with: event)
        setPointerPressed(false)
    }

    private func setPointerInside(_ isInside: Bool) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        needsDisplay = true
    }

    private func setPointerPressed(_ isPressed: Bool) {
        guard isPointerPressed != isPressed else { return }
        isPointerPressed = isPressed
        layer?.setAffineTransform(isPressed
            ? CGAffineTransform(scaleX: 0.97, y: 0.97)
            : .identity)
        needsDisplay = true
    }
}

// MARK: - Flat tool button (CleanShot tool strip)

/// One tool in the header strip. CleanShot draws inactive tools as a bare glyph
/// (no bezel) and the SELECTED tool as a monochrome rounded pad (light pad + dark
/// glyph in dark mode, dark pad + white glyph in light mode), NOT the coral
/// accent, coral is reserved for the background toggle and Done. The button draws
/// itself entirely (the native bezel is off) so the inactive state is truly flat.
///
/// `isBorderedTool` makes it draw a faint chrome pad even when inactive, so the
/// leading crop reads as part of the bordered canvas group rather than the flat
/// strip; its selected state still uses the same mono pad as the strip.
@MainActor
final class FlatToolButton: EditorChromeButton {
    let tool: AnnotationTool
    /// Draw a chrome pad even when not selected (canvas-group crop). The flat
    /// strip tools leave this false, so they show only the bare glyph.
    var isBorderedTool = false { didSet { needsDisplay = true } }
    var isSelectedTool = false {
        didSet {
            setAccessibilityValue(isSelectedTool ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    private let glyph: NSImage?

    init(tool: AnnotationTool, target: AnyObject?, action: Selector?) {
        self.tool = tool
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        self.glyph = NSImage(systemSymbolName: tool.icon, accessibilityDescription: tool.tooltip)?
            .withSymbolConfiguration(config)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tool.tooltip
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tool.tooltip)
        setAccessibilityValue("Not selected")
        translatesAutoresizingMaskIntoConstraints = false
        // Circular hit target on the pill's ruler.
        widthAnchor.constraint(equalToConstant: AnnotationToolbar.controlSize).isActive = true
        heightAnchor.constraint(equalToConstant: AnnotationToolbar.controlSize).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // On dark glass a tool is a circle that appears when you reach for it.
        // Selected is a solid white disc with the glyph knocked out, which is
        // the only state that has to survive on top of any screenshot.
        let disc = NSBezierPath(ovalIn: bounds)
        if isSelectedTool {
            NSColor.white.setFill()
            disc.fill()
        } else if isPointerPressed {
            NSColor.white.withAlphaComponent(0.26).setFill()
            disc.fill()
        } else if isPointerInside {
            NSColor.white.withAlphaComponent(0.16).setFill()
            disc.fill()
        } else if isBorderedTool {
            NSColor.white.withAlphaComponent(0.10).setFill()
            disc.fill()
        }

        guard let glyph else { return }
        let tint = isSelectedTool ? KritColors.onLightChrome : NSColor.white.withAlphaComponent(0.92)
        let tinted = glyph.tinted(with: tint)
        let size = tinted.size
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// A compact native menu for a family of related tools. The active member is
/// reflected in the glyph and selection pad, while every member keeps its own
/// keyboard shortcut through the canvas command path.
@MainActor
final class ToolFamilyButton: EditorChromeButton {
    let tools: [AnnotationTool]
    var onSelect: ((AnnotationTool) -> Void)?

    private let fallbackSymbol: String
    private let familyLabel: String
    private var selectedTool: AnnotationTool?
    private var isActiveFamily = false

    init(symbol: String, label: String, tools: [AnnotationTool]) {
        fallbackSymbol = symbol
        familyLabel = label
        self.tools = tools
        super.init(frame: .zero)
        target = self
        action = #selector(presentToolMenu)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        toolTip = "\(label) tools"
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: AnnotationToolbar.controlSize).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(label) tools")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelectedTool(_ tool: AnnotationTool) {
        let member = tools.contains(tool)
        isActiveFamily = member
        if member { selectedTool = tool }
        setAccessibilityValue(member ? "Selected, \(toolName(tool))" : familyLabel)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = isActiveFamily
        // A family button is wider than it is tall (glyph plus chevron), so its
        // shape is a capsule rather than the plain tools' circle. Same states.
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if selected {
            NSColor.white.setFill()
            path.fill()
        } else if isPointerPressed {
            NSColor.white.withAlphaComponent(0.26).setFill()
            path.fill()
        } else if isPointerInside {
            NSColor.white.withAlphaComponent(0.16).setFill()
            path.fill()
        }

        let symbol = selectedTool?.icon ?? fallbackSymbol
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tint = selected ? KritColors.onLightChrome : NSColor.white.withAlphaComponent(0.92)
            let tinted = glyph.tinted(with: tint)
            let origin = NSPoint(x: 8, y: bounds.midY - tinted.size.height / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig) {
            let tint = selected ? KritColors.onLightChrome : NSColor.white.withAlphaComponent(0.92)
            let tinted = chevron.tinted(with: tint.withAlphaComponent(0.72))
            tinted.draw(
                at: NSPoint(x: bounds.maxX - tinted.size.width - 3, y: bounds.midY - tinted.size.height / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }

    @objc private func presentToolMenu() {
        let menu = NSMenu(title: familyLabel)
        menu.autoenablesItems = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        for tool in tools {
            let item = NSMenuItem(title: toolName(tool), action: #selector(toolMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            item.state = selectedTool == tool ? .on : .off
            item.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY - 2), in: self)
    }

    @objc private func toolMenuItemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tool = AnnotationTool(rawValue: rawValue) else { return }
        selectedTool = tool
        onSelect?(tool)
    }

    private func toolName(_ tool: AnnotationTool) -> String {
        String(tool.tooltip.split(separator: "(").first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Chrome toggle button (canvas group)

/// A bordered toggle in the canvas group (background panel, smart redact). It
/// always draws a chrome pad (the bordered CleanShot canvas group); when active
/// it fills coral with a white glyph (CleanShot tints this blue). Custom-drawn so
/// the active state is a real fill, not just a tint over a native bezel.
@MainActor
final class ChromeToggleButton: EditorChromeButton {
    var isActive = false {
        didSet {
            setAccessibilityValue(isActive ? "On" : "Off")
            needsDisplay = true
        }
    }
    /// Hides the glyph while the redact spinner overlays it.
    var hidesGlyph = false { didSet { needsDisplay = true } }

    private let glyph: NSImage?

    init(symbol: String, target: AnyObject?, action: Selector?) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        self.glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityValue("Off")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds)
        if isActive {
            // Active fills with the accent: this is the one place on the pill
            // where colour means "this mode is running", not "this is primary".
            let activeFill: NSColor
            if isPointerPressed {
                activeFill = KritColors.accent.blended(withFraction: 0.16, of: .black) ?? KritColors.accent
            } else if isPointerInside {
                activeFill = KritColors.accent.blended(withFraction: 0.12, of: .white) ?? KritColors.accent
            } else {
                activeFill = KritColors.accent
            }
            activeFill.setFill()
            path.fill()
        } else {
            let inactiveFill = isPointerPressed
                ? NSColor.white.withAlphaComponent(0.26)
                : (isPointerInside ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.10))
            inactiveFill.setFill()
            path.fill()
        }

        guard let glyph, !hidesGlyph else { return }
        let tint = NSColor.white
        let tinted = glyph.tinted(with: tint)
        let size = tinted.size
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        // The controller owns the persistent toggle state. Super keeps the
        // standard momentary click tracking, including a held-press response.
        super.mouseDown(with: event)
    }
}

private extension NSImage {
    /// A copy of the symbol image rendered in a single flat color, the simplest
    /// way to tint an SF Symbol glyph for custom drawing.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Editor bottom bar (ES4)

/// The editor's floating action pill: zoom, Annotate/Preview, an explicit
/// drag-out source, Share and Pin. The controller sizes and centers it over the
/// stage through layoutStage.
@MainActor
final class EditorBottomBar: NSView {

    var onZoomChanged: ((CGFloat) -> Void)?
    var onZoomFit: (() -> Void)?
    var onCreateDragExportSnapshot: (() -> AnnotationCanvas.ExportSnapshot?)?
    var onRequestDragPreview: (() -> NSImage?)?
    var onRequestImmediateDragExport: (() -> NSImage?)?
    var onDragDelivered: (() -> Void)?
    var onShare: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Fired when the Annotate/Preview segmented control flips (the Snapzy
    /// editor-mode toggle). true = preview (editing chrome hidden).
    var onPreviewModeChanged: ((Bool) -> Void)?

    /// The action pill shares the tool pill's ruler: same padding, same control
    /// size, same gap. Two floating capsules that disagreed on their metrics
    /// would read as two apps.
    static let pillPadding: CGFloat = AnnotationToolbar.pillPadding
    static let controlSize: CGFloat = AnnotationToolbar.controlSize
    static let controlGap: CGFloat = AnnotationToolbar.controlGap
    static let pillHeight: CGFloat = AnnotationToolbar.totalHeight

    private let zoomPopup = NSPopUpButton()
    private let modeControl = NSSegmentedControl(labels: ["Annotate", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private var shareButton: NSButton?
    private var sharePicker: NSSharingServicePicker?
    private var dragPill: BottomBarDragPill?
    private var actionCluster: NSStackView?
    private var contentRow: NSStackView?

    // Zoom presets: explicit % plus a "Fit" entry that re-fits the composition.
    private static let zoomPercents: [Int] = [35, 50, 75, 100]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // The action pill: a second capsule of glass, in the top-trailing corner
        // of the stage. It holds what you do WITH the shot (zoom, mode, drag it
        // out, share, pin, copy) as opposed to what you do TO it, which is the
        // tool pill's job. Two pills, two verbs.
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: Self.pillPadding, left: Self.pillPadding,
                                      bottom: Self.pillPadding, right: Self.pillPadding)

        let glass = KritGlassBacking(style: .bar, cornerRadius: Self.pillHeight / 2)
        glass.setContent(row)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentRow = row

        // Zoom. Borderless inside glass: a native bezel here would draw a second
        // shape inside the capsule and the pill would read as a container of
        // buttons instead of one control surface.
        zoomPopup.translatesAutoresizingMaskIntoConstraints = false
        zoomPopup.controlSize = .small
        zoomPopup.isBordered = false
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged(_:))
        zoomPopup.removeAllItems()
        for pct in Self.zoomPercents { zoomPopup.addItem(withTitle: "\(pct)%") }
        zoomPopup.addItem(withTitle: "Fit")
        zoomPopup.selectItem(withTitle: "Fit")
        zoomPopup.contentTintColor = .white
        // Centred, not leading: a borderless pop-up draws its title flush to the
        // cell edge, so the only gap left was the pill's own 5pt padding and the
        // number sat on the capsule's rim.
        zoomPopup.alignment = .center
        row.addArrangedSubview(zoomPopup)
        zoomPopup.widthAnchor.constraint(equalToConstant: 82).isActive = true

        // Annotate/Preview toggle. Preview hides every piece of editing chrome so
        // the user sees exactly what exports.
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = 0
        modeControl.selectedSegmentBezelColor = KritColors.accent
        modeControl.controlSize = .small
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(modeControl)

        let pill = BottomBarDragPill()
        pill.exportSnapshotProvider = { [weak self] in self?.onCreateDragExportSnapshot?() }
        pill.previewProvider = { [weak self] in self?.onRequestDragPreview?() }
        pill.immediateExportImageProvider = { [weak self] in self?.onRequestImmediateDragExport?() }
        pill.onDragDelivered = { [weak self] in self?.onDragDelivered?() }
        pill.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(pill)
        dragPill = pill

        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = Self.controlGap
        cluster.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(cluster)

        // Share and Pin only. A plain "Copy" here duplicated the tool pill's
        // "Copy & Close": two buttons, same verb, one screen apart. Copying now
        // lives once, on the primary action.
        let share = iconButton(symbol: "square.and.arrow.up", tooltip: "Share", action: #selector(shareTapped))
        shareButton = share
        cluster.addArrangedSubview(share)
        cluster.addArrangedSubview(iconButton(symbol: "pin", tooltip: "Pin to desktop", action: #selector(pinTapped)))
        actionCluster = cluster
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onPreviewModeChanged?(sender.selectedSegment == 1)
    }

    /// Preferred width with the full drag-out affordance reserved. Measuring the
    /// row as-is is circular: a narrow first frame hides the drag control, then a
    /// fitting-size read omits that hidden view and can never make room for it
    /// again when the editor settles.
    var fittingWidth: CGFloat {
        guard let row = contentRow, let pill = dragPill else { return 240 }
        row.layoutSubtreeIfNeeded()
        let views = row.arrangedSubviews
        let controlsWidth = views.reduce(CGFloat(0)) { partial, view in
            partial + (view === pill ? BottomBarDragPill.fullWidth : view.fittingSize.width)
        }
        let gapsWidth = row.spacing * CGFloat(max(0, views.count - 1))
        return max(240, controlsWidth + gapsWidth + row.edgeInsets.left + row.edgeInsets.right)
    }

    override func layout() {
        super.layout()
        // The row is intrinsically sized now, so the drag pill no longer has to
        // measure slack against neighbours: it degrades only when the stage
        // itself is too narrow to give the pill its full label.
        guard let pill = dragPill else { return }
        let others = (contentRow?.arrangedSubviews ?? [])
            .filter { $0 !== pill }
            .reduce(CGFloat(0)) { $0 + $1.fittingSize.width + Self.controlGap }
        let available = bounds.width - others - Self.pillPadding * 2
        let newMode: BottomBarDragPill.PillMode
        if available >= BottomBarDragPill.fullWidth { newMode = .full }
        else if available >= BottomBarDragPill.compactWidth { newMode = .compact }
        else { newMode = .hidden }
        pill.setMode(newMode)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        if let pill = dragPill, !pill.isHidden {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            let pointInPill = pill.convert(localPoint, from: self)
            if pill.containsHitPoint(pointInPill) {
                return pill
            }
        }
        return super.hitTest(point)
    }

    /// A borderless glyph button sized to the pill's control ruler. On glass the
    /// shape comes from the hover wash, not from a bezel.
    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = GlassPillButton(title: "", target: self, action: action)
        btn.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .white
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: Self.controlSize),
            btn.heightAnchor.constraint(equalToConstant: Self.controlSize),
        ])
        return btn
    }

    /// ES7: reflects the live magnification in the popup label. Snaps to the
    /// nearest preset when close, otherwise shows the exact integer percent.
    func setZoomLabel(for magnification: CGFloat) {
        let pct = Int((magnification * 100).rounded())
        if let match = Self.zoomPercents.first(where: { abs($0 - pct) <= 1 }) {
            zoomPopup.selectItem(withTitle: "\(match)%")
            return
        }
        // No preset matches: show the live value as a transient first item.
        let title = "\(pct)%"
        if zoomPopup.item(withTitle: title) == nil {
            zoomPopup.insertItem(withTitle: title, at: 0)
        }
        zoomPopup.selectItem(withTitle: title)
        // Trim any stale custom item so the menu doesn't accumulate values.
        for item in zoomPopup.itemArray where item.title.hasSuffix("%") {
            let value = Int(item.title.dropLast()) ?? -1
            if value != pct && !Self.zoomPercents.contains(value) {
                zoomPopup.removeItem(withTitle: item.title)
            }
        }
    }

    @objc private func zoomChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? "Fit"
        if title == "Fit" {
            onZoomFit?()
            return
        }
        let pct = Int(title.dropLast()) ?? 100
        onZoomChanged?(CGFloat(pct) / 100)
    }

    @objc private func shareTapped() {
        onShare?()
    }
    @objc private func pinTapped()  { onPin?() }
    @objc private func copyTapped() { onCopy?() }

    @discardableResult
    func prepareConcreteDragFile() async -> URL? {
        await dragPill?.prepareConcreteDragFile()
    }

    func invalidatePreparedDragFile() {
        dragPill?.invalidatePreparedDragFile()
    }

    /// Anchor for the share picker presented from the bar's Share button.
    func presentSharePicker(items: [Any]) {
        let anchor = shareButton ?? self
        let picker = NSSharingServicePicker(items: items)
        sharePicker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

// MARK: - Bottom bar drag-out control (ES4)

private struct EditorDragExportDescriptor: Equatable, Sendable {
    let encoding: CaptureEncoding
    let preferredExtension: String

    @MainActor
    static func current() -> EditorDragExportDescriptor {
        let format = ImageExporter.preferredFormat()
        return EditorDragExportDescriptor(
            encoding: CaptureEncoding.fileFormat(
                extension: format.ext,
                jpegQuality: Settings.jpegQuality
            ),
            preferredExtension: format.ext
        )
    }
}

private final class EditorPreparedDragFile: @unchecked Sendable {
    let url: URL
    let descriptor: EditorDragExportDescriptor

    init(url: URL, descriptor: EditorDragExportDescriptor) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A pill that drags the edited flattened image out as one concrete file URL.
/// The native-resolution export is prepared while the editor is idle, with a
/// synchronous correctness fallback only when a gesture beats preparation.
///
/// The drag source lives inside the action glass beside Share and Pin. It uses
/// the same white glyph and pointer-state wash as those controls instead of
/// drawing another opaque surface inside the capsule.
@MainActor
final class BottomBarDragPill: NSView, NSDraggingSource {

    var exportSnapshotProvider: (() -> AnnotationCanvas.ExportSnapshot?)?
    var previewProvider: (() -> NSImage?)?
    var immediateExportImageProvider: (() -> NSImage?)?
    /// Fired only after a real target accepts the concrete file drop.
    var onDragDelivered: (() -> Void)?

    /// Graceful degradation under narrow windows (the Snapzy footer pattern):
    /// full (icon + label), compact (icon only), hidden (zero width) so the
    /// centered pill never overlaps the zoom popup or the action cluster.
    enum PillMode { case full, compact, hidden }
    private(set) var mode: PillMode = .full

    static let fullWidth: CGFloat = 96
    static let compactWidth: CGFloat = EditorBottomBar.controlSize
    static let dragThreshold: CGFloat = 4
    static let previewMaxSize = NSSize(width: 120, height: 120)
    private static let promiseWriteStartTimeout: TimeInterval = 5
    static let dragTitle = "Drag out"
    static var dragSymbolName: String? {
        ["cursorarrow.motionlines", "hand.point.up.left"].first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    func setMode(_ newMode: PillMode) {
        guard newMode != mode else { return }
        mode = newMode
        isHidden = newMode == .hidden
        widthConstraint?.constant = newMode == .compact ? Self.compactWidth : Self.fullWidth
        toolTip = "Drag the edited image to another app or Finder"
        needsDisplay = true
    }

    private var widthConstraint: NSLayoutConstraint?
    private var dragOrigin: NSPoint?
    private var activeDragSession: NSDraggingSession?
    private var activeDragFileLease: EditorPreparedDragFile?
    private var preparedDragFile: EditorPreparedDragFile?
    private var dragFileGeneration = 0
    private var fileDragDeliveryGeneration = 0
    private var fileDragDeliveryGate: FileDragDeliveryGate?
    private var activeFilePromiseDelegate: BottomBarFilePromiseDelegate?
    private var filePromiseWriteStarted = false
    private(set) var uiTestMouseDownCount = 0
    private(set) var uiTestMouseDraggedCount = 0
    private(set) var uiTestThresholdCrossCount = 0
    private(set) var uiTestBeginSessionCount = 0
    private(set) var uiTestSessionMoveCount = 0
    private(set) var uiTestEndedSessionCount = 0
    private(set) var uiTestLastDropAccepted = false
    var uiTestOnDragSnapshotCreated: (() -> Void)?
    private var uiTestSessionPasteboardTypes: [String] = []
    private var uiTestLastSessionScreenPoint: NSPoint?
    private var uiTestMouseDownAtUptime: TimeInterval?
    private var uiTestBeginSessionAtUptime: TimeInterval?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    private var enlargedHitBounds: NSRect {
        bounds.insetBy(dx: -6, dy: -8)
    }

    func containsHitPoint(_ point: NSPoint) -> Bool {
        !isHidden && enlargedHitBounds.contains(point)
    }

    static func exceedsDragThreshold(from origin: NSPoint, to current: NSPoint, threshold: CGFloat? = nil) -> Bool {
        let threshold = threshold ?? dragThreshold
        return hypot(current.x - origin.x, current.y - origin.y) >= threshold
    }

    static func previewSize(for imageSize: NSSize, maxSize: NSSize? = nil) -> NSSize {
        let maxSize = maxSize ?? previewMaxSize
        guard imageSize.width > 0, imageSize.height > 0, maxSize.width > 0, maxSize.height > 0 else {
            return maxSize
        }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func draggingFrame(centeredAt point: NSPoint, previewSize: NSSize) -> NSRect {
        NSRect(
            x: point.x - previewSize.width / 2,
            y: point.y - previewSize.height / 2,
            width: previewSize.width,
            height: previewSize.height
        )
    }

    static func draggingItem(
        fileURL: URL,
        preview: NSImage,
        frame: NSRect
    ) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(frame, contents: preview)
        return item
    }

    var preparedDragFileURL: URL? {
        matchingPreparedDragFile()?.url
    }

    func invalidatePreparedDragFile() {
        dragFileGeneration += 1
        preparedDragFile = nil
    }

    @discardableResult
    func prepareConcreteDragFile() async -> URL? {
        dragFileGeneration += 1
        let generation = dragFileGeneration
        preparedDragFile = nil
        let descriptor = EditorDragExportDescriptor.current()
        guard let snapshot = exportSnapshotProvider?(),
              let artifact = snapshot.captureArtifact(),
              let export = await artifact.encoded(as: descriptor.encoding) else { return nil }

        let filename = "\(ImageExporter.timestampedName)-\(UUID().uuidString.prefix(8)).\(export.ext)"
        let url = await Task.detached(priority: .utility) {
            Self.writeTemporaryDragFile(data: export.data, filename: filename)
        }.value
        guard let url else { return nil }
        guard !Task.isCancelled, generation == dragFileGeneration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let prepared = EditorPreparedDragFile(url: url, descriptor: descriptor)
        preparedDragFile = prepared
        return prepared.url
    }

    func concreteDragFileForCurrentDocument() -> URL? {
        if let prepared = matchingPreparedDragFile() {
            return prepared.url
        }

        dragFileGeneration += 1
        _ = exportSnapshotProvider?()
        let descriptor = EditorDragExportDescriptor.current()
        guard let image = immediateExportImageProvider?(),
              let export = ImageExporter.encodedForExport(image) else { return nil }
        let filename = "\(ImageExporter.timestampedName)-\(UUID().uuidString.prefix(8)).\(export.ext)"
        guard let url = Self.writeTemporaryDragFile(data: export.data, filename: filename) else { return nil }
        let prepared = EditorPreparedDragFile(url: url, descriptor: descriptor)
        preparedDragFile = prepared
        return prepared.url
    }

    private func matchingPreparedDragFile() -> EditorPreparedDragFile? {
        guard let preparedDragFile,
              preparedDragFile.descriptor == EditorDragExportDescriptor.current(),
              FileManager.default.fileExists(atPath: preparedDragFile.url.path) else {
            preparedDragFile = nil
            return nil
        }
        return preparedDragFile
    }

    nonisolated private static func writeTemporaryDragFile(data: Data, filename: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KritDrag", isDirectory: true)
        let url = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[KRIT] Editor drag export failed at \(url.path): \(error)")
            return nil
        }
    }

    private static func retainDeliveredFile(_ file: EditorPreparedDragFile) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            _ = file
        }
    }

    static func draggingItem(
        fileType: String,
        delegate: NSFilePromiseProviderDelegate,
        preview: NSImage,
        frame: NSRect
    ) -> NSDraggingItem {
        let provider = RetainedFilePromiseProvider.make(fileType: fileType, delegate: delegate)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(frame, contents: preview)
        return item
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // The view stays custom because it is a drag source, but its hit surface
        // uses the exact control ruler shared by Share and Pin.
        let width = widthAnchor.constraint(equalToConstant: Self.fullWidth)
        width.isActive = true
        widthConstraint = width
        heightAnchor.constraint(equalToConstant: EditorBottomBar.controlSize).isActive = true
        toolTip = "Drag the edited image to another app or Finder"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag image out")
        setAccessibilityHelp("Drag this control to another app or Finder")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: enlargedHitBounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(enlargedHitBounds, cursor: pressed ? .closedHand : .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        guard containsHitPoint(localPoint) else { return nil }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if pressed {
            NSColor.white.withAlphaComponent(0.26).setFill()
            path.fill()
        } else if hovering {
            NSColor.white.withAlphaComponent(0.16).setFill()
            path.fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let showLabel = mode == .full
        let textSize = showLabel ? (Self.dragTitle as NSString).size(withAttributes: attrs) : .zero
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let glyph = Self.dragSymbolName
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Drag image out") }
            .flatMap { $0.withSymbolConfiguration(config) }
            .map { $0.tinted(with: NSColor.white.withAlphaComponent(0.92)) }
        let glyphSize = glyph?.size ?? NSSize(width: 12, height: 12)
        let gap: CGFloat = showLabel ? 6 : 0
        let totalW = glyphSize.width + gap + textSize.width
        var x = bounds.midX - totalW / 2
        if let glyph {
            glyph.draw(at: NSPoint(x: x, y: bounds.midY - glyphSize.height / 2),
                       from: NSRect.zero, operation: NSCompositingOperation.sourceOver, fraction: 1)
        } else {
            // Old systems without either SF Symbol keep a visible drag handle.
            NSColor.white.withAlphaComponent(0.72).setFill()
            for column in 0..<2 {
                for row in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(
                        x: x + CGFloat(column) * 4,
                        y: bounds.midY - 5 + CGFloat(row) * 4,
                        width: 2, height: 2
                    )).fill()
                }
            }
        }
        if showLabel {
            x += glyphSize.width + gap
            (Self.dragTitle as NSString).draw(
                at: NSPoint(x: x, y: bounds.midY - textSize.height / 2),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        if KritTestHarness.isEnabled {
            uiTestMouseDownCount += 1
            uiTestMouseDownAtUptime = ProcessInfo.processInfo.systemUptime
        }
        guard activeDragSession == nil, fileDragDeliveryGate == nil else { return }
        pressed = true
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if KritTestHarness.isEnabled { uiTestMouseDraggedCount += 1 }
        guard let origin = dragOrigin else { return }
        let current = event.locationInWindow
        guard Self.exceedsDragThreshold(from: origin, to: current) else { return }
        if KritTestHarness.isEnabled { uiTestThresholdCrossCount += 1 }
        dragOrigin = nil
        pressed = false
        window?.invalidateCursorRects(for: self)

        // The drag preview reads as a file card, not a raw bitmap: rounded
        // corners and a hairline keep a dark screenshot from looking like a
        // broken black rectangle while it rides the cursor.
        let previewSource = previewProvider?()
        let previewSize = Self.previewSize(
            for: previewSource?.size ?? NSSize(width: 120, height: 80)
        )
        let preview = NSImage(size: previewSize)
        preview.lockFocus()
        let previewRect = NSRect(origin: .zero, size: preview.size)
        let previewClip = NSBezierPath(roundedRect: previewRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        previewClip.addClip()
        if let previewSource {
            previewSource.draw(in: previewRect)
        } else {
            NSColor.windowBackgroundColor.setFill()
            previewRect.fill()
        }
        NSColor.white.withAlphaComponent(0.3).setStroke()
        previewClip.lineWidth = 1
        previewClip.stroke()
        preview.unlockFocus()

        let localDragPoint = convert(event.locationInWindow, from: nil)
        let draggingFrame = Self.draggingFrame(centeredAt: localDragPoint, previewSize: preview.size)
        guard let fileURL = concreteDragFileForCurrentDocument() else { return }
        if KritTestHarness.isEnabled {
            uiTestOnDragSnapshotCreated?()
        }
        fileDragDeliveryGeneration += 1
        filePromiseWriteStarted = false
        fileDragDeliveryGate = FileDragDeliveryGate(requiresPromiseCompletion: false)
        activeFilePromiseDelegate = nil
        activeDragFileLease = preparedDragFile
        let item = Self.draggingItem(
            fileURL: fileURL,
            preview: preview,
            frame: draggingFrame
        )

        if KritTestHarness.isEnabled {
            uiTestBeginSessionCount += 1
            uiTestBeginSessionAtUptime = ProcessInfo.processInfo.systemUptime
        }
        activeDragSession = beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        pressed = false
        window?.invalidateCursorRects(for: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        let types = session.draggingPasteboard.types?.map(\.rawValue) ?? []
        DispatchQueue.main.async { [weak self] in
            guard let self, KritTestHarness.isEnabled else { return }
            self.uiTestSessionPasteboardTypes = types
            self.uiTestLastSessionScreenPoint = screenPoint
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self, KritTestHarness.isEnabled else { return }
            self.uiTestSessionMoveCount += 1
            self.uiTestLastSessionScreenPoint = screenPoint
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let accepted = operation != []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if KritTestHarness.isEnabled {
                self.uiTestEndedSessionCount += 1
                self.uiTestLastDropAccepted = accepted
            }
            self.activeDragSession = nil
            let completedFileLease = self.activeDragFileLease
            self.activeDragFileLease = nil
            if accepted, let completedFileLease {
                Self.retainDeliveredFile(completedFileLease)
            }
            guard var gate = self.fileDragDeliveryGate else { return }
            let outcome = gate.noteDrop(accepted: accepted)
            self.fileDragDeliveryGate = gate
            self.resolveFileDragDelivery(outcome)
            if outcome == .waiting, accepted, !self.filePromiseWriteStarted {
                self.schedulePromiseWriteStartTimeout(generation: self.fileDragDeliveryGeneration)
            }
        }
    }

    private func handlePromiseWriteStarted(generation: Int) {
        guard generation == fileDragDeliveryGeneration,
              fileDragDeliveryGate != nil else { return }
        filePromiseWriteStarted = true
    }

    private func handlePromiseCompletion(succeeded: Bool, generation: Int) {
        guard generation == fileDragDeliveryGeneration,
              var gate = fileDragDeliveryGate else { return }
        let outcome = gate.notePromiseCompletion(succeeded: succeeded)
        fileDragDeliveryGate = gate
        resolveFileDragDelivery(outcome)
    }

    private func resolveFileDragDelivery(_ outcome: FileDragDeliveryOutcome) {
        switch outcome {
        case .delivered:
            fileDragDeliveryGate = nil
            activeFilePromiseDelegate = nil
            filePromiseWriteStarted = false
            onDragDelivered?()
        case .failed:
            _ = activeFilePromiseDelegate?.cancelIfNotStarted()
            fileDragDeliveryGate = nil
            activeFilePromiseDelegate = nil
            filePromiseWriteStarted = false
        case .waiting:
            break
        }
    }

    private func schedulePromiseWriteStartTimeout(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promiseWriteStartTimeout) { [weak self] in
            guard let self,
                  generation == self.fileDragDeliveryGeneration,
                  self.fileDragDeliveryGate != nil,
                  !self.filePromiseWriteStarted,
                  self.activeFilePromiseDelegate?.cancelIfNotStarted() == true else { return }
            self.fileDragDeliveryGate = nil
            self.activeFilePromiseDelegate = nil
        }
    }

    func uiTestResetDragTrace() {
        uiTestMouseDownCount = 0
        uiTestMouseDraggedCount = 0
        uiTestThresholdCrossCount = 0
        uiTestBeginSessionCount = 0
        uiTestSessionMoveCount = 0
        uiTestEndedSessionCount = 0
        uiTestLastDropAccepted = false
        uiTestSessionPasteboardTypes = []
        uiTestLastSessionScreenPoint = nil
        uiTestMouseDownAtUptime = nil
        uiTestBeginSessionAtUptime = nil
    }

    var uiTestDragTrace: [String: Any] {
        let beginLatencyMs: Double
        if let mouseDown = uiTestMouseDownAtUptime,
           let begin = uiTestBeginSessionAtUptime {
            beginLatencyMs = (begin - mouseDown) * 1000
        } else {
            beginLatencyMs = -1
        }
        return [
            "mouseDown": uiTestMouseDownCount,
            "mouseDragged": uiTestMouseDraggedCount,
            "thresholdCross": uiTestThresholdCrossCount,
            "beginSession": uiTestBeginSessionCount,
            "sessionMoves": uiTestSessionMoveCount,
            "endedSession": uiTestEndedSessionCount,
            "dropAccepted": uiTestLastDropAccepted,
            "pasteboardTypes": uiTestSessionPasteboardTypes,
            "lastSessionScreenPoint": uiTestLastSessionScreenPoint.map(NSStringFromPoint) ?? "none",
            "beginLatencyMs": beginLatencyMs,
        ]
    }

}

final class BottomBarFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Krit.BottomBarFilePromise"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private final class Completion: @unchecked Sendable {
        let handler: (Error?) -> Void

        init(_ handler: @escaping (Error?) -> Void) {
            self.handler = handler
        }
    }

    private enum WriteState: Equatable {
        case waiting
        case writing
        case finished
        case cancelled
    }

    private let stateLock = NSLock()
    private var writeState: WriteState = .waiting
    private let exportSnapshot: AnnotationCanvas.ExportSnapshot
    private let encoding: CaptureEncoding
    private let fileExtension: String
    private let fileType: String
    private let promisedFileName: String
    private let onWriteStarted: @Sendable () -> Void
    private let onCompletion: @Sendable (Bool) -> Void

    @MainActor
    init(
        exportSnapshot: AnnotationCanvas.ExportSnapshot,
        encoding: CaptureEncoding,
        fileExtension: String,
        fileType: String,
        onWriteStarted: @escaping @Sendable () -> Void,
        onCompletion: @escaping @Sendable (Bool) -> Void
    ) {
        self.exportSnapshot = exportSnapshot
        self.encoding = encoding
        self.fileExtension = fileExtension
        self.fileType = fileType
        promisedFileName = "\(ImageExporter.timestampedName).\(fileExtension)"
        self.onWriteStarted = onWriteStarted
        self.onCompletion = onCompletion
    }

    /// Invalidates a promise that no destination started consuming. A provider
    /// may outlive the editor inside another process, so clearing UI state alone
    /// is insufficient: a late receiver must get a cancellation error instead
    /// of materializing a second, orphaned export.
    func cancelIfNotStarted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard writeState == .waiting else { return false }
        writeState = .cancelled
        return true
    }

    private func beginWriting() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard writeState == .waiting else { return false }
        writeState = .writing
        return true
    }

    private func finishWriting() {
        stateLock.lock()
        writeState = .finished
        stateLock.unlock()
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        promisedFileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        guard beginWriting() else {
            handler(CancellationError())
            onCompletion(false)
            return
        }
        onWriteStarted()
        let completion = Completion(handler)
        Task { [exportSnapshot, encoding, fileExtension, fileType, onCompletion] in
            do {
                guard let artifact = await exportSnapshot.captureArtifact(),
                      let export = await artifact.encoded(as: encoding),
                      export.ext == fileExtension,
                      export.uti == fileType else {
                    throw ImageExporter.ExportError.encodingFailed(format: fileExtension)
                }
                let data = export.data
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                }.value
                self.finishWriting()
                completion.handler(nil)
                onCompletion(true)
            } catch {
                self.finishWriting()
                completion.handler(error)
                onCompletion(false)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }
}

// MARK: - UI test harness hooks
// Exposição mínima pro UITestRunner validar comportamento real (estado, não
// leitura de código). Só leitura/ações já existentes; nada de lógica nova.
extension AnnotationWindowController {
    static var uiTestLastController: AnnotationWindowController? { openControllers.last }
    var uiTestCanvas: AnnotationCanvas { canvas }
    var uiTestHasUnsavedChanges: Bool { hasUnsavedChanges }
    func uiTestMarkCurrentDocumentClean() { markCurrentDocumentClean() }
    /// Nova verdade (fit-to-stage): o canvas, NA ESCALA ATUAL, cabe dentro do
    /// palco visível (o viewport do scroll view), tolerância 2pt. A janela não
    /// acompanha mais o canvas; é o canvas que re-escala pra caber. Em modo fit a
    /// escala fica <= 1 (nunca upscale). Substitui a antiga R1 ("a janela cresce
    /// pro canvas"), que morreu com o novo comportamento.
    var uiTestWindowFollowsCanvas: Bool {
        guard let sv = editorScrollView else { return false }
        let scale = sv.magnification
        let viewport = sv.contentView.bounds.size   // já em coords do conteúdo (pré-escala)
        // O viewport do clip view é medido em pontos não-escalados; o canvas
        // (canvas.frame) está no mesmo espaço, então comparar direto basta.
        return canvas.frame.width <= viewport.width + 2
            && canvas.frame.height <= viewport.height + 2
            && scale <= 1.0001
    }
    /// Métricas cruas do fit pro orquestrador montar o assert novo: a escala
    /// atual, o tamanho do canvas (pontos não-escalados) e o palco visível
    /// (viewport do scroll view). Asserção esperada: canvas * scale cabe no
    /// stage e scale <= 1.
    var uiTestFitInfo: [String: Double] {
        guard let sv = editorScrollView else {
            return ["scale": 0, "canvasW": 0, "canvasH": 0, "stageW": 0, "stageH": 0]
        }
        let viewport = sv.contentView.bounds.size
        return [
            "scale": Double(sv.magnification),
            "canvasW": Double(canvas.frame.width),
            "canvasH": Double(canvas.frame.height),
            "stageW": Double(viewport.width),
            "stageH": Double(viewport.height),
            // Viewport in VIEW points (frame, not document-scaled bounds), so the
            // tall-fit test can compare the on-screen stage against the scaled image
            // without mixing coordinate spaces.
            "stageViewW": Double(sv.contentView.frame.width),
            "stageViewH": Double(sv.contentView.frame.height),
            "windowW": Double(window?.frame.width ?? 0),
            "windowH": Double(window?.frame.height ?? 0),
            "screenH": Double(window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 0),
        ]
    }
    var uiTestOptions: ScreenshotBackgroundOptions { backgroundOptions }

    /// Test hook: applies background options through the real sidebar path.
    func uiTestApplyBackground(_ options: ScreenshotBackgroundOptions) {
        applyBackgroundOptions(options)
        toolbar.setBackgroundOptionsExternally(options)
        backgroundSidebar?.options = options
    }
    var uiTestSidebar: BackgroundSidebar? { backgroundSidebar }

    /// Exposed so the spacing test asserts the real band instead of repeating
    /// the number, which would make the two drift apart independently.
    static var uiTestTrafficLightBand: CGFloat { trafficLightBand }

    /// Measured chrome geometry, so spacing can be asserted instead of eyeballed
    /// in a screenshot. Every value is a distance the design ruler has an
    /// opinion about; a render can only tell you it "looks about right".
    var uiTestChromeMetrics: [String: Double]? {
        guard let container = window?.contentView, let panel = backgroundSidebar else { return nil }
        let bounds = container.bounds
        let panelFrame = panel.frame
        let toolFrame = toolbar.frame
        let actionFrame = bottomBar?.frame ?? .zero
        return [
            "panelWidth": panelFrame.width,
            "panelMarginLeading": panelFrame.minX,
            "panelMarginBottom": panelFrame.minY,
            "panelMarginTop": bounds.maxY - panelFrame.maxY,
            "toolPillHeight": toolFrame.height,
            "toolPillMarginTop": bounds.maxY - toolFrame.maxY,
            "actionPillHeight": actionFrame.height,
            "actionPillCenterOffset": actionFrame.midX - toolFrame.midX,
            // The pill must be centred on the stage, which is the window minus
            // the panel: a pill centred on the window drifts when the panel opens.
            // Centre of the STAGE, which with one leading panel is not the
            // centre of the window.
            "toolPillCenterOffset": toolFrame.midX
                - (panelFrame.width + KritMetrics.Panel.margin * 2
                   + (bounds.width - panelFrame.width - KritMetrics.Panel.margin * 2) / 2),
        ]
    }
    func uiTestToggleSidebar() { toggleBackgroundSidebar() }

    /// Smart Redact harness hook: runs the pure detection pass (OCR + classifier)
    /// on `image` and returns the findings as plain dictionaries the runner can
    /// assert on. Independent of any open editor, so the harness can build a known
    /// secret-bearing image and verify categories + boxes without touching the
    /// canvas. Boxes are in image-pixel space (top-left origin).
    func uiTestSmartRedactFindings(in image: NSImage) async -> [[String: Any]] {
        await Self.uiTestSmartRedactFindings(in: image)
    }

    /// Static variant so the runner can probe the classifier without an editor
    /// instance. Same pipeline the editor uses: Vision text lines -> image-pixel
    /// boxes -> SecretClassifier.
    static func uiTestSmartRedactFindings(in image: NSImage) async -> [[String: Any]] {
        let detector = TextRegionDetector()
        let lines = await detector.recognizedLines(for: image)
        guard !lines.isEmpty else { return [] }
        let pixelSize: CGSize = {
            if let cg = image.bestCGImage, cg.width > 0, cg.height > 0 {
                return CGSize(width: cg.width, height: cg.height)
            }
            return image.size
        }()
        let classifierLines: [SecretClassifier.Line] = lines.compactMap { line in
            guard !line.text.isEmpty else { return nil }
            let top = 1 - (line.normalizedBox.minY + line.normalizedBox.height)
            let box = CGRect(
                x: line.normalizedBox.minX * pixelSize.width,
                y: top * pixelSize.height,
                width: line.normalizedBox.width * pixelSize.width,
                height: line.normalizedBox.height * pixelSize.height
            )
            return SecretClassifier.Line(text: line.text, box: box)
        }
        let findings = SecretClassifier.classify(lines: classifierLines)
        return findings.map { finding in
            [
                "category": finding.category.rawValue,
                "label": finding.category.label,
                "text": finding.text,
                "boxes": finding.boxes.map { box in
                    ["x": Double(box.minX), "y": Double(box.minY),
                     "w": Double(box.width), "h": Double(box.height)]
                },
            ] as [String: Any]
        }
    }
}
