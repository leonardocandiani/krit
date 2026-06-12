import AppKit

/// The main drawing surface for the annotation editor.
/// Handles tool interaction, renders all annotation objects, and manages undo.
@MainActor
final class AnnotationCanvas: NSView {

    // MARK: - State

    var backgroundImage: NSImage?
    var objects: [any AnnotationObject] = []
    var selectedObjects: [any AnnotationObject] = []
    var activeTool: AnnotationTool = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
            // Per-tool thickness memory (item 4): each tool carries its own line
            // width, so switching tools restores that tool's last size and the
            // slider can follow. The arrow keeps the full default (its identity);
            // the rest start thinner via lineWidth(for:).
            if oldValue != activeTool {
                activeLineWidth = lineWidth(for: activeTool)
                onActiveLineWidthChanged?(activeLineWidth)
            }
            // Item 2: picking crop drops the user straight into crop mode with the
            // region already covering the whole shot (photo-editor style), so the
            // handles are live immediately, no need to draw a rect from scratch.
            if oldValue != activeTool, activeTool == .crop {
                enterCropModeFullImage()
            }
            // Highlighter snaps onto detected text, so warm the OCR cache the moment
            // the tool is picked. Detection runs in the background; if the user
            // starts dragging before it lands, the highlighter falls back to a free
            // band (see beginTextHighlightSnapping).
            if oldValue != activeTool, activeTool == .highlighter {
                prepareTextDetection()
            }
            onToolChanged?(activeTool)
        }
    }
    var activeColor: NSColor = KritColors.accent
    var activeLineWidth: CGFloat = CGFloat(Settings.annotationLineWidth)
    var activeFontFamily: AnnotationFontFamily = .system
    var activeFontSize: CGFloat = 24
    var activeFontWeight: NSFont.Weight = .bold
    var activeItalic: Bool = false
    var activeBackplate: TextBackplate = .none
    var activeOutline: Bool = false
    // When on, new blur strokes are created as secure blur (irreversible mosaic)
    // instead of a recoverable gaussian. Toggled from the blur tool's context row.
    var activeBlurSecure: Bool = false

    /// Per-tool line-width memory (item 4): only tools the user has touched with
    /// the slider get an entry; everything else derives its default from
    /// `lineWidth(for:)` so the arrow stays bold and the rest start finer.
    private var toolLineWidths: [AnnotationTool: CGFloat] = [:]

    /// The default thickness for a freshly opened tool. The arrow uses the full
    /// global default (bold, its signature); every other stroke tool starts at
    /// 60% of it, floored at 2pt, so lines/rects/ellipses/freehand read finer.
    private func lineWidth(for tool: AnnotationTool) -> CGFloat {
        if let remembered = toolLineWidths[tool] { return remembered }
        let base = CGFloat(Settings.annotationLineWidth)
        switch tool {
        case .arrow:
            return base
        default:
            return max(base * 0.6, 2)
        }
    }

    var onToolChanged: ((AnnotationTool) -> Void)?
    /// Fires when the active line width changes because the tool changed, so the
    /// toolbar slider can track the per-tool default without a feedback loop.
    var onActiveLineWidthChanged: ((CGFloat) -> Void)?
    var onSelectionChanged: (([any AnnotationObject]) -> Void)?
    /// Fires whenever the Smart Redact preview is staged or cleared, so the
    /// controller can reflect the apply/cancel affordance and pending state.
    var onSmartRedactStateChanged: ((_ hasPreview: Bool) -> Void)?
    /// ES7: fires whenever the live magnification changes (pinch, ⌘±, fit, popup),
    /// so the bottom-bar zoom popup stays in sync with the canvas.
    var onMagnificationChanged: ((CGFloat) -> Void)?

    // Undo/redo managed via undoSnapshots/redoSnapshots below

    // In-progress drawing state
    private var currentObject: (any AnnotationObject)?
    private var dragStart: CGPoint?
    private var lastDragPoint: CGPoint?

    // Highlighter OCR snapping: detected text lines per image, cached. During a
    // highlighter drag, lines the drag crosses turn into a fixed-rect
    // TextHighlightAnnotation; if no text is hit, the free band stands.
    private let textRegionDetector = TextRegionDetector()
    /// Extra vertical breathing room added to each snapped line, so the highlight
    /// fully covers ascenders/descenders instead of clipping the glyphs.
    private let textHighlightVerticalPadding: CGFloat = 2

    // Smart Redact: pending preview boxes (canvas view rects) with their category
    // label, shown as translucent red overlays before the user confirms. Empty
    // means no preview is active. Confirm turns each into a real PixelateAnnotation
    // (undoable); cancel just clears these.
    struct SmartRedactPreview {
        let rect: CGRect
        let label: String
    }
    private(set) var smartRedactPreviews: [SmartRedactPreview] = []
    /// Padding added around each detected line before redaction, so the cover
    /// fully eats the glyphs (ascenders/descenders and a little side margin)
    /// instead of leaving a readable sliver at the edges.
    private let smartRedactPadding: CGFloat = 3

    // Smart Redact banner: a floating bar at the bottom of the viewport that
    // makes applying the staged redaction discoverable ("Redact all" / "Cancel"
    // instead of a hidden Enter). It is hosted as an NSScrollView floating
    // subview, a sibling above the clip view, so it stays at a fixed on-screen
    // size: the clip view is what NSScrollView magnifies, and the banner is
    // chrome that must not zoom with the artwork. Reposition is driven by the
    // clip view's bounds (scroll, magnification) and frame (viewport resize)
    // notifications.
    private var smartRedactBanner: SmartRedactBanner?
    private var smartRedactBannerClipObserver: NSObjectProtocol?
    private var smartRedactBannerFrameObserver: NSObjectProtocol?
    /// Cancels a pending auto-dismiss of the "no findings" banner if the bar is
    /// torn down (or replaced) before the timer fires.
    private var smartRedactBannerDismissWork: DispatchWorkItem?

    // Text editing
    private var activeTextField: NSTextField?
    // Floating emoji button shown above the inline editor while typing. Clicking
    // it opens the native macOS character palette, which inserts the picked emoji
    // into the first responder (the text field) at the caret. Created with the
    // editor, follows it as the field grows/moves, torn down on commit.
    private var emojiButton: NSButton?
    // Local mouse monitor alive only while the inline editor is: a click
    // anywhere outside the field commits the text, so toolbar controls (style
    // presets, font changes) apply on click instead of demanding Return first.
    private var textCommitClickMonitor: Any?

    // Crop overlay
    var cropRect: CGRect?
    var onCropChanged: ((CGRect?) -> Void)?
    /// Fired when the user commits the crop from inside the canvas
    /// (Return/Enter or double-click in the region). The controller runs the
    /// same path as the toolbar check button.
    var onCropCommit: (() -> Void)?
    var backgroundOptions = ScreenshotBackgroundOptions.editorDefault
    private var cachedPresentationImage: NSImage?
    private var cachedPresentationSource: NSImage?
    private var cachedPresentationOptions: ScreenshotBackgroundOptions?
    private var cachedPresentationSize: NSSize = .zero

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer = smartRedactBannerClipObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = smartRedactBannerFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = textCommitClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true } // Easier coordinate math (top-left origin)

    // Space toggles a transient pan mode, reset on keyUp. If the canvas loses
    // first-responder while Space is held (alert, sheet, popover, app switch), that
    // keyUp never arrives and the canvas would be stuck in pan mode forever. Clear
    // it on resign so the next mouseDown draws/selects normally.
    override func resignFirstResponder() -> Bool {
        clearSpacePan()
        return super.resignFirstResponder()
    }

    private func clearSpacePan() {
        guard spaceDown else { return }
        spaceDown = false
        panAnchor = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Cursor Management

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        switch activeTool {
        case .select:                                      cursor = .arrow
        case .arrow, .rectangle, .filledRectangle, .ellipse: cursor = .crosshair
        case .line, .freehand, .highlighter:               cursor = .crosshair
        case .text:                                        cursor = .iBeam
        case .numberedStep:                                cursor = .pointingHand
        case .blur, .pixelate, .crop:                      cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Screenshot and optional presentation background
        if let img = backgroundImage {
            drawBackgroundImage(img, ctx: ctx)
        }

        // 2. Blur and pixelate (CIFilter applied to background region)
        for obj in objects {
            if let blur = obj as? BlurAnnotation {
                drawBlur(blur, ctx: ctx)
            } else if let px = obj as? PixelateAnnotation {
                drawPixelate(px, ctx: ctx)
            }
        }

        // 3. All other annotations (skip the one being edited in place)
        for obj in objects {
            if obj is BlurAnnotation || obj is PixelateAnnotation { continue }
            if let editing = editingTextAnnotation, editing.id == obj.id { continue }
            obj.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
        }

        // 4. In-progress object. Blur/pixelate render no-op through `draw`, so route
        // the one being dragged through the live-effect path, otherwise the region
        // reads as empty while you create or resize it.
        if let blur = currentObject as? BlurAnnotation {
            drawBlur(blur, ctx: ctx)
        } else if let px = currentObject as? PixelateAnnotation {
            drawPixelate(px, ctx: ctx)
        } else if let band = currentObject as? HighlighterAnnotation {
            // Highlighter previews the OCR snap live: if the drag is crossing
            // detected text, show the fixed line rects instead of the free band so
            // the user sees exactly what will be highlighted. No text under the
            // drag (or detection not ready) keeps the free stroke.
            let snapped = snappedTextHighlightRects(for: band)
            if snapped.isEmpty {
                band.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
            } else {
                let preview = TextHighlightAnnotation(rects: snapped)
                preview.color = band.color
                preview.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
            }
        } else {
            currentObject?.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
        }

        // 5. Selection handles
        for obj in selectedObjects {
            drawSelectionHandle(for: obj, ctx: ctx)
        }

        // 6. Crop overlay
        if let crop = cropRect {
            drawCropOverlay(crop, ctx: ctx)
        }

        // 6b. Smart Redact preview: translucent red boxes over each pending
        // finding, with a small category chip, so the user sees exactly what
        // Apply will cover before committing.
        if !smartRedactPreviews.isEmpty {
            drawSmartRedactPreviews(ctx: ctx)
        }

        // 7. Precision chrome: marquee rect (B1) and smart-guide lines (B3).
        if let marquee = marqueeRect {
            drawMarquee(marquee, ctx: ctx)
        }
        if !activeGuides.isEmpty {
            drawGuides(ctx: ctx)
        }
    }

    // Coral translucent selection rect drawn while marquee-dragging on empty canvas.
    private func drawMarquee(_ rect: CGRect, ctx: CGContext) {
        guard !rect.isEmpty else { return }
        let accent = KritColors.accent
        let aligned = pixelAligned(rect, scale: max(window?.backingScaleFactor ?? 2, 1))
        ctx.saveGState()
        ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        ctx.fill(aligned)
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1 / max(enclosingScrollView?.magnification ?? 1, 0.01))
        ctx.stroke(aligned)
        ctx.restoreGState()
    }

    // Full-span coral alignment lines while snapping (B3).
    private func drawGuides(ctx: CGContext) {
        let accent = KritColors.accent.withAlphaComponent(0.9)
        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1 / max(enclosingScrollView?.magnification ?? 1, 0.01))
        for guide in activeGuides {
            switch guide.axis {
            case .vertical:
                let x = (guide.position * (window?.backingScaleFactor ?? 2)).rounded() / (window?.backingScaleFactor ?? 2)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            case .horizontal:
                let y = (guide.position * (window?.backingScaleFactor ?? 2)).rounded() / (window?.backingScaleFactor ?? 2)
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawBackgroundImage(_ image: NSImage, ctx: CGContext) {
        // High-quality resampling so a small or zoomed-in capture renders smooth
        // instead of blocky when the canvas scales it past its native pixels.
        ctx.interpolationQuality = .high
        NSGraphicsContext.current?.imageInterpolation = .high

        guard backgroundOptions.isEnabled else {
            image.draw(in: bounds)
            return
        }

        presentationImage(for: image).draw(in: bounds)
    }

    private func presentationImage(for image: NSImage) -> NSImage {
        if let cachedPresentationImage,
           cachedPresentationSource === image,
           cachedPresentationOptions == backgroundOptions,
           cachedPresentationSize == bounds.size {
            return cachedPresentationImage
        }

        let composed = ScreenshotBackgroundComposer.composeIfNeeded(image, options: backgroundOptions)
        cachedPresentationImage = composed
        cachedPresentationSource = image
        cachedPresentationOptions = backgroundOptions
        cachedPresentationSize = bounds.size
        return composed
    }

    private func backgroundImageRect(for image: NSImage) -> CGRect {
        guard backgroundOptions.isEnabled else { return bounds }
        // Single source of truth: the composer returns the EXACT slot rect (padding,
        // inset, alignment, aspect, pixel-snap) where it drew the screenshot. The
        // old local approximation drifted from the render once inset/alignment/aspect
        // came into play, which is what knocked blur/pixelate out of registration.
        return ScreenshotBackgroundComposer.imageSlotRect(
            imageSize: image.size, canvasSize: bounds.size, options: backgroundOptions
        )
    }

    private func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }

    /// Convert a view rect (flipped, top-left origin) to CGImage coordinates (also top-left origin).
    private func viewRectToCGImageRect(_ viewRect: CGRect, imageSize: CGSize) -> CGRect? {
        guard let backgroundImage else { return nil }
        let imageRect = backgroundImageRect(for: backgroundImage)
        let clipped = viewRect.intersection(imageRect)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        let scaleX = imageSize.width / imageRect.width
        let scaleY = imageSize.height / imageRect.height
        return CGRect(
            x: (clipped.origin.x - imageRect.origin.x) * scaleX,
            y: (clipped.origin.y - imageRect.origin.y) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )
    }

    // MARK: - Highlighter OCR snapping

    /// Warm the text-detection cache for the current image (called when the
    /// highlighter tool is picked). When results land, only refresh if the
    /// highlighter is still active and a drag is in progress, so a freshly drawn
    /// band can snap as soon as detection finishes.
    private func prepareTextDetection() {
        guard let backgroundImage else { return }
        textRegionDetector.detect(in: backgroundImage) { [weak self] in
            guard let self, self.activeTool == .highlighter, self.dragStart != nil else { return }
            self.setNeedsDisplay(self.bounds)
        }
    }

    /// Convert a Vision boundingBox (normalized, BOTTOM-LEFT origin, relative to
    /// the image) into a canvas view rect (flipped, top-left origin). This is the
    /// inverse of `viewRectToCGImageRect`: it rides the SAME slot rect that blur/
    /// pixelate use (`backgroundImageRect`), only flipping y for Vision's
    /// bottom-left convention so the highlight lands exactly over the writing.
    private func textLineViewRect(_ normalizedBox: CGRect) -> CGRect? {
        guard let backgroundImage else { return nil }
        let slot = backgroundImageRect(for: backgroundImage)
        guard slot.width > 0, slot.height > 0 else { return nil }
        let x = slot.minX + normalizedBox.minX * slot.width
        // Vision y grows upward from the image bottom; the canvas y grows downward
        // from the image top. The box top in normalized image space is
        // (minY + height); its distance from the image top is 1 - that.
        let topFraction = 1 - (normalizedBox.minY + normalizedBox.height)
        let y = slot.minY + topFraction * slot.height
        return CGRect(
            x: x,
            y: y,
            width: normalizedBox.width * slot.width,
            height: normalizedBox.height * slot.height
        )
    }

    /// The straight highlight rects for the lines the free band crosses, or an
    /// empty array when no detected text falls under the band (caller then keeps
    /// the free stroke). The band is treated as its bounding rect so a roughly
    /// horizontal swipe grabs the whole line it sweeps over.
    private func snappedTextHighlightRects(for band: HighlighterAnnotation) -> [CGRect] {
        guard let backgroundImage,
              let lines = textRegionDetector.lines(for: backgroundImage),
              !lines.isEmpty else { return [] }

        let half = band.lineWidth / 2
        let bandRect = CGRect(
            x: min(band.startPoint.x, band.endPoint.x),
            y: min(band.startPoint.y, band.endPoint.y) - half,
            width: abs(band.endPoint.x - band.startPoint.x),
            height: abs(band.endPoint.y - band.startPoint.y) + band.lineWidth
        )

        var rects: [CGRect] = []
        for line in lines {
            guard let lineRect = textLineViewRect(line.normalizedBox) else { continue }
            guard lineRect.intersects(bandRect) else { continue }
            let padded = lineRect.insetBy(dx: 0, dy: -textHighlightVerticalPadding)
            rects.append(clampRectToCanvas(padded))
        }
        return rects
    }

    /// Pulls a snapped highlight rect fully inside the canvas, mirroring the
    /// clamp the free shapes get so OCR rects never spill past the export edge.
    private func clampRectToCanvas(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let minX = max(standardized.minX, bounds.minX)
        let minY = max(standardized.minY, bounds.minY)
        let maxX = min(standardized.maxX, bounds.maxX)
        let maxY = min(standardized.maxY, bounds.maxY)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    // MARK: - Smart Redact

    /// Runs OCR + the local secret classifier on the current screenshot and stages
    /// a redaction preview (red boxes + category chips) for every finding. Returns
    /// the number of findings staged, so the caller can show a "nothing found"
    /// toast when it is zero. Detection runs off the main thread inside the
    /// detector; only the preview update touches the canvas, back on the main
    /// actor. Nothing is committed here, the user confirms with `applySmartRedact`.
    func runSmartRedact() async -> Int {
        guard let backgroundImage else { return 0 }
        let lines = await textRegionDetector.recognizedLines(for: backgroundImage)
        guard !lines.isEmpty else {
            smartRedactPreviews = []
            onSmartRedactStateChanged?(false)
            showSmartRedactBanner(mode: .empty)
            setNeedsDisplay(bounds)
            return 0
        }

        // Feed the classifier image-pixel boxes (its documented input space). The
        // box is carried through untouched, so each finding comes back with the
        // exact rects we sent and we map them onto the canvas afterwards.
        let pixelSize = imagePixelSize(of: backgroundImage)
        let classifierLines: [SecretClassifier.Line] = lines.compactMap { line in
            guard !line.text.isEmpty else { return nil }
            return SecretClassifier.Line(
                text: line.text,
                box: imagePixelRect(fromNormalized: line.normalizedBox, pixelSize: pixelSize)
            )
        }
        let findings = SecretClassifier.classify(lines: classifierLines)

        var previews: [SmartRedactPreview] = []
        for finding in findings {
            for box in finding.boxes {
                guard let viewRect = viewRect(fromImagePixelRect: box, pixelSize: pixelSize) else { continue }
                let padded = clampRectToCanvas(viewRect.insetBy(dx: -smartRedactPadding, dy: -smartRedactPadding))
                guard padded.width >= 1, padded.height >= 1 else { continue }
                previews.append(SmartRedactPreview(rect: padded, label: finding.category.label))
            }
        }

        smartRedactPreviews = previews
        onSmartRedactStateChanged?(!previews.isEmpty)
        if previews.isEmpty {
            showSmartRedactBanner(mode: .empty)
        } else {
            showSmartRedactBanner(mode: .findings(count: previews.count))
        }
        setNeedsDisplay(bounds)
        return previews.count
    }

    /// Confirms the staged preview: each red box becomes a real pixelate
    /// annotation, pushed as one undoable edit so a single Cmd-Z removes the whole
    /// batch. Clears the preview afterwards. No-op when nothing is staged.
    func applySmartRedact() {
        guard !smartRedactPreviews.isEmpty else { return }
        pushUndo()
        for preview in smartRedactPreviews {
            let px = PixelateAnnotation(rect: preview.rect.standardized)
            objects.append(px)
        }
        smartRedactPreviews = []
        onSmartRedactStateChanged?(false)
        hideSmartRedactBanner()
        setSelection([])
        setNeedsDisplay(bounds)
    }

    /// Discards the staged preview without redacting anything.
    func cancelSmartRedact() {
        guard !smartRedactPreviews.isEmpty else { return }
        smartRedactPreviews = []
        onSmartRedactStateChanged?(false)
        hideSmartRedactBanner()
        setNeedsDisplay(bounds)
    }

    var hasSmartRedactPreview: Bool { !smartRedactPreviews.isEmpty }

    // MARK: - Smart Redact banner

    /// Bottom margin between the banner and the viewport's lower edge.
    private let smartRedactBannerBottomInset: CGFloat = 20
    /// How long the "no sensitive content found" banner lingers before it fades
    /// itself out, so a zero-finding pass reads as feedback, not as silence.
    private let smartRedactEmptyBannerDuration: TimeInterval = 2.0

    /// Shows (or re-targets) the redaction banner over the viewport. Hosted as a
    /// scroll view floating subview so it keeps a fixed on-screen size while the
    /// canvas underneath zooms and scrolls (the clip view is what magnifies, the
    /// banner must not). The `.empty` mode auto-dismisses; the `.findings` mode
    /// stays until the user picks "Redact all" or "Cancel" (or presses Enter/Esc,
    /// which run the same paths).
    private func showSmartRedactBanner(mode: SmartRedactBanner.Mode) {
        guard let scrollView = enclosingScrollView else { return }
        smartRedactBannerDismissWork?.cancel()
        smartRedactBannerDismissWork = nil

        let banner: SmartRedactBanner
        if let existing = smartRedactBanner {
            existing.update(mode: mode)
            banner = existing
        } else {
            banner = SmartRedactBanner(mode: mode)
            banner.onRedactAll = { [weak self] in self?.applySmartRedact() }
            banner.onCancel = { [weak self] in self?.cancelSmartRedact() }
            // A floating subview lives above the clip view in the scroll view's
            // own (unscaled) coordinate space, so magnification never touches it.
            // Pinning to .vertical keeps it stuck while the document scrolls.
            scrollView.addFloatingSubview(banner, for: .vertical)
            smartRedactBanner = banner
            observeClipBoundsForSmartRedactBanner(scrollView.contentView)
        }

        repositionSmartRedactBanner()

        if case .empty = mode {
            let work = DispatchWorkItem { [weak self] in self?.hideSmartRedactBanner() }
            smartRedactBannerDismissWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + smartRedactEmptyBannerDuration,
                execute: work
            )
        }
    }

    /// Tears the banner down and stops following the clip view. Idempotent.
    private func hideSmartRedactBanner() {
        smartRedactBannerDismissWork?.cancel()
        smartRedactBannerDismissWork = nil
        if let observer = smartRedactBannerClipObserver {
            NotificationCenter.default.removeObserver(observer)
            smartRedactBannerClipObserver = nil
        }
        if let observer = smartRedactBannerFrameObserver {
            NotificationCenter.default.removeObserver(observer)
            smartRedactBannerFrameObserver = nil
        }
        smartRedactBanner?.removeFromSuperview()
        smartRedactBanner = nil
    }

    /// Centers the banner horizontally over the visible viewport and pins it just
    /// above the viewport's bottom edge, so it never covers the marked findings up
    /// top. The banner is a floating subview, so positions are in the scroll
    /// view's own coordinate space (the clip view's frame is the live viewport
    /// there) and stay at a fixed on-screen scale regardless of magnification.
    private func repositionSmartRedactBanner() {
        guard let banner = smartRedactBanner,
              let scrollView = enclosingScrollView else { return }
        banner.layoutBanner()
        let viewport = scrollView.contentView.frame
        let x = viewport.midX - banner.frame.width / 2
        // The scroll view is not flipped, so the viewport's bottom edge is minY.
        let y = viewport.minY + smartRedactBannerBottomInset
        banner.frame.origin = CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Keeps the banner glued to the bottom of the live viewport. The clip view's
    /// bounds change on scroll and magnification; its frame changes when the
    /// scroll view (and so the viewport) is resized. Both feed the same reposition.
    private func observeClipBoundsForSmartRedactBanner(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        smartRedactBannerClipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionSmartRedactBanner() }
        }
        smartRedactBannerFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionSmartRedactBanner() }
        }
    }

    /// The screenshot's pixel size (CGImage dimensions), or its logical size as a
    /// fallback. Used to convert Vision's normalized boxes into the image-pixel
    /// space the classifier expects.
    private func imagePixelSize(of image: NSImage) -> CGSize {
        if let cg = image.bestCGImage, cg.width > 0, cg.height > 0 {
            return CGSize(width: cg.width, height: cg.height)
        }
        return image.size
    }

    /// Converts a Vision normalized box (bottom-left origin, [0,1]) into an
    /// image-pixel rect (top-left origin), the classifier's documented input.
    private func imagePixelRect(fromNormalized box: CGRect, pixelSize: CGSize) -> CGRect {
        let topFraction = 1 - (box.minY + box.height)
        return CGRect(
            x: box.minX * pixelSize.width,
            y: topFraction * pixelSize.height,
            width: box.width * pixelSize.width,
            height: box.height * pixelSize.height
        )
    }

    /// Inverse of `viewRectToCGImageRect`: maps an image-pixel rect (top-left
    /// origin) back to a canvas view rect, riding the SAME slot rect blur/pixelate
    /// use (`backgroundImageRect`). This is the exact path the OCR highlighter
    /// snap uses, so the redaction lands precisely over the writing.
    private func viewRect(fromImagePixelRect rect: CGRect, pixelSize: CGSize) -> CGRect? {
        guard let backgroundImage, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let slot = backgroundImageRect(for: backgroundImage)
        guard slot.width > 0, slot.height > 0 else { return nil }
        let scaleX = slot.width / pixelSize.width
        let scaleY = slot.height / pixelSize.height
        return CGRect(
            x: slot.minX + rect.minX * scaleX,
            y: slot.minY + rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    /// Draws the pending redaction boxes: a translucent red fill + crisp border,
    /// each topped with a small category chip so the user knows what is covered.
    private func drawSmartRedactPreviews(ctx: CGContext) {
        let red = NSColor.systemRed
        let scale = max(enclosingScrollView?.magnification ?? 1, 0.01)
        ctx.saveGState()
        for preview in smartRedactPreviews {
            let rect = preview.rect.standardized
            ctx.setFillColor(red.withAlphaComponent(0.32).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(red.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5 / scale)
            ctx.stroke(rect)
        }
        ctx.restoreGState()
        // Chips drawn after all boxes so a box never paints over a neighbour's label.
        for preview in smartRedactPreviews {
            drawSmartRedactChip(preview.label, above: preview.rect.standardized)
        }
    }

    /// A small rounded label chip with the finding category, anchored to the
    /// top-left of its box (tucked just inside when the box hugs the top edge).
    private func drawSmartRedactChip(_ label: String, above rect: CGRect) {
        let scale = max(enclosingScrollView?.magnification ?? 1, 0.01)
        let fontSize = 10 / scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let padX = 5 / scale
        let padY = 2 / scale
        let chipW = textSize.width + padX * 2
        let chipH = textSize.height + padY * 2
        // Sit the chip just above the box; if there is no room (box at the very
        // top), drop it just inside the box instead.
        var chipY = rect.minY - chipH - (2 / scale)
        if chipY < bounds.minY { chipY = rect.minY + (2 / scale) }
        let chipRect = CGRect(x: rect.minX, y: chipY, width: chipW, height: chipH)

        let path = NSBezierPath(roundedRect: chipRect, xRadius: 3 / scale, yRadius: 3 / scale)
        NSColor.systemRed.withAlphaComponent(0.95).setFill()
        path.fill()
        text.draw(
            at: CGPoint(x: chipRect.minX + padX, y: chipRect.minY + padY),
            withAttributes: attributes
        )
    }

    private enum EffectKind {
        case blur(Double)        // gaussian radius
        case pixelate(Double)    // cell scale
        case secureBlur(Double)  // irreversible: heavy block mosaic + light gaussian
    }

    private func drawBlur(_ blur: BlurAnnotation, ctx: CGContext) {
        let key = effectCacheKey(region: blur.rect.standardized, strength: blur.radius, secure: blur.secure)
        if blur.cachedKey == key, let cached = blur.cachedRender {
            cached.draw(in: blur.rect.standardized)
            return
        }
        let kind: EffectKind = blur.secure ? .secureBlur(blur.radius) : .blur(blur.radius)
        guard let render = renderEffect(region: blur.rect.standardized, kind: kind) else {
            drawEffectPlaceholder(blur.rect.standardized, ctx: ctx)
            return
        }
        render.draw(in: blur.rect.standardized)
        blur.cachedRender = render
        blur.cachedKey = key
    }

    private func drawPixelate(_ px: PixelateAnnotation, ctx: CGContext) {
        let key = effectCacheKey(region: px.rect.standardized, strength: px.scale)
        if px.cachedKey == key, let cached = px.cachedRender {
            cached.draw(in: px.rect.standardized)
            return
        }
        guard let render = renderEffect(region: px.rect.standardized, kind: .pixelate(px.scale)) else {
            drawEffectPlaceholder(px.rect.standardized, ctx: ctx)
            return
        }
        render.draw(in: px.rect.standardized)
        px.cachedRender = render
        px.cachedKey = key
    }

    private func effectCacheKey(region: CGRect, strength: Double, secure: Bool = false) -> EffectCacheKey? {
        guard let bg = backgroundImage, let cg = bg.bestCGImage else { return nil }
        return EffectCacheKey(
            region: region,
            slot: backgroundImageRect(for: bg),
            strength: strength,
            secure: secure,
            options: backgroundOptions,
            imagePixelWidth: cg.width,
            imagePixelHeight: cg.height
        )
    }

    /// Renders the live effect for `region` into an image the size of the region,
    /// in region-local coordinates. The effect is applied ONLY to the part of the
    /// region that overlaps the screenshot slot; any part hanging into the padded
    /// backdrop gets a translucent veil so the region is never empty and never
    /// pretends to blur the wallpaper. Returns nil only when there is no
    /// background image at all; the caller then draws a placeholder veil.
    private func renderEffect(region: CGRect, kind: EffectKind) -> NSImage? {
        guard region.width >= 1, region.height >= 1 else { return nil }
        guard let bg = backgroundImage, let cgImg = bg.bestCGImage else { return nil }

        let result = NSImage(size: region.size)
        result.lockFocusFlipped(true)
        defer { result.unlockFocus() }
        guard let local = NSGraphicsContext.current?.cgContext else { return nil }

        // Veil the whole region first as the floor: wherever the real effect lands
        // it paints over this, and any out-of-slot remainder keeps the veil.
        local.setFillColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        local.fill(CGRect(origin: .zero, size: region.size))

        let slot = backgroundImageRect(for: bg)
        let overlap = region.intersection(slot)
        let imgSize = CGSize(width: cgImg.width, height: cgImg.height)
        if !overlap.isNull, !overlap.isEmpty,
           let cropRect = viewRectToCGImageRect(overlap, imageSize: imgSize),
           let croppedCG = cgImg.cropping(to: cropRect) {
            let ci = CIImage(cgImage: croppedCG)
            let filtered: CIImage?
            switch kind {
            case .blur(let radius):
                let f = CIFilter(name: "CIGaussianBlur")
                f?.setValue(ci, forKey: kCIInputImageKey)
                f?.setValue(radius, forKey: kCIInputRadiusKey)
                filtered = f?.outputImage?.cropped(to: ci.extent)
            case .pixelate(let scale):
                let f = CIFilter(name: "CIPixellate")
                f?.setValue(ci, forKey: kCIInputImageKey)
                f?.setValue(max(scale, 4), forKey: kCIInputScaleKey)
                filtered = f?.outputImage?.cropped(to: ci.extent)
            case .secureBlur:
                // Irreversible redaction: collapse the crop into roughly 14 coarse
                // blocks across its shorter side. A block that big spans whole
                // words, so the original glyphs (and their low-frequency outline,
                // which a plain gaussian preserves and can be deconvolved) are gone
                // for good. The block size is computed in IMAGE PIXELS, not view
                // points, so the mosaic stays the same coarseness at any zoom.
                let shortSidePx = min(ci.extent.width, ci.extent.height)
                let blockSize = max(shortSidePx / 14, 12)
                let pixel = CIFilter(name: "CIPixellate")
                pixel?.setValue(ci, forKey: kCIInputImageKey)
                pixel?.setValue(CIVector(x: ci.extent.midX, y: ci.extent.midY), forKey: kCIInputCenterKey)
                pixel?.setValue(blockSize, forKey: kCIInputScaleKey)
                let mosaic = pixel?.outputImage?.cropped(to: ci.extent) ?? ci
                // A light gaussian on top softens the hard block edges so the
                // result reads as a clean redaction band rather than a jagged grid.
                let soft = CIFilter(name: "CIGaussianBlur")
                soft?.setValue(mosaic, forKey: kCIInputImageKey)
                soft?.setValue(max(blockSize * 0.35, 4), forKey: kCIInputRadiusKey)
                filtered = soft?.outputImage?.cropped(to: ci.extent) ?? mosaic
            }
            if let filtered {
                let rep = NSCIImageRep(ciImage: filtered)
                let piece = NSImage(size: overlap.size)
                piece.addRepresentation(rep)
                // Draw the effect into the overlap, expressed in region-local coords.
                let localRect = CGRect(x: overlap.minX - region.minX,
                                       y: overlap.minY - region.minY,
                                       width: overlap.width, height: overlap.height)
                piece.draw(in: localRect)
            }
        }
        return result
    }

    /// Last-resort placeholder when there is no usable background to sample (the
    /// region is degenerate or the image is missing): a translucent veil plus a
    /// dashed outline so the user still sees a defined region instead of nothing.
    private func drawEffectPlaceholder(_ region: CGRect, ctx: CGContext) {
        guard region.width >= 1, region.height >= 1 else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        ctx.fill(region)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(region.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    private func drawSelectionHandle(for obj: any AnnotationObject, ctx: CGContext) {
        if let arrow = obj as? ArrowAnnotation {
            drawArrowSelection(for: arrow, ctx: ctx)
            return
        }

        if let line = obj as? LineAnnotation {
            drawEndpointSelection(start: line.startPoint, end: line.endPoint, ctx: ctx)
            return
        }

        if let highlighter = obj as? HighlighterAnnotation {
            drawEndpointSelection(start: highlighter.startPoint, end: highlighter.endPoint, ctx: ctx)
            return
        }

        // Snapped text highlight: a plain dashed box, no resize handles. Its rects
        // are locked to the detected lines, so it can be moved or deleted but not
        // resized; showing resize handles would imply an interaction that does
        // nothing.
        if obj is TextHighlightAnnotation {
            ctx.saveGState()
            let accent = KritColors.accent
            ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(obj.bounds.insetBy(dx: -3, dy: -3))
            ctx.restoreGState()
            return
        }

        let inset: CGFloat = 4
        let expanded = obj.bounds.insetBy(dx: -inset, dy: -inset)

        ctx.saveGState()

        let accent = KritColors.accent
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(expanded)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setShadow(offset: .zero, blur: 0)

        for handle in ResizeHandle.allCases {
            drawResizeHandle(at: resizeHandleCenter(for: expanded, handle: handle), handle: handle, accent: accent, ctx: ctx)
        }

        ctx.restoreGState()
    }

    private func drawEndpointSelection(start: CGPoint, end: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        let accent = KritColors.accent
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        drawRoundHandle(at: start, radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: end, radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        ctx.restoreGState()
    }

    private func drawArrowSelection(for arrow: ArrowAnnotation, ctx: CGContext) {
        ctx.saveGState()

        let accent = KritColors.accent
        ctx.setStrokeColor(accent.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.move(to: arrow.startPoint)
        if let controlPoint = arrow.controlPoint {
            ctx.addQuadCurve(to: arrow.endPoint, control: controlPoint)
        } else {
            ctx.addLine(to: arrow.endPoint)
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        drawRoundHandle(at: arrow.handlePoint(.start), radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: arrow.handlePoint(.end), radius: 6.5, fill: .white, stroke: accent, ctx: ctx)
        drawRoundHandle(at: arrow.handlePoint(.control), radius: 7.5, fill: accent, stroke: .white, ctx: ctx)

        ctx.restoreGState()
    }

    private func drawRoundHandle(at point: CGPoint, radius: CGFloat, fill: NSColor, stroke: NSColor, ctx: CGContext) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)
    }

    private func drawResizeHandle(at point: CGPoint, handle: ResizeHandle, accent: NSColor, ctx: CGContext) {
        let radius: CGFloat = isCornerHandle(handle) ? 5.5 : 4.5
        drawRoundHandle(at: point, radius: radius, fill: .white, stroke: accent, ctx: ctx)
    }

    private func resizeHandleCenter(for rect: CGRect, handle: ResizeHandle) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func isCornerHandle(_ handle: ResizeHandle) -> Bool {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }

    private func drawCropOverlay(_ crop: CGRect, ctx: CGContext) {
        ctx.saveGState()
        // Dim everything outside the region.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        let outer = bounds
        for rect in [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: crop.minY - outer.minY),
            CGRect(x: outer.minX, y: crop.maxY, width: outer.width, height: outer.maxY - crop.maxY),
            CGRect(x: outer.minX, y: crop.minY, width: crop.minX - outer.minX, height: crop.height),
            CGRect(x: crop.maxX, y: crop.minY, width: outer.maxX - crop.maxX, height: crop.height),
        ] {
            ctx.fill(rect)
        }

        // Thin white border.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(crop)

        // Rule-of-thirds grid, once the region is big enough to read it.
        if crop.width > 32, crop.height > 32 {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            for i in 1...2 {
                let x = crop.minX + crop.width * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: crop.minY))
                ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
                let y = crop.minY + crop.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: crop.minX, y: y))
                ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
            ctx.strokePath()
        }

        // 8 resize handles: 4 corners + 4 edge midpoints.
        for handle in ResizeHandle.allCases {
            let radius: CGFloat = isCornerHandle(handle) ? 5.5 : 4.5
            drawRoundHandle(at: resizeHandleCenter(for: crop, handle: handle),
                            radius: radius, fill: .white,
                            stroke: NSColor.black.withAlphaComponent(0.35), ctx: ctx)
        }
        ctx.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags

        // Space-drag pan (B5): grab the canvas regardless of the active tool.
        if spaceDown {
            panAnchor = event.locationInWindow
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        // Double-click re-opens an existing text annotation for editing,
        // regardless of the active tool. Crop mode is the exception: there a
        // double-click inside the region commits the crop.
        if event.clickCount == 2, activeTool != .crop,
           let textHit = objects.last(where: { $0.contains(point: point) }) as? TextAnnotation {
            commitTextField()
            beginTextEdit(of: textHit)
            return
        }

        commitTextField()

        if activeTool == .select {
            handleSelectDown(point: point)
            return
        }
        if activeTool == .crop {
            handleCropDown(at: point, clickCount: event.clickCount)
            return
        }
        if activeTool == .text {
            // Item 3: start text inside the image so it never begins off-edge.
            beginTextEntry(at: clampPointToCanvas(point))
            return
        }
        if activeTool == .numberedStep {
            pushUndo()
            let step = NumberedStepAnnotation(center: clampPointToCanvas(point), number: nextStepNumber())
            step.color = activeColor
            objects.append(step)
            setSelection([step])
            setNeedsDisplay(bounds)
            return
        }

        // Drawing tools can still grab the handles of the current selection,
        // so the object you just drew stays adjustable without switching tools.
        if let hitAction = editHandleHit(at: point) {
            if let object = hitAction.object, !selectedObjects.contains(where: { $0.id == object.id }) {
                setSelection([object])
            }
            selectDragStart = point
            selectDragAction = hitAction.action
            didPushSelectMoveUndo = false
            setNeedsDisplay(bounds)
            return
        }

        // Corpo de um objeto SELECIONADO move em qualquer ferramenta (política
        // CleanShot): selecionou, o corpo inteiro é alça de arrasto. Sem isso o
        // clique no corpo com ferramenta de desenho ativa desenha por cima do
        // objeto que o usuário claramente está tentando reposicionar.
        if selectedObjects.contains(where: { $0.contains(point: point) }) || selectedObjectInterior(at: point) != nil {
            beginMoveDrag(at: point)
            setNeedsDisplay(bounds)
            return
        }

        pushUndo()
        // Item 3: anchor the new shape inside the image; updateCurrentObject also
        // clamps the moving point so the whole shape stays in bounds.
        let anchor = clampPointToCanvas(point)
        dragStart = anchor
        lastDragPoint = anchor
        currentObject = makeObject(at: anchor)
    }

    override func mouseDragged(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags

        // Space-drag pan (B5): scroll the clip view by the cursor delta.
        if spaceDown, let anchor = panAnchor {
            panBy(from: anchor, to: event.locationInWindow)
            panAnchor = event.locationInWindow
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select || selectDragAction != nil {
            handleSelectDrag(point: point)
            return
        }
        if activeTool == .crop {
            handleCropDrag(to: point)
            return
        }

        let previousBounds = highlighterDragDirtyRect() ?? currentObject?.bounds
        updateCurrentObject(to: point)
        lastDragPoint = point
        let newBounds = highlighterDragDirtyRect() ?? currentObject?.bounds
        invalidate(previousBounds, newBounds, padding: activeLineWidth + 12)
    }

    /// Redraw region for an in-progress highlighter drag: the union of the free
    /// band's bounds and any snapped line rects. Snapping can paint full text
    /// lines well outside the band, so the band bounds alone would leave stale
    /// preview behind. Nil for any other tool, where the band logic is moot.
    private func highlighterDragDirtyRect() -> CGRect? {
        guard let band = currentObject as? HighlighterAnnotation else { return nil }
        var dirty = band.bounds
        for rect in snappedTextHighlightRects(for: band) {
            dirty = dirty.union(rect)
        }
        return dirty
    }

    override func mouseUp(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags

        if spaceDown {
            panAnchor = nil
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select || selectDragAction != nil {
            handleSelectUp(point: point)
            return
        }
        if activeTool == .crop {
            handleCropUp()
            return
        }
        if let obj = currentObject {
            currentObject = nil
            if isDegenerate(obj) {
                // The press never became a real shape. Drop the undo snapshot
                // pushed at mouseDown, and treat a still click as selection,
                // CleanShot behavior: tools select on click, draw on drag.
                discardLastUndo()
                if let hit = objects.last(where: { $0.contains(point: point) }) {
                    setSelection([hit])
                } else {
                    setSelection([])
                }
            } else {
                let finalObject = finalizedHighlighter(obj)
                objects.append(finalObject)
                // Fresh objects come in selected so handles are live immediately.
                setSelection([finalObject])
            }
        }
        dragStart = nil
        setNeedsDisplay(bounds)
    }

    /// At drag end, a highlighter that swept over detected text commits as a
    /// fixed-rect `TextHighlightAnnotation` (snapped to the lines) instead of the
    /// free band. When the drag missed all text the free band is kept as-is, so
    /// highlighting non-text areas still works exactly like before.
    private func finalizedHighlighter(_ obj: any AnnotationObject) -> any AnnotationObject {
        guard let band = obj as? HighlighterAnnotation else { return obj }
        let snapped = snappedTextHighlightRects(for: band)
        guard !snapped.isEmpty else { return obj }
        let snappedHighlight = TextHighlightAnnotation(rects: snapped)
        snappedHighlight.color = band.color
        return snappedHighlight
    }

    /// A shape too small to be intentional: stray click residue.
    private func isDegenerate(_ obj: any AnnotationObject) -> Bool {
        switch obj {
        case let a as ArrowAnnotation:
            return hypot(a.endPoint.x - a.startPoint.x, a.endPoint.y - a.startPoint.y) < 4
        case let l as LineAnnotation:
            return hypot(l.endPoint.x - l.startPoint.x, l.endPoint.y - l.startPoint.y) < 4
        case let h as HighlighterAnnotation:
            return hypot(h.endPoint.x - h.startPoint.x, h.endPoint.y - h.startPoint.y) < 4
        case let r as RectangleAnnotation:
            return r.rect.width * r.rect.height < 16
        case let e as EllipseAnnotation:
            return e.rect.width * e.rect.height < 16
        case let b as BlurAnnotation:
            return b.rect.width * b.rect.height < 16
        case let p as PixelateAnnotation:
            return p.rect.width * p.rect.height < 16
        case let f as FreehandAnnotation:
            return f.points.count < 3
        default:
            return false
        }
    }

    func setSelection(_ objects: [any AnnotationObject]) {
        selectedObjects = objects
        onSelectionChanged?(objects)
    }

    // MARK: - Select tool

    private var selectDragStart: CGPoint?
    private var selectObjectStart: [(UUID, CGPoint)] = []
    private var didPushSelectMoveUndo = false
    private var selectDragAction: SelectDragAction?

    // MARK: - Precision-tool state (B1-B5)

    // Modifier flags of the in-flight mouse event, set as the first line of every
    // mouse handler so the select/draw logic can read shift/cmd without changing
    // every method signature.
    private var lastEventModifiers: NSEvent.ModifierFlags = []

    // Marquee multi-select (B1/B2).
    private var marqueeOrigin: CGPoint?
    private var marqueeRect: CGRect?
    private var marqueeBaseSelection: [any AnnotationObject] = []

    // Smart guides + snapping (B3).
    private struct SnapGuide {
        enum Axis { case vertical, horizontal }
        let axis: Axis
        let position: CGFloat   // x for a vertical line, y for a horizontal line
    }
    private var activeGuides: [SnapGuide] = []
    private let snapThreshold: CGFloat = 6
    // Snap is presentational: the object follows the cursor logically while the
    // displayed position snaps, so the magnet never detaches from the pointer.
    private var dragAccumulated: CGPoint = .zero

    // Canvas pan (B5).
    private var spaceDown = false
    private var panAnchor: CGPoint?

    private enum ResizeHandle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum SelectDragAction {
        case move
        case arrowHandle(ArrowAnnotation, ArrowHandle)
        case lineEndpoint(LineAnnotation, EndpointHandle)
        case highlighterEndpoint(HighlighterAnnotation, EndpointHandle)
        case resize(any AnnotationObject, ResizeHandle)
    }

    private enum EndpointHandle {
        case start, end
    }

    private func handleSelectDown(point: CGPoint) {
        let shift = lastEventModifiers.contains(.shift)

        // Resize/endpoint handles take priority over selection toggling so a
        // shift-click on a handle still resizes (B2 edge case).
        if let hitAction = editHandleHit(at: point) {
            if let object = hitAction.object, !selectedObjects.contains(where: { $0.id == object.id }) {
                setSelection([object])
            }
            selectDragStart = point
            selectDragAction = hitAction.action
            didPushSelectMoveUndo = false
            setNeedsDisplay(bounds)
            return
        }

        // `contains` is the per-object pick test, where hollow rect/ellipse hit only
        // on their stroke band so objects below them stay clickable. That makes a
        // click on a SELECTED hollow shape's interior miss and fall through to the
        // marquee/deselect branch below (R1). CleanShot policy: once selected, the
        // whole body is draggable, so fall back to an interior test of the current
        // selection and treat an interior hit as that object.
        let hit = objects.last(where: { $0.contains(point: point) })
            ?? selectedObjectInterior(at: point)
        if let hit {
            if shift {
                // Toggle membership; only arm a move if the object stayed selected,
                // so shift-clicking to deselect doesn't immediately drag it.
                toggleInSelection(hit)
                if selectedObjects.contains(where: { $0.id == hit.id }) {
                    beginMoveDrag(at: point)
                } else {
                    // Shift-click removed it from the selection: disarm any drag so a
                    // tiny follow-up drag doesn't move the remaining selection.
                    selectDragAction = nil
                    selectDragStart = nil
                    dragAccumulated = .zero
                }
            } else {
                if !selectedObjects.contains(where: { $0.id == hit.id }) {
                    setSelection([hit])
                }
                beginMoveDrag(at: point)
            }
        } else {
            // Empty space: start a marquee. Shift keeps the current selection and
            // makes the marquee additive (B2); plain click clears it (B1).
            marqueeBaseSelection = shift ? selectedObjects : []
            if !shift { setSelection([]) }
            marqueeOrigin = point
            marqueeRect = CGRect(origin: point, size: .zero)
            selectDragAction = nil
        }
        setNeedsDisplay(bounds)
    }

    private func beginMoveDrag(at point: CGPoint) {
        selectDragStart = point
        selectDragAction = .move
        didPushSelectMoveUndo = false
        dragAccumulated = .zero
        selectObjectStart = selectedObjects.map { ($0.id, CGPoint(x: $0.bounds.origin.x, y: $0.bounds.origin.y)) }
    }

    private func toggleInSelection(_ obj: any AnnotationObject) {
        if let i = selectedObjects.firstIndex(where: { $0.id == obj.id }) {
            var s = selectedObjects
            s.remove(at: i)
            setSelection(s)
        } else {
            setSelection(selectedObjects + [obj])
        }
    }

    private func handleSelectDrag(point: CGPoint) {
        let shift = lastEventModifiers.contains(.shift)

        // Marquee branch (B1/B2): live-select intersected objects while dragging.
        if let origin = marqueeOrigin {
            let new = rectFrom(origin, to: point)
            let dirty = (marqueeRect ?? new).union(new).insetBy(dx: -2, dy: -2)
            marqueeRect = new
            let intersected = objects.filter { marqueeIntersects($0, rect: new) }
            // Additive marquee unions with the captured base selection (shift).
            if marqueeBaseSelection.isEmpty {
                setSelection(intersected)
            } else {
                var union = marqueeBaseSelection
                for obj in intersected where !union.contains(where: { $0.id == obj.id }) {
                    union.append(obj)
                }
                setSelection(union)
            }
            setNeedsDisplay(dirty.intersection(bounds))
            return
        }

        guard let start = selectDragStart else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        guard delta.x != 0 || delta.y != 0 else { return }
        if !didPushSelectMoveUndo {
            pushUndo()
            didPushSelectMoveUndo = true
        }
        let previousRects = selectedObjects.map(\.bounds)
        switch selectDragAction {
        case .arrowHandle(let arrow, let handle):
            arrow.setHandle(handle, to: constrainedHandlePoint(arrow, handle: handle, to: point, shift: shift))
        case .lineEndpoint(let line, let endpoint):
            setEndpoint(endpoint, on: line, to: constrainedEndpoint(start: endpoint == .start ? line.endPoint : line.startPoint, to: point, shift: shift))
        case .highlighterEndpoint(let highlighter, let endpoint):
            setEndpoint(endpoint, on: highlighter, to: constrainedEndpoint(start: endpoint == .start ? highlighter.endPoint : highlighter.startPoint, to: point, shift: shift))
        case .resize(let object, let handle):
            resize(object, handle: handle, by: delta, shift: shift)
        case .move, nil:
            // Grabbing the body to move it shows the closed-hand grip; set it on the
            // first real move step (not at mousedown) so a click-to-select that never
            // drags keeps the arrow cursor.
            if NSCursor.current != NSCursor.closedHand { NSCursor.closedHand.set() }
            applyMoveDrag(rawDelta: delta)
        }
        selectDragStart = point
        let currentRects = selectedObjects.map(\.bounds)
        for rect in previousRects + currentRects {
            setNeedsDisplay(rect.insetBy(dx: -12, dy: -12).intersection(bounds))
        }
        if !activeGuides.isEmpty { setNeedsDisplay(bounds) }
    }

    // Moves the selection following the cursor logically (dragAccumulated) while
    // snapping presentationally (B3). Cmd suppresses snapping.
    private func applyMoveDrag(rawDelta: CGPoint) {
        dragAccumulated.x += rawDelta.x
        dragAccumulated.y += rawDelta.y

        // Union of the mousedown snapshot origins, offset by the raw accumulated drag.
        guard !selectObjectStart.isEmpty else {
            for obj in selectedObjects { obj.move(by: rawDelta) }
            return
        }

        var snapDelta = CGPoint.zero
        if !lastEventModifiers.contains(.command) {
            let result = snap(movedBounds: snapFreeUnionBounds())
            snapDelta = result.delta
            activeGuides = result.guides
        } else {
            activeGuides = []
        }

        // Position each object absolutely: start + accumulated + snap, applied as a
        // relative step from its current origin (move(by:) is relative).
        for obj in selectedObjects {
            guard let snapshot = selectObjectStart.first(where: { $0.0 == obj.id })?.1 else {
                obj.move(by: rawDelta)
                continue
            }
            let target = CGPoint(x: snapshot.x + dragAccumulated.x + snapDelta.x,
                                 y: snapshot.y + dragAccumulated.y + snapDelta.y)
            let current = CGPoint(x: obj.bounds.origin.x, y: obj.bounds.origin.y)
            let step = CGPoint(x: target.x - current.x, y: target.y - current.y)
            if step.x != 0 || step.y != 0 {
                obj.move(by: step)
                if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
                if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
            }
        }

        // Item 3: a body drag can't push the selection past the image edges. Pull
        // the whole group back by the union's overhang so it stays fully inside.
        if let union = visualUnion(of: selectedObjects) {
            let fix = canvasClampDelta(for: union)
            if fix.x != 0 || fix.y != 0 {
                for obj in selectedObjects {
                    obj.move(by: fix)
                    if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
                    if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
                }
            }
        }
    }

    // The selection's visual union bounds at the snap-free logical position
    // (mousedown snapshot + accumulated raw drag), used as the input to the snap
    // solver. Uses visualBounds so guides align to the visible edges, not the
    // padded chrome boxes.
    private func snapFreeUnionBounds() -> CGRect {
        var union: CGRect?
        for obj in selectedObjects {
            guard let snapshot = selectObjectStart.first(where: { $0.0 == obj.id })?.1 else { continue }
            let b = visualBounds(for: obj)
            // The snapshot is the object's `bounds.origin`; translate the visual box
            // back to its snap-free position by the same offset its bounds moved.
            let offsetX = snapshot.x + dragAccumulated.x - obj.bounds.origin.x
            let offsetY = snapshot.y + dragAccumulated.y - obj.bounds.origin.y
            let logical = b.offsetBy(dx: offsetX, dy: offsetY)
            union = union.map { $0.union(logical) } ?? logical
        }
        return union ?? .zero
    }

    /// An object's visible bounding box, with the per-type UI padding stripped so
    /// snap guides and marquee target the edges the user actually sees.
    private func visualBounds(for obj: any AnnotationObject) -> CGRect {
        switch obj {
        case let a as ArrowAnnotation:
            var pts = [a.startPoint, a.endPoint]
            if let c = a.controlPoint { pts.append(c) }
            let minX = pts.map(\.x).min() ?? 0, maxX = pts.map(\.x).max() ?? 0
            let minY = pts.map(\.y).min() ?? 0, maxY = pts.map(\.y).max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let l as LineAnnotation:
            return CGRect(x: min(l.startPoint.x, l.endPoint.x), y: min(l.startPoint.y, l.endPoint.y),
                          width: abs(l.endPoint.x - l.startPoint.x), height: abs(l.endPoint.y - l.startPoint.y))
        case let h as HighlighterAnnotation:
            return CGRect(x: min(h.startPoint.x, h.endPoint.x), y: min(h.startPoint.y, h.endPoint.y),
                          width: abs(h.endPoint.x - h.startPoint.x), height: abs(h.endPoint.y - h.startPoint.y))
        case let f as FreehandAnnotation:
            guard !f.points.isEmpty else { return .zero }
            var minX = f.points[0].x, maxX = minX, minY = f.points[0].y, maxY = minY
            for p in f.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let r as RectangleAnnotation:   return r.rect.standardized
        case let e as EllipseAnnotation:     return e.rect.standardized
        case let b as BlurAnnotation:        return b.rect.standardized
        case let p as PixelateAnnotation:    return p.rect.standardized
        default:                             return obj.bounds
        }
    }

    // Snaps the moved union bounds to other objects' edges/centers and the canvas
    // edges/center, returning the correction delta and the guides to draw (B3).
    private func snap(movedBounds: CGRect) -> (delta: CGPoint, guides: [SnapGuide]) {
        let threshold = snapThreshold / max(enclosingScrollView?.magnification ?? 1, 0.01)
        let selectedIDs = Set(selectedObjects.map(\.id))

        // Candidate lines on the dragged bounds.
        let candX: [CGFloat] = [movedBounds.minX, movedBounds.midX, movedBounds.maxX]
        let candY: [CGFloat] = [movedBounds.minY, movedBounds.midY, movedBounds.maxY]

        // Targets: every other object's edges/center plus the canvas edges/center.
        var targetX: [CGFloat] = [bounds.minX, bounds.midX, bounds.maxX]
        var targetY: [CGFloat] = [bounds.minY, bounds.midY, bounds.maxY]
        for obj in objects where !selectedIDs.contains(obj.id) {
            let b = visualBounds(for: obj)
            targetX.append(contentsOf: [b.minX, b.midX, b.maxX])
            targetY.append(contentsOf: [b.minY, b.midY, b.maxY])
        }

        var bestDX: CGFloat = 0, bestDXMag = threshold, snappedX: CGFloat?
        for c in candX {
            for t in targetX where abs(t - c) <= bestDXMag {
                bestDXMag = abs(t - c); bestDX = t - c; snappedX = t
            }
        }
        var bestDY: CGFloat = 0, bestDYMag = threshold, snappedY: CGFloat?
        for c in candY {
            for t in targetY where abs(t - c) <= bestDYMag {
                bestDYMag = abs(t - c); bestDY = t - c; snappedY = t
            }
        }

        var guides: [SnapGuide] = []
        if let x = snappedX { guides.append(SnapGuide(axis: .vertical, position: x)) }
        if let y = snappedY { guides.append(SnapGuide(axis: .horizontal, position: y)) }
        return (CGPoint(x: snappedX != nil ? bestDX : 0, y: snappedY != nil ? bestDY : 0), guides)
    }

    // Marquee hit-test against an object's REAL geometry, not its `bounds` (which
    // bakes in a generous UI padding for arrows/lines/highlighters/freehand). This
    // keeps marquee selection matching the visible stroke (CleanShot behavior).
    private func marqueeIntersects(_ obj: any AnnotationObject, rect: CGRect) -> Bool {
        switch obj {
        case let a as ArrowAnnotation:
            return rect.contains(a.startPoint) || rect.contains(a.endPoint)
                || arrowCurveIntersects(a, rect: rect)
        case let l as LineAnnotation:
            return rect.contains(l.startPoint) || rect.contains(l.endPoint)
                || segmentIntersectsRect(l.startPoint, l.endPoint, rect)
        case let h as HighlighterAnnotation:
            return rect.contains(h.startPoint) || rect.contains(h.endPoint)
                || segmentIntersectsRect(h.startPoint, h.endPoint, rect)
        case let f as FreehandAnnotation:
            guard !f.points.isEmpty else { return false }
            var minX = f.points[0].x, maxX = minX, minY = f.points[0].y, maxY = minY
            for p in f.points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return rect.intersects(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        case let r as RectangleAnnotation:   return rect.intersects(r.rect.standardized)
        case let e as EllipseAnnotation:     return rect.intersects(e.rect.standardized)
        case let b as BlurAnnotation:        return rect.intersects(b.rect.standardized)
        case let p as PixelateAnnotation:    return rect.intersects(p.rect.standardized)
        default:                             return rect.intersects(obj.bounds)
        }
    }

    private func arrowCurveIntersects(_ arrow: ArrowAnnotation, rect: CGRect) -> Bool {
        var previous = arrow.startPoint
        for step in 1...28 {
            let current = arrow.pointOnCurve(at: CGFloat(step) / 28)
            if rect.contains(current) || segmentIntersectsRect(previous, current, rect) { return true }
            previous = current
        }
        return false
    }

    // True when segment a-b crosses or lies inside `rect`. Endpoint-containment is
    // checked by the caller; this covers a segment passing through the rect.
    private func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ]
        return edges.contains { segmentsIntersect(a, b, $0.0, $0.1) }
    }

    private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
            let v = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if v > 0 { return 1 }
            if v < 0 { return 2 }
            return 0
        }
        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)
        return o1 != o2 && o3 != o4
    }

    private func handleSelectUp(point: CGPoint) {
        if marqueeRect != nil {
            marqueeOrigin = nil
            marqueeRect = nil
            marqueeBaseSelection = []
            setNeedsDisplay(bounds)
        }
        // Restore the tool's cursor after a body-move drag released the closed hand.
        if NSCursor.current == NSCursor.closedHand {
            window?.invalidateCursorRects(for: self)
        }
        selectDragStart = nil
        selectDragAction = nil
        didPushSelectMoveUndo = false
        dragAccumulated = .zero
        if !activeGuides.isEmpty {
            activeGuides = []
            setNeedsDisplay(bounds)
        }
    }

    private func editHandleHit(at point: CGPoint) -> (object: (any AnnotationObject)?, action: SelectDragAction)? {
        for obj in selectedObjects.reversed() {
            if let arrow = obj as? ArrowAnnotation {
                for handle in [ArrowHandle.control, .end, .start] {
                    let center = arrow.handlePoint(handle)
                    let radius = handle == .control ? CGFloat(9) : CGFloat(8)
                    if hit(point, center: center, radius: radius + 4) {
                        return (arrow, .arrowHandle(arrow, handle))
                    }
                }
                continue
            }

            if let line = obj as? LineAnnotation {
                if hit(point, center: line.startPoint, radius: 10) { return (line, .lineEndpoint(line, .start)) }
                if hit(point, center: line.endPoint, radius: 10) { return (line, .lineEndpoint(line, .end)) }
                continue
            }

            if let highlighter = obj as? HighlighterAnnotation {
                if hit(point, center: highlighter.startPoint, radius: 10) { return (highlighter, .highlighterEndpoint(highlighter, .start)) }
                if hit(point, center: highlighter.endPoint, radius: 10) { return (highlighter, .highlighterEndpoint(highlighter, .end)) }
                continue
            }

            // Snapped text highlights have no resize handles (rects are locked to
            // the lines), so skip handle hit-testing and let the body act as the
            // move grip via the regular selection path.
            if obj is TextHighlightAnnotation { continue }

            let expanded = obj.bounds.insetBy(dx: -4, dy: -4)
            for handle in ResizeHandle.allCases {
                if hit(point, center: resizeHandleCenter(for: expanded, handle: handle), radius: 10) {
                    return (obj, .resize(obj, handle))
                }
            }
        }
        return nil
    }

    private func hit(_ point: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius
    }

    // R1: once an object is selected, CleanShot lets you grab its whole BODY to
    // move it, even hollow rect/ellipse whose `contains` only hits the stroke band
    // (so unselected hollow shapes stay pass-through). This is the selected-only
    // interior pick used as a fallback after the per-object `contains` test misses.
    // Topmost selected object wins. For lines/arrows/highlighters the visible box is
    // mostly empty diagonal space, so we keep their generous stroke-band semantics
    // instead of grabbing the bounding rect; for everything else the visible
    // interior (plus a few px of slop) is draggable.
    private func selectedObjectInterior(at point: CGPoint) -> (any AnnotationObject)? {
        let slop: CGFloat = 4
        for obj in selectedObjects.reversed() {
            switch obj {
            case is ArrowAnnotation, is LineAnnotation, is HighlighterAnnotation:
                // Stroke-band objects: a thin band already returned false above, so
                // widen the band a touch rather than claiming their empty box.
                if obj.contains(point: point) { return obj }
            default:
                if visualBounds(for: obj).insetBy(dx: -slop, dy: -slop).contains(point) {
                    return obj
                }
            }
        }
        return nil
    }

    private func setEndpoint(_ endpoint: EndpointHandle, on line: LineAnnotation, to point: CGPoint) {
        switch endpoint {
        case .start: line.startPoint = point
        case .end:   line.endPoint = point
        }
    }

    private func setEndpoint(_ endpoint: EndpointHandle, on highlighter: HighlighterAnnotation, to point: CGPoint) {
        switch endpoint {
        case .start: highlighter.startPoint = point
        case .end:   highlighter.endPoint = point
        }
    }

    private func resize(_ object: any AnnotationObject, handle: ResizeHandle, by delta: CGPoint, shift: Bool = false) {
        let sourceRect = editableRect(for: object)
        var newRect = resizedRect(from: sourceRect, handle: handle, by: delta)

        // Shift on a corner handle locks the aspect to a square/circle (B4),
        // anchored at the corner opposite the dragged one (the fixed corner).
        let aspectLockable = object is RectangleAnnotation || object is EllipseAnnotation
            || object is BlurAnnotation || object is PixelateAnnotation
        if shift && aspectLockable && isCornerHandle(handle) {
            newRect = squaredResize(newRect, handle: handle)
        }

        // Item 3: keep rect-based shapes inside the image while resizing. Clip the
        // new rect to the canvas so a handle can't be dragged past the edges.
        // (Text/numbered-step scale by font/diameter and stay small; the export
        // clip backstops anything that still pokes out.)
        switch object {
        case is RectangleAnnotation, is EllipseAnnotation, is BlurAnnotation, is PixelateAnnotation:
            let clipped = newRect.intersection(bounds)
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 {
                newRect = clipped
            }
        default:
            break
        }

        switch object {
        case let rectangle as RectangleAnnotation:
            rectangle.rect = newRect
        case let ellipse as EllipseAnnotation:
            ellipse.rect = newRect
        case let blur as BlurAnnotation:
            blur.rect = newRect
            blur.cachedRender = nil
        case let pixelate as PixelateAnnotation:
            pixelate.rect = newRect
            pixelate.cachedRender = nil
        case let text as TextAnnotation:
            // Text scales by font size, driven by height. A purely horizontal handle
            // (.left/.right) doesn't change height and must not jump the origin, so
            // restrict text resize to handles that move a vertical edge.
            switch handle {
            case .left, .right:
                break
            default:
                let oldHeight = max(sourceRect.height, 1)
                let scale = max(newRect.height, 1) / oldHeight
                text.origin = newRect.origin
                text.fontSize = min(96, max(8, text.fontSize * scale))
            }
        case let step as NumberedStepAnnotation:
            let diameter = min(160, max(14, max(newRect.width, newRect.height)))
            step.origin = CGPoint(x: newRect.midX, y: newRect.midY)
            step.diameter = diameter
        case let freehand as FreehandAnnotation:
            resizeFreehand(freehand, from: sourceRect, to: newRect)
        default:
            break
        }
    }

    private func editableRect(for object: any AnnotationObject) -> CGRect {
        switch object {
        case let rectangle as RectangleAnnotation: return rectangle.rect
        case let ellipse as EllipseAnnotation:     return ellipse.rect
        case let blur as BlurAnnotation:           return blur.rect
        case let pixelate as PixelateAnnotation:   return pixelate.rect
        default:                                   return object.bounds
        }
    }

    private func resizedRect(from rect: CGRect, handle: ResizeHandle, by delta: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:     minX += delta.x; minY += delta.y
        case .top:         minY += delta.y
        case .topRight:    maxX += delta.x; minY += delta.y
        case .right:       maxX += delta.x
        case .bottomRight: maxX += delta.x; maxY += delta.y
        case .bottom:      maxY += delta.y
        case .bottomLeft:  minX += delta.x; maxY += delta.y
        case .left:        minX += delta.x
        }

        let minSize: CGFloat = 10
        if maxX - minX < minSize {
            if handle == .left || handle == .topLeft || handle == .bottomLeft { minX = maxX - minSize }
            else { maxX = minX + minSize }
        }
        if maxY - minY < minSize {
            if handle == .top || handle == .topLeft || handle == .topRight { minY = maxY - minSize }
            else { maxY = minY + minSize }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizeFreehand(_ freehand: FreehandAnnotation, from sourceRect: CGRect, to newRect: CGRect) {
        guard !freehand.points.isEmpty else { return }
        let sourceWidth = max(sourceRect.width, 1)
        let sourceHeight = max(sourceRect.height, 1)
        freehand.points = freehand.points.map { point in
            let xRatio = (point.x - sourceRect.minX) / sourceWidth
            let yRatio = (point.y - sourceRect.minY) / sourceHeight
            return CGPoint(x: newRect.minX + xRatio * newRect.width,
                           y: newRect.minY + yRatio * newRect.height)
        }
    }

    // MARK: - Object factory

    private func makeObject(at point: CGPoint) -> (any AnnotationObject)? {
        switch activeTool {
        case .arrow:
            let a = ArrowAnnotation(start: point, end: point)
            a.color = activeColor; a.lineWidth = activeLineWidth; return a
        case .rectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: false)
            r.color = activeColor; r.lineWidth = activeLineWidth; return r
        case .filledRectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: true)
            r.color = activeColor; r.lineWidth = activeLineWidth; return r
        case .ellipse:
            let e = EllipseAnnotation(rect: CGRect(origin: point, size: .zero))
            e.color = activeColor; e.lineWidth = activeLineWidth; return e
        case .line:
            let l = LineAnnotation(start: point, end: point)
            l.color = activeColor; l.lineWidth = activeLineWidth; return l
        case .freehand:
            let f = FreehandAnnotation()
            f.points = [point]; f.color = activeColor; f.lineWidth = activeLineWidth; return f
        case .highlighter:
            let h = HighlighterAnnotation(start: point, end: point)
            h.color = activeColor; return h
        case .blur:
            let b = BlurAnnotation(rect: CGRect(origin: point, size: .zero))
            b.secure = activeBlurSecure
            return b
        case .pixelate:
            let p = PixelateAnnotation(rect: CGRect(origin: point, size: .zero))
            return p
        default: return nil
        }
    }

    private func updateCurrentObject(to rawPoint: CGPoint) {
        guard let start = dragStart else { return }
        // Item 3: keep what the user draws inside the final image. Clamping the
        // moving point to the canvas means a shape can't be dragged past the
        // edges while it's being created.
        let point = clampPointToCanvas(rawPoint)
        // Shift constrains shapes to square/circle and lines/arrows to 45° (B4).
        let shift = lastEventModifiers.contains(.shift)
        switch currentObject {
        case let a as ArrowAnnotation:       a.endPoint = shift ? constrain45(from: start, to: point) : point
        case let r as RectangleAnnotation:   r.rect = shift ? squareRect(from: start, to: point) : rectFrom(start, to: point)
        case let e as EllipseAnnotation:     e.rect = shift ? squareRect(from: start, to: point) : rectFrom(start, to: point)
        case let l as LineAnnotation:        l.endPoint = shift ? constrain45(from: start, to: point) : point
        case let f as FreehandAnnotation:
            if let last = f.points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
            f.points.append(point)
        case let h as HighlighterAnnotation: h.endPoint = point
        case let b as BlurAnnotation:        b.rect = shift ? squareRect(from: start, to: point) : rectFrom(start, to: point)
        case let p as PixelateAnnotation:    p.rect = shift ? squareRect(from: start, to: point) : rectFrom(start, to: point)
        default: break
        }
    }

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }

    // MARK: - Keep annotations inside the image (item 3)

    /// Clamps a point to the canvas bounds (the final image area). Used while
    /// creating and resizing so a shape's defining point never lands outside.
    private func clampPointToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    /// Correction delta that pulls a visual box fully back inside the canvas. If
    /// the box is larger than the canvas on an axis it is pinned to the leading
    /// edge (cropping the overhang is the export clip's job). Zero when already in.
    private func canvasClampDelta(for box: CGRect) -> CGPoint {
        var dx: CGFloat = 0, dy: CGFloat = 0
        if box.width <= bounds.width {
            if box.minX < bounds.minX { dx = bounds.minX - box.minX }
            else if box.maxX > bounds.maxX { dx = bounds.maxX - box.maxX }
        } else {
            dx = bounds.minX - box.minX
        }
        if box.height <= bounds.height {
            if box.minY < bounds.minY { dy = bounds.minY - box.minY }
            else if box.maxY > bounds.maxY { dy = bounds.maxY - box.maxY }
        } else {
            dy = bounds.minY - box.minY
        }
        return CGPoint(x: dx, y: dy)
    }

    /// Union of the current visual boxes of `objs`, the input to the move clamp.
    private func visualUnion(of objs: [any AnnotationObject]) -> CGRect? {
        var union: CGRect?
        for obj in objs {
            let b = visualBounds(for: obj)
            union = union.map { $0.union(b) } ?? b
        }
        return union
    }

    /// Pulls the current selection back inside the canvas as a group, used after a
    /// keyboard nudge that may have crossed an edge.
    private func clampSelectionToCanvas() {
        guard let union = visualUnion(of: selectedObjects) else { return }
        let fix = canvasClampDelta(for: union)
        guard fix.x != 0 || fix.y != 0 else { return }
        for obj in selectedObjects {
            obj.move(by: fix)
            if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
            if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
        }
    }

    // MARK: - Shift-constrain geometry (B4)

    // Square from `a` to `b`, tracking the larger drag dimension (CleanShot feel).
    private func squareRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        let sx: CGFloat = b.x >= a.x ? 1 : -1
        let sy: CGFloat = b.y >= a.y ? 1 : -1
        return rectFrom(a, to: CGPoint(x: a.x + side * sx, y: a.y + side * sy))
    }

    // Forces a resized rect square, anchored at the corner opposite the handle.
    private func squaredResize(_ rect: CGRect, handle: ResizeHandle) -> CGRect {
        let side = max(rect.width, rect.height)
        switch handle {
        case .bottomRight: return CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
        case .topLeft:     return CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
        case .topRight:    return CGRect(x: rect.minX, y: rect.maxY - side, width: side, height: side)
        case .bottomLeft:  return CGRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
        default:           return rect
        }
    }

    // Snaps `b` to the nearest 45-degree increment from `a`, preserving length.
    private func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let ang = atan2(dy, dx)
        let snapped = (ang / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }

    private func constrainedEndpoint(start: CGPoint, to point: CGPoint, shift: Bool) -> CGPoint {
        // Item 3: endpoint handles stay inside the image.
        let p = clampPointToCanvas(point)
        return shift ? constrain45(from: start, to: p) : p
    }

    // Arrow handles: 45-constrain only the start/end endpoints, never the control.
    private func constrainedHandlePoint(_ arrow: ArrowAnnotation, handle: ArrowHandle, to point: CGPoint, shift: Bool) -> CGPoint {
        // Item 3: drag handles stay inside the image (control included, so a curved
        // arrow's bend can't be flung off-canvas).
        let p = clampPointToCanvas(point)
        guard shift, handle != .control else { return p }
        let anchor = handle == .start ? arrow.endPoint : arrow.startPoint
        return constrain45(from: anchor, to: p)
    }

    private func invalidate(_ oldRect: CGRect?, _ newRect: CGRect?, padding: CGFloat) {
        if let oldRect {
            setNeedsDisplay(oldRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
        if let newRect {
            setNeedsDisplay(newRect.insetBy(dx: -padding, dy: -padding).intersection(bounds))
        }
    }

    private func nextStepNumber() -> Int {
        let existing = objects.compactMap { ($0 as? NumberedStepAnnotation)?.number }
        return (existing.max() ?? 0) + 1
    }

    // MARK: - Text

    /// The annotation being re-edited in place (hidden from draw while active).
    private var editingTextAnnotation: TextAnnotation?

    /// Top-left where a freshly typed text will be committed. The inline editor is
    /// offset from this by the field's internal cell inset so the glyphs you type
    /// land exactly where the committed annotation draws them, and the commit uses
    /// this stored origin rather than the (auto-growing) field frame so the text
    /// never shifts between typing and rendering.
    private var pendingTextOrigin: CGPoint?

    /// A borderless NSTextField insets its drawn text from the frame edges (~2pt).
    /// Offsetting the field by this keeps the inline glyphs registered with where
    /// `TextAnnotation.draw` puts them, so committing or dragging never nudges them.
    private let textFieldContentInset = CGPoint(x: 2, y: 2)

    /// The font new text uses, honoring the active weight and italic so the inline
    /// editor matches what the committed annotation will render.
    private var activeTextFont: NSFont {
        let base = activeFontFamily.font(size: activeFontSize, weight: activeFontWeight)
        guard activeItalic else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: activeFontSize) ?? base
    }

    private func beginTextEntry(at point: CGPoint) {
        // Editing a text field steals first-responder, so a held Space would never
        // get its keyUp here; drop pan mode before handing focus over.
        clearSpacePan()
        let font = activeTextFont
        let field = makeTextField(font: font, color: activeColor)
        // Place the field so its inset-adjusted text top-left sits at `point`; the
        // committed annotation will draw its top-left at that same point.
        pendingTextOrigin = point
        field.frame = NSRect(x: point.x - textFieldContentInset.x,
                             y: point.y - textFieldContentInset.y,
                             width: 220, height: font.ascender - font.descender + 6)
        addSubview(field)
        field.becomeFirstResponder()
        activeTextField = field
        installTextCommitClickMonitor()
        showEmojiButton(for: field)
    }

    /// Re-opens an existing text annotation for editing, WYSIWYG: same font,
    /// size and color; the object's render is hidden until commit.
    func beginTextEdit(of annotation: TextAnnotation) {
        clearSpacePan()
        pushUndo()
        editingTextAnnotation = annotation
        pendingTextOrigin = nil
        setSelection([])

        let field = makeTextField(font: annotation.font, color: annotation.color)
        field.stringValue = annotation.text
        let size = annotation.textSize
        // Offset by the same inset as a fresh entry so the editor's glyphs sit
        // exactly over the rendered annotation (WYSIWYG re-edit).
        field.frame = NSRect(x: annotation.origin.x - textFieldContentInset.x,
                             y: annotation.origin.y - textFieldContentInset.y,
                             width: max(size.width + 24, 80), height: size.height + 4)
        addSubview(field)
        field.becomeFirstResponder()
        field.currentEditor()?.selectAll(nil)
        activeTextField = field
        installTextCommitClickMonitor()
        showEmojiButton(for: field)
        setNeedsDisplay(bounds)
    }

    private func makeTextField(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.isEditable = true
        field.font = font
        field.textColor = color
        field.placeholderString = "Type here…"
        field.delegate = self
        return field
    }

    func commitTextField() {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Capture and clear before we mutate state, so a re-entrant commit (the
        // field-editor end notification can fire during teardown) is a no-op.
        let origin = pendingTextOrigin
        pendingTextOrigin = nil

        if let editing = editingTextAnnotation {
            // Mutate the existing object (the undo snapshot was pushed when
            // editing began). Empty text deletes it.
            if text.isEmpty {
                objects.removeAll { $0.id == editing.id }
            } else {
                editing.text = text
            }
            editingTextAnnotation = nil
        } else if !text.isEmpty {
            pushUndo()
            // Use the stored origin (where the user started typing), not the live
            // field frame: the field auto-grows its width while typing, which would
            // otherwise drift the committed text away from where it was entered.
            let ann = TextAnnotation(origin: origin ?? field.frame.origin)
            ann.text = text
            ann.color = activeColor
            ann.fontSize = activeFontSize
            ann.fontFamily = activeFontFamily
            ann.fontWeight = activeFontWeight
            ann.italic = activeItalic
            ann.backplate = activeBackplate
            ann.outline = activeOutline
            objects.append(ann)
            setSelection([ann])
            // CleanShot parity: the text tool drops one object then hands control
            // back to Select, so the very next click-drag moves what you just typed
            // (instead of re-arming the text tool and spawning a new editor on top).
            if activeTool == .text { activeTool = .select }
        }
        field.removeFromSuperview()
        activeTextField = nil
        hideEmojiButton()
        removeTextCommitClickMonitor()
        setNeedsDisplay(bounds)
    }

    private func installTextCommitClickMonitor() {
        removeTextCommitClickMonitor()
        textCommitClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard let field = self.activeTextField else {
                self.removeTextCommitClickMonitor()
                return event
            }
            // Clicks inside the live editor keep editing; the floating emoji
            // button is editor chrome too, so a tap on it opens the palette
            // instead of committing. Anything else commits BEFORE the click
            // lands, so the control being clicked already acts on the committed
            // text.
            if event.window === field.window {
                let local = field.convert(event.locationInWindow, from: nil)
                if field.bounds.contains(local) { return event }
                if let emoji = self.emojiButton {
                    let emojiLocal = emoji.convert(event.locationInWindow, from: nil)
                    if emoji.bounds.contains(emojiLocal) { return event }
                }
            }
            self.commitTextField()
            return event
        }
    }

    private func removeTextCommitClickMonitor() {
        if let monitor = textCommitClickMonitor {
            NSEvent.removeMonitor(monitor)
            textCommitClickMonitor = nil
        }
    }

    // MARK: - Emoji button (inline text editor)

    /// Diameter of the circular emoji button floating above the text editor.
    private let emojiButtonSize: CGFloat = 30
    /// Vertical gap between the editor's top edge and the button's bottom edge.
    private let emojiButtonGap: CGFloat = 10

    /// Builds the coral circular emoji button and parks it above the editor. The
    /// button stays out of the field's key-view loop and never takes first
    /// responder, so clicking it does not commit the text (the click monitor also
    /// treats it as in-editor chrome).
    private func showEmojiButton(for field: NSTextField) {
        hideEmojiButton()
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: emojiButtonSize, height: emojiButtonSize))
        button.title = ""
        button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Insert emoji")
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(presentEmojiPicker)
        button.wantsLayer = true
        button.layer?.backgroundColor = KritColors.accent.cgColor
        button.layer?.cornerRadius = emojiButtonSize / 2
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.22
        button.layer?.shadowRadius = 3
        button.layer?.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(button)
        emojiButton = button
        repositionEmojiButton(for: field)
    }

    /// Centers the button horizontally over the field and floats it a fixed gap
    /// above the field's top edge. The canvas is flipped (top-left origin), so the
    /// field's visual top is its frame minY and the button sits above it at a
    /// smaller y.
    private func repositionEmojiButton(for field: NSTextField) {
        guard let button = emojiButton else { return }
        let x = field.frame.midX - emojiButtonSize / 2
        let y = field.frame.minY - emojiButtonGap - emojiButtonSize
        button.frame.origin = CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func hideEmojiButton() {
        emojiButton?.removeFromSuperview()
        emojiButton = nil
    }

    /// Opens the native macOS emoji and symbols palette. The picker inserts the
    /// chosen emoji into the current first responder, which is the active text
    /// field's field editor, so the emoji lands at the caret.
    @objc private func presentEmojiPicker() {
        // Make sure the field (its field editor) is first responder, otherwise the
        // palette has nowhere to insert.
        if let field = activeTextField, field.window?.firstResponder !== field.currentEditor() {
            field.becomeFirstResponder()
        }
        NSApp.orderFrontCharacterPalette(nil)
    }

    func duplicateSelected() {
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        var clones: [any AnnotationObject] = []
        for obj in selectedObjects {
            let clone = obj.cloneWithNewID()
            clone.move(by: CGPoint(x: 14, y: 14))
            if let step = clone as? NumberedStepAnnotation { step.number = nextStepNumber() }
            objects.append(clone)
            clones.append(clone)
        }
        setSelection(clones)
        setNeedsDisplay(bounds)
    }

    // MARK: - Styling

    func setActiveColor(_ color: NSColor) {
        activeColor = color
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        for obj in selectedObjects {
            obj.color = color
        }
        setNeedsDisplay(bounds)
    }

    func setActiveLineWidth(_ lineWidth: CGFloat) {
        activeLineWidth = lineWidth
        // Item 4: the slider value becomes this tool's remembered default for the
        // rest of the session, so re-picking the tool reopens at the same size.
        toolLineWidths[activeTool] = lineWidth
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        for obj in selectedObjects where !(obj is TextAnnotation) && !(obj is NumberedStepAnnotation) {
            obj.lineWidth = lineWidth
        }
        setNeedsDisplay(bounds)
    }

    func offsetContent(by delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }

        for obj in objects {
            obj.move(by: delta)
            if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
            if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
        }

        currentObject?.move(by: delta)

        if var crop = cropRect {
            crop.origin.x += delta.x
            crop.origin.y += delta.y
            cropRect = crop
            onCropChanged?(crop)
        }

        if let activeTextField {
            activeTextField.frame.origin.x += delta.x
            activeTextField.frame.origin.y += delta.y
            // Keep the pending commit origin in step with the shifted editor so a
            // text typed during a background change still commits where it shows.
            pendingTextOrigin = pendingTextOrigin.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            repositionEmojiButton(for: activeTextField)
        }

        setNeedsDisplay(bounds)
    }

    // MARK: - Undo / Redo
    //
    // Each snapshot is a full editor state: the annotation objects, the selection,
    // and the document itself (background image, canvas size, background options).
    // Capturing the document too is what makes crop and background changes
    // reversible. Crop undo is pixel-perfect because the snapshot holds the
    // ORIGINAL pre-crop NSImage by reference (our images are never mutated in
    // place), so restoring it is the exact source, not a recomposition.

    struct EditorSnapshot {
        let objects: [any AnnotationObject]
        let selected: [any AnnotationObject]
        let backgroundImage: NSImage?
        let canvasSize: NSSize
        let options: ScreenshotBackgroundOptions
    }

    private var undoSnapshots: [EditorSnapshot] = []
    private var redoSnapshots: [EditorSnapshot] = []

    /// Fired after undo/redo restores a snapshot whose document differs from the
    /// live one (image or canvas size changed, e.g. crop). The controller uses it
    /// to resync its own `image`, the canvas frame and the window size.
    var onDocumentRestored: (() -> Void)?
    /// Fired whenever the undo/redo stacks change depth, so the toolbar can enable
    /// or disable its undo/redo buttons.
    var onUndoStateChanged: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)?

    var canUndo: Bool { !undoSnapshots.isEmpty }
    var canRedo: Bool { !redoSnapshots.isEmpty }

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            objects: objects.map { $0.copy() },
            selected: selectedObjects.map { $0.copy() },
            backgroundImage: backgroundImage,
            canvasSize: frame.size,
            options: backgroundOptions
        )
    }

    func pushUndo() {
        undoSnapshots.append(currentSnapshot())
        redoSnapshots.removeAll()
        onUndoStateChanged?(canUndo, canRedo)
    }

    /// Drops the most recent undo snapshot without restoring it. Used when a press
    /// never became a real edit (a stray click that pushed undo at mousedown).
    func discardLastUndo() {
        guard !undoSnapshots.isEmpty else { return }
        undoSnapshots.removeLast()
        onUndoStateChanged?(canUndo, canRedo)
    }

    func performUndo() {
        guard let prev = undoSnapshots.popLast() else { return }
        redoSnapshots.append(currentSnapshot())
        applySnapshot(prev)
        onUndoStateChanged?(canUndo, canRedo)
    }

    func performRedo() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(currentSnapshot())
        applySnapshot(next)
        onUndoStateChanged?(canUndo, canRedo)
    }

    /// Restores a snapshot's full state. When the document (image or canvas size)
    /// differs from the live one, swap it back and tell the controller to resync.
    private func applySnapshot(_ snapshot: EditorSnapshot) {
        commitTextField()
        // A staged redaction preview is transient; restoring a snapshot drops it
        // so stale red boxes never linger over a different document state.
        if !smartRedactPreviews.isEmpty {
            smartRedactPreviews = []
            onSmartRedactStateChanged?(false)
            hideSmartRedactBanner()
        }
        let documentChanged = snapshot.backgroundImage !== backgroundImage
            || snapshot.canvasSize != frame.size
            || snapshot.options != backgroundOptions

        objects = snapshot.objects
        setSelection([])

        if documentChanged {
            backgroundImage = snapshot.backgroundImage
            backgroundOptions = snapshot.options
            // The canvas is the documentView of a centering clip view, so the
            // controller always sizes it at origin .zero; mirror that here.
            frame = NSRect(origin: .zero, size: snapshot.canvasSize)
            // Effect renders are tied to the old slot geometry; force a re-render.
            for obj in objects {
                if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
                if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
            }
            // The OCR cache is keyed on the old image; a different document means
            // a different image, so drop it. If the highlighter is active, re-warm
            // detection for the restored image.
            textRegionDetector.invalidate()
            if activeTool == .highlighter { prepareTextDetection() }
            onDocumentRestored?()
        }
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        // Space enters a transient pan mode (B5). Still types into text fields.
        // Restrict to a bare Space (no modifiers) so Cmd+Space / system shortcuts
        // aren't swallowed.
        let bareSpace = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if event.keyCode == 49, activeTextField == nil, bareSpace {
            if !spaceDown {
                spaceDown = true
                NSCursor.openHand.set()
            }
            return
        }

        // Smart Redact preview owns Enter (apply) and Esc (cancel) while staged,
        // so confirming the suggested boxes is one keystroke and bailing is Esc.
        if !smartRedactPreviews.isEmpty, activeTextField == nil {
            if event.keyCode == 36 || event.keyCode == 76 { applySmartRedact(); return }
            if event.keyCode == 53 { cancelSmartRedact(); return }
        }

        // Return/Enter commits a pending crop region (crop mode only).
        if activeTool == .crop, activeTextField == nil,
           event.keyCode == 36 || event.keyCode == 76,
           let crop = cropRect, crop.width >= 1, crop.height >= 1 {
            onCropCommit?()
            return
        }

        // Canvas zoom (B5): ⌘+ / ⌘- / ⌘0 (fit). Checked before ⌘Z below.
        if event.modifierFlags.contains(.command), activeTextField == nil {
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoomIn(); return
            case "-":      zoomOut(); return
            case "0":      fitToWindow(); return
            default: break
            }
        }

        // ⌘Z / ⌘⇧Z for undo/redo
        if event.modifierFlags.contains(.command) && event.keyCode == 6 {
            if event.modifierFlags.contains(.shift) {
                performRedo()
            } else {
                performUndo()
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete/Backspace
            deleteSelected()
            return
        }
        if event.keyCode == 53 { // Esc: cancel crop mode, else clear selection
            if activeTool == .crop {
                // Leave crop mode entirely: drop the region and fall back to
                // Select. The tool change syncs the toolbar via onToolChanged.
                cropRect = nil
                cropDragMode = nil
                onCropChanged?(nil)
                activeTool = .select
                setNeedsDisplay(bounds)
                return
            }
            if cropRect != nil {
                cropRect = nil
                onCropChanged?(nil)
            }
            setSelection([])
            setNeedsDisplay(bounds)
            return
        }
        // Arrow keys nudge the selection: 1pt, 10pt with Shift.
        if !selectedObjects.isEmpty, (123...126).contains(Int(event.keyCode)) {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var delta = CGPoint.zero
            switch Int(event.keyCode) {
            case 123: delta.x = -step
            case 124: delta.x = step
            case 125: delta.y = step    // flipped view: down is +y
            case 126: delta.y = -step
            default: break
            }
            pushUndo()
            for obj in selectedObjects {
                obj.move(by: delta)
                if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
                if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
            }
            // Item 3: a nudge can't push the selection past the image edges.
            clampSelectionToCanvas()
            setNeedsDisplay(bounds)
            return
        }
        // ⌘D duplicates the selection with a small cascade offset.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "d" {
            duplicateSelected()
            return
        }
        // Canvas zoom shortcuts: Cmd+plus / Cmd+minus step, Cmd+0 fits. The "="
        // key doubles as "+" so the unshifted keystroke works like every editor.
        if event.modifierFlags.contains(.command), activeTextField == nil {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                zoomIn(); onUserZoom?(); return
            case "-":
                zoomOut(); onUserZoom?(); return
            case "0":
                onUserFit?(); return
            default: break
            }
        }

        // Single-key tool shortcuts (only when no text field is active and no command key)
        if activeTextField == nil && !event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": activeTool = .select; return
            case "a": activeTool = .arrow; return
            case "r":
                if event.modifierFlags.contains(.shift) { activeTool = .filledRectangle }
                else { activeTool = .rectangle }
                return
            case "e": activeTool = .ellipse; return
            case "l": activeTool = .line; return
            case "d": activeTool = .freehand; return
            case "t": activeTool = .text; return
            case "n": activeTool = .numberedStep; return
            case "h": activeTool = .highlighter; return
            case "b": activeTool = .blur; return
            case "p": activeTool = .pixelate; return
            case "c": activeTool = .crop; return
            default: break
            }
        }

        // Nothing handled it: pass up the responder chain so menu key equivalents
        // and the default beep still work.
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {   // Space: leave pan mode, restore the tool cursor.
            clearSpacePan()
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - Zoom + pan (B5)
    //
    // Zoom rides NSScrollView's built-in magnification, so the canvas stays in
    // unscaled point space: convert(from: nil) remains magnification-aware and
    // annotation hit-testing/geometry need no changes. Magnification is enabled
    // lazily here so the controller (out of scope to edit) needs no setup.

    private func prepareScrollViewForZoom(_ sv: NSScrollView) {
        guard !sv.allowsMagnification else { return }
        sv.allowsMagnification = true
        sv.minMagnification = 0.1
        sv.maxMagnification = 8
    }

    private var currentMagnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// ES7: current canvas magnification, for the bottom-bar zoom popup.
    var zoomLevel: CGFloat { currentMagnification }

    func zoomIn() { setMagnification(currentMagnification * 1.25) }
    func zoomOut() { setMagnification(currentMagnification / 1.25) }

    /// ES7: set an exact magnification (driven by the bottom-bar zoom popup),
    /// centered on the canvas; emits onMagnificationChanged so the label tracks.
    func applyZoom(_ m: CGFloat) {
        setMagnification(m)
    }

    private func setMagnification(_ m: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        prepareScrollViewForZoom(sv)
        let clamped = min(max(m, sv.minMagnification), sv.maxMagnification)
        let centerInClip = CGPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
        sv.setMagnification(clamped, centeredAt: convert(centerInClip, from: sv.contentView))
        onMagnificationChanged?(clamped)
    }

    /// Diagnostics trail for the auto-fit path; every attempt appends one line.
    nonisolated(unsafe) static var uiTestFitLog: [String] = []

    @discardableResult
    func fitToWindow() -> CGFloat {
        guard let sv = enclosingScrollView else {
            AnnotationCanvas.uiTestFitLog.append("no-scrollview")
            return 1
        }
        prepareScrollViewForZoom(sv)
        // Viewport in WINDOW points (clip view frame), never bounds: with a
        // magnification applied, contentView.bounds is in document units and
        // grows as the zoom shrinks, so a second fit pass computed from bounds
        // lands back at 1.0 and silently undoes the fit (the "editor opens at
        // 100% on a huge shot" bug).
        let vp = sv.contentView.frame.size
        guard bounds.width > 0, bounds.height > 0 else {
            AnnotationCanvas.uiTestFitLog.append("zero-bounds vp=\(Int(vp.width))x\(Int(vp.height))")
            return currentMagnification
        }
        // Fit with breathing room: target ~90% of the viewport (about 5% margin per
        // side) so the composition never opens glued to the chrome edges. Still never
        // zoom past 100%, a tiny capture shouldn't balloon, only big ones shrink.
        let fitMargin: CGFloat = 0.9
        let fit = min(min(vp.width / bounds.width, vp.height / bounds.height) * fitMargin, 1)
        let clamped = min(max(fit, sv.minMagnification), sv.maxMagnification)
        AnnotationCanvas.uiTestFitLog.append(
            "vp=\(Int(vp.width))x\(Int(vp.height)) bounds=\(Int(bounds.width))x\(Int(bounds.height)) fit=\(String(format: "%.3f", fit)) clamped=\(String(format: "%.3f", clamped))"
        )
        sv.magnification = clamped
        // CenteringClipView recenters content smaller than the viewport.
        sv.contentView.scroll(to: CGPoint(
            x: (bounds.width - sv.contentView.bounds.width) / 2,
            y: (bounds.height - sv.contentView.bounds.height) / 2
        ))
        sv.reflectScrolledClipView(sv.contentView)
        onMagnificationChanged?(clamped)
        return clamped
    }

    // Pans the clip view by the cursor delta (window coordinates). isFlipped =
    // true, so a downward drag (window y decreasing) scrolls content downward.
    private func panBy(from anchor: CGPoint, to now: CGPoint) {
        guard let sv = enclosingScrollView else { return }
        let dx = now.x - anchor.x
        let dy = now.y - anchor.y
        var origin = sv.contentView.bounds.origin
        origin.x -= dx
        origin.y += dy   // flipped: window-up (dy>0) moves the document origin up
        sv.contentView.scroll(to: origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// Fired on any USER-driven zoom (pinch, Cmd+scroll, Cmd+plus/minus) so the
    /// controller can drop auto-fit mode; fit-driven changes never fire it.
    var onUserZoom: (() -> Void)?
    /// Fired when the user asks for fit (Cmd+0); the controller owns fit mode.
    var onUserFit: (() -> Void)?

    override func magnify(with event: NSEvent) {
        guard let sv = enclosingScrollView else { return }
        prepareScrollViewForZoom(sv)
        let target = currentMagnification * (1 + event.magnification)
        let clamped = min(max(target, sv.minMagnification), sv.maxMagnification)
        // Pinch zooms around the cursor so the point under the pointer stays put.
        sv.setMagnification(clamped, centeredAt: convert(event.locationInWindow, from: nil))
        onUserZoom?()
        onMagnificationChanged?(clamped)   // ES7: keep the popup label in sync
    }

    /// Cmd+scroll zooms around the cursor (the Snapzy/CleanShot canvas gesture);
    /// plain scrolling stays the scroll view's pan.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let sv = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        prepareScrollViewForZoom(sv)
        // Exponential factor: equal scroll steps give equal zoom ratios, and the
        // direction follows natural scrolling (up = in).
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        let target = currentMagnification * exp(delta)
        let clamped = min(max(target, sv.minMagnification), sv.maxMagnification)
        sv.setMagnification(clamped, centeredAt: convert(event.locationInWindow, from: nil))
        onUserZoom?()
        onMagnificationChanged?(clamped)
    }

    func deleteSelected() {
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        let ids = Set(selectedObjects.map(\.id))
        let removedSteps = objects.contains { ids.contains($0.id) && $0 is NumberedStepAnnotation }
        objects.removeAll { ids.contains($0.id) }
        if removedSteps { renumberSteps() }
        setSelection([])
        setNeedsDisplay(bounds)
    }

    /// Keeps counter badges sequential after a deletion (CleanShot behavior).
    private func renumberSteps() {
        let steps = objects.compactMap { $0 as? NumberedStepAnnotation }.sorted { $0.number < $1.number }
        for (index, step) in steps.enumerated() {
            step.number = index + 1
        }
    }

    // MARK: - Crop mode (CleanShot-style)
    //
    // The crop tool is a real cropping MODE, not a rectangle drawer: drag to
    // define a region (clamped to the screenshot slot), refine it with 8
    // resize handles or by dragging the interior, then commit with Return,
    // double-click or the toolbar check. Commit crops the BASE image; the
    // background composition re-renders around the new size.

    private enum CropDragMode {
        case create
        case move
        case resize(ResizeHandle)
    }
    private var cropDragMode: CropDragMode?
    private var cropDragAnchor: CGPoint?
    private var cropRectAtDragStart: CGRect?

    /// The area the crop region may cover: the screenshot slot when a
    /// background is composed, else the whole canvas. Cropping selects base
    /// image content, so the region never extends into the padded backdrop.
    private func cropBoundsRect() -> CGRect {
        guard let backgroundImage else { return bounds }
        return backgroundImageRect(for: backgroundImage)
    }

    /// Item 2: enter crop mode with the region already framing the whole shot.
    /// The user just nudges the 8 handles (or drags the interior) instead of
    /// drawing a rectangle from nothing, matching a photo editor's crop tool.
    private func enterCropModeFullImage() {
        // Live text would be lost once the region commits; settle it first.
        commitTextField()
        setSelection([])
        cropRect = cropBoundsRect()
        cropDragMode = nil
        cropDragAnchor = nil
        cropRectAtDragStart = nil
        onCropChanged?(cropRect)
        setNeedsDisplay(bounds)
    }

    private func clampPoint(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX),
                y: min(max(p.y, rect.minY), rect.maxY))
    }

    private func cropHandleHit(at point: CGPoint, crop: CGRect) -> ResizeHandle? {
        for handle in ResizeHandle.allCases
        where hit(point, center: resizeHandleCenter(for: crop, handle: handle), radius: 10) {
            return handle
        }
        return nil
    }

    private func handleCropDown(at point: CGPoint, clickCount: Int) {
        if let crop = cropRect, !crop.isEmpty {
            if clickCount == 2, crop.contains(point) {
                onCropCommit?()
                return
            }
            if let handle = cropHandleHit(at: point, crop: crop) {
                cropDragMode = .resize(handle)
                cropDragAnchor = point
                cropRectAtDragStart = crop
                return
            }
            if crop.contains(point) {
                cropDragMode = .move
                cropDragAnchor = point
                cropRectAtDragStart = crop
                return
            }
        }
        // Outside any existing region: start a fresh one.
        let start = clampPoint(point, to: cropBoundsRect())
        cropDragMode = .create
        cropDragAnchor = start
        cropRectAtDragStart = nil
        cropRect = CGRect(origin: start, size: .zero)
        onCropChanged?(cropRect)
        setNeedsDisplay(bounds)
    }

    private func handleCropDrag(to point: CGPoint) {
        guard let mode = cropDragMode, let anchor = cropDragAnchor else { return }
        let region = cropBoundsRect()
        let previous = cropRect
        switch mode {
        case .create:
            cropRect = rectFrom(anchor, to: clampPoint(point, to: region))
        case .move:
            guard var crop = cropRectAtDragStart else { return }
            let dx = min(max(point.x - anchor.x, region.minX - crop.minX), region.maxX - crop.maxX)
            let dy = min(max(point.y - anchor.y, region.minY - crop.minY), region.maxY - crop.maxY)
            crop.origin.x += dx
            crop.origin.y += dy
            cropRect = crop
        case .resize(let handle):
            guard let start = cropRectAtDragStart else { return }
            let clamped = clampPoint(point, to: region)
            let delta = CGPoint(x: clamped.x - anchor.x, y: clamped.y - anchor.y)
            let resized = resizedRect(from: start, handle: handle, by: delta).intersection(region)
            if !resized.isNull, !resized.isEmpty { cropRect = resized }
        }
        onCropChanged?(cropRect)
        // The dim only flips state inside old ∪ new, so this union redraw covers it.
        invalidate(previous, cropRect, padding: 14)
    }

    private func handleCropUp() {
        if case .create = cropDragMode, let crop = cropRect, crop.width < 3 || crop.height < 3 {
            // A still click never became a region.
            cropRect = nil
            onCropChanged?(nil)
        }
        cropDragMode = nil
        cropDragAnchor = nil
        cropRectAtDragStart = nil
        setNeedsDisplay(bounds)
    }

    /// Commits the crop against the BASE screenshot (not the flattened
    /// composition): maps the region from canvas space to source pixels, crops
    /// them at native resolution, drops annotations that fall entirely outside
    /// and translates the rest so they stay registered with the kept content.
    /// Returns the new base image; the controller swaps it in, resizes the
    /// canvas and re-renders the background composition at the new size.
    func applyCrop() -> NSImage? {
        guard let bg = backgroundImage, let rawCrop = cropRect, !rawCrop.isEmpty else { return nil }
        // Live text would get lost in the coordinate shift; commit it first.
        commitTextField()

        // The region selects screenshot content; clamp to the image slot
        // (the whole canvas when no background is composed).
        let crop = rawCrop.standardized.intersection(cropBoundsRect())
        guard crop.width >= 1, crop.height >= 1 else { return nil }

        // Item 1: crop is undoable. Snapshot the full pre-crop document (original
        // image by reference, canvas size, options, annotation positions) BEFORE
        // mutating anything, so ⌘Z restores the exact original pixels and layout.
        pushUndo()

        guard let srcCG = bg.bestCGImage else { return nil }
        let pixelSize = CGSize(width: srcCG.width, height: srcCG.height)
        // viewRectToCGImageRect maps through the slot geometry and both spaces
        // are top-left origin, so the rect carries straight over (no Y flip).
        guard let mapped = viewRectToCGImageRect(crop, imageSize: pixelSize) else { return nil }
        let pixelCrop = CGRect(
            x: mapped.origin.x.rounded(),
            y: mapped.origin.y.rounded(),
            width: mapped.width.rounded(),
            height: mapped.height.rounded()
        ).intersection(CGRect(origin: .zero, size: pixelSize))
        guard !pixelCrop.isEmpty, let croppedCG = srcCG.cropping(to: pixelCrop) else { return nil }

        // Preserve the source's pixels-per-point so a Retina capture stays
        // Retina after the crop (rep carries native pixels, reports points).
        let nativeScale = max(pixelSize.width / max(bg.size.width, 1),
                              pixelSize.height / max(bg.size.height, 1), 1)
        let newPointSize = NSSize(width: CGFloat(croppedCG.width) / nativeScale,
                                  height: CGFloat(croppedCG.height) / nativeScale)
        let rep = NSBitmapImageRep(cgImage: croppedCG)
        rep.size = newPointSize
        let result = NSImage(size: newPointSize)
        result.addRepresentation(rep)

        // Annotations entirely outside the kept region are discarded; the rest
        // translate by the slot delta so they follow the content they annotate.
        objects.removeAll { !visualBounds(for: $0).intersects(crop) }
        let newSlotOrigin: CGPoint
        if backgroundOptions.isEnabled {
            let newCanvasSize = ScreenshotBackgroundComposer.outputPointSize(
                for: newPointSize, options: backgroundOptions
            )
            newSlotOrigin = ScreenshotBackgroundComposer.imageSlotOrigin(
                imageSize: newPointSize, canvasSize: newCanvasSize, options: backgroundOptions
            )
        } else {
            newSlotOrigin = .zero
        }
        let delta = CGPoint(x: newSlotOrigin.x - crop.origin.x, y: newSlotOrigin.y - crop.origin.y)
        for obj in objects {
            obj.move(by: delta)
            if let blur = obj as? BlurAnnotation { blur.cachedRender = nil }
            if let pixelate = obj as? PixelateAnnotation { pixelate.cachedRender = nil }
        }
        setSelection([])

        cropRect = nil
        cropDragMode = nil
        cropDragAnchor = nil
        cropRectAtDragStart = nil
        onCropChanged?(nil)
        // Item 1: the snapshot pushed above carries the original document, so the
        // stacks are kept (no longer wiped) and ⌘Z reverses the crop. The new
        // image/frame are applied by the controller after this returns; that
        // post-crop state becomes the redo target on the next ⌘Z.
        // Crop mode is done; hand control back to Select (syncs the toolbar).
        activeTool = .select
        return result
    }

    // MARK: - Flatten to NSImage
    //
    // Composites into a CGContext sized to the SOURCE pixel dimensions, not the
    // view's backing scale, so a 1x (or headless) display never silently
    // downsamples a Retina capture. Geometry stays in points; the CTM scales it
    // to native pixels, keeping hairlines crisp at full resolution (D3).

    func flatten() -> NSImage {
        let pointSize = bounds.size
        guard pointSize.width > 0, pointSize.height > 0 else { return NSImage() }

        // Native pixel/point ratio: from the screenshot's own pixels when present,
        // else the window backing scale (detached canvas falls back to 2).
        let nativeScale: CGFloat
        if let bg = backgroundImage, let srcCG = bg.bestCGImage, bg.size.width > 0, bg.size.height > 0 {
            nativeScale = max(CGFloat(srcCG.width) / bg.size.width,
                              CGFloat(srcCG.height) / bg.size.height, 1)
        } else {
            nativeScale = max(window?.backingScaleFactor ?? 2, 1)
        }

        let pixelW = max(1, Int(ceil(pointSize.width * nativeScale)))
        let pixelH = max(1, Int(ceil(pointSize.height * nativeScale)))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage() }

        // Top-left origin in point space (matches the flipped canvas), rasterized
        // at nativeScale. After this the draw pipeline is identical to draw(_:).
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: nativeScale, y: -nativeScale)
        ctx.interpolationQuality = .high

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        // Same draw order as draw(_:), minus all editing chrome.
        if let img = backgroundImage {
            drawBackgroundImage(img, ctx: ctx)
        }
        // Item 3, export-side guarantee: clip every annotation to the canvas so
        // nothing renders past the final image edges, even if a stray object
        // slipped outside. The background fills the whole canvas above, so clipping
        // it too is harmless.
        ctx.clip(to: CGRect(origin: .zero, size: pointSize))
        for obj in objects {
            if let blur = obj as? BlurAnnotation {
                drawBlur(blur, ctx: ctx)
            } else if let px = obj as? PixelateAnnotation {
                drawPixelate(px, ctx: ctx)
            }
        }
        for obj in objects {
            if obj is BlurAnnotation || obj is PixelateAnnotation { continue }
            obj.draw(in: ctx, scale: nativeScale)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return NSImage() }
        // rep reports point size but carries native pixels, so bestCGImage pulls
        // the full-resolution image for PNG encode (no downsample downstream).
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        let img = NSImage(size: pointSize)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - NSTextFieldDelegate

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) { commitTextField() }

    // Grow the in-place editor with its content so typing never clips.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = activeTextField, let font = field.font else { return }
        let size = (field.stringValue as NSString).size(withAttributes: [.font: font])
        field.frame.size.width = max(size.width + 24, 80)
        repositionEmojiButton(for: field)
    }
}
