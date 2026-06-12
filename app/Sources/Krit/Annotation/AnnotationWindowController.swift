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

    // Shared stage metrics: used both at init and on every relayout so the header,
    // canvas, sidebar and bottom bar stay registered with one another. The header
    // is now two bands (main tools + contextual properties); the toolbar owns the
    // canonical height.
    private static let toolbarHeight: CGFloat = AnnotationToolbar.totalHeight
    private static let stageInset: CGFloat = 18
    /// ES4: height of the editor's bottom bar (zoom · Drag me · Share/Pin/Copy/Save).
    /// The window minimum and the stage band both account for it.
    private static let bottomBarHeight: CGFloat = 48
    /// Canvas height the sidebar needs to show its scrolling control column
    /// comfortably; the window minimum is derived from this so opening the
    /// sidebar never crams the editor.
    private static let minimumCanvasHeight: CGFloat = 420

    private let canvas: AnnotationCanvas
    private let toolbar: AnnotationToolbar
    private var backgroundSidebar: BackgroundSidebar?
    private var bottomBar: EditorBottomBar?
    private var chromeBackdrop: EditorChromeBackdrop?
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
    // R1: distingue resize programático (auto-fit) de resize manual do usuário.
    private var isProgrammaticResize = false
    private var userManuallyResized = false
    // Fit-to-stage: por padrão o editor mantém o canvas inteiro encaixado no
    // palco visível. Mudar padding/inset/background/aspect/crop NÃO cresce a
    // janela: o canvas re-escala (fit) pra caber, e o label de zoom reflete.
    // Sai do modo quando o usuário escolhe um zoom manual no popup; volta ao
    // escolher "Fit". A janela é sempre do usuário (abertura + resize manual).
    private var fitMode = true

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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        if isWindowShot {
            initialBackground = Self.windowShotBackground(for: image, captureRect: historyItem?.captureRect?.cgRect)
        } else if let defaultOptions = TemplateStore.defaultBackgroundOptions(for: Self.screenContaining(historyItem?.captureRect?.cgRect)) {
            initialBackground = defaultOptions   // default template: open composed
        } else {
            initialBackground = .editorDefault   // isEnabled == false: raw shot
        }
        let canvasSize = ScreenshotBackgroundComposer.outputPointSize(for: image.size, options: initialBackground)
        let toolbarHeight = Self.toolbarHeight
        let stageInset = Self.stageInset

        // Open the window sized to the image (scaled to fit), not to a fraction of
        // the screen. Limiting width and height independently broke the aspect for
        // extreme ratios: a wide shot in a tall window left a sea of black stage
        // below it (the bug the owner saw). Instead, scale the canvas to fit a
        // moderate envelope and size the window to canvas*scale + chrome, so the
        // stage padding stays uniform and the window never opens near-fullscreen.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
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
        let fitScale = min(1, min(availW / canvasSize.width, availH / canvasSize.height))
        let shownCanvas = NSSize(width: canvasSize.width * fitScale, height: canvasSize.height * fitScale)
        let winW = max(shownCanvas.width + chromeW, effectiveMinimumWidth)
        let winH = max(shownCanvas.height + chromeH, effectiveMinimumHeight)
        let windowSize = NSSize(width: winW, height: winH)

        let win = EditorKeyWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // Unified toolbar style with an empty NSToolbar: the SYSTEM centers the
        // traffic lights in a 52pt band, putting them on the main band's ruler
        // with zero frame hacks on the standard window buttons.
        win.toolbarStyle = .unified
        let emptyToolbar = NSToolbar()
        emptyToolbar.showsBaselineSeparator = false
        win.toolbar = emptyToolbar
        win.isReleasedWhenClosed = false
        // Janela normal de documento: .floating prendia o editor acima de TODOS
        // os apps (clicar num app abaixo não o trazia pra frente).
        win.level = .normal
        win.minSize = NSSize(width: effectiveMinimumWidth, height: effectiveMinimumHeight)
        win.center()

        super.init(window: win)

        // Set before the sidebar/canvas are built (the sidebar reads it for its
        // initial `options`); the canvas is resized to the composed size below,
        // after the view hierarchy exists.
        backgroundOptions = initialBackground

        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: canvasSize)

        // Scroll view for canvas. It fills the chrome notch EXACTLY (header to
        // footer, sidebar to trailing edge), no inset band, no own border or
        // shadow: a second frame floating inside the notch read as a detached
        // panel, with the stage color leaking around it. Breathing room around
        // the document comes from the window sizing formulas (stageInset) via
        // the centering clip view, not from chrome geometry.
        let scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: Self.bottomBarHeight,
            width: winW,
            height: winH - toolbarHeight - Self.bottomBarHeight
        ))
        // Center canvas when viewport is larger than the image (eliminates blank side areas)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
        // property, so there is nothing to guard with #available. The stage already
        // separates from the chrome via the notch hairline drawn by the backdrop.

        // Header band: a single full-width row pinned to the top of the window,
        // the same disciplined layout as the footer. The toolbar's own internal
        // stack (leading-anchored, centerY) drives every control; the controller
        // only frames this band, no dock-centering or left-group math.
        toolbar.frame = Self.headerFrame(winW: winW, winH: winH)
        // Manual layout on resize (layoutStage) so the band tracks the window.
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
        toolbar.onLineWidthChanged = { [weak self] w   in self?.canvas.setActiveLineWidth(w) }
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
        toolbar.onDone            = { [weak self] in self?.window?.performClose(nil) }
        toolbar.onApplyCrop       = { [weak self] in self?.applyCrop() }
        toolbar.onCancelCrop      = { [weak self] in
            // Same path as Esc inside the crop tool: drop the staged region,
            // restore the Save as/Done pair, stay on the crop tool.
            self?.canvas.cropRect = nil
            self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
            self?.toolbar.setCropApplyVisible(false)
        }
        toolbar.onUndo            = { [weak self] in self?.canvas.performUndo() }
        toolbar.onRedo            = { [weak self] in self?.canvas.performRedo() }
        toolbar.onBackgroundOptionsChanged = { [weak self] options in
            self?.hasUserBackgroundEdit = true
            self?.pushBackgroundUndoIfNeeded()
            self?.applyBackgroundOptions(options)
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
            let hasCrop = rect != nil && !(rect?.isEmpty ?? true)
            self?.toolbar.setCropApplyVisible(hasCrop)
        }

        // Return/Enter or double-click inside the region commits the crop,
        // same path as the toolbar check button.
        canvas.onCropCommit = { [weak self] in self?.applyCrop() }

        // Item 1: undo/redo. Mirror the canvas stacks on the header buttons and
        // resync the document when an undo/redo restores a different image/size
        // (crop and background changes), then refit the window to it.
        canvas.onUndoStateChanged = { [weak self] canUndo, canRedo in
            self?.toolbar.setUndoRedoEnabled(canUndo: canUndo, canRedo: canRedo)
        }
        canvas.onDocumentRestored = { [weak self] in self?.syncDocumentFromCanvas() }

        // Build hierarchy FIRST, then configure layers (layers don't exist until views are in a window)
        let container = PremiumEditorStageView(frame: NSRect(origin: .zero, size: windowSize))

        // ES1/ES4: one continuous L-shaped chrome surface (left column + footer as a
        // single material piece) sits behind everything. The sidebar and bottom bar
        // are just transparent control hosts on top of it; the canvas/stage occupies
        // the notch of the L. Added first so it stays at the back.
        let backdrop = EditorChromeBackdrop(frame: container.bounds)
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        chromeBackdrop = backdrop

        container.addSubview(scrollView)
        container.addSubview(toolbar)

        // The leading actions ([undo/redo][crop][backgrounds][redact]) are now the
        // first members of the toolbar's single internal row, so there is no
        // separate left-group view to parent or frame here.

        // Backgrounds sidebar (CleanShot "B" panel), an integrated left column
        // (ES1): x:0, full height between the bottom bar and the floating dock.
        // Hidden until toggled.
        let sidebar = BackgroundSidebar(options: backgroundOptions)
        sidebar.frame = NSRect(x: 0, y: Self.bottomBarHeight,
                               width: Self.sidebarWidth,
                               height: winH - toolbarHeight - Self.bottomBarHeight)
        // Owned by layoutStage; height tracks the content band, width is fixed.
        sidebar.autoresizingMask = []
        sidebar.isHidden = true
        sidebar.onChange = { [weak self] options in
            guard let self else { return }
            self.hasUserBackgroundEdit = true
            self.pushBackgroundUndoIfNeeded()
            self.toolbar.setBackgroundOptionsExternally(options)
            self.applyBackgroundOptions(options)
        }
        container.addSubview(sidebar)
        backgroundSidebar = sidebar
        editorScrollView = scrollView

        // ES4: editor bottom bar, zoom popup (left), Drag me pill (center, file
        // promise out), Share/Pin/Copy/Save cluster (right, Save tinted coral).
        let bar = EditorBottomBar()
        bar.frame = NSRect(x: 0, y: 0, width: winW, height: Self.bottomBarHeight)
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
            self.toolbar.setPreviewMode(preview)
            self.canvas.isPreviewMode = preview
            // Preview means "what exports": close the background sidebar if open
            // so nothing editorial frames the result.
            if preview, self.sidebarVisible { self.toggleBackgroundSidebar() }
        }
        bar.onRequestDragImage = { [weak self] in self?.exportImage() }
        bar.onDragDelivered = { [weak self] in self?.window?.close() }
        bar.onShare = { [weak self] in self?.shareFromBottomBar() }
        bar.onPin = { [weak self] in self?.pin() }
        bar.onCopy = { [weak self] in self?.copyToClipboard() }
        container.addSubview(bar)
        bottomBar = bar

        // Seed the L backdrop's arms for the initial (sidebar-closed) layout.
        backdrop.update(leftArmWidth: 0, bottomArmHeight: Self.bottomBarHeight, topArmHeight: toolbarHeight)

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
        guard ImageExporter.save(image: flat, to: url) != nil else {
            ToastWindow.show(message: "Could not save screenshot")
            return
        }
        // Non-destructive edits also land in Capture History as their own entry.
        historyManager?.add(image: flat, rect: historyItem?.captureRect?.cgRect)
        SoundManager.play(.save)
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
            SoundManager.play(.save)
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

    /// ES4: Share from the bottom-bar cluster. Prefers a real file URL (AirDrop/
    /// Mail/Photos keep filename + metadata), falling back to the raw image.
    private func shareFromBottomBar() {
        canvas.commitTextField()
        let flat = exportImage()
        let items: [Any]
        if let png = ImageExporter.pngData(from: flat), let url = DragFileVault.makeFile(data: png) {
            DragFileVault.scheduleCleanup(url)
            items = [url]
        } else {
            items = [flat]
        }
        NSApp.activate(ignoringOtherApps: true)
        bottomBar?.presentSharePicker(items: items)
    }

    private func exportImage() -> NSImage {
        canvas.flatten()
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
            guard let self else { return }
            let level = self.canvas.fitToWindow()
            self.bottomBar?.setZoomLabel(for: level)
            // The window can still be reshaped after this first pass (sidebar
            // opening, large-shot window sizing), which leaves the early fit
            // stale and a big window shot opening at the wrong zoom. One more
            // pass against the settled viewport covers that case.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                let settled = self.canvas.fitToWindow()
                self.bottomBar?.setZoomLabel(for: settled)
            }
        }
    }


    private func toggleBackgroundSidebar() {
        guard let sidebar = backgroundSidebar, let window else { return }
        let showing = !sidebarVisible
        sidebarVisible = showing

        // User rule: opening the panel never auto-applies a background, the
        // shot stays raw until the user explicitly picks one in the sidebar.
        sidebar.options = backgroundOptions
        toolbar.setBackgroundPanelOpen(showing)   // ES3: icon button selected state

        // Opening the sidebar must not shrink the canvas below a usable width:
        // widen the window so the sidebar takes new space instead of eating the
        // canvas. The canvas reflows in lockstep inside layoutStage.
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
            }
        }

        // ES1: the column slides in from the left edge (off-screen at x:-width) to
        // x:0 while the canvas reflows beside it; closing slides it back out.
        sidebar.isHidden = false
        if showing {
            // Seed the off-screen start frame before animating to x:0.
            sidebar.frame = Self.sidebarRect(winH: window.frame.height, visible: false)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            layoutStage(sidebarVisible: showing, animated: true)
        }, completionHandler: { [weak self] in
            if !showing { sidebar.isHidden = true }
            self?.canvas.setNeedsDisplay(self?.canvas.bounds ?? .zero)
        })
    }

    // MARK: - Stage layout (dock + canvas + sidebar + bottom bar in lockstep)

    /// Re-lays out the floating dock, the canvas scroll view, the integrated
    /// sidebar column and the bottom bar from the current window size. The dock
    /// always clears the traffic lights (R6) and the open sidebar; the canvas
    /// takes whatever horizontal space is left so the art is never crammed.
    private func layoutStage(sidebarVisible: Bool, animated: Bool) {
        guard let container = window?.contentView, let scrollView = editorScrollView else { return }
        let winW = container.bounds.width
        let winH = container.bounds.height

        // The canvas fills the chrome notch exactly: flush against the sidebar's
        // trailing edge (or the window edge when closed), the header band and the
        // footer. Any gap here exposes the stage color as a stray frame.
        let leftEdge = sidebarVisible ? Self.sidebarWidth : 0
        let canvasRect = NSRect(
            x: leftEdge,
            y: Self.bottomBarHeight,
            width: max(1, winW - leftEdge),
            height: max(1, winH - Self.toolbarHeight - Self.bottomBarHeight)
        )
        let sidebarRect = Self.sidebarRect(winH: winH, visible: sidebarVisible)
        let headerRect = Self.headerFrame(winW: winW, winH: winH)
        let barRect = NSRect(x: 0, y: 0, width: winW, height: Self.bottomBarHeight)

        // The L-shaped chrome backdrop spans from y:0 up to the dock band; its left
        // arm is the open sidebar width (0 when closed), its bottom arm is the bar.
        // The canvas hairline is drawn by the backdrop along the notch edges.
        let leftArm = sidebarVisible ? Self.sidebarWidth : 0

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
        // The backdrop redraws its continuous frame from these arm metrics every
        // layout pass (top header + left sidebar + bottom footer around the notch).
        chromeBackdrop?.update(leftArmWidth: leftArm, bottomArmHeight: Self.bottomBarHeight, topArmHeight: Self.toolbarHeight)
    }

    /// Integrated sidebar column frame: flush left (x:0) and full-height between
    /// the bottom bar and the floating dock when visible; parked just off the left
    /// edge (x:-width) when hidden, so opening/closing reads as a slide.
    private static func sidebarRect(winH: CGFloat, visible: Bool) -> NSRect {
        NSRect(
            x: visible ? 0 : -sidebarWidth,
            y: bottomBarHeight,
            width: sidebarWidth,
            height: max(1, winH - toolbarHeight - bottomBarHeight)
        )
    }

    /// Header band frame: a single full-width row across the top of the window,
    /// spanning the whole `toolbarHeight`. The toolbar's own internal stack
    /// (leading-anchored past the traffic lights, centerY) positions every
    /// control, so the controller only needs this one trivial frame, no
    /// dock-centering or left-group math.
    private static func headerFrame(winW: CGFloat, winH: CGFloat) -> NSRect {
        NSRect(x: 0, y: winH - toolbarHeight, width: winW, height: toolbarHeight)
    }

    /// Window width that keeps the full header row visible (its fitting width,
    /// which already includes the leading inset past the traffic lights and the
    /// trailing breathing room) and a usable canvas beside the sidebar when open.
    /// Uses the toolbar's measured content width, never a stale constant.
    private static func minimumWindowWidth(toolbarWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        // The header row must fit in full; `toolbarWidth` (fittingWidth) already
        // accounts for the leading inset and trailing room. The +8 is breathing
        // room so the toolbar never sits flush against the edge: native popups
        // (the font family menu) settle a couple of points wider after the system
        // measures their text, and without slack that growth clips the edge button.
        let headerNeed = toolbarWidth + 8
        guard sidebarVisible else { return headerNeed }
        // ...and the canvas must stay usable beside the open sidebar.
        let canvasNeed = sidebarWidth + minimumCanvasWidth + stageInset
        return max(headerNeed, canvasNeed)
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

    private func applyBackgroundOptions(_ options: ScreenshotBackgroundOptions) {
        canvas.commitTextField()

        // Annotations are positioned in canvas space; when the background slot
        // moves (padding/inset/aspect/alignment), shift them by the slot-origin
        // delta so they stay registered with the screenshot they annotate.
        let oldOrigin = imageSlotOrigin(for: backgroundOptions)
        let newOrigin = imageSlotOrigin(for: options)
        backgroundOptions = options

        canvas.backgroundOptions = options
        canvas.backgroundImage = image
        canvas.frame = NSRect(origin: .zero, size: previewSize(for: options))
        canvas.offsetContent(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
        canvas.setNeedsDisplay(canvas.bounds)
        updateCheckerboard()

        // Fit-to-stage: padding/ratio/background mudam o canvas; a janela NÃO
        // cresce, o canvas re-escala (fit) pra caber no palco visível. O usuário
        // mantém o tamanho que deu à janela; só o conteúdo encolhe pra caber.
        refitCanvasToStage()
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
        guard !canvas.objects.isEmpty || hasUserBackgroundEdit else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Annotations"
        alert.informativeText = "You have annotations that haven't been saved. Close without saving?"
        alert.addButton(withTitle: "Close")
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

// MARK: - Editor chrome backdrop (continuous frame, ES1/ES3/ES4)

/// One continuous material surface that frames the canvas on all chrome sides as a
/// single piece: top arm (header/toolbar band), left arm (sidebar, when open) and
/// bottom arm (the footer), folding around the corners with no seam. The canvas
/// occupies the notch. The material runs full-bleed to the window edges (under the
/// transparent titlebar + traffic lights), so the header reads as the SAME frame as
/// the sidebar and footer, not a separate panel. A 1px hairline traces only the
/// notch boundary (the edges where the frame meets the canvas).
@MainActor
final class EditorChromeBackdrop: NSView {
    private let material: NSVisualEffectView
    private let hairline = CAShapeLayer()
    private var leftArmWidth: CGFloat = 0
    private var bottomArmHeight: CGFloat = 0
    private var topArmHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        material = NSVisualEffectView(frame: frameRect)
        super.init(frame: frameRect)
        wantsLayer = true
        // HIG: the L-frame is STRUCTURAL window chrome (it bounds the content notch
        // and runs flush to the window edges), not a floating element, so it stays
        // a window material and does NOT become NSGlassEffectView. Glass is reserved
        // for elements that float over content; the stage in the notch is the
        // content layer and never gets glass. Window-background material so the whole
        // frame (header + sidebar + footer) reads as one continuous window chrome.
        // Sits behind the controls; the mask carves out the canvas notch so the dark
        // stage shows through.
        material.material = .windowBackground
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        hairline.fillColor = NSColor.clear.cgColor
        // Subtle: at separatorColor 0.8 this read as bright "white wires" around
        // the canvas. The notch boundary only needs a whisper of definition.
        hairline.strokeColor = KritColors.editorChromeBorder.cgColor
        hairline.lineWidth = 1
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Re-carve the frame from the current arm metrics. The notch (canvas) is the
    /// rectangle inset by the three arms; the right edge runs flush to the window.
    func update(leftArmWidth: CGFloat, bottomArmHeight: CGFloat, topArmHeight: CGFloat) {
        self.leftArmWidth = leftArmWidth
        self.bottomArmHeight = bottomArmHeight
        self.topArmHeight = topArmHeight
        relayoutMask()
    }

    override func layout() {
        super.layout()
        relayoutMask()
    }

    private func relayoutMask() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        // The notch (canvas) is bounded by the top arm above, left arm at leading,
        // bottom arm below, and runs flush to the trailing window edge.
        let notch = CGRect(
            x: leftArmWidth,
            y: bottomArmHeight,
            width: max(0, b.width - leftArmWidth),
            height: max(0, b.height - topArmHeight - bottomArmHeight)
        )

        // Mask the material: fill the whole bounds, punch out the notch (even-odd).
        let path = CGMutablePath()
        path.addRect(b)
        path.addRect(notch)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        material.layer?.mask = mask

        // Hairline along the three inner edges of the notch (top, left, bottom),
        // only where the frame actually borders the canvas. The trailing edge is the
        // window edge, so no hairline there.
        let border = CGMutablePath()
        // Left edge (only when the sidebar arm is present).
        if leftArmWidth > 0 {
            border.move(to: CGPoint(x: notch.minX + 0.5, y: notch.minY))
            border.addLine(to: CGPoint(x: notch.minX + 0.5, y: notch.maxY))
        }
        // Top edge (header band).
        border.move(to: CGPoint(x: notch.minX, y: notch.maxY - 0.5))
        border.addLine(to: CGPoint(x: b.width, y: notch.maxY - 0.5))
        // Bottom edge (footer band).
        border.move(to: CGPoint(x: notch.minX, y: notch.minY + 0.5))
        border.addLine(to: CGPoint(x: b.width, y: notch.minY + 0.5))
        hairline.path = border
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Flat neutral void. The old purple/coral radial glows belonged to the
        // floating-dock design; inside the chrome notch they read as a "purple
        // smear" leaking around the canvas, so the stage is now a single color.
        KritColors.editorStageTop.setFill()
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

    // Conservative window-width floor before the live `fittingWidth` exists at
    // init time. The two-band header is far leaner per band than the old single
    // row (color + context controls moved to the properties band), so the editor
    // window can now get much narrower.
    static let requiredWidth: CGFloat = 840
    /// Main band: tools and window actions. 52pt so the system-centered traffic
    /// lights (unified toolbar style) sit on the same vertical ruler as the
    /// controls, no frame hacks on the standard window buttons.
    static let mainBarHeight: CGFloat = 52
    /// Contextual properties band under the main band (the Snapzy/CleanShot
    /// pattern): shows ONLY the active tool's options, so each band stays light
    /// and the window minimum stays small.
    static let propertiesBarHeight: CGFloat = 48
    /// Total chrome height the controller reserves for the header.
    static let totalHeight: CGFloat = mainBarHeight + propertiesBarHeight

    /// Leading inset of the main band, large enough to clear the traffic lights
    /// so the first action group never slides under the close button (R6).
    static let leadingInset: CGFloat = 92
    /// Trailing breathing room so the bands never butt against the window edge.
    static let trailingInset: CGFloat = 16

    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onLineWidthChanged: ((CGFloat) -> Void)?
    var onFontFamilyChanged: ((AnnotationFontFamily) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onBackplateChanged: ((TextBackplate) -> Void)?
    /// Fired when the secure-blur toggle flips (blur tool only). On = new blurs
    /// are an irreversible mosaic instead of a recoverable gaussian.
    var onSecureBlurChanged: ((Bool) -> Void)?
    /// Fired when a style preset is chosen in the text style popover (regular,
    /// bold, italic, bold+italic, backplate, outlined).
    var onStylePresetChanged: ((TextStylePreset) -> Void)?
    /// The preset to ring as active when the style popover opens. Read at present
    /// time so the popover reflects the current text (or the active default).
    var currentStylePreset: TextStylePreset = .regular
    /// Top toolbar carries only "Save as…" and the primary "Done" (close). Copy /
    /// Pin / Share / quick Save live in the bottom bar (ES4), so those closures are
    /// gone from here, one place per action.
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

    /// Every tool is its own flat button in the strip (the CleanShot pattern):
    /// bare glyph when inactive, a monochrome rounded pad behind the SELECTED one.
    /// Selection is exclusive across the whole strip, so selectTool lights one
    /// button and clears the rest; this registry holds every tool button.
    private var toolButtons: [AnnotationTool: FlatToolButton] = [:]
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
    /// The main band's horizontal flow (tools + actions). The properties band
    /// below it has its own stack; fittingWidth takes the wider of the two.
    private var rootStack: NSStackView?
    private var propertiesStack: NSStackView?
    private var toolChipIcon: NSImageView?
    private var toolChipLabel: NSTextField?
    private var contextWidthRow: NSView?
    private var contextFontRow: NSView?
    private var secureBlurButton: NSButton?
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
        // ES3: in the editor the header is the TOP ARM of the continuous chrome
        // frame (EditorChromeBackdrop provides the material). Two bands, the
        // Snapzy/CleanShot hierarchy:
        //   main band (52): canvas group | tool strip | flexible gap | Save as/Done
        //   properties band (48): the ACTIVE tool's options only
        // Splitting the old single 76pt row in two is what makes the header truly
        // responsive: the main band ends in a flexible gap (it absorbs narrowing
        // instead of forcing the window wider), and the properties band only ever
        // holds one tool's controls.
        wantsLayer = true

        let main = NSStackView()
        main.orientation = .horizontal
        main.alignment = .centerY
        main.distribution = .fill
        main.spacing = 8
        main.translatesAutoresizingMaskIntoConstraints = false
        addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            main.topAnchor.constraint(equalTo: topAnchor),
            main.heightAnchor.constraint(equalToConstant: Self.mainBarHeight),
            // Pinned trailing edge: the flexible gap inside the band stretches and
            // shrinks with the window, so the actions hug the right edge at every
            // width instead of the window being forced to fit a rigid row.
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
        ])
        rootStack = main

        // Canvas group right after the traffic lights: crop, backgrounds toggle,
        // smart redact, bordered chrome buttons like CleanShot's leading group.
        appendCanvasGroup(to: main)
        if let group = canvasGroup { main.setCustomSpacing(10, after: group) }
        let leadingDivider = makeHeaderDivider()
        main.addArrangedSubview(leadingDivider)
        headerDivider = leadingDivider

        // Tool strip: one flat button per tool (bare glyph when inactive, a mono
        // pad behind the selected one), in the CleanShot order.
        let strip = makeToolStrip([
            .select, .rectangle, .filledRectangle, .ellipse, .line, .arrow,
            .text, .pixelate, .blur, .numberedStep, .freehand, .highlighter,
        ])
        main.addArrangedSubview(strip)
        toolStripView = strip

        // Flexible gap: this is the band's shock absorber. It has no minimum
        // beyond a hair of breathing room and zero hugging, so the band tracks
        // the window from requiredWidth on up.
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        main.addArrangedSubview(gap)

        // Window actions on the right: Save as… + the primary Done (native
        // bezels, coral on the emphasized action). Copy/Pin/Share live ONCE in
        // the bottom bar. While a crop region is staged the pair swaps for
        // Cancel/Apply (the Snapzy/CleanShot contextual action slot).
        let saveBtn = makeActionButton(title: "Save as\u{2026}", action: #selector(saveAsTapped))
        main.addArrangedSubview(saveBtn)
        saveAsButton = saveBtn
        let doneBtn = makeActionButton(title: "Done", action: #selector(doneTapped), isPrimary: true)
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

        // Hairline between the bands, the same separator token as the rest of
        // the chrome, so the hierarchy reads without a heavy divider.
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor, constant: Self.mainBarHeight),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Properties band: tool chip + color + the active tool's controls.
        buildPropertiesBar()

        selectTool(.arrow)
    }

    /// Width the header needs to fit its content, used by the controller to size
    /// the window (ensureWindowFitsToolbar). The wider of the two bands wins;
    /// the flexible gap contributes only its 8pt minimum to the main band.
    var fittingWidth: CGFloat {
        rootStack?.layoutSubtreeIfNeeded()
        propertiesStack?.layoutSubtreeIfNeeded()
        let mainContent = rootStack?.fittingSize.width ?? Self.requiredWidth
        let propsContent = propertiesStack?.fittingSize.width ?? 0
        return max(Self.leadingInset + mainContent + Self.trailingInset,
                   16 + propsContent + Self.trailingInset)
    }

    /// A 1x20 vertical separator for the main band's group splits.
    private func makeHeaderDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return divider
    }

    /// Builds the contextual properties band: a chip naming the active tool, the
    /// color well, then the stroke-size or font controls, only what the active
    /// tool actually uses, in one light always-fitting row.
    private func buildPropertiesBar() {
        let props = NSStackView()
        props.orientation = .horizontal
        props.alignment = .centerY
        props.spacing = 12
        props.detachesHiddenViews = true
        props.translatesAutoresizingMaskIntoConstraints = false
        addSubview(props)
        NSLayoutConstraint.activate([
            props.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            props.topAnchor.constraint(equalTo: topAnchor, constant: Self.mainBarHeight + 1),
            props.heightAnchor.constraint(equalToConstant: Self.propertiesBarHeight - 1),
            props.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset),
        ])
        propertiesStack = props

        // Tool chip: icon + name of the active tool (the Snapzy context chip),
        // so the band always says what it is configuring.
        let chipIcon = NSImageView()
        chipIcon.contentTintColor = .secondaryLabelColor
        chipIcon.translatesAutoresizingMaskIntoConstraints = false
        toolChipIcon = chipIcon
        let chipLabel = NSTextField(labelWithString: "")
        chipLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        chipLabel.textColor = .secondaryLabelColor
        toolChipLabel = chipLabel
        let chip = NSStackView(views: [chipIcon, chipLabel])
        chip.orientation = .horizontal
        chip.alignment = .centerY
        chip.spacing = 5
        props.addArrangedSubview(chip)
        props.addArrangedSubview(makeHeaderDivider())

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
        group.addArrangedSubview(backgroundBtn)
        backgroundButton = backgroundBtn

        // Smart Redact: KRIT's own auto-detect of sensitive content. Same bordered
        // chrome look; its ON state (coral) tracks a staged preview. A spinner
        // overlays the glyph while the local detection pass runs.
        let redactBtn = makeChromeToggleButton(symbol: "eye.slash", action: #selector(smartRedactTapped(_:)))
        redactBtn.toolTip = "Smart redact (auto-detect sensitive content)"
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

    /// Builds the flat tool strip: one `FlatToolButton` per tool, tightly and
    /// uniformly spaced, no bezel when inactive and a monochrome pad behind the
    /// selected one (the CleanShot strip). Each button is registered in
    /// `toolButtons`, and selection stays exclusive across the whole strip via
    /// selectTool, which lights one and clears the rest.
    private func makeToolStrip(_ tools: [AnnotationTool]) -> NSStackView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 4
        strip.translatesAutoresizingMaskIntoConstraints = false
        for tool in tools {
            let button = makeFlatToolButton(tool)
            strip.addArrangedSubview(button)
        }
        return strip
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

    /// Builds the stroke-size row and the font row for the properties band.
    /// They sit side by side as arranged views; selectTool toggles visibility
    /// and the band's detachesHiddenViews collapses the hidden one. No fixed
    /// width container anymore: the band has the whole window width to itself.
    private func makeContextRows() -> (widthRow: NSView, fontRow: NSView) {
        // Stroke size (drawing tools).
        let label = NSTextField(labelWithString: "Size")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        widthLabel = label
        let slider = NSSlider(value: Settings.annotationLineWidth, minValue: 1, maxValue: 20, target: self, action: #selector(lineWidthChanged))
        // Brand coral on the filled track; the system blue clashed with the dock.
        slider.trackFillColor = KritColors.accent
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
        secureBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        secureBtn.isHidden = true
        secureBlurButton = secureBtn

        let widthRow = NSStackView(views: [label, slider, secureBtn])
        widthRow.orientation = .horizontal
        widthRow.alignment = .centerY
        widthRow.spacing = 8
        widthRow.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 140).isActive = true

        // Font controls (text tool).
        let familyPopup = NSPopUpButton()
        familyPopup.addItems(withTitles: AnnotationFontFamily.allCases.map(\.displayName))
        familyPopup.font = .systemFont(ofSize: 11)
        familyPopup.target = self
        familyPopup.action = #selector(fontFamilyChanged(_:))
        familyPopup.translatesAutoresizingMaskIntoConstraints = false
        familyPopup.widthAnchor.constraint(equalToConstant: 88).isActive = true
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
        plateButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        backplateButton = plateButton

        // Style presets: opens the rich popover of WYSIWYG style swatches (regular,
        // bold, italic, bold+italic, backplate, outlined).
        let styleBtn = NSButton(image: NSImage(systemSymbolName: "textformat", accessibilityDescription: "Text styles")!,
                                target: self, action: #selector(styleButtonTapped(_:)))
        styleBtn.bezelStyle = .texturedRounded
        styleBtn.imagePosition = .imageOnly
        styleBtn.toolTip = "Text styles"
        styleBtn.translatesAutoresizingMaskIntoConstraints = false
        styleBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true
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
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        btn.translatesAutoresizingMaskIntoConstraints = false
        if isPrimary {
            btn.keyEquivalent = "\r"
            btn.bezelColor = KritColors.accent
        }
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
        btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
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
        contextWidthRow?.isHidden = isText
        contextFontRow?.isHidden = !isText
        // The secure toggle only makes sense for the blur tool; the width slider
        // is shared with the other drawing tools.
        secureBlurButton?.isHidden = (tool != .blur)
        // Properties band chip: name the tool the band is configuring.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        toolChipIcon?.image = NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        toolChipLabel?.stringValue = String(tool.tooltip.split(separator: "(").first ?? "")
            .trimmingCharacters(in: .whitespaces)
        selectedTool = tool
        // Exclusive selection across the whole strip (and the bordered crop in the
        // canvas group): light the active tool's button, clear every other one.
        for (candidate, button) in toolButtons {
            button.isSelectedTool = (candidate == tool)
        }
    }

    /// Preview mode (the Snapzy editor-mode toggle): hides every editing
    /// control in both bands, keeping only Save as/Done, so the header reads
    /// as plain chrome while the user inspects the final result.
    func setPreviewMode(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            canvasGroup?.animator().isHidden = on
            headerDivider?.animator().isHidden = on
            toolStripView?.animator().isHidden = on
            propertiesStack?.animator().isHidden = on
        }
    }

    /// Contextual action slot: while a crop region is staged, Save as/Done fade
    /// out and Cancel/Apply fade in (NSStackView collapses the hidden pair).
    func setCropApplyVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
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
        // Item 4: only the arrow drives the persisted global default (its bold size
        // is the editor's signature). Other tools keep their thickness in the
        // canvas's in-session per-tool memory, set via onLineWidthChanged, so they
        // don't overwrite the arrow's saved default.
        if selectedTool == .arrow {
            Settings.annotationLineWidth = sender.doubleValue
        }
        onLineWidthChanged?(CGFloat(sender.doubleValue))
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
final class FlatToolButton: NSButton {
    let tool: AnnotationTool
    /// Draw a chrome pad even when not selected (canvas-group crop). The flat
    /// strip tools leave this false, so they show only the bare glyph.
    var isBorderedTool = false { didSet { needsDisplay = true } }
    var isSelectedTool = false { didSet { needsDisplay = true } }

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
        translatesAutoresizingMaskIntoConstraints = false
        // 28x28 flat hit target, the CleanShot strip footprint.
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Pad: drawn when selected (mono contrast pad) or when this is a bordered
        // canvas-group tool (faint chrome pad even at rest).
        let pad = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = 6
        if isSelectedTool {
            let path = NSBezierPath(roundedRect: pad, xRadius: radius, yRadius: radius)
            KritColors.toolSelectedFill.setFill()
            path.fill()
        } else if isBorderedTool {
            let path = NSBezierPath(roundedRect: pad, xRadius: radius, yRadius: radius)
            KritColors.editorActionBackground.setFill()
            path.fill()
            KritColors.editorDockBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        guard let glyph else { return }
        let tint = isSelectedTool
            ? KritColors.toolSelectedGlyph
            : KritColors.toolInactiveGlyph
        let tinted = glyph.tinted(with: tint)
        let size = tinted.size
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

// MARK: - Chrome toggle button (canvas group)

/// A bordered toggle in the canvas group (background panel, smart redact). It
/// always draws a chrome pad (the bordered CleanShot canvas group); when active
/// it fills coral with a white glyph (CleanShot tints this blue). Custom-drawn so
/// the active state is a real fill, not just a tint over a native bezel.
@MainActor
final class ChromeToggleButton: NSButton {
    var isActive = false { didSet { needsDisplay = true } }
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let pad = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: pad, xRadius: 6, yRadius: 6)
        if isActive {
            KritColors.accent.setFill()
            path.fill()
        } else {
            KritColors.editorActionBackground.setFill()
            path.fill()
            KritColors.editorDockBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        guard let glyph, !hidesGlyph else { return }
        let tint = isActive ? NSColor.white : KritColors.toolInactiveGlyph
        let tinted = glyph.tinted(with: tint)
        let size = tinted.size
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        // Independent toggle: flip on click (the controller may override via
        // isActive), then fire the action. AppKit's pushOnPushOff is bypassed
        // because the button is custom-drawn; the controller owns the truth.
        sendAction(action, to: target)
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

/// The editor's bottom bar: zoom popup (left), a "Drag me" pill that drags the
/// edited flattened image out as a file (center), and the Share / Pin / Copy /
/// Save cluster (right, Save tinted coral as the primary). A small "Save as…"
/// secondary sits beside Save (ES6). Spans the window width; the controller
/// positions it via layoutStage.
@MainActor
final class EditorBottomBar: NSView {

    var onZoomChanged: ((CGFloat) -> Void)?
    var onZoomFit: (() -> Void)?
    var onRequestDragImage: (() -> NSImage?)?
    var onDragDelivered: (() -> Void)?
    var onShare: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Fired when the Annotate/Preview segmented control flips (the Snapzy
    /// editor-mode toggle). true = preview (editing chrome hidden).
    var onPreviewModeChanged: ((Bool) -> Void)?

    private let zoomPopup = NSPopUpButton()
    private let modeControl = NSSegmentedControl(labels: ["Annotate", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private var shareButton: NSButton?
    private var sharePicker: NSSharingServicePicker?
    private var dragPill: BottomBarDragPill?
    private var actionCluster: NSStackView?

    // Zoom presets: explicit % plus a "Fit" entry that re-fits the composition.
    private static let zoomPercents: [Int] = [35, 50, 75, 100]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        // The bottom bar is the BOTTOM ARM of the continuous L-shaped chrome
        // (EditorChromeBackdrop provides the material). It owns no material/hairline
        // of its own, so the footer and the sidebar flow as one piece. The hairline
        // that borders the canvas is drawn by the stage, not here.

        // Left: zoom popup. Native rounded pop-up at the same regular control size
        // as the cluster buttons, so every footer control shares one Apple ruler.
        zoomPopup.translatesAutoresizingMaskIntoConstraints = false
        zoomPopup.controlSize = .regular
        zoomPopup.bezelStyle = .rounded
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChanged(_:))
        zoomPopup.removeAllItems()
        for pct in Self.zoomPercents { zoomPopup.addItem(withTitle: "\(pct)%") }
        zoomPopup.addItem(withTitle: "Fit")
        zoomPopup.selectItem(withTitle: "Fit")
        addSubview(zoomPopup)
        NSLayoutConstraint.activate([
            zoomPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            zoomPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomPopup.widthAnchor.constraint(equalToConstant: 88),
        ])

        // Annotate/Preview mode toggle beside the zoom popup (Snapzy's editor
        // mode switch). Preview hides every piece of editing chrome so the user
        // sees exactly what exports.
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = 0
        modeControl.controlSize = .regular
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeControl)
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: zoomPopup.trailingAnchor, constant: 10),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Center: Drag me pill. Degrades gracefully when the window narrows
        // (full -> grip-only -> hidden) so it never overlaps the side zones;
        // layout() below measures the real central slack each pass.
        let pill = BottomBarDragPill()
        pill.imageProvider = { [weak self] in self?.onRequestDragImage?() }
        pill.onDragDelivered = { [weak self] in self?.onDragDelivered?() }
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        dragPill = pill

        // Right: action cluster.
        let cluster = NSStackView()
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 8
        cluster.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cluster)
        NSLayoutConstraint.activate([
            cluster.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cluster.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Footer cluster: Share, Pin, Copy only, like CleanShot's footer (share /
        // pin / copy / cloud). Saving lives entirely in the header ("Save as…" and
        // "Done"); a second "Save" down here was a duplicate the owner flagged.
        let share = iconButton(symbol: "square.and.arrow.up", tooltip: "Share", action: #selector(shareTapped))
        shareButton = share
        cluster.addArrangedSubview(share)
        cluster.addArrangedSubview(iconButton(symbol: "pin", tooltip: "Pin to desktop", action: #selector(pinTapped)))
        cluster.addArrangedSubview(iconButton(symbol: "doc.on.doc", tooltip: "Copy", action: #selector(copyTapped)))
        actionCluster = cluster
    }

    /// Measures the real central slack between the zoom popup (left zone) and
    /// the action cluster (right zone) and degrades the centered drag pill:
    /// full label, grip only, or gone. The Snapzy footer pattern, in AppKit.
    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onPreviewModeChanged?(sender.selectedSegment == 1)
    }

    override func layout() {
        super.layout()
        guard let pill = dragPill else { return }
        let leftEdge = max(zoomPopup.frame.maxX, modeControl.frame.maxX)
        let rightEdge = actionCluster?.frame.minX ?? bounds.maxX
        let margin: CGFloat = 12   // breathing room on each side of the pill
        // The pill is pinned to centerX, so its usable half-slack is limited by
        // the NEAREST zone edge; the symmetric slack is twice that.
        let halfSlack = min(bounds.midX - leftEdge, rightEdge - bounds.midX) - margin
        let available = max(0, halfSlack * 2)
        let newMode: BottomBarDragPill.PillMode
        if available >= BottomBarDragPill.fullWidth { newMode = .full }
        else if available >= BottomBarDragPill.compactWidth { newMode = .compact }
        else { newMode = .hidden }
        pill.setMode(newMode)
    }

    /// A native rounded icon button (Share / Pin / Copy). Native bezel sizes its
    /// own height, so the whole cluster shares the system ruler with the Save
    /// button and the zoom pop-up; the symbol is centered by AppKit. A fixed width
    /// keeps the three icon buttons identical instead of each hugging its glyph.
    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 40).isActive = true
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

    /// Anchor for the share picker presented from the bar's Share button.
    func presentSharePicker(items: [Any]) {
        let anchor = shareButton ?? self
        let picker = NSSharingServicePicker(items: items)
        sharePicker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

// MARK: - Bottom bar "Drag me" pill (ES4)

/// A pill that drags the edited flattened image out as a real file, reusing the
/// proven overlay/HistoryPanel pattern: a plain file URL (Finder, most apps) plus
/// an NSFilePromiseProvider fallback (Slack, Mail, browsers).
///
/// HIG note: this is NOT a glass surface. The pill is a control hosted on the
/// footer, which is the bottom arm of the L-chrome material, so it sits ON
/// material, not floating over the content stage. Glass over material is
/// forbidden, so it keeps a flat fill that matches the other footer controls.
@MainActor
private final class BottomBarDragPill: NSView, NSDraggingSource {

    var imageProvider: (() -> NSImage?)?
    /// Fired when a drag-out lands on a real drop target (operation != []).
    var onDragDelivered: (() -> Void)?

    /// Graceful degradation under narrow windows (the Snapzy footer pattern):
    /// full (grip + label), compact (grip only), hidden (zero width) so the
    /// centered pill never overlaps the zoom popup or the action cluster.
    enum PillMode { case full, compact, hidden }
    private(set) var mode: PillMode = .full

    static let fullWidth: CGFloat = 116
    static let compactWidth: CGFloat = 36

    func setMode(_ newMode: PillMode) {
        guard newMode != mode else { return }
        mode = newMode
        isHidden = newMode == .hidden
        widthConstraint?.constant = newMode == .compact ? Self.compactWidth : Self.fullWidth
        toolTip = newMode == .compact ? "Drag me: drag the edited image out" : "Drag the edited image out"
        needsDisplay = true
    }

    private var widthConstraint: NSLayoutConstraint?
    private var dragOrigin: NSPoint?
    private var activeDragFileURL: URL?
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Sized to read as a peer of the native rounded footer buttons (~21pt
        // tall): the pill stays custom because it is a drag SOURCE (NSDraggingSource
        // can't ride a stock NSButton cleanly), but it sits on the same ruler.
        let width = widthAnchor.constraint(equalToConstant: Self.fullWidth)
        width.isActive = true
        widthConstraint = width
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolTip = "Drag the edited image out"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        // 6pt corner matches the native rounded button bezel beside it; the fill
        // is the shared footer-control color so the pill reads as a peer.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (hovering ? KritColors.cornerButtonHover : KritColors.editorActionBackground).setFill()
        path.fill()
        KritColors.editorDockBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        let title = "Drag me"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.86),
        ]
        // Grip dots (2x3), the universal "this can be dragged" affordance and
        // the same visual language as the recording preflight's grip. A doc
        // icon said "file", the dots say "grab here". Compact mode keeps only
        // the grip, centered.
        let showLabel = mode == .full
        let textSize = showLabel ? (title as NSString).size(withAttributes: attrs) : .zero
        let dotRadius: CGFloat = 1.2
        let dotStep: CGFloat = 4.4
        let gripW = dotStep + dotRadius * 2
        let gripH = dotStep * 2 + dotRadius * 2
        let gap: CGFloat = showLabel ? 6 : 0
        let totalW = gripW + gap + textSize.width
        var x = bounds.midX - totalW / 2
        NSColor.labelColor.withAlphaComponent(0.5).setFill()
        let gripTop = bounds.midY - gripH / 2
        for column in 0..<2 {
            for row in 0..<3 {
                let dot = NSRect(
                    x: x + CGFloat(column) * dotStep,
                    y: gripTop + CGFloat(row) * dotStep,
                    width: dotRadius * 2, height: dotRadius * 2
                )
                NSBezierPath(ovalIn: dot).fill()
            }
        }
        if showLabel {
            x += gripW + gap
            (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - textSize.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let dragImg = imageProvider?() else { return }
        let current = event.locationInWindow
        guard abs(current.x - origin.x) > 3 || abs(current.y - origin.y) > 3 else { return }
        dragOrigin = nil

        guard let png = ImageExporter.pngData(from: dragImg),
              let fileURL = DragFileVault.makeFile(data: png) else { return }
        activeDragFileURL = fileURL

        // The drag preview reads as a file card, not a raw bitmap: rounded
        // corners and a hairline keep a dark screenshot from looking like a
        // broken black rectangle while it rides the cursor.
        let preview = NSImage(size: NSSize(width: 120, height: 120 * (dragImg.size.height / max(dragImg.size.width, 1))))
        preview.lockFocus()
        let previewRect = NSRect(origin: .zero, size: preview.size)
        let previewClip = NSBezierPath(roundedRect: previewRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        previewClip.addClip()
        dragImg.draw(in: previewRect)
        NSColor.white.withAlphaComponent(0.3).setStroke()
        previewClip.lineWidth = 1
        previewClip.stroke()
        preview.unlockFocus()

        let fileItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        fileItem.setDraggingFrame(bounds, contents: preview)
        let promise = NSFilePromiseProvider(fileType: "public.png", delegate: BottomBarFilePromiseDelegate(image: dragImg))
        let promiseItem = NSDraggingItem(pasteboardWriter: promise)
        promiseItem.setDraggingFrame(bounds, contents: preview)

        beginDraggingSession(with: [fileItem, promiseItem], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = self.activeDragFileURL {
                self.activeDragFileURL = nil
                DragFileVault.scheduleCleanup(url)
            }
            // A drop somewhere real means the user TOOK the result, the editor's
            // job is done, so it closes (CleanShot behavior). A cancelled drag
            // (operation == []) keeps editing.
            if operation != [] { self.onDragDelivered?() }
        }
    }
}

private final class BottomBarFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Krit.BottomBarFilePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let image: NSImage
    init(image: NSImage) { self.image = image }

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

// MARK: - UI test harness hooks
// Exposição mínima pro UITestRunner validar comportamento real (estado, não
// leitura de código). Só leitura/ações já existentes; nada de lógica nova.
extension AnnotationWindowController {
    static var uiTestLastController: AnnotationWindowController? { openControllers.last }
    var uiTestCanvas: AnnotationCanvas { canvas }
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
    var uiTestSidebar: BackgroundSidebar? { backgroundSidebar }
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
