import AppKit

// MARK: - Overlay NSWindow

/// Full-screen panel that hosts the live annotation surface over one display.
/// A non-activating panel so it can become key (Esc, ⌘Z) without stealing
/// frontmost/active appearance from whatever app the presenter is showing —
/// the exact pattern `AreaSelectionWindow`'s `SelectionOverlayWindow` uses.
@MainActor
final class LiveAnnotationOverlayWindow: NSPanel {

    let surfaceView: LiveAnnotationSurfaceView

    init(screenFrame: CGRect) {
        surfaceView = LiveAnnotationSurfaceView(frame: CGRect(origin: .zero, size: screenFrame.size))
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Starts click-through; the controller flips this to false only while
        // in `.drawing` mode.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A floating panel auto-hides when its owning app deactivates by
        // default, and passive mode deliberately deactivates KRIT (handing
        // focus back to the app underneath) while the ink must stay ON
        // SCREEN. Both flags below undo that default, mirroring
        // AreaSelectionWindow's SelectionOverlayWindow.
        isFloatingPanel = false
        hidesOnDeactivate = false
        // Same level PresentationZoomController's magnifier uses: above
        // everything a presenter shows, including the menu bar. MUST be set
        // AFTER isFloatingPanel — that setter resets the panel's level, which
        // silently demoted both annotation windows to .normal (ink sank behind
        // clicked apps, and the full-screen overlay ate the toolbar's clicks).
        level = .screenSaver
        // Deliberately NO sharingType = .none, unlike the toolbar. This window
        // shows the live ink itself: a presenter screen-sharing or recording
        // with KRIT needs their audience (and their own recording) to see the
        // marks, exactly the reasoning in PresentationZoomController's window
        // comment for the same property. The toolbar's chrome is the only
        // piece that should stay invisible to captures.
        contentView = surfaceView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Surface NSView

/// The drawing surface itself: renders every annotation object plus the one
/// in progress, and turns mouse/keyboard input into new objects, moves, undo
/// and text editing. A reduced sibling of the screenshot editor's
/// `AnnotationCanvas` — same model types (`AnnotationObject`), same flipped
/// top-left coordinate convention, but no background bitmap (the "background"
/// is the real desktop compositing underneath this transparent window) and no
/// resize handles (select here only moves objects; a full manipulate-after-the-
/// fact editor is what the screenshot flow is for).
@MainActor
final class LiveAnnotationSurfaceView: NSView {

    // MARK: State

    var activeTool: AnnotationTool = .arrow {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var activeColor: NSColor = KritColors.accent
    var activeLineWidth: CGFloat = 6

    /// Hide/show without deleting (the toolbar's eye button).
    var inkVisible = true {
        didSet { setNeedsDisplay(bounds) }
    }

    var objects: [any AnnotationObject] = [] {
        didSet { setNeedsDisplay(bounds) }
    }
    private var selectedObjects: [any AnnotationObject] = []
    private var currentObject: (any AnnotationObject)?
    private var dragStart: CGPoint?
    private var lastEventModifiers: NSEvent.ModifierFlags = []

    private var isMoving = false
    private var moveDragStart: CGPoint?
    private var didPushMoveUndo = false

    private var undoStack: [[any AnnotationObject]] = []
    private var redoStack: [[any AnnotationObject]] = []
    var onUndoStateChanged: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Esc with nothing left to dismiss locally (no selection, no in-place text
    /// edit) bubbles up to the controller: exit draw mode, keep the ink.
    var onRequestExitDrawMode: (() -> Void)?

    // Text tool
    private var activeTextView: NSTextView?
    private var pendingTextOrigin: CGPoint?
    private var editingTextAnnotation: TextAnnotation?
    private var textCommitClickMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor = textCommitClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override var isFlipped: Bool { true } // top-left origin, matches AnnotationCanvas
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        switch activeTool {
        case .select:       cursor = .arrow
        case .text:         cursor = .iBeam
        case .numberedStep: cursor = .pointingHand
        default:            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard inkVisible else { return }

        for obj in objects {
            if let editing = editingTextAnnotation, editing.id == obj.id { continue }
            obj.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
        }
        currentObject?.draw(in: ctx, scale: window?.backingScaleFactor ?? 2)
        for obj in selectedObjects {
            drawSelectionOutline(for: obj, ctx: ctx)
        }
    }

    /// Simple dashed bounding-box outline. There are no resize handles here
    /// (see the type doc comment), so this is only a "this is selected"
    /// indicator, not a manipulation affordance.
    private func drawSelectionOutline(for obj: any AnnotationObject, ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(KritColors.accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(obj.bounds)
        ctx.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let textHit = topHit(at: point) as? TextAnnotation {
            commitTextField()
            beginTextEdit(of: textHit)
            return
        }
        commitTextField()

        switch activeTool {
        case .select:
            handleSelectDown(at: point)
            return
        case .text:
            beginTextEntry(at: point)
            return
        case .numberedStep:
            pushUndo()
            let step = NumberedStepAnnotation(center: point, number: nextStepNumber())
            step.color = activeColor
            objects.append(step)
            setSelection([step])
            return
        default:
            break
        }

        // A drawing tool can still grab the body of an already-selected object
        // (CleanShot policy, mirrored from AnnotationCanvas): otherwise a click
        // meant to reposition what you just drew would draw a new shape on
        // top of it instead.
        if selectedObjects.contains(where: { $0.contains(point: point) }) {
            beginMove(at: point)
            return
        }

        pushUndo()
        dragStart = point
        currentObject = makeObject(at: point)
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select || isMoving {
            handleSelectDrag(to: point)
            return
        }

        let previousBounds = currentObject?.bounds
        updateCurrentObject(to: point)
        invalidate(previousBounds, currentObject?.bounds)
    }

    override func mouseUp(with event: NSEvent) {
        lastEventModifiers = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)

        if activeTool == .select || isMoving {
            handleSelectUp()
            return
        }

        guard let obj = currentObject else { return }
        currentObject = nil
        if isDegenerate(obj) {
            // The press never became a real shape: drop the undo snapshot
            // pushed at mouseDown and treat the still click as a selection tap.
            discardLastUndo()
            setSelection(topHit(at: point).map { [$0] } ?? [])
        } else {
            objects.append(obj)
            setSelection([obj])
        }
        dragStart = nil
        setNeedsDisplay(bounds)
    }

    private func topHit(at point: CGPoint) -> (any AnnotationObject)? {
        objects.last(where: { $0.contains(point: point) })
    }

    // MARK: - Select tool (move only, no resize handles)

    private func handleSelectDown(at point: CGPoint) {
        if let hit = topHit(at: point) {
            if !selectedObjects.contains(where: { $0.id == hit.id }) {
                setSelection([hit])
            }
            beginMove(at: point)
        } else {
            setSelection([])
        }
    }

    private func beginMove(at point: CGPoint) {
        guard !selectedObjects.isEmpty else { return }
        isMoving = true
        moveDragStart = point
        didPushMoveUndo = false
    }

    private func handleSelectDrag(to point: CGPoint) {
        guard isMoving, let start = moveDragStart else { return }
        if !didPushMoveUndo {
            pushUndo()
            didPushMoveUndo = true
        }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        for obj in selectedObjects { obj.move(by: delta) }
        moveDragStart = point
        setNeedsDisplay(bounds)
    }

    private func handleSelectUp() {
        isMoving = false
        moveDragStart = nil
        didPushMoveUndo = false
    }

    func setSelection(_ objs: [any AnnotationObject]) {
        selectedObjects = objs
        setNeedsDisplay(bounds)
    }

    // MARK: - Shape creation

    private func makeObject(at point: CGPoint) -> (any AnnotationObject)? {
        switch activeTool {
        case .arrow:
            let a = ArrowAnnotation(start: point, end: point)
            a.color = activeColor; a.lineWidth = activeLineWidth
            return a
        case .line:
            let l = LineAnnotation(start: point, end: point)
            l.color = activeColor; l.lineWidth = activeLineWidth
            return l
        case .rectangle:
            let r = RectangleAnnotation(rect: CGRect(origin: point, size: .zero), filled: false)
            r.color = activeColor; r.lineWidth = activeLineWidth
            return r
        case .ellipse:
            let e = EllipseAnnotation(rect: CGRect(origin: point, size: .zero))
            e.color = activeColor; e.lineWidth = activeLineWidth
            return e
        case .freehand:
            let f = FreehandAnnotation()
            f.points = [point]; f.color = activeColor; f.lineWidth = activeLineWidth
            return f
        case .highlighter:
            let h = HighlighterAnnotation(start: point, end: point)
            h.color = activeColor
            return h
        default:
            return nil
        }
    }

    private func updateCurrentObject(to rawPoint: CGPoint) {
        guard let start = dragStart else { return }
        switch currentObject {
        case let a as ArrowAnnotation:
            a.endPoint = shiftConstrainedPoint(from: start, to: rawPoint)
        case let l as LineAnnotation:
            l.endPoint = shiftConstrainedPoint(from: start, to: rawPoint)
        case let r as RectangleAnnotation:
            r.rect = shiftConstrainedRect(from: start, to: rawPoint)
        case let e as EllipseAnnotation:
            e.rect = shiftConstrainedRect(from: start, to: rawPoint)
        case let f as FreehandAnnotation:
            appendFreehandPoint(rawPoint, to: f)
        case let h as HighlighterAnnotation:
            h.endPoint = rawPoint
        default:
            break
        }
    }

    /// Shift constrains a fresh arrow/line to 45° steps (used at both the
    /// arrow call site here and wherever a future line-like tool joins it).
    private func shiftConstrainedPoint(from start: CGPoint, to point: CGPoint) -> CGPoint {
        lastEventModifiers.contains(.shift) ? constrain45(from: start, to: point) : point
    }

    /// Shift constrains a fresh rect to a square (shared by rectangle and ellipse).
    private func shiftConstrainedRect(from start: CGPoint, to point: CGPoint) -> CGRect {
        lastEventModifiers.contains(.shift) ? squareRect(from: start, to: point) : rectFrom(start, to: point)
    }

    /// Freehand only appends a new point once the pen has actually moved past
    /// the jitter floor, so a near-stationary drag doesn't flood the path.
    private func appendFreehandPoint(_ point: CGPoint, to freehand: FreehandAnnotation) {
        if let last = freehand.points.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
        freehand.points.append(point)
    }

    private func isDegenerate(_ obj: any AnnotationObject) -> Bool {
        switch obj {
        case let a as ArrowAnnotation:
            return hypot(a.endPoint.x - a.startPoint.x, a.endPoint.y - a.startPoint.y) < 4
        case let l as LineAnnotation:
            return hypot(l.endPoint.x - l.startPoint.x, l.endPoint.y - l.startPoint.y) < 4
        case let r as RectangleAnnotation:
            return r.rect.width * r.rect.height < 16
        case let e as EllipseAnnotation:
            return e.rect.width * e.rect.height < 16
        case let h as HighlighterAnnotation:
            return hypot(h.endPoint.x - h.startPoint.x, h.endPoint.y - h.startPoint.y) < 4
        case let f as FreehandAnnotation:
            return f.points.count < 3
        default:
            return false
        }
    }

    private func nextStepNumber() -> Int {
        let existing = objects.compactMap { ($0 as? NumberedStepAnnotation)?.number }
        return (existing.max() ?? 0) + 1
    }

    private func renumberSteps() {
        let steps = objects.compactMap { $0 as? NumberedStepAnnotation }.sorted { $0.number < $1.number }
        for (index, step) in steps.enumerated() {
            step.number = index + 1
        }
    }

    private func invalidate(_ old: CGRect?, _ new: CGRect?) {
        let padding = activeLineWidth + 12
        if let old { setNeedsDisplay(old.insetBy(dx: -padding, dy: -padding)) }
        if let new { setNeedsDisplay(new.insetBy(dx: -padding, dy: -padding)) }
        if old == nil && new == nil { setNeedsDisplay(bounds) }
    }

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func squareRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let dx = b.x - a.x, dy = b.y - a.y
        let side = max(abs(dx), abs(dy))
        let sx: CGFloat = dx < 0 ? -side : side
        let sy: CGFloat = dy < 0 ? -side : side
        return rectFrom(a, to: CGPoint(x: a.x + sx, y: a.y + sy))
    }

    private func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return b }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    // MARK: - Delete / clear

    func deleteSelected() {
        guard !selectedObjects.isEmpty else { return }
        pushUndo()
        let ids = Set(selectedObjects.map(\.id))
        let removedSteps = objects.contains { ids.contains($0.id) && $0 is NumberedStepAnnotation }
        objects.removeAll { ids.contains($0.id) }
        if removedSteps { renumberSteps() }
        setSelection([])
    }

    /// The toolbar's trash button: wipes every mark and stays active, as opposed
    /// to `LiveAnnotationController.deactivate` which tears the whole session
    /// down. Clear is a one-way action (spec: "Clear is not undoable"), so it
    /// wipes the undo/redo history too — ⌘Z right after must not resurrect what
    /// was just cleared.
    func clearAll() {
        guard !objects.isEmpty else { return }
        objects.removeAll()
        setSelection([])
        undoStack.removeAll()
        redoStack.removeAll()
        onUndoStateChanged?(canUndo, canRedo)
    }

    // MARK: - Undo / redo

    private func snapshotObjects() -> [any AnnotationObject] { objects.map { $0.copy() } }

    /// Automation/test hook (`krit live-annotation --action seed-ink`):
    /// deterministically appends one freehand stroke as if the user had drawn
    /// it, so headless flows can exercise ink-dependent states (passive keeps
    /// ink, golden images) without synthetic mouse input.
    func seedTestInk() {
        pushUndo()
        let savedTool = activeTool
        activeTool = .freehand
        let start = CGPoint(x: bounds.midX - 100, y: bounds.midY - 40)
        currentObject = makeObject(at: start)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            updateCurrentObject(to: CGPoint(x: start.x + 200 * t, y: start.y + 80 * t * t))
        }
        if let obj = currentObject { objects.append(obj) }
        currentObject = nil
        activeTool = savedTool
        setNeedsDisplay(bounds)
    }

    func pushUndo() {
        undoStack.append(snapshotObjects())
        redoStack.removeAll()
        onUndoStateChanged?(canUndo, canRedo)
    }

    func discardLastUndo() {
        guard !undoStack.isEmpty else { return }
        undoStack.removeLast()
        onUndoStateChanged?(canUndo, canRedo)
    }

    func performUndo() {
        // Commit any open text field FIRST: committing itself mutates the
        // undo/redo stacks (pushUndo), so doing it after snapshotting would wipe
        // the redo entry we just pushed and drop the typed text on `objects =`.
        commitTextField()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshotObjects())
        objects = previous
        setSelection([])
        onUndoStateChanged?(canUndo, canRedo)
    }

    func performRedo() {
        commitTextField()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshotObjects())
        objects = next
        setSelection([])
        onUndoStateChanged?(canUndo, canRedo)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc: progressively dismiss, then hand off to the controller
            if activeTextView != nil {
                cancelTextField()
                return
            }
            if !selectedObjects.isEmpty {
                setSelection([])
                return
            }
            onRequestExitDrawMode?()
            return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 6 { // ⌘Z / ⌘⇧Z
            if event.modifierFlags.contains(.shift) { performRedo() } else { performUndo() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Backspace
            deleteSelected()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Text tool

    private var activeTextFont: NSFont { .systemFont(ofSize: 24, weight: .bold) }

    private func beginTextEntry(at point: CGPoint) {
        let font = activeTextFont
        let view = makeTextView(font: font, color: activeColor)
        pendingTextOrigin = point
        view.frame = NSRect(x: point.x, y: point.y, width: 220, height: font.ascender - font.descender + 6)
        addSubview(view)
        // makeFirstResponder via the window — calling becomeFirstResponder()
        // directly never routes the key loop, so the field silently ate no
        // keystrokes at all (the original "text tool does nothing" bug).
        window?.makeFirstResponder(view)
        activeTextView = view
        installTextCommitClickMonitor()
    }

    /// Re-opens an existing text annotation for editing, WYSIWYG: same font,
    /// size and color; the object's own render is hidden until commit.
    func beginTextEdit(of annotation: TextAnnotation) {
        pushUndo()
        editingTextAnnotation = annotation
        pendingTextOrigin = nil
        setSelection([])

        let view = makeTextView(font: annotation.font, color: annotation.color)
        view.string = annotation.text
        let size = annotation.textSize
        view.frame = NSRect(x: annotation.origin.x, y: annotation.origin.y,
                            width: max(size.width + 24, 80), height: size.height + 4)
        addSubview(view)
        window?.makeFirstResponder(view)
        view.selectAll(nil)
        activeTextView = view
        installTextCommitClickMonitor()
        setNeedsDisplay(bounds)
    }

    private func makeTextView(font: NSFont, color: NSColor) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = true
        // A faint backing plate + colored caret: with no background and no focus
        // ring an empty field is literally invisible over the live desktop, and
        // the tool reads as broken before the first keystroke.
        view.drawsBackground = true
        view.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        view.insertionPointColor = color
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.font = font
        view.textColor = color
        view.isRichText = false
        view.usesFontPanel = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = self
        return view
    }

    func commitTextField() {
        guard let view = activeTextView else { return }
        let text = view.string.trimmingCharacters(in: .whitespaces)
        let origin = pendingTextOrigin
        pendingTextOrigin = nil

        if let editing = editingTextAnnotation {
            if text.isEmpty {
                objects.removeAll { $0.id == editing.id }
            } else {
                editing.text = text
            }
            editingTextAnnotation = nil
        } else if !text.isEmpty {
            pushUndo()
            let ann = TextAnnotation(origin: origin ?? view.frame.origin)
            ann.text = text
            ann.color = activeColor
            objects.append(ann)
            setSelection([ann])
            if activeTool == .text { activeTool = .select }
        }
        view.removeFromSuperview()
        activeTextView = nil
        removeTextCommitClickMonitor()
        setNeedsDisplay(bounds)
    }

    /// Esc while a text field is open cancels the FIELD, not the mode (spec):
    /// a fresh entry is dropped without ever becoming an annotation, and an
    /// in-place edit of an existing annotation is abandoned with its original
    /// text intact.
    func cancelTextField() {
        guard let view = activeTextView else { return }
        pendingTextOrigin = nil
        if editingTextAnnotation != nil {
            // `beginTextEdit` pushed an undo snapshot and hid the annotation; we
            // never touched its text, so drop that snapshot and let it draw again.
            editingTextAnnotation = nil
            discardLastUndo()
        }
        view.removeFromSuperview()
        activeTextView = nil
        removeTextCommitClickMonitor()
        setNeedsDisplay(bounds)
    }

    private func installTextCommitClickMonitor() {
        removeTextCommitClickMonitor()
        textCommitClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard let view = self.activeTextView else {
                self.removeTextCommitClickMonitor()
                return event
            }
            if event.window === view.window {
                let local = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(local) { return event }
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
}

// MARK: - NSTextViewDelegate

extension LiveAnnotationSurfaceView: NSTextViewDelegate {
    func textDidEndEditing(_ notification: Notification) { commitTextField() }

    /// Grows the in-place editor with its content so typing never clips.
    func textDidChange(_ notification: Notification) {
        guard let view = activeTextView, let font = view.font else { return }
        let size = (view.string as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).size
        view.frame.size.width = max(ceil(size.width) + 24, 80)
        view.frame.size.height = max(ceil(size.height), ceil(font.ascender - font.descender)) + 4
    }

    /// Return commits; Shift+Return inserts a real newline; Esc cancels. The
    /// text view owns first responder while typing, so Esc arrives here as
    /// `cancelOperation(_:)` — the surface view's own keyDown never sees it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            commitTextField()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextField()
            return true
        }
        return false
    }
}
