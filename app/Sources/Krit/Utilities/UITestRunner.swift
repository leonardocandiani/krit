import AppKit
import KeyboardShortcuts
import AudioToolbox
import os

/// Harness de validação empírica da UI: recebe "cenário|/saida.json" via
/// distributed notification "com.krit.test.ui", injeta eventos de mouse/teclado
/// REAIS na janela (window.sendEvent, o mesmo pipeline de hit-test e handlers
/// do clique humano) e afirma o ESTADO resultante (objeto moveu, opção aplicou,
/// nível da janela), escrevendo um relatório JSON. Não exige Acessibilidade
/// porque os eventos nunca saem do processo.
///
/// Cenários:
///  - "editor-suite": abre o editor real e valida nível da janela, mover
///    elemento por arrasto no corpo, slider de padding aplicando sem distorcer,
///    seleção de wallpaper + toggle de blur.
///  - "sound": resolve e TOCA o som de captura (prova audível) + status da API.
///  - "preferences": abre a janela de Settings, percorre todas as seções e
///    snapshota cada uma em PNG, validando abertura, contagem e tamanho.
@MainActor
final class UITestRunner: NSObject {

    static let notificationName = Notification.Name("com.krit.test.ui")
    private static let log = Logger(subsystem: "com.krit.app", category: "uitest")

    override init() {
        super.init()
        // Segurança: o IPC do harness é opt-in por lançamento. App lançado normal
        // (Finder/Dock/open) NUNCA registra o observer, então nenhum processo local
        // consegue disparar captura/gravação nem escrever arquivo através dele
        // (DistributedNotification não autentica o remetente). A bateria de testes
        // lança o binário direto com KRIT_UI_TEST=1 no ambiente.
        guard ProcessInfo.processInfo.environment["KRIT_UI_TEST"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handle(_:)),
            name: Self.notificationName,
            object: nil
        )
    }

    @objc private func handle(_ note: Notification) {
        guard let payload = note.object as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].hasPrefix("/") else {
            Self.log.error("uitest: malformed payload \(payload)")
            return
        }
        let scenario = parts[0]
        // Segurança: o remetente não é autenticado, então o destino do write não
        // pode ser arbitrário. Reports só pousam em /tmp (path resolvido, sem
        // escapar por symlink).
        let outPath = URL(fileURLWithPath: parts[1]).resolvingSymlinksInPath().path
        guard outPath.hasPrefix("/tmp/") || outPath.hasPrefix("/private/tmp/") else {
            Self.log.error("uitest: rejected out path \(parts[1], privacy: .public)")
            return
        }
        Task { @MainActor in
            var report: [String: Any] = ["scenario": scenario]
            switch scenario {
            case "editor-suite": report = await Self.runEditorSuite()
            case "sound":        report = Self.runSoundProbe()
            case "onboarding":   report = await Self.runOnboardingSuite()
            case "preferences":  report = await Self.runPreferencesSuite()
            case "overlay-show": report = await Self.runOverlayShowSuite()
            case "blur-map":     report = await Self.runBlurMapSuite()
            case "overlay-trace": report = await Self.runOverlayCaptureTrace()
            case "window-capture": report = await Self.runWindowCaptureSuite()
            case "history-restore": report = await Self.runHistoryRestoreSuite()
            case "preset-gallery": report = await Self.runPresetGallery()
            case "preset-save": report = await Self.runPresetSaveSuite()
            case "preset-default-open": report = await Self.runPresetDefaultOpenSuite()
            case "highlighter-partial": report = await Self.runHighlighterPartialSuite()
            case "ocr":          report = await Self.runOCRSuite()
            case "shadow-sweep": report = Self.runShadowSweep()
            case "window-editor": report = await Self.runWindowEditorSuite()
            case "record-smoke": report = await Self.runRecordSmoke()
            case "record-smoke-audio": report = await Self.runRecordSmoke(systemAudio: true)
            case "record-smoke-mic": report = await Self.runRecordSmoke(microphone: true)
            case "smart-redact":  report = await Self.runSmartRedactSuite()
            case "glass-renders": report = await Self.runGlassRenders()
            case "default-template": report = await Self.runDefaultTemplateSuite()
            case "editor-fit-large": report = await Self.runEditorFitLargeSuite()
            case "editor-fit-tall": report = await Self.runEditorFitTallSuite()
            case "chooser-visual": report = await Self.runChooserVisual()
            case "compose-scale": report = await Self.runComposeScaleSuite()
            case "wallpaper-dump": report = await Self.runWallpaperDump()
            case "overlay-entrance": report = await Self.runOverlayEntranceFrames()
            case "area-delay": report = await Self.runAreaSelectionDelay()
            case "overlay-interaction": report = await Self.runOverlayInteraction()
            case "area-delay-real": report = await Self.runAreaDelayReal()
            case "overlay-postgesture": report = await Self.runOverlayPostGesture()
            case "update-check": report = await Self.runUpdateCheck()
            case "color-pick": report = await Self.runColorPick()
            case "alignment": report = await Self.runAlignment()
            case "wallpaper-apply": report = await Self.runWallpaperApply()
            case "wallpaper-sweep": report = await Self.runWallpaperSweep()
            case "sidebar-motion": report = await Self.runSidebarMotion()
            case "prefs-bottom": report = await Self.runPrefsBottom()
            case "controls-demo": report = await Self.runControlsDemo()
            case "drag-prep": report = await Self.runDragPrep()
            case "overlay-foreign-vis": report = await Self.runOverlayForeignVis()
            case "editor-draw-perf": report = await Self.runEditorDrawPerf()
            case "arrow-scale": report = await Self.runArrowScale()
            case "editor-off-render": report = await Self.runEditorOffRender()
            case "export-formats": report = await Self.runExportFormats()
            case "overlay-conveyor": report = await Self.runOverlayConveyor()
            case "overlay-space-stress": report = await Self.runOverlaySpaceStress()
            case "overlay-park-capture": report = await Self.runOverlayParkCapture()
            case "prefs-shortcuts": report = await Self.runPrefsShortcuts()
            case "autozoom-core": report = Self.runAutoZoomCore()
            default:             report["error"] = "unknown scenario"
            }
            report["scenario"] = scenario
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: outPath))
            }
        }
    }

    // MARK: - Cenário: overlay-conveyor (esteira: stack inteira segue o standby)

    /// Prova a "esteira": com 3 cards empilhados, puxar o de baixo pra standby move
    /// TODOS juntos como um cinto (não só o agarrado), e o cancel traz todos de
    /// volta. Usa o hook direto (sem mouse sintético) porque o drag real é síncrono
    /// e trava o main thread, e porque evento sintético brigaria com o cursor real.
    private static func runOverlayConveyor() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        func makeCard(_ i: Int, _ color: NSColor) {
            let img = NSImage(size: NSSize(width: 300, height: 200))
            img.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
            let p = "/tmp/krit-conveyor-\(i).png"
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: p))
            }
            let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: p, thumbnailPath: p, captureRect: nil)
            QuickAccessOverlay.show(image: img, historyItem: item,
                                    historyManager: appDelegate.historyManager, screen: NSScreen.main)
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        makeCard(0, .systemRed);   try? await Task.sleep(nanoseconds: 500_000_000)
        makeCard(1, .systemGreen); try? await Task.sleep(nanoseconds: 500_000_000)
        makeCard(2, .systemBlue);  try? await Task.sleep(nanoseconds: 1_000_000_000)
        let count = QuickAccessOverlay.uiTestWindows.count - before
        r["cardCount"] = count
        guard count >= 3 else { r["error"] = "cards did not appear (\(count))"; r["allPass"] = false; return r }

        let beforeOrigins = QuickAccessOverlay.uiTestStackOrigins(on: NSScreen.main)
        r["beforeOrigins"] = beforeOrigins
        let dy: CGFloat = -120
        let moved = QuickAccessOverlay.uiTestConveyorStep(dy: dy)
        r["movedOrigins"] = moved
        // Every card must have dropped by ~|dy| (tolerance 2pt) = moved as one belt.
        var allMoved = moved.count == beforeOrigins.count && !moved.isEmpty
        for (b, m) in zip(beforeOrigins, moved) {
            let delta = (m["y"] ?? 0) - (b["y"] ?? 0)
            if abs(delta - Double(dy)) > 2 { allMoved = false }
        }
        r["allMovedTogether"] = allMoved

        QuickAccessOverlay.uiTestConveyorReset()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let afterOrigins = QuickAccessOverlay.uiTestStackOrigins(on: NSScreen.main)
        r["afterOrigins"] = afterOrigins
        var allHome = afterOrigins.count == beforeOrigins.count
        for (b, a) in zip(beforeOrigins, afterOrigins) {
            if abs((a["y"] ?? 0) - (b["y"] ?? 0)) > 2 { allHome = false }
        }
        r["allHomeAfterReset"] = allHome

        // Phase 2: a REAL synthetic mouse drag (not the hook) on the newest card,
        // straight down past the standby threshold, must park the WHOLE stack, not
        // just the grabbed card. Proves the live gesture path (handleThumbDrag →
        // cardDragUpdate → applyConveyor → parkAll) end to end. Flaky if the
        // physical cursor competes, so it re-arms hover until the card is key.
        guard let newest = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "no newest card for live drag"; r["allPass"] = false; return r
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func cg(_ pnt: NSPoint) -> CGPoint { CGPoint(x: pnt.x, y: primaryH - pnt.y) }
        func post(_ type: CGEventType, _ pt: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func center() -> CGPoint { cg(NSPoint(x: newest.frame.midX, y: newest.frame.midY)) }
        func hover() async {
            post(.mouseMoved, CGPoint(x: center().x - 25, y: center().y))
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.mouseMoved, center())
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for _ in 0..<6 {
            await hover()
            if (QuickAccessOverlay.uiTestHoverState()["isKey"] as? Bool) == true { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let dragStart = center()
        post(.leftMouseDown, dragStart); try? await Task.sleep(nanoseconds: 60_000_000)
        var dp = dragStart
        for _ in 0..<8 { dp.y += 90.0 / 8.0; post(.leftMouseDragged, dp); try? await Task.sleep(nanoseconds: 16_000_000) }
        post(.leftMouseUp, dp); try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Trace from DURING the gesture (set by applyConveyor): the real drag must
        // have translated BOTH siblings while pulling, not only parked them at the
        // end. This is what distinguishes the conveyor from the old per-card park.
        let trace = QuickAccessOverlay.uiTestConveyorTrace()
        r["liveDragTrace"] = trace
        let siblingsMovedDuringDrag = (trace["siblingsMoved"] ?? 0) >= 2   // 3 cards → 2 siblings
        let beltDropSeen = (trace["maxDrop"] ?? 0) >= 40                   // belt traveled real distance
        r["siblingsMovedDuringDrag"] = siblingsMovedDuringDrag
        r["beltDropSeen"] = beltDropSeen
        let states = QuickAccessOverlay.uiTestStandbyStates()
        let liveDragParkedAll = !states.isEmpty && states.allSatisfy { $0 }
        r["liveDragStates"] = states
        r["liveDragParkedAll"] = liveDragParkedAll

        // Restore must bring the WHOLE stack back up together (subir = mesma regra).
        QuickAccessOverlay.uiTestRestoreAll(on: NSScreen.main)
        try? await Task.sleep(nanoseconds: 900_000_000)
        let restoredStates = QuickAccessOverlay.uiTestStandbyStates()
        let restoredAll = !restoredStates.isEmpty && restoredStates.allSatisfy { !$0 }
        r["restoredAll"] = restoredAll

        for _ in 0..<count {
            QuickAccessOverlay.uiTestCloseNewest()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        r["allPass"] = allMoved && allHome && liveDragParkedAll
            && siblingsMovedDuringDrag && beltDropSeen && restoredAll
        return r
    }

    // MARK: - Cenário: autozoom-core (a matemática de auto-zoom portada do Snapzy)

    /// Roda o motor de auto-zoom com um rastro de cursor sintético (varre da
    /// esquerda pra direita no meio do frame) e checa os invariantes: o caminho da
    /// câmera é gerado, os centros ficam dentro do crop (pra 2x, [0.25, 0.75]), a
    /// câmera segue o cursor pra direita, e o estado resolvido no meio está zoomado.
    private static func runAutoZoomCore() -> [String: Any] {
        var r: [String: Any] = ["scenario": "autozoom-core"]
        let fps = 30
        let total = 60
        var samples: [RecordedMouseSample] = []
        for i in 0..<total {
            let t = Double(i) / Double(fps)
            let x = 0.15 + 0.7 * Double(i) / Double(total - 1)   // 0.15 -> 0.85
            samples.append(RecordedMouseSample(time: t, normalizedX: CGFloat(x), normalizedY: 0.5, isInsideCapture: true))
        }
        let metadata = RecordingMetadata(captureSize: CGSize(width: 1920, height: 1080), samplesPerSecond: fps, mouseSamples: samples)
        let segment = ZoomSegment(startTime: 0, duration: 2.0, zoomLevel: 2.0, zoomType: .auto)

        let path = AutoFocusEngine.buildPath(from: metadata, segment: segment)
        r["pathCount"] = path.count

        let cropHalf: CGFloat = 0.5 / 2.0
        let inBounds = path.allSatisfy {
            $0.center.x >= cropHalf - 0.001 && $0.center.x <= 1 - cropHalf + 0.001 &&
            $0.center.y >= cropHalf - 0.001 && $0.center.y <= 1 - cropHalf + 0.001
        }
        r["centersInBounds"] = inBounds

        let startX = path.first?.center.x ?? 0
        let endX = path.last?.center.x ?? 0
        r["startCenterX"] = Double(startX)
        r["endCenterX"] = Double(endX)
        let followsRight = endX > startX + 0.05
        r["followsCursorRight"] = followsRight

        let mid = AutoFocusEngine.resolvedCameraState(
            at: 1.0, segments: [segment], autoFocusPaths: [segment.id: path], transitionDuration: 0.4
        )
        r["midZoom"] = Double(mid.zoomLevel)
        r["midCenterX"] = Double(mid.center.x)

        // Outside any segment must be identity (no zoom).
        let outside = AutoFocusEngine.resolvedCameraState(
            at: 5.0, segments: [segment], autoFocusPaths: [segment.id: path], transitionDuration: 0.4
        )
        r["outsideIsIdentity"] = (outside == CameraState.identity)

        r["allPass"] = path.count > 10 && inBounds && followsRight && mid.zoomLevel > 1.5 && outside == .identity
        return r
    }

    // MARK: - Cenário: prefs-shortcuts (abrir a aba Shortcuts sem crashar)

    /// Prova o fix do crash da aba Shortcuts: monta a seção pelo caminho REAL
    /// (show(tab: .shortcuts) -> ShortcutsForm -> KeyboardShortcuts.Recorder ->
    /// RecorderCocoa -> String.localized -> Bundle.module). Se o resource bundle do
    /// KeyboardShortcuts faltasse no app, o Bundle.module dava fatalError e o
    /// processo morria ANTES de escrever este report (timeout = ainda crasha). Report
    /// escrito com windowUp=true = sobreviveu = bundle presente, fix de runtime ok.
    private static func runPrefsShortcuts() async -> [String: Any] {
        var r: [String: Any] = [:]
        let ctrl = PreferencesWindowController.shared
        ctrl.show(tab: .shortcuts)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let win = ctrl.uiTestWindow
        r["windowUp"] = win?.isVisible ?? false
        // Re-render a couple of other tabs and come back, to exercise the section
        // cache + Recorder teardown/rebuild that a real user does by clicking around.
        ctrl.show(tab: .general)
        try? await Task.sleep(nanoseconds: 300_000_000)
        ctrl.show(tab: .shortcuts)
        try? await Task.sleep(nanoseconds: 500_000_000)
        r["survivedTabSwitch"] = (ctrl.uiTestWindow?.isVisible ?? false)
        if let win = ctrl.uiTestWindow {
            let shot = "/tmp/krit-prefs-glass.png"
            r["snapshot"] = Self.snapshotWindow(win, to: shot) ? shot : "FAILED"
        }
        ctrl.uiTestClose()
        r["allPass"] = (r["windowUp"] as? Bool == true) && (r["survivedTabSwitch"] as? Bool == true)
        return r
    }

    // MARK: - Cenário: overlay-park-capture (print com hide continua a mesma sessão)

    /// Prova o fix do "print com a stack em hide cria sessão nova": parka 2 cards,
    /// depois 'captura' um 3º (QuickAccessOverlay.show, o mesmo caminho da captura
    /// real). Esperado: a stack restaura e o novo card entra numa ÚNICA sessão
    /// contínua (zero parked, 3 visíveis), não um card solto ao lado do handle.
    /// Hook direto, sem mouse sintético (não briga com o cursor).
    private static func runOverlayParkCapture() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        func makeCard(_ i: Int, _ color: NSColor) {
            let img = NSImage(size: NSSize(width: 300, height: 200))
            img.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
            let p = "/tmp/krit-parkcap-\(i).png"
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: p))
            }
            let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: p, thumbnailPath: p, captureRect: nil)
            QuickAccessOverlay.show(image: img, historyItem: item,
                                    historyManager: appDelegate.historyManager, screen: NSScreen.main)
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        makeCard(0, .systemRed); try? await Task.sleep(nanoseconds: 450_000_000)
        makeCard(1, .systemGreen); try? await Task.sleep(nanoseconds: 800_000_000)
        let count = QuickAccessOverlay.uiTestWindows.count - before
        guard count >= 2 else { r["error"] = "cards did not appear (\(count))"; r["allPass"] = false; return r }

        // Hide the whole stack (standby).
        QuickAccessOverlay.uiTestParkAll(on: NSScreen.main)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let parkedBefore = QuickAccessOverlay.uiTestParkedCount()
        r["parkedAfterHide"] = parkedBefore

        // 'Capture' a new shot while hidden — the real capture path.
        makeCard(2, .systemBlue)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let parkedAfter = QuickAccessOverlay.uiTestParkedCount()
        let visible = QuickAccessOverlay.uiTestStandbyStates()
        r["parkedAfterCapture"] = parkedAfter
        r["standbyStatesAfter"] = visible
        // Pass: the stack was hidden (≥2 parked), then a capture restored everyone
        // into ONE continuing session (0 parked, all visible) with the new card.
        let continued = parkedBefore >= 2 && parkedAfter == 0
            && !visible.isEmpty && visible.allSatisfy { !$0 }
        r["continuedSameSession"] = continued

        for _ in 0..<(count + 1) {
            QuickAccessOverlay.uiTestCloseNewest()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        r["allPass"] = continued
        return r
    }

    // MARK: - Cenário: overlay-space-stress (abrir Space N vezes não pode quebrar)

    /// Martela o Space: abre/fecha o companion N vezes seguidas e exige que TODA
    /// iteração abra E feche, e que o drag (standby) ainda funcione depois de toda
    /// a repetição. Cobre o "abro o Space algumas vezes e ele falha". Usa CGEvent
    /// (precisa de Accessibility/Input Monitoring no app de teste, como os outros
    /// cenários de gesto); pode flakear se o cursor físico disputar, por isso
    /// re-arma o hover até o card virar key antes de cada Space.
    private static func runOverlaySpaceStress() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        let img = NSImage(size: NSSize(width: 300, height: 200))
        img.lockFocus(); NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
        let p = "/tmp/krit-space-stress.png"
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: p))
        }
        let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: p, thumbnailPath: p, captureRect: nil)
        QuickAccessOverlay.show(image: img, historyItem: item,
                                historyManager: appDelegate.historyManager, screen: NSScreen.main)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard QuickAccessOverlay.uiTestWindows.count > before,
              let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "card did not appear"; r["allPass"] = false; return r
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func cg(_ pnt: NSPoint) -> CGPoint { CGPoint(x: pnt.x, y: primaryH - pnt.y) }
        func post(_ type: CGEventType, _ pt: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func center() -> CGPoint { cg(NSPoint(x: card.frame.midX, y: card.frame.midY)) }
        func hover() async {
            post(.mouseMoved, CGPoint(x: center().x - 25, y: center().y))
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.mouseMoved, center())
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        func armCard() async -> Bool {
            for _ in 0..<6 {
                await hover()
                if (QuickAccessOverlay.uiTestHoverState()["isKey"] as? Bool) == true { return true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return false
        }
        func postKey(_ code: CGKeyCode, down: Bool) {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
        let iterations = 10
        var opens = 0, closes = 0, armedCount = 0
        var perIter: [[String: Any]] = []
        for i in 0..<iterations {
            let armed = await armCard()
            if armed { armedCount += 1 }
            postKey(49, down: true); postKey(49, down: false)
            try? await Task.sleep(nanoseconds: 450_000_000)
            let opened = QuickLookController.shared.isOpen
            if opened { opens += 1 }
            postKey(49, down: true); postKey(49, down: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let closed = !QuickLookController.shared.isOpen
            if closed { closes += 1 }
            perIter.append(["i": i, "armed": armed, "opened": opened, "closed": closed,
                            "keyGateDrop": QuickAccessOverlay.uiTestHoverState()["keyGateDrop"] as? Int ?? -1])
        }
        r["iterations"] = iterations
        r["opens"] = opens; r["closes"] = closes; r["armed"] = armedCount
        r["perIter"] = perIter

        // After the Space churn the DRAG must still work: standby past 50pt parks.
        func dragFrom(_ start: CGPoint, by: CGVector, steps: Int, settleNs: UInt64) async {
            post(.leftMouseDown, start); try? await Task.sleep(nanoseconds: 60_000_000)
            var pt = start
            for _ in 0..<steps {
                pt.x += by.dx / CGFloat(steps); pt.y += by.dy / CGFloat(steps)
                post(.leftMouseDragged, pt); try? await Task.sleep(nanoseconds: 16_000_000)
            }
            post(.leftMouseUp, pt); try? await Task.sleep(nanoseconds: settleNs)
        }
        _ = await armCard()
        await dragFrom(center(), by: CGVector(dx: 0, dy: 90), steps: 8, settleNs: 900_000_000)
        let dragWorks = QuickAccessOverlay.uiTestStandbyStates().last == true
        r["dragWorksAfterStress"] = dragWorks
        if dragWorks { QuickAccessOverlay.uiTestRestoreAll(on: NSScreen.main); try? await Task.sleep(nanoseconds: 500_000_000) }
        QuickAccessOverlay.uiTestCloseNewest()

        r["allPass"] = (opens == iterations) && (closes == iterations) && dragWorks
        return r
    }

    // MARK: - Cenário: export-formats (encode por formato via o caminho REAL)

    /// Exercita ImageExporter.encodedForExport no caminho real, para cada formato
    /// que o usuário pode escolher. Prova: bytes não-vazios, extensão/UTI certos,
    /// magic bytes do container batem, e o PDF abre como PÁGINA EM PONTOS (não em
    /// pixels) com a resolução cheia embutida, sem inverter. Cobre o que o PR de
    /// export PDF precisa garantir antes do merge.
    private static func runExportFormats() async -> [String: Any] {
        var r: [String: Any] = [:]

        // Captura 2x: 240x160 pt, bitmap 480x320 px. Metade de cima vermelha,
        // de baixo azul (em coordenadas top-left de NSImage).
        let pt = NSSize(width: 240, height: 160)
        let img = NSImage(size: pt)
        img.lockFocus()
        NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 80, width: 240, height: 80).fill()  // top (flipped focus: y up)
        NSColor(srgbRed: 0.1, green: 0.2, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 240, height: 80).fill()
        img.unlockFocus()

        let saved = Settings.screenshotFormat
        defer { Settings.screenshotFormat = saved }

        func magicOK(_ data: Data, _ ext: String) -> Bool {
            let b = [UInt8](data.prefix(5))
            switch ext {
            case "png":  return b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
            case "jpg":  return b.count >= 2 && b[0] == 0xFF && b[1] == 0xD8
            case "webp": return true  // RIFF container; codec presence is environment-dependent
            case "pdf":  return b.count >= 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46 // %PDF
            default:     return false
            }
        }

        var perFormat: [String: Any] = [:]
        var allPass = true
        // webp resolves to png when the codec is unavailable, so assert the resolved ext.
        for requested in ["png", "jpg", "webp", "pdf"] {
            Settings.screenshotFormat = requested
            guard let export = ImageExporter.encodedForExport(img) else {
                perFormat[requested] = ["ok": false, "reason": "nil export"]; allPass = false; continue
            }
            var entry: [String: Any] = ["ext": export.ext, "uti": export.uti, "bytes": export.data.count]
            let ok = export.data.count > 0 && magicOK(export.data, export.ext)
            entry["magicOK"] = ok
            if !ok { allPass = false }

            if export.ext == "pdf" {
                if let doc = CGPDFDocument(CGDataProvider(data: export.data as CFData)!), let page = doc.page(at: 1) {
                    let box = page.getBoxRect(.mediaBox)
                    entry["pageW"] = Int(box.width); entry["pageH"] = Int(box.height)
                    // Page must be in POINTS (240x160), not pixels (480x320).
                    let pageOK = Int(box.width) == 240 && Int(box.height) == 160
                    entry["pageInPoints"] = pageOK
                    if !pageOK { allPass = false }
                } else {
                    entry["pageInPoints"] = false; allPass = false
                }
            }
            perFormat[export.ext] = entry
        }
        r["formats"] = perFormat
        r["allPass"] = allPass
        return r
    }

    // MARK: - Cenário: sidebar-motion (filma a abertura da coluna de backgrounds)

    /// Diagnóstico visual: abre o editor, dispara o toggle da sidebar e captura
    /// frames da janela durante a moção (e o estado final). Gate é olhar os
    /// PNGs em /tmp/krit-sidebar-motion: janela, coluna, canvas e chrome têm
    /// que se mover como UMA peça (o relato era "componentes se movem diferente
    /// do fundo"). allPass valida só o estado final são (sidebar visível em x:0).
    private static func runSidebarMotion() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        let img = NSImage(size: NSSize(width: 1600, height: 1000))
        img.lockFocus()
        NSColor(srgbRed: 0.16, green: 0.45, blue: 0.78, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let window = ctrl.window else {
            r["error"] = "editor window did not open"; r["allPass"] = false; return r
        }
        defer { window.close() }

        let dir = "/tmp/krit-sidebar-motion"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Sidebar fechada no início (estado default), dispara e mede a moção
        // REAL pelo presentation layer (screenshot custa ~100ms+ e perde os
        // frames; o presentation é o que o render server está pintando).
        ctrl.uiTestToggleSidebar()
        var xs: [Int] = []
        for _ in 0..<18 {
            let x = ctrl.uiTestSidebar?.layer?.presentation()?.frame.origin.x
                ?? ctrl.uiTestSidebar?.frame.origin.x ?? -9999
            xs.append(Int(x))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        r["presentationXs"] = xs
        // Moção suave = pelo menos 3 valores intermediários distintos entre
        // -width e 0 (um jump-cut só registra os extremos).
        let intermediates = Set(xs.filter { $0 > -Int(BackgroundSidebar.preferredWidth) + 4 && $0 < -4 })
        r["intermediateCount"] = intermediates.count
        let smooth = intermediates.count >= 3
        r["smoothMotionPass"] = smooth

        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = Self.snapshotWindow(window, to: "\(dir)/final.png")

        let sidebarOpen = ctrl.uiTestSidebar?.isHidden == false && (ctrl.uiTestSidebar?.frame.minX ?? -1) == 0
        r["sidebarOpenAtEnd"] = sidebarOpen
        r["frames"] = dir
        r["allPass"] = sidebarOpen && smooth
        return r
    }

    // MARK: - Cenário: prefs-bottom (margem no fim do scroll das Preferences)

    /// Abre as Preferences reais, rola a seção General até o FIM e fotografa:
    /// a última row precisa de margem de segurança antes da borda da janela
    /// (o relato: "sem bordas no final"). Gate visual em /tmp/krit-prefs-bottom.png.
    private static func runPrefsBottom() async -> [String: Any] {
        var r: [String: Any] = [:]
        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let win = ctrl.uiTestWindow else {
            r["error"] = "preferences window did not open"; r["allPass"] = false; return r
        }
        // A janela do shared controller sobrevive ao close: restaurar o frame,
        // senão a próxima abertura REAL vem com os 520pt do teste.
        let originalFrame = win.frame
        defer {
            win.setFrame(originalFrame, display: false)
            ctrl.uiTestClose()
        }

        // Janela curta o bastante pra General PRECISAR rolar.
        var f = win.frame
        f.size.height = 520
        win.setFrame(f, display: true)
        try? await Task.sleep(nanoseconds: 400_000_000)

        guard let scroll = findView(in: win.contentView ?? NSView(), where: { $0 is NSScrollView }) as? NSScrollView,
              let doc = scroll.documentView else {
            r["error"] = "form scroll view not found"; r["allPass"] = false; return r
        }
        // Rola até o fim do documento.
        let endY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? endY : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(nanoseconds: 400_000_000)

        let shot = "/tmp/krit-prefs-bottom.png"
        let ok = Self.snapshotWindow(win, to: shot)
        r["snapshot"] = ok ? shot : "FAILED"
        // Margem: o fim do documento fica acima da borda inferior da janela por
        // pelo menos ~16pt de respiro (contentMargins de 24 menos tolerância).
        let visibleBottom = scroll.contentView.bounds.maxY
        let docEnd = doc.frame.height
        r["docEnd"] = docEnd
        r["visibleBottom"] = visibleBottom
        r["allPass"] = ok
        return r
    }

    // MARK: - Cenário: drag-prep (hitch do drag-out do card)

    /// Reproduz a "travada" relatada na transformação card → arquivo: o encode
    /// PNG + escrita aconteciam na main thread dentro do gesto. Mede a etapa de
    /// materialização nos dois caminhos com a MESMA captura grande: o fast path
    /// (arquivo pré-exportado no pouso do card) tem que ser ~0ms; o forceInline
    /// reporta o custo legado como evidência do delta.
    private static func runDragPrep() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count

        // Captura Retina grande com conteúdo não-trivial: PNG encode caro de
        // verdade (gradiente + grade de retângulos quebra a compressão fácil).
        let size = NSSize(width: 5120, height: 2880)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGradient(colors: [.systemBlue, .systemPurple, .systemOrange])?
            .draw(in: NSRect(origin: .zero, size: size), angle: 30)
        for i in stride(from: 0, to: 5120, by: 64) {
            NSColor(calibratedHue: CGFloat(i % 360) / 360, saturation: 0.8, brightness: 0.9, alpha: 0.35).setFill()
            NSRect(x: CGFloat(i), y: CGFloat((i * 7) % 2400), width: 48, height: 320).fill()
        }
        img.unlockFocus()

        let tmpPath = "/tmp/krit-dragprep-test.png"
        let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: tmpPath,
                               thumbnailPath: tmpPath, captureRect: nil)
        QuickAccessOverlay.show(image: img, historyItem: item,
                                historyManager: appDelegate.historyManager, screen: NSScreen.main)
        // Pouso do card + pre-export em background.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        defer { if QuickAccessOverlay.uiTestWindows.count > before { QuickAccessOverlay.uiTestCloseNewest() } }
        guard QuickAccessOverlay.uiTestWindows.count > before else {
            r["error"] = "card did not appear"; r["allPass"] = false; return r
        }

        // Probe cedo: gesto disparado logo após o pouso NUNCA pode bloquear,
        // mesmo que o pre-export ainda esteja rodando (vira promise-only).
        let early = QuickAccessOverlay.uiTestDragPrep(forceInline: false)
        r["earlyMs"] = early["ms"] ?? -1
        r["earlyMode"] = early["mode"] ?? "?"
        let earlyQuick = ((early["ms"] as? Double) ?? 999) < 8

        // O pre-export tem que completar e devolver o caminho de URL concreta.
        var preparedMs = -1.0
        var preparedSeen = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let probe = QuickAccessOverlay.uiTestDragPrep(forceInline: false)
            if probe["mode"] as? String == "prepared" {
                preparedSeen = true
                preparedMs = probe["ms"] as? Double ?? -1
                break
            }
        }
        r["preparedSeen"] = preparedSeen
        r["preparedMs"] = preparedMs

        // Evidência do custo que o caminho antigo cobrava na main thread.
        let legacy = QuickAccessOverlay.uiTestDragPrep(forceInline: true)
        r["legacyMs"] = legacy["ms"] ?? -1

        r["allPass"] = earlyQuick && preparedSeen && preparedMs >= 0 && preparedMs < 8
        return r
    }

    // MARK: - Cenário: controls-demo (controles atuais vs nativos macOS 26+)

    /// Side-by-side demo for the owner to choose from, nothing in the product
    /// changes here. Left column replicates the sidebar's current controls
    /// (checkbox, rounded "None", smallSquare alignment grid); right column
    /// shows the native macOS 26+ counterparts (NSSwitch, .glass bezels) over
    /// a vivid backdrop so glass has something to sample. Deliverable is the
    /// snapshot at /tmp/krit-controls-demo.png (WindowServer composite).
    private static func runControlsDemo() async -> [String: Any] {
        var r: [String: Any] = [:]

        let size = NSSize(width: 880, height: 560)
        let backdrop = NSImage(size: size)
        backdrop.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.32, blue: 0.75, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.20, blue: 0.65, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.45, blue: 0.30, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        backdrop.unlockFocus()

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        let bg = NSImageView(frame: NSRect(origin: .zero, size: size))
        bg.image = backdrop
        bg.imageScaling = .scaleAxesIndependently
        bg.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(bg)

        func sectionLabel(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            return l
        }

        func alignmentGrid(native: Bool) -> NSView {
            var rows: [[NSView]] = []
            var current: [NSView] = []
            for i in 0..<9 {
                let b = NSButton()
                b.title = ""
                if native, #available(macOS 26.0, *) {
                    b.bezelStyle = .glass
                } else {
                    b.bezelStyle = .smallSquare
                }
                b.setButtonType(.toggle)
                b.state = i == 4 ? .on : .off
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                b.heightAnchor.constraint(equalToConstant: 22).isActive = true
                current.append(b)
                if current.count == 3 { rows.append(current); current = [] }
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 3
            grid.columnSpacing = 3
            grid.translatesAutoresizingMaskIntoConstraints = false
            return grid
        }

        func column(native: Bool) -> NSView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

            let title = NSTextField(labelWithString: native ? "Native (macOS 26+)" : "Current")
            title.font = .systemFont(ofSize: 13, weight: .bold)
            stack.addArrangedSubview(title)

            stack.addArrangedSubview(sectionLabel("Toggle"))
            if native {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                let sw = NSSwitch()
                sw.state = .on
                row.addArrangedSubview(sw)
                let lbl = NSTextField(labelWithString: "Auto-balance")
                lbl.font = .systemFont(ofSize: 12)
                row.addArrangedSubview(lbl)
                stack.addArrangedSubview(row)
            } else {
                let cb = NSButton(checkboxWithTitle: "Auto-balance", target: nil, action: nil)
                cb.state = .on
                cb.font = .systemFont(ofSize: 11)
                cb.controlSize = .small
                stack.addArrangedSubview(cb)
            }

            stack.addArrangedSubview(sectionLabel("Push toggle"))
            let none = NSButton(title: "None", target: nil, action: nil)
            none.setButtonType(.pushOnPushOff)
            if native, #available(macOS 26.0, *) {
                none.bezelStyle = .glass
            } else {
                none.bezelStyle = .rounded
            }
            none.state = .on
            none.translatesAutoresizingMaskIntoConstraints = false
            none.widthAnchor.constraint(equalToConstant: 180).isActive = true
            stack.addArrangedSubview(none)

            stack.addArrangedSubview(sectionLabel("Alignment"))
            stack.addArrangedSubview(alignmentGrid(native: native))

            stack.addArrangedSubview(sectionLabel(native ? "Slider (already native)" : "Slider"))
            let slider = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            stack.addArrangedSubview(slider)

            stack.addArrangedSubview(sectionLabel(native ? "Segmented (already native)" : "Segmented"))
            let seg = NSSegmentedControl(labels: ["Annotate", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
            seg.selectedSegment = 0
            stack.addArrangedSubview(seg)

            return ChromeFactory.make(content: stack, cornerRadius: ChromeFactory.Radius.panel)
        }

        let rowStack = NSStackView(views: [column(native: false), column(native: true)])
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.distribution = .fillEqually
        rowStack.spacing = 60
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        win.contentView?.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.centerXAnchor.constraint(equalTo: win.contentView!.centerXAnchor),
            rowStack.centerYAnchor.constraint(equalTo: win.contentView!.centerYAnchor),
        ])

        if let primary = NSScreen.screens.first {
            let pf = primary.visibleFrame
            win.setFrameOrigin(NSPoint(x: pf.midX - size.width / 2, y: pf.midY - size.height / 2))
        }
        win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let shot = "/tmp/krit-controls-demo.png"
        let cg = snapshotScreenRegion(of: win, to: shot)
        let contrast = cg.map { hasVisibleContrast($0) } ?? false
        win.orderOut(nil)
        r["snapshot"] = cg != nil ? shot : "FAILED"
        r["contrast"] = contrast
        r["allPass"] = cg != nil && contrast
        return r
    }

    // MARK: - Cenário: wallpaper-apply (clique real no thumbnail + render)

    /// Reproduz o relato "clico num wallpaper e fica bugado": abre o editor com
    /// uma imagem vermelha, clica num thumbnail REAL da seção Wallpapers e
    /// valida o RESULTADO: o canvas composto mostra o conteúdo (pixels
    /// vermelhos) sobre um fundo não-preto-uniforme, e a janela fica num
    /// tamanho são. Snapshot em /tmp/krit-editor/wallpaper-apply.png é o gate
    /// visual. (O editor-suite só validava as OPTIONS, o render preto passava.)
    private static func runWallpaperApply() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        // Imagem GRANDE (print de ultrawide): o relato do dono era com um shot
        // que abre o editor no envelope máximo com fit < 100%; o caso pequeno
        // não reproduzia o palco preto com canvas fora da viewport.
        let img = NSImage(size: NSSize(width: 2800, height: 1200))
        img.lockFocus()
        NSColor(srgbRed: 0.85, green: 0.12, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 2800, height: 1200).fill()
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let window = ctrl.window else {
            r["error"] = "editor window did not open"; r["allPass"] = false; return r
        }
        defer { window.close() }

        let frameBefore = window.frame
        r["windowBefore"] = ["w": frameBefore.width, "h": frameBefore.height]

        if ctrl.uiTestSidebar == nil || ctrl.uiTestSidebar?.isHidden != false {
            ctrl.uiTestToggleSidebar()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        guard let sidebar = ctrl.uiTestSidebar,
              let wpLabel = findView(in: sidebar, where: { ($0 as? NSTextField)?.stringValue.caseInsensitiveCompare("Wallpapers") == .orderedSame }),
              let section = wpLabel.superview?.superview ?? wpLabel.superview,
              let thumb = findView(in: section, where: {
                  String(describing: type(of: $0)).contains("ThumbnailButton") && $0.frame.width > 10
              }) else {
            r["error"] = "wallpaper thumbnail not found"; r["allPass"] = false; return r
        }
        await synthesizeClick(in: window, view: thumb)
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // backgroundData é async

        let opts = ctrl.uiTestOptions
        r["optionsApplied"] = opts.isEnabled && opts.style == .image
        let frameAfter = window.frame
        r["windowAfter"] = ["w": frameAfter.width, "h": frameAfter.height]
        let canvas = ctrl.uiTestCanvas
        r["canvasFrame"] = ["w": canvas.frame.width, "h": canvas.frame.height]

        // Render real: compõe via o pipeline do canvas? Não, valida o que está NA
        // TELA: snapshot da janela e análise de pixels do palco.
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        let shotPath = "/tmp/krit-editor/wallpaper-apply.png"
        let shotOK = Self.snapshotWindow(window, to: shotPath)
        r["snapshot"] = shotOK ? shotPath : "FAILED"

        var contentVisible = false, backgroundNotBlack = false
        if shotOK, let data = FileManager.default.contents(atPath: shotPath),
           let rep = NSBitmapImageRep(data: data) {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            var redCount = 0, darkCount = 0, sampled = 0
            // Varre o terço central-direito (palco; a sidebar ocupa a esquerda).
            var x = w * 45 / 100
            while x < w - 8 {
                var y = h * 20 / 100
                while y < h * 90 / 100 {
                    guard let c = rep.colorAt(x: x, y: y) else { y += 12; continue }
                    sampled += 1
                    if c.redComponent > 0.55 && c.greenComponent < 0.35 && c.blueComponent < 0.35 { redCount += 1 }
                    if c.redComponent < 0.06 && c.greenComponent < 0.06 && c.blueComponent < 0.06 { darkCount += 1 }
                    y += 12
                }
                x += 12
            }
            r["pixelStats"] = ["sampled": sampled, "red": redCount, "nearBlack": darkCount]
            contentVisible = sampled > 0 && redCount > sampled / 50
            backgroundNotBlack = sampled > 0 && darkCount < sampled * 9 / 10
        }
        r["contentVisible"] = contentVisible
        r["backgroundNotBlack"] = backgroundNotBlack

        // Janela sã: não estourou o envelope padrão da tela.
        let vf = NSScreen.main?.visibleFrame ?? .zero
        let windowSane = frameAfter.width <= vf.width + 2 && frameAfter.height <= vf.height + 2
        r["windowSane"] = windowSane

        r["allPass"] = (r["optionsApplied"] as? Bool ?? false) && contentVisible && backgroundNotBlack && windowSane
        return r
    }

    // MARK: - Cenário: wallpaper-sweep (diagnóstico: TODOS os wallpapers)

    /// Varre a lista inteira de wallpapers aplicando cada um pelo caminho real
    /// (backgroundData + commit) e analisando o render do canvas: acha qualquer
    /// wallpaper que pinte o fundo preto-uniforme (o relato do dono). Não entra
    /// na bateria, é diagnóstico sob demanda.
    private static func runWallpaperSweep() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus()
        NSColor(srgbRed: 0.85, green: 0.12, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let window = ctrl.window else {
            r["error"] = "editor window did not open"; r["allPass"] = false; return r
        }
        defer { window.close() }

        var failures: [String] = []
        var checked = 0
        let wallpapers = SystemWallpaperSource.all
        r["total"] = wallpapers.count
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)

        for wallpaper in wallpapers {
            let data: Data? = await withCheckedContinuation { cont in
                SystemWallpaperSource.backgroundData(for: wallpaper) { cont.resume(returning: $0) }
            }
            guard let data else { failures.append("\(wallpaper.name): data nil"); continue }
            var opts = ctrl.uiTestOptions
            opts.isEnabled = true
            opts.style = .image
            opts.presetName = wallpaper.name
            opts.customImageName = wallpaper.name
            opts.customImageData = data
            ctrl.uiTestApplyBackground(opts)
            try? await Task.sleep(nanoseconds: 250_000_000)
            checked += 1

            // Render direto do pipeline (sem screenshot de janela): compõe e
            // mede a uniformidade do fundo fora do slot do conteúdo.
            let composed = ScreenshotBackgroundComposer.composeIfNeeded(img, options: opts)
            guard let cg = composed.bestCGImage else { failures.append("\(wallpaper.name): compose nil"); continue }
            var dark = 0, samples = 0
            if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
                let w = 64, h = 64
                var buf = [UInt8](repeating: 0, count: w * h * 4)
                if let bctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: srgb,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    bctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                    // Bordas (fundo): topo, base, esquerda, direita do downscale.
                    for i in 0..<w {
                        for row in [1, h - 2] {
                            let o = (row * w + i) * 4
                            samples += 1
                            if buf[o] < 14 && buf[o+1] < 14 && buf[o+2] < 14 { dark += 1 }
                        }
                    }
                }
            }
            if samples > 0 && dark > samples * 9 / 10 {
                failures.append("\(wallpaper.name): fundo preto (\(dark)/\(samples))")
            }
        }
        r["checked"] = checked
        r["failures"] = failures
        r["allPass"] = failures.isEmpty
        return r
    }

    // MARK: - Cenário: alignment (âncoras seamless do composer)

    /// Prova as âncoras de alinhamento no caminho REAL de compose: conteúdo
    /// vermelho 400×300 num canvas 16:9 com padding, uma composição por âncora,
    /// e o bounding box dos pixels vermelhos no PNG final tem que ENCOSTAR na
    /// borda da âncora (semântica seamless do Snapzy) ou centrar no centro.
    /// Pega regressão do alignedOrigin (o bug "alignment não faz nada" vinha
    /// de free space zerado pelo inset em canvas justo).
    private static func runAlignment() async -> [String: Any] {
        var r: [String: Any] = [:]

        let content = NSImage(size: NSSize(width: 400, height: 300))
        content.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        content.unlockFocus()

        var opts = ScreenshotBackgroundOptions.editorDefault
        opts.isEnabled = true
        opts.style = .solid
        opts.colorHex = "#101418"
        opts.padding = 64
        opts.cornerRadius = 0
        opts.shadow = 0
        opts.aspectPreset = .ratio16x9

        // Bounding box dos pixels vermelhos, em pontos, row 0 = topo.
        func redBox(_ image: NSImage) -> (left: Int, right: Int, top: Int, bottom: Int, w: Int, h: Int)? {
            let w = Int(image.size.width.rounded()), h = Int(image.size.height.rounded())
            guard w > 0, h > 0, let cg = image.bestCGImage,
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            var minX = w, maxX = -1, minY = h, maxY = -1
            for row in 0..<h {
                for col in 0..<w {
                    let o = (row * w + col) * 4
                    if buf[o] > 200 && buf[o + 1] < 100 && buf[o + 2] < 100 {
                        if col < minX { minX = col }; if col > maxX { maxX = col }
                        if row < minY { minY = row }; if row > maxY { maxY = row }
                    }
                }
            }
            guard maxX >= 0 else { return nil }
            return (minX, maxX, minY, maxY, w, h)
        }

        let tol = 2
        var all = true
        let cases: [(String, BackgroundAlignment, ((Int, Int, Int, Int, Int, Int)) -> Bool)] = [
            ("bottom",      .bottom,      { $0.3 >= $0.5 - 1 - tol && abs($0.0 - ($0.4 - 1 - $0.1)) <= tol }),
            ("topRight",    .topRight,    { $0.2 <= tol && $0.1 >= $0.4 - 1 - tol }),
            ("bottomLeft",  .bottomLeft,  { $0.3 >= $0.5 - 1 - tol && $0.0 <= tol }),
            ("center",      .center,      { abs($0.0 - ($0.4 - 1 - $0.1)) <= tol && abs($0.2 - ($0.5 - 1 - $0.3)) <= tol }),
        ]
        for (name, alignment, check) in cases {
            opts.alignment = alignment
            let composed = ScreenshotBackgroundComposer.composeIfNeeded(content, options: opts)
            guard composed !== content, let box = redBox(composed) else {
                r[name] = "compose/scan failed"; all = false; continue
            }
            let pass = check(box)
            r[name] = ["left": box.left, "right": box.right, "top": box.top, "bottom": box.bottom,
                       "w": box.w, "h": box.h, "pass": pass]
            if !pass { all = false }
        }
        r["allPass"] = all
        return r
    }

    // MARK: - Cenário: color-pick (eyedropper end-to-end)

    /// Prova o eyedropper de ponta a ponta: janela real de cor conhecida na
    /// tela → startColorPick (overlay + frozen grab SCK reais) → pick no centro
    /// da janela via o caminho exato do mouseDown → clipboard com o hex. A
    /// tolerância cobre o color matching sRGB → perfil do display (o sampler
    /// lê bytes crus do frame capturado, espaço do display por definição).
    private static func runColorPick() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let engine = appDelegate.uiTestCaptureEngine

        // Janela alvo: sRGB #3366CC, grande o bastante pra paralaxe de pixel não importar.
        let target = NSColor(srgbRed: 51.0/255, green: 102.0/255, blue: 204.0/255, alpha: 1)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let winRect = NSRect(x: screen.frame.midX - 120, y: screen.frame.midY - 90, width: 240, height: 180)
        let win = NSWindow(contentRect: winRect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.backgroundColor = target
        win.level = .floating
        win.sharingType = .readWrite
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 500_000_000)

        Task { await engine.startColorPick() }
        // Espera o frozen frame DO OVERLAY DA TELA DO PICK: com dois monitores o
        // primeiro freeze a chegar pode ser o da outra tela, e picar antes do
        // certo congelar cancela silenciosamente (sample nil).
        var ready = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let diag = engine.uiTestActiveSelection?.uiTestPickDiag(atScreen: NSPoint(x: winRect.midX, y: winRect.midY)),
               diag["chosenHasFrozen"] as? Bool == true { ready = true; break }
        }
        r["overlayReady"] = ready
        guard ready else {
            engine.uiTestActiveSelection?.cancel()
            r["allPass"] = false; return r
        }

        NSPasteboard.general.clearContents()
        if let diag = engine.uiTestActiveSelection?.uiTestPickDiag(atScreen: NSPoint(x: winRect.midX, y: winRect.midY)) {
            for (k, v) in diag { r["diag_\(k)"] = v }
        }
        engine.uiTestActiveSelection?.uiTestPickColor(atScreen: NSPoint(x: winRect.midX, y: winRect.midY))
        try? await Task.sleep(nanoseconds: 400_000_000)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        r["copied"] = copied
        r["pickerClosed"] = engine.uiTestActiveSelection == nil

        // Dois candidatos válidos: bytes em sRGB puro ou no espaço do display.
        func channels(_ c: NSColor) -> [Int] {
            [Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255))]
        }
        var candidates: [[Int]] = [[51, 102, 204]]
        if let cs = screen.colorSpace, let display = target.usingColorSpace(cs) {
            candidates.append(channels(display))
        }
        var match = false
        if copied.count == 7, copied.hasPrefix("#"),
           let rv = Int(copied.dropFirst().prefix(2), radix: 16),
           let gv = Int(copied.dropFirst(3).prefix(2), radix: 16),
           let bv = Int(copied.dropFirst(5).prefix(2), radix: 16) {
            let got = [rv, gv, bv]
            r["gotRGB"] = got
            r["candidates"] = candidates
            match = candidates.contains { zip($0, got).allSatisfy { abs($0 - $1) <= 12 } }
        }
        r["colorMatch"] = match
        r["allPass"] = ready && match && (engine.uiTestActiveSelection == nil)
        return r
    }

    // MARK: - Cenário: update-check (Sparkle background check)

    /// Dispara o check de update do Sparkle em background (o caminho silencioso
    /// que baixa e instala no quit quando SUAutomaticallyUpdate está ligado).
    /// A prova de instalação acontece FORA do app: test-update-local.sh espera,
    /// encerra o processo e lê a versão do bundle reinstalado em /Applications.
    private static func runUpdateCheck() async -> [String: Any] {
        var r: [String: Any] = [:]
        let updater = UpdaterManager.shared.updater
        r["feedOverride"] = UserDefaults.standard.string(forKey: "KritFeedURLOverride") ?? ""
        r["automaticallyDownloads"] = updater.automaticallyDownloadsUpdates
        r["canCheck"] = updater.canCheckForUpdates
        updater.checkForUpdatesInBackground()
        // sessionInProgress é só informativo: com feed local o ciclo inteiro
        // (check + download) pode fechar antes do sleep. O gate determinístico
        // é o updater estar apto; a prova real é a troca do bundle no quit.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        r["sessionInProgress"] = updater.sessionInProgress
        r["allPass"] = updater.canCheckForUpdates || updater.sessionInProgress
        return r
    }

    // MARK: - Cenário: smart-redact (OCR real + classificador de segredos)

    /// Prova o pipeline do Smart Redact de ponta a ponta dentro do app: renderiza
    /// uma imagem determinística com um email, uma chave AWS e um cartão válido
    /// (Luhn) como TEXTO, roda Vision OCR + SecretClassifier via o hook do editor
    /// e asserta que as três categorias são detectadas com boxes não-vazias, e que
    /// a prosa inocente da imagem NÃO gera achados extras.
    private static func runSmartRedactSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        let lines = [
            "Contact: alice.smith@example.com",
            "aws key AKIAIOSFODNN7EXAMPLE",
            "card 4111 1111 1111 1111",
            "This sentence is perfectly innocent prose."
        ]
        let img = NSImage(size: NSSize(width: 900, height: 400))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 400).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: 320 - CGFloat(i) * 80), withAttributes: attrs)
        }
        img.unlockFocus()

        let findings = await AnnotationWindowController.uiTestSmartRedactFindings(in: img)
        r["findings"] = findings
        let categories = Set(findings.compactMap { $0["category"] as? String })
        r["categories"] = Array(categories).sorted()
        let boxesOK = findings.allSatisfy { (($0["boxes"] as? [[String: Any]])?.count ?? ($0["boxes"] as? [Any])?.count ?? 0) > 0 }

        r["emailPass"] = categories.contains("email")
        r["awsKeyPass"] = categories.contains("awsKey")
        r["creditCardPass"] = categories.contains("creditCard")
        r["boxesPass"] = boxesOK
        // Sem falso positivo grosseiro: nada além das 3 categorias esperadas
        // (highEntropySecret na chave AWS seria duplicata aceitável, tolerada).
        let allowed: Set<String> = ["email", "awsKey", "creditCard", "highEntropySecret"]
        r["noFalsePositivesPass"] = categories.isSubset(of: allowed)

        r["allPass"] = (r["emailPass"] as? Bool ?? false)
            && (r["awsKeyPass"] as? Bool ?? false)
            && (r["creditCardPass"] as? Bool ?? false)
            && boxesOK
            && (r["noFalsePositivesPass"] as? Bool ?? false)
        return r
    }

    // MARK: - Cenário: record-smoke (gravação real de 2s, dim e card no overlay)

    /// Prova empírica do pipeline de gravação: grava 2 segundos de um rect real
    /// na tela principal pelo caminho de produção (sem preflight, hook direto),
    /// asserta que o dim apareceu ao redor da área, para, e asserta que o
    /// resultado chegou como card de vídeo no QuickAccessOverlay. Fecha o card
    /// no final pra não deixar resíduo.
    ///
    /// `systemAudio: true` liga o system audio do SCK na gravação (restaurando a
    /// setting no final): cobre a regressão real do "Could not save recording",
    /// em que PTS de áudio pré-vídeo/clock divergente derrubava o AVAssetWriter.
    /// O mic fica fora da automação de propósito (dispararia prompt de permissão).
    private static func runRecordSmoke(systemAudio: Bool = false, microphone: Bool = false) async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; return r
        }
        // Determinístico: força AMBAS as fontes de áudio pro estado do cenário
        // (sem isso, o mic do usuário ligado nas Settings vazava pro cenário
        // "sem áudio" e os resultados flip-flopavam). Restaura no final.
        let savedSystemAudio = Settings.recordingSystemAudio
        let savedMicrophone = Settings.recordingMicrophone
        Settings.recordingSystemAudio = systemAudio
        Settings.recordingMicrophone = microphone
        defer {
            Settings.recordingSystemAudio = savedSystemAudio
            Settings.recordingMicrophone = savedMicrophone
        }
        r["systemAudioVariant"] = systemAudio
        r["microphoneVariant"] = microphone
        let engine = appDelegate.uiTestCaptureEngine
        guard !engine.recordingActive else {
            r["error"] = "a recording is already running"; return r
        }
        guard let screen = NSScreen.main else { r["error"] = "no screen"; return r }

        let vf = screen.visibleFrame
        let rect = CGRect(x: vf.midX - 200, y: vf.midY - 150, width: 400, height: 300)
        let cardsBefore = QuickAccessOverlay.uiTestWindows.count

        await engine.uiTestStartRecording(rect: rect, on: screen)
        var started = false
        for _ in 0..<50 {
            if engine.recordingActive { started = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        r["recordingStarted"] = started
        r["dimPanelCount"] = engine.uiTestDimPanelCount

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        engine.stopRecording()

        var cardsAfter = cardsBefore
        for _ in 0..<200 {   // finishing + thumbnail podem levar alguns segundos
            cardsAfter = QuickAccessOverlay.uiTestWindows.count
            if cardsAfter > cardsBefore { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        r["cardAppeared"] = cardsAfter > cardsBefore
        r["dimGoneAfterStop"] = (engine.uiTestDimPanelCount == 0)
        r["finishOutcome"] = engine.uiTestRecordingOutcome
        r["streamError"] = engine.uiTestStreamError

        r["allPass"] = started
            && (r["dimPanelCount"] as? Int ?? 0) >= 1
            && (cardsAfter > cardsBefore)
            && (engine.uiTestDimPanelCount == 0)

        if cardsAfter > cardsBefore {
            if let card = QuickAccessOverlay.uiTestWindows.last {
                _ = Self.snapshotWindow(card, to: "/tmp/krit-video-card.png")
                r["cardShot"] = "/tmp/krit-video-card.png"
            }
            QuickAccessOverlay.uiTestCloseNewest()
        }
        return r
    }

    // MARK: - Cenário: window-editor (window shot abre com wallpaper aplicado)

    /// Prova a regra "print de janela abre com o wallpaper do macOS já aplicado,
    /// prontinho": abre o editor com um HistoryItem forjado de window capture e
    /// asserta background HABILITADO, estilo .image e dados de wallpaper
    /// presentes. Snapshot em /tmp/krit-editor/window-editor.png pro gate visual.
    /// (O print comum continua coberto pelo editor-suite, que asserta o oposto.)
    private static func runWindowEditorSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus()
        NSColor(srgbRed: 0.92, green: 0.94, blue: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        img.unlockFocus()

        // Exercita o caminho REAL do wallpaper: o grab SCK da janela de wallpaper
        // do Dock (o fluxo de window capture faz isso antes do finishing). Sem
        // isso o cenário cai no fallback estático e não prova o fix.
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            await SystemWallpaperSource.refreshCurrentWallpaper(for: screen)
        }
        // Diagnóstico de fonte: "sck-onscreen" é o caminho saudável; "builtin-first"
        // significa que o usuário recebeu um wallpaper de catálogo, não o desktop
        // real (o bug "wallpaper baixado").
        r["wallpaperGrab"] = SystemWallpaperSource.uiTestLastWallpaperGrab
        r["wallpaperGrabDetail"] = SystemWallpaperSource.uiTestLastWallpaperGrabDetail
        _ = SystemWallpaperSource.currentDesktopBackgroundData(for: NSScreen.main)
        r["wallpaperSource"] = SystemWallpaperSource.uiTestLastWallpaperSource

        let fakeWindowShot = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: "",
            thumbnailPath: "",
            captureRect: CodableRect(CGRect(x: 200, y: 200, width: 600, height: 400)),
            isWindowCapture: true
        )
        AnnotationWindowController.open(image: img, historyItem: fakeWindowShot)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let window = ctrl.window else {
            r["error"] = "editor window did not open"
            return r
        }
        defer { window.close() }

        let opts = ctrl.uiTestOptions
        r["backgroundEnabled"] = opts.isEnabled
        r["styleRaw"] = opts.style.rawValue
        r["hasWallpaperData"] = (opts.customImageData != nil)

        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        let shotPath = "/tmp/krit-editor/window-editor.png"
        try? await Task.sleep(nanoseconds: 300_000_000)
        let shotOK = Self.snapshotWindow(window, to: shotPath)
        r["snapshot"] = shotOK ? shotPath : "FAILED"

        r["allPass"] = opts.isEnabled && opts.style == .image
            && (opts.customImageData != nil) && shotOK
        return r
    }

    // MARK: - Cenário: shadow-sweep (prova do range da sombra do composer)

    /// Compõe a MESMA imagem determinística em 5 intensidades de sombra
    /// (0.15 a 1.0) sobre um fundo claro, offscreen, via o caminho real do
    /// composer. Prova visual de que o slider de sombra tem range dramático
    /// (a reclamação era "muda pouquíssimo ao aumentar"). PNGs em
    /// /tmp/krit-shadow/ pro gate visual; asserts garantem que cada nível
    /// escurece mensuravelmente mais a região logo abaixo do card.
    private static func runShadowSweep() -> [String: Any] {
        var r: [String: Any] = [:]

        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus()
        NSColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        img.unlockFocus()

        let dir = "/tmp/krit-shadow"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var opts = ScreenshotBackgroundOptions.editorDefault
        opts.isEnabled = true
        opts.style = .solid
        opts.colorHex = "#f4eadb"   // fundo claro: sombra fica mensurável
        opts.padding = 96

        let levels: [CGFloat] = [0.15, 0.4, 0.55, 0.8, 1.0]
        // Luminância média numa faixa logo abaixo do card, onde a sombra cai.
        var lumas: [Double] = []
        var paths: [String] = []
        for level in levels {
            opts.shadow = level
            let composed = ScreenshotBackgroundComposer.composeIfNeeded(img, options: opts)
            guard let cg = composed.bestCGImage else { continue }
            let path = String(format: "%@/shadow-%03d.png", dir, Int(level * 100))
            if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                          "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                if CGImageDestinationFinalize(dest) { paths.append(path) }
            }
            // Acha a borda INFERIOR do card empiricamente: varre a coluna central
            // de baixo pra cima até achar a cor exata da imagem de teste. Imune a
            // origem de coordenadas e a escala de pixels (o probe por slot rect
            // errou exatamente nisso e amostrava dentro do card).
            guard let buf = rgbaPixels(cg) else { lumas.append(-1); continue }
            let w = cg.width, h = cg.height
            let cx = w / 2
            var cardBottomRow = -1
            var row = h - 1
            while row >= 0 {
                let i = (row * w + cx) * 4
                if abs(Int(buf[i]) - 38) < 12, abs(Int(buf[i + 1]) - 43) < 12, abs(Int(buf[i + 2]) - 56) < 12 {
                    cardBottomRow = row
                    break
                }
                row -= 1
            }
            guard cardBottomRow > 0 else { lumas.append(-1); continue }
            let probeY = min(cardBottomRow + max(8, h / 80), h - 1)
            var total = 0.0, count = 0.0
            for x in stride(from: cx - 60, through: cx + 60, by: 20) {
                guard x >= 0, x < w else { continue }
                let i = (probeY * w + x) * 4
                total += 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
                count += 1
            }
            lumas.append(count > 0 ? total / count : -1)
        }

        r["levels"] = levels.map { Double($0) }
        r["lumasBelowCard"] = lumas
        r["renderedPaths"] = paths
        // Range dramático: cada passo escurece a faixa, e do primeiro ao último
        // a queda precisa ser grande (> 60 de 255 de luminância).
        let monotonic = lumas.count == levels.count && zip(lumas, lumas.dropFirst()).allSatisfy { $0 > $1 }
        let bigDrop = (lumas.first ?? 0) - (lumas.last ?? 0) > 60
        r["monotonicPass"] = monotonic
        r["dynamicRangePass"] = bigDrop
        r["allPass"] = monotonic && bigDrop && paths.count == levels.count
        return r
    }

    // MARK: - Cenário: window-capture (prova do grab isolado via SCK)

    /// Proves the isolated window-capture path: opens the real KRIT Preferences
    /// window, grabs it in ISOLATION through the production SCK path
    /// (CaptureEngine.isolatedWindowImage), and asserts (a) the image has real
    /// dimensions (> 0) and (b) the rounded window has TRANSPARENT corners
    /// (low alpha) over an OPAQUE centre (high alpha), the signature of a clean
    /// window grab with its real shape, not a flat screen-rect crop. Saves the
    /// captured PNG for visual review. Requires macOS 14 + Screen Recording
    /// consent; reports "skipped" with a reason when those are unavailable so the
    /// gate is never falsely red in a degraded headless sandbox.
    private static func runWindowCaptureSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard #available(macOS 14.0, *) else {
            r["skipped"] = "needs macOS 14+"; r["allPass"] = false; return r
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }

        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 500_000_000)   // let the window compose
        guard let win = ctrl.uiTestWindow, win.windowNumber > 0 else {
            r["error"] = "preferences window did not open"; r["allPass"] = false; return r
        }
        let windowID = CGWindowID(win.windowNumber)
        r["windowID"] = Int(windowID)

        let engine = appDelegate.uiTestCaptureEngine
        guard let image = await engine.uiTestIsolatedWindowImage(windowID: windowID) else {
            // Degraded sandbox (no Screen Recording / locked screen): the grab
            // can't run, but that's an environment limit, not a code failure.
            r["skipped"] = "isolated grab returned nil (Screen Recording consent or SCK unavailable)"
            r["allPass"] = false
            ctrl.uiTestClose()
            return r
        }

        r["logicalSize"] = ["w": image.size.width, "h": image.size.height]
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else {
            r["error"] = "captured image had no pixels"; r["allPass"] = false; ctrl.uiTestClose(); return r
        }
        r["pixelSize"] = ["w": cg.width, "h": cg.height]
        let dimensionsPass = cg.width > 0 && cg.height > 0
        r["dimensionsPass"] = dimensionsPass

        // Save for visual review.
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-window-capture", withIntermediateDirectories: true)
        let pngPath = "/tmp/krit-window-capture/isolated.png"
        if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: pngPath))
            r["snapshot"] = pngPath
        }

        // Alpha proof: sample a corner pixel inset a few px (rounded corners cut
        // here -> transparent) against the centre (window body -> opaque).
        let inset = 4
        let cornerAlpha = Self.alpha(at: (inset, inset), in: cg)
            ?? Self.alpha(at: (cg.width - 1 - inset, inset), in: cg)
        let centerAlpha = Self.alpha(at: (cg.width / 2, cg.height / 2), in: cg)
        r["cornerAlpha"] = cornerAlpha.map { Int($0) } ?? -1
        r["centerAlpha"] = centerAlpha.map { Int($0) } ?? -1
        // A clean isolated grab keeps the rounded corner transparent and the
        // body opaque. If the image had no alpha channel at all (flat crop),
        // hasAlpha is false and the rounded-corner proof can't hold.
        let alphaInfo = cg.alphaInfo
        let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
        r["hasAlphaChannel"] = hasAlpha
        let alphaPass = hasAlpha
            && (cornerAlpha ?? 255) < 64
            && (centerAlpha ?? 0) > 200
        r["alphaPass"] = alphaPass

        ctrl.uiTestClose()
        r["allPass"] = dimensionsPass && alphaPass
        return r
    }

    // MARK: - Cenário: history-restore (restaurar floata o resultado COMPOSTO)
    //
    // Prova a queixa "restaurei e veio sem o background/edição": pega o primeiro
    // item REAL da history que tem presentedPath (window shot / preset / editado),
    // floata via o caminho EXATO do restore (QuickAccessOverlay.show com
    // item.presentedImage) e asserta que presentedImage resolve pro frame composto,
    // NÃO pro raw imagePath. Snapshot do card em /tmp/krit-history pro gate visual.

    private static func runHistoryRestoreSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let manager = appDelegate.historyManager!

        // O primeiro item com presentedPath é o caso quebrado (thumbnail mostrava o
        // background, restore floatava o raw). Sem nenhum, não há o que provar aqui.
        guard let item = manager.items.first(where: { $0.presentedPath != nil }) else {
            r["skipped"] = "no history item with a presentedPath (capture a window shot first)"
            r["allPass"] = false
            return r
        }

        let presented = item.presentedImage
        let raw = item.fullImage
        let pPx = presented.bestCGImage.map { "\($0.width)x\($0.height)" } ?? "?"
        let rPx = raw.bestCGImage.map { "\($0.width)x\($0.height)" } ?? "?"
        r["presentedPixels"] = pPx
        r["rawPixels"] = rPx
        // A prova central: o restore agora floata o frame COMPOSTO, que para um
        // window shot/preset é um bitmap diferente (maior, com background) do raw.
        let usesPresented = (presented.bestCGImage?.width ?? 0) != (raw.bestCGImage?.width ?? -1)
            || (presented.bestCGImage?.height ?? 0) != (raw.bestCGImage?.height ?? -1)
        r["usesPresentedFrame"] = usesPresented

        let before = QuickAccessOverlay.uiTestWindows.count
        // Caminho IDÊNTICO ao onRestore do HistoryPanelController.
        QuickAccessOverlay.show(image: item.presentedImage, historyItem: item,
                                historyManager: manager, screen: NSScreen.main)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        defer { if QuickAccessOverlay.uiTestWindows.count > before { QuickAccessOverlay.uiTestCloseNewest() } }

        let floated = QuickAccessOverlay.uiTestWindows.count > before
        r["overlayFloated"] = floated
        if floated, let win = QuickAccessOverlay.uiTestWindows.last {
            try? FileManager.default.createDirectory(atPath: "/tmp/krit-history", withIntermediateDirectories: true)
            let path = "/tmp/krit-history/restore.png"
            r["snapshot"] = Self.snapshotWindow(win, to: path) ? path : "FAILED"
        }

        r["allPass"] = usesPresented && floated
        return r
    }

    // MARK: - Cenário: preset-save (editar um preset e salvar as mudanças nele)
    //
    // Prova a queixa "to com o preset selecionado, edito, e preciso poder salvar":
    // o edit base persiste pela edição (diferente do activePreset, que cai pra nil),
    // "Save Changes" grava a config editada NO preset (update, não duplica) e o
    // preset volta a ficar selecionado (sem o badge "(edited)"). Testa o caminho
    // do store que o sidebar chama.

    private static func runPresetSaveSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        let testName = "UITestPreset_SaveFlow"
        if let existing = TemplateStore.all().first(where: { $0.name == testName }) {
            TemplateStore.delete(id: existing.id)
        }
        TemplateStore.setActive(name: nil)
        TemplateStore.setEditingBase(name: nil)

        // Editor hosts the real background sidebar whose dropdown we inspect.
        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus(); NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill(); img.unlockFocus()
        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let sidebar = ctrl.uiTestSidebar else {
            r["error"] = "editor/sidebar did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.window?.close() }

        // 1. Base preset (padding 40), selected and marked as the edit base.
        var base = ScreenshotBackgroundOptions.editorDefault
        base.isEnabled = true
        base.style = .gradient
        base.padding = 40
        guard let created = TemplateStore.add(name: testName, background: base) else {
            r["error"] = "add failed"; r["allPass"] = false; return r
        }
        TemplateStore.setActive(name: testName)
        TemplateStore.setEditingBase(name: testName)
        ctrl.uiTestApplyBackground(base)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let titlesClean = sidebar.uiTestPresetMenuTitles()
        r["menuClean"] = titlesClean
        let cleanShowsName = titlesClean.first == testName
        let cleanHasNoSave = !titlesClean.contains { $0.contains("Save Changes") }
        r["cleanShowsName"] = cleanShowsName
        r["cleanHasNoSave"] = cleanHasNoSave

        // 2. Hand-edit (padding 120) through the REAL options path -> "(edited)".
        var edited = base; edited.padding = 120
        ctrl.uiTestApplyBackground(edited)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let titlesEdited = sidebar.uiTestPresetMenuTitles()
        r["menuEdited"] = titlesEdited
        let editedBadge = titlesEdited.contains { $0 == "\(testName) (edited)" }
        let hasSaveItem = titlesEdited.contains { $0.contains("Save Changes to") && $0.contains(testName) }
        r["editedBadge"] = editedBadge
        r["hasSaveItem"] = hasSaveItem

        // 3. Save the edits back into the SAME preset (the store path the menu item
        //    triggers): no duplicate, the saved config carries the edit.
        _ = TemplateStore.update(id: created.id, background: edited)
        TemplateStore.setActive(name: testName)
        let copies = TemplateStore.all().filter { $0.name == testName }.count
        let savedPadding = TemplateStore.template(named: testName)?.background.padding ?? -1
        r["copies"] = copies
        r["savedPadding"] = savedPadding

        // cleanup
        if let s = TemplateStore.template(named: testName) { TemplateStore.delete(id: s.id) }
        TemplateStore.setEditingBase(name: nil)
        TemplateStore.setActive(name: nil)

        r["allPass"] = cleanShowsName && cleanHasNoSave && editedBadge && hasSaveItem
            && copies == 1 && abs(savedPadding - 120) < 0.5
        return r
    }

    // MARK: - Cenário: highlighter-partial (grifador segue o swipe, não a linha toda)
    //
    // Renderiza uma frase, roda o OCR real e faz um swipe sobre ~40% da linha. Prova
    // que o grifo cobre só o trecho percorrido (como marca-texto de verdade), não a
    // linha inteira (o bug), e que um swipe na linha toda ainda grifa tudo.

    private static func runHighlighterPartialSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        // Open raw (no default background) so OCR maps onto the full canvas slot.
        let savedDefault = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefault) }

        let size = NSSize(width: 900, height: 300)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("The quick brown fox jumps over the lazy dog" as NSString).draw(
            at: NSPoint(x: 40, y: 130),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .semibold),
                             .foregroundColor: NSColor.black])
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.window?.close() }
        let canvas = ctrl.uiTestCanvas

        await canvas.uiTestWarmTextDetection()
        let lineRects = canvas.uiTestDetectedLineRects()
        r["detectedLines"] = lineRects.count
        guard let line = lineRects.max(by: { $0.width < $1.width }) else {
            r["error"] = "no text detected"; r["allPass"] = false; return r
        }
        let fullWidth = line.width
        r["fullLineWidth"] = Int(fullWidth)

        // Swipe the LEFT ~40% of the line only.
        let y = line.midY
        let partial = canvas.uiTestSnappedHighlightRects(
            from: CGPoint(x: line.minX + 2, y: y),
            to: CGPoint(x: line.minX + fullWidth * 0.4, y: y))
        r["snappedCount"] = partial.count
        guard let hi = partial.first else {
            r["error"] = "no snap (band missed the line)"; r["allPass"] = false; return r
        }
        let ratio = hi.width / fullWidth
        r["partialWidth"] = Int(hi.width)
        r["ratio"] = ratio
        // The bug highlighted the whole line (ratio ~1.0). A real marker follows the
        // swipe, so ~0.4 here; allow slack but it must be clearly under the full line.
        let isPartial = ratio < 0.7
        let coversSwept = hi.width > fullWidth * 0.2
        r["isPartial"] = isPartial
        r["coversSwept"] = coversSwept

        // A full-line swipe still highlights essentially the whole line.
        let full = canvas.uiTestSnappedHighlightRects(
            from: CGPoint(x: line.minX - 5, y: y),
            to: CGPoint(x: line.maxX + 5, y: y))
        let fullW = full.first?.width ?? 0
        let fullStillWorks = fullW > fullWidth * 0.9
        r["fullSwipeWidth"] = Int(fullW)
        r["fullStillWorks"] = fullStillWorks

        r["allPass"] = isPartial && coversSwept && fullStillWorks
        return r
    }

    // MARK: - Cenário: preset-default-open (print com preset padrão abre SELECIONADO)
    //
    // Reproduz a queixa: um print tirado com o preset definido como padrão abria no
    // editor como "Custom", então editar criava um template novo em vez de oferecer
    // "Save Changes". Prova que o editor agora abre com o preset padrão SELECIONADO
    // e que editar acende o "Save Changes to <name>".

    private static func runPresetDefaultOpenSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        let testName = "UITestPreset_DefaultOpen"
        let savedDefault = TemplateStore.defaultTemplate?.name
        if let existing = TemplateStore.all().first(where: { $0.name == testName }) {
            TemplateStore.delete(id: existing.id)
        }

        // 1. A gradient preset, pinned as the default for new captures.
        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = true
        bg.style = .gradient
        bg.padding = 64
        guard TemplateStore.add(name: testName, background: bg) != nil else {
            r["error"] = "add failed"; r["allPass"] = false; return r
        }
        TemplateStore.setDefault(name: testName)

        // 2. A fresh capture (no historyItem) opens composed from the default preset.
        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus(); NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill(); img.unlockFocus()
        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let sidebar = ctrl.uiTestSidebar else {
            TemplateStore.setDefault(name: savedDefault)
            if let s = TemplateStore.template(named: testName) { TemplateStore.delete(id: s.id) }
            r["error"] = "editor/sidebar did not open"; r["allPass"] = false; return r
        }
        defer {
            ctrl.window?.close()
            TemplateStore.setDefault(name: savedDefault)
            if let s = TemplateStore.template(named: testName) { TemplateStore.delete(id: s.id) }
            TemplateStore.setEditingBase(name: nil)
            TemplateStore.setActive(name: nil)
        }

        // 3. On open the dropdown shows the preset SELECTED, not "Custom".
        let onOpen = sidebar.uiTestPresetMenuTitles()
        r["menuOnOpen"] = onOpen
        let selectedOnOpen = onOpen.first == testName
        r["selectedOnOpen"] = selectedOnOpen

        // 4. Editing it offers "Save Changes to <name>" (not only a new template).
        var edited = bg; edited.padding = 130
        ctrl.uiTestApplyBackground(edited)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let onEdit = sidebar.uiTestPresetMenuTitles()
        r["menuOnEdit"] = onEdit
        let hasSave = onEdit.contains { $0.contains("Save Changes to") && $0.contains(testName) }
        r["hasSaveAfterEdit"] = hasSave

        r["allPass"] = selectedOnOpen && hasSave
        return r
    }

    // MARK: - Cenário: preset-gallery (contact sheet de TODOS os wallpapers curados)
    //
    // Compõe cada preset de `imagePresets` (mesh + waves) com um card neutro no
    // caminho real (composeIfNeeded) e tila num contact sheet pra revisão visual
    // do set inteiro de uma vez. Diagnóstico sob demanda, não entra na bateria.

    private static func runPresetGallery() async -> [String: Any] {
        var r: [String: Any] = [:]
        let presets = ScreenshotBackgroundOptions.imagePresets
        r["count"] = presets.count
        r["names"] = presets.map { $0.name }

        // Small neutral card so the swatch reads like a real composed shot while
        // the mesh fills most of the tile.
        let card = NSImage(size: NSSize(width: 90, height: 58))
        card.lockFocus()
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 90, height: 58).fill()
        card.unlockFocus()

        let cols = 6
        let tileW: CGFloat = 200, tileH: CGFloat = 150, labelH: CGFloat = 22, pad: CGFloat = 10
        let rows = (presets.count + cols - 1) / cols
        let sheetW = CGFloat(cols) * (tileW + pad) + pad
        let sheetH = CGFloat(rows) * (tileH + labelH + pad) + pad

        let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
        sheet.lockFocus()
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

        for (i, preset) in presets.enumerated() {
            var opts = ScreenshotBackgroundOptions.editorDefault
            opts.isEnabled = true
            opts.style = .image
            opts.presetName = preset.name
            opts.customImageData = nil
            opts.padding = 60
            let composed = ScreenshotBackgroundComposer.composeIfNeeded(card, options: opts)
            let col = i % cols, row = i / cols
            let x = pad + CGFloat(col) * (tileW + pad)
            let y = sheetH - (CGFloat(row + 1) * (tileH + labelH + pad)) + pad
            composed.draw(in: NSRect(x: x, y: y + labelH, width: tileW, height: tileH),
                          from: .zero, operation: .copy, fraction: 1.0)
            (preset.name as NSString).draw(at: NSPoint(x: x + 2, y: y + 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }
        sheet.unlockFocus()

        try? FileManager.default.createDirectory(atPath: "/tmp/krit-presets", withIntermediateDirectories: true)
        let path = "/tmp/krit-presets/gallery.png"
        if let tiff = sheet.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            r["gallery"] = path
        }
        r["allPass"] = (r["gallery"] != nil)
        return r
    }

    /// Isolates WHICH link of the supersampled window-shot pipeline breaks:
    /// grab (raw 3x), compose (windowShotBackground + composeIfNeeded), or the
    /// persist route (the tiffRepresentation path HistoryManager uses for the
    /// presented PNG). Saves one PNG per stage to /tmp/krit-compose for the
    /// visual gate, and diffs compose-direct vs persist-route numerically.
    private static func runComposeScaleSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard #available(macOS 14.0, *) else {
            r["skipped"] = "needs macOS 14+"; r["allPass"] = false; return r
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let win = ctrl.uiTestWindow, win.windowNumber > 0 else {
            r["error"] = "preferences window did not open"; r["allPass"] = false; return r
        }
        let engine = appDelegate.uiTestCaptureEngine

        let realRect = win.frame
        guard let image = await engine.uiTestIsolatedWindowImage(windowID: CGWindowID(win.windowNumber)) else {
            r["skipped"] = "grab returned nil"; r["allPass"] = false; ctrl.uiTestClose(); return r
        }
        ctrl.uiTestClose()
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-compose", withIntermediateDirectories: true)

        func savePNG(_ cg: CGImage, _ name: String) {
            if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/krit-compose/\(name).png"))
            }
        }
        // Stage 1: the raw grab.
        var insetPass = false
        if let rawCG = image.bestCGImage {
            savePNG(rawCG, "raw")
            r["rawPixels"] = ["w": rawCG.width, "h": rawCG.height]
            // The window content must reach (almost) the buffer edges. A large
            // inset means SCK shrank the window to fit the native shadow into
            // the buffer, the clipped halo that composed as the ghost rounded
            // rect around window shots ("invisible border" bug).
            if let insets = opaqueContentInsets(rawCG) {
                r["contentInsets"] = ["l": insets.l, "r": insets.r, "t": insets.t, "b": insets.b]
                let maxInset = max(insets.l, insets.r, insets.t, insets.b)
                let tolerance = Int(Double(max(rawCG.width, rawCG.height)) * 0.02)
                insetPass = maxInset <= tolerance
                r["contentInsetPass"] = insetPass
            }
        }
        r["rawPointSize"] = ["w": image.size.width, "h": image.size.height]

        // Stage 2: the real window-shot compose.
        let opts = AnnotationWindowController.windowShotBackground(for: image, captureRect: nil)
        r["optionsEnabled"] = opts.isEnabled
        let composed = ScreenshotBackgroundComposer.composeIfNeeded(image, options: opts)
        r["composedPointSize"] = ["w": composed.size.width, "h": composed.size.height]
        var directCG: CGImage?
        if let cg = composed.bestCGImage {
            directCG = cg
            savePNG(cg, "composed-direct")
            r["composedPixels"] = ["w": cg.width, "h": cg.height]
        }

        // Stage 3: the persist route HistoryManager uses for presentedPath.
        var tiffCG: CGImage?
        if let tiff = composed.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/krit-compose/composed-tiff.png"))
            tiffCG = rep.cgImage
            r["tiffPixels"] = ["w": rep.pixelsWide, "h": rep.pixelsHigh]
        }

        // The two routes must encode the SAME picture.
        if let a = directCG, let b = tiffCG, let diff = Self.meanAbsDiff(a, b) {
            r["routeDiff"] = diff
            r["routesMatch"] = diff < 12
        }

        // Stage 4: the EXACT production call, with the real on-screen rect (it
        // selects the screen/wallpaper). The Leo-reported artifact survived the
        // nil-rect probe, so this is the remaining variable.
        let optsReal = AnnotationWindowController.windowShotBackground(for: image, captureRect: realRect)
        let composedReal = ScreenshotBackgroundComposer.composeIfNeeded(image, options: optsReal)
        var realMatch = false
        if let cg = composedReal.bestCGImage {
            savePNG(cg, "composed-realrect")
            r["composedRealPixels"] = ["w": cg.width, "h": cg.height]
            if let a = directCG, let diff = Self.meanAbsDiff(a, cg) {
                r["realRectDiff"] = diff
                // The wallpaper crop may legitimately differ; what must NOT
                // happen is the window shrinking into a corner, which produces
                // a huge diff. Threshold is loose on purpose.
                realMatch = diff < 40
            }
        }
        r["realRectMatch"] = realMatch

        // Stage 5: the FULL production flow, end to end (wallpaper refresh +
        // grab + finishCapture compose + history persist + overlay). Diff the
        // presented PNG it writes against the known-good direct compose. This
        // is the file the user drags out, the artifact the bug reports show.
        // When a SECOND display exists, the window is moved there first: the
        // user's machine is dual-monitor and that permutation was the one never
        // covered (different backing scale and wallpaper per display).
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 400_000_000)
        if NSScreen.screens.count > 1, let win2 = ctrl.uiTestWindow {
            let target = NSScreen.screens[1].visibleFrame
            win2.setFrameOrigin(NSPoint(x: target.midX - win2.frame.width / 2,
                                        y: target.midY - win2.frame.height / 2))
            r["movedToSecondScreen"] = true
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        var fullMatch = false
        if let win2 = ctrl.uiTestWindow, win2.windowNumber > 0,
           let screen = win2.screen ?? NSScreen.main {
            let before = appDelegate.historyManager.items.first?.id
            await engine.uiTestFullWindowCapture(
                windowID: CGWindowID(win2.windowNumber), rect: win2.frame,
                on: screen, historyManager: appDelegate.historyManager
            )
            // The presented PNG persists in a detached task; give it a moment.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let item = appDelegate.historyManager.items.first, item.id != before,
               let presentedPath = item.presentedPath,
               let presented = NSImage(contentsOfFile: presentedPath),
               let pcg = presented.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                savePNG(pcg, "presented-full-flow")
                r["fullFlowPixels"] = ["w": pcg.width, "h": pcg.height]
                if let a = directCG, let diff = Self.meanAbsDiff(a, pcg) {
                    r["fullFlowDiff"] = diff
                    fullMatch = diff < 40
                }
            } else {
                r["fullFlowError"] = "no new history item or presentedPath missing"
            }
        }
        ctrl.uiTestClose()
        r["fullFlowMatch"] = fullMatch

        r["allPass"] = (r["routesMatch"] as? Bool ?? false) && realMatch && fullMatch && insetPass
        return r
    }

    /// Distance from each buffer edge to the first nearly-opaque pixel, sampled
    /// along the middle row/column. Cheap proxy for "does the window content
    /// fill the buffer" (native-shadow margins show up as large insets).
    private static func opaqueContentInsets(_ cg: CGImage) -> (l: Int, r: Int, t: Int, b: Int)? {
        let w = cg.width, h = cg.height
        guard w > 4, h > 4,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        guard bpp >= 4 else { return nil }
        // Alpha byte position depends on BOTH alphaInfo and byte order: SCK
        // frames are typically BGRA in memory (alpha-first + 32-bit little),
        // which puts the alpha byte LAST despite the "first" alpha info.
        let alphaInfo = cg.alphaInfo
        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first
        let littleEndian = cg.bitmapInfo.contains(.byteOrder32Little)
        let alphaOffset = (alphaFirst != littleEndian) ? 0 : 3
        func alpha(_ x: Int, _ y: Int) -> UInt8 { ptr[y * bpr + x * bpp + alphaOffset] }
        let midY = h / 2, midX = w / 2
        var left = w, right = w, top = h, bottom = h
        for x in 0..<w where alpha(x, midY) > 250 { left = x; break }
        for x in stride(from: w - 1, through: 0, by: -1) where alpha(x, midY) > 250 { right = w - 1 - x; break }
        for y in 0..<h where alpha(midX, y) > 250 { top = y; break }
        for y in stride(from: h - 1, through: 0, by: -1) where alpha(midX, y) > 250 { bottom = h - 1 - y; break }
        return (left, right, top, bottom)
    }

    /// The user's literal sequence: file-drag the card out (and cancel), then
    /// try to HIDE it (standby gesture); open/close the Space preview, then try
    /// to DELETE it (edge gesture). Asserts each gesture still works after the
    /// preceding interaction, which is the reported breakage.
    private static func runOverlayPostGesture() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        let img = NSImage(size: NSSize(width: 300, height: 200))
        img.lockFocus(); NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
        let tmpPath = "/tmp/krit-postgesture-test.png"
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tmpPath))
        }
        let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: tmpPath,
                               thumbnailPath: tmpPath, captureRect: nil)
        QuickAccessOverlay.show(image: img, historyItem: item,
                                historyManager: appDelegate.historyManager, screen: NSScreen.main)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard QuickAccessOverlay.uiTestWindows.count > before,
              let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "card did not appear"; r["allPass"] = false; return r
        }

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryH - p.y) }
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func center() -> CGPoint { cg(NSPoint(x: card.frame.midX, y: card.frame.midY)) }
        func hover() async {
            post(.mouseMoved, CGPoint(x: center().x - 25, y: center().y))
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.mouseMoved, center())
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        func dragFrom(_ start: CGPoint, by: CGVector, steps: Int, settleNs: UInt64) async {
            post(.leftMouseDown, start)
            try? await Task.sleep(nanoseconds: 60_000_000)
            var p = start
            for _ in 0..<steps {
                p.x += by.dx / CGFloat(steps); p.y += by.dy / CGFloat(steps)
                post(.leftMouseDragged, p)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            post(.leftMouseUp, p)
            try? await Task.sleep(nanoseconds: settleNs)
        }

        // 1. FILE-DRAG with regret: pull INTO the screen (clearly horizontal so
        //    the classifier converts to a file drag), then come back and release
        //    on the card's own slot, where nothing accepts the drop. This is the
        //    user's "dragged as a file, gave up" interaction.
        await hover()
        let inward: CGFloat = Settings.overlayOnLeft ? 1 : -1
        let fileStart = center()
        post(.leftMouseDown, fileStart)
        try? await Task.sleep(nanoseconds: 60_000_000)
        var fp = fileStart
        for _ in 0..<12 {
            fp.x += inward * 24
            post(.leftMouseDragged, fp)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        for _ in 0..<12 {
            fp.x -= inward * 24
            post(.leftMouseDragged, fp)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        post(.leftMouseUp, fp)
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // session end + regret slide-back
        r["afterFileDrag"] = QuickAccessOverlay.uiTestHoverState()
        r["gestureAfterFileDrag"] = QuickAccessOverlay.uiTestGestureState()

        // 2. HIDE (standby): hover again, drag straight DOWN past 50pt.
        await hover()
        await dragFrom(center(), by: CGVector(dx: 0, dy: 90), steps: 8, settleNs: 900_000_000)
        let standbyStates = QuickAccessOverlay.uiTestStandbyStates()
        let parked = standbyStates.last == true
        r["standbyWorkedAfterFileDrag"] = parked
        r["gestureAfterStandby"] = QuickAccessOverlay.uiTestGestureState()

        // 3. Restore the parked card so the preview/delete phase has a live card.
        if parked { QuickAccessOverlay.uiTestRestoreAll(on: NSScreen.main) }
        try? await Task.sleep(nanoseconds: 900_000_000)

        // 4. PREVIEW: Space open + close. O Space só chega no card se ele for a
        // key window NAQUELE instante (o monitor de teclado é local): re-asserta
        // o hover até o probe confirmar, porque o cursor físico do usuário
        // disputa com o sintético (flaky conhecido de CGEvent em Mac em uso).
        func armCard() async -> Bool {
            for _ in 0..<5 {
                await hover()
                if (QuickAccessOverlay.uiTestHoverState()["isKey"] as? Bool) == true { return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }
        r["spaceArmed"] = await armCard()
        func postKey(_ code: CGKeyCode, down: Bool) {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
        postKey(49, down: true); postKey(49, down: false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let previewOpened = QuickLookController.shared.isOpen
        r["previewOpened"] = previewOpened
        postKey(49, down: true); postKey(49, down: false)
        try? await Task.sleep(nanoseconds: 600_000_000)

        // 5. DELETE after preview: drag toward the stack edge past 40% width.
        r["deleteArmed"] = await armCard()
        let edge: CGFloat = Settings.overlayOnLeft ? -1 : 1
        let countBeforeDelete = QuickAccessOverlay.uiTestWindows.count
        await dragFrom(center(), by: CGVector(dx: edge * card.frame.width * 0.7, dy: 0),
                       steps: 8, settleNs: 1_200_000_000)
        let deleted = QuickAccessOverlay.uiTestWindows.count < countBeforeDelete
        r["deleteWorkedAfterPreview"] = deleted

        r["allPass"] = parked && previewOpened && deleted
        if !deleted { QuickAccessOverlay.uiTestCloseNewest() }
        return r
    }

    /// Measures the REAL hotkey path: another app frontmost, the configured
    /// area shortcut synthesized as CGEvents, cursor wiggling like a user's
    /// hand. Reports per-link deltas (handler, window, key, first mouseMoved =
    /// crosshair live) so the perceived "mouse enters selection mode" latency
    /// is the thing measured, not a proxy.
    /// Reproduces "the overlay doesn't appear right when another app is in
    /// front". With Finder activated (KRIT is an LSUIElement accessory, so it
    /// goes inactive), starts area capture and reports whether each overlay is
    /// ACTUALLY on screen (visible + unoccluded + on the active Space), plus the
    /// app activation state. A non-activating panel of an inactive accessory app
    /// can fail to order in front of the active app's window.
    /// Measures the editor canvas redraw cost — the "editing photos lags" report.
    /// Opens the editor with a large capture and times forced synchronous draws,
    /// which is exactly what every annotation drag triggers (each mouseDragged
    /// calls setNeedsDisplay(bounds) → a full draw). Reports ms per frame; a
    /// drag at 60fps needs <16ms/frame to feel smooth.
    /// Verifies the default arrow weight scales with the capture size (the "arrow
    /// size should follow the screen proportion" report): a 4K shot must open
    /// with a thicker default than a small region, both starting from the same
    /// preference.
    /// Renders the editor with the background OFF (raw capture, the owner's
    /// case) and snapshots it, so the gate is the actual rendered image filling
    /// the canvas — not just "background ON works" (which is what the perf change
    /// regressed: the raw image drew shifted with empty space above).
    private static func runEditorOffRender() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        // High-frequency content like a real screenshot, portrait-ish so a
        // vertical shift would be obvious.
        let size = NSSize(width: 1800, height: 1150)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSRect(x: 80, y: size.height - 160, width: 600, height: 60).fill()   // a bright bar near the TOP
        NSColor.orange.setFill()
        NSRect(x: 80, y: 80, width: 600, height: 60).fill()                  // a bar near the BOTTOM
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.close() }

        // Force background OFF (raw capture).
        var off = ScreenshotBackgroundOptions.editorDefault
        off.isEnabled = false
        ctrl.uiTestApplyBackground(off)
        try? await Task.sleep(nanoseconds: 500_000_000)
        r["backgroundEnabled"] = ctrl.uiTestOptions.isEnabled

        let canvas = ctrl.uiTestCanvas
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            r["error"] = "no rep"; r["allPass"] = false; return r
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let shot = "/tmp/krit-editor/off-render.png"
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: shot))
            r["snapshot"] = shot
        }
        r["canvasSize"] = NSStringFromRect(canvas.bounds)
        r["allPass"] = FileManager.default.fileExists(atPath: shot)
        return r
    }

    private static func runArrowScale() async -> [String: Any] {
        var r: [String: Any] = [:]
        // Deterministic base so the assertions don't ride on whatever the user last
        // set; restore it after so the test never mutates real preferences.
        let savedBase = Settings.annotationLineWidth
        Settings.annotationLineWidth = 8
        defer { Settings.annotationLineWidth = savedBase }

        func openWidth(_ size: NSSize) async -> CGFloat {
            let img = NSImage(size: size)
            img.lockFocus(); NSColor.gray.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
            AnnotationWindowController.open(image: img)
            // A large capture's editor takes longer to settle on the arrow tool; read
            // too early and it's still on the non-arrow (0.6×) default. Give it room.
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            let w = AnnotationWindowController.uiTestLastController?.uiTestCanvas.activeLineWidth ?? -1
            AnnotationWindowController.uiTestLastController?.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return w
        }
        // 4K (≥ the 2400 reference, factor clamps at 1.5×), the external UWQHD the
        // owner annotates on (3440 → 1.43×), the built-in (≤ reference → 1.0×), and
        // a small area (1.0×).
        let k4 = await openWidth(NSSize(width: 3840, height: 2160))
        let ext = await openWidth(NSSize(width: 3440, height: 1440))
        let builtin = await openWidth(NSSize(width: 1800, height: 1169))
        let small = await openWidth(NSSize(width: 600, height: 400))
        r["arrow4K"] = k4
        r["arrowExternal"] = ext
        r["arrowBuiltin"] = builtin
        r["arrowSmall"] = small

        // The fix: the gentle factor (cap 1.5×) keeps every default comfortably in
        // the lower half of the 1–20 slider. The old 1400/3.5× curve opened the 4K
        // arrow near 28pt and the external one near 20pt, so each shot had to be
        // shrunk by hand. base 8 → 4K ≈ 12, external ≈ 11.4, built-in/small = 8.
        let gentle4K = abs(k4 - 12.0) < 0.6          // 8 × 1.5
        let gentleExt = abs(ext - 11.43) < 0.6       // 8 × (3440/2400)
        let baseKept = abs(builtin - 8.0) < 0.4 && abs(small - 8.0) < 0.4
        let underSliderMax = k4 < 15 && ext < 15     // never crowd the 20pt ceiling
        let scalesUp = k4 > small                      // big captures still bump up
        r["gentle4K"] = gentle4K
        r["gentleExternal"] = gentleExt
        r["baseKept"] = baseKept
        r["underSliderMax"] = underSliderMax
        r["allPass"] = gentle4K && gentleExt && baseKept && underSliderMax && scalesUp
        return r
    }

    private static func runEditorDrawPerf() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        // Large retina-class capture with HIGH-FREQUENCY content (gradient +
        // colored rects): a solid fill resamples for free and hides the cost; a
        // real photo does not. This is the shot that lags in the editor.
        let img = NSImage(size: NSSize(width: 3840, height: 2160))
        img.lockFocus()
        NSGradient(colors: [.systemBlue, .systemPurple, .systemOrange])?
            .draw(in: NSRect(x: 0, y: 0, width: 3840, height: 2160), angle: 30)
        for i in stride(from: 0, to: 3840, by: 48) {
            NSColor(calibratedHue: CGFloat(i % 360) / 360, saturation: 0.7, brightness: 0.9, alpha: 0.4).setFill()
            NSRect(x: CGFloat(i), y: CGFloat((i * 11) % 2000), width: 36, height: 220).fill()
        }
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.close() }
        let canvas = ctrl.uiTestCanvas

        // Background ON (padding, wallpaper, shadow, corner) — the common editing
        // state, and what runs the composer + resample path every draw.
        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = true
        ctrl.uiTestApplyBackground(bg)
        try? await Task.sleep(nanoseconds: 500_000_000)
        r["backgroundEnabled"] = ctrl.uiTestOptions.isEnabled

        // cacheDisplay FORCES a real rasterization regardless of window
        // visibility (display() is a no-op when the test window isn't on
        // screen, which is why it falsely reported 0.1ms). This is the true
        // cost of the draw an annotation drag triggers.
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            r["error"] = "no bitmap rep"; r["allPass"] = false; return r
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep) // warm the presentation cache

        // Full-bounds redraw (today's behavior: every drag does
        // setNeedsDisplay(bounds)). Min of N runs to shed scheduler noise on a
        // loaded machine.
        func timeFull() -> Double {
            let frames = 12
            let t = CACurrentMediaTime()
            for _ in 0..<frames { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
            return (CACurrentMediaTime() - t) * 1000 / Double(frames)
        }
        var fullMin = Double.greatestFiniteMagnitude
        for _ in 0..<3 { fullMin = min(fullMin, timeFull()) }

        // Small-region redraw (what invalidating only the dragged annotation's
        // rect would cost). A 360×240 slice, the size of a typical annotation.
        let slice = NSRect(x: canvas.bounds.midX - 180, y: canvas.bounds.midY - 120, width: 360, height: 240)
        guard let sliceRep = canvas.bitmapImageRepForCachingDisplay(in: slice) else {
            r["error"] = "no slice rep"; r["allPass"] = false; return r
        }
        func timeSlice() -> Double {
            let frames = 12
            let t = CACurrentMediaTime()
            for _ in 0..<frames { canvas.cacheDisplay(in: slice, to: sliceRep) }
            return (CACurrentMediaTime() - t) * 1000 / Double(frames)
        }
        var sliceMin = Double.greatestFiniteMagnitude
        for _ in 0..<3 { sliceMin = min(sliceMin, timeSlice()) }

        // The background composite (mesh + shadow + grain) is a heavy CPU render.
        // composeIfNeeded re-runs it whole on every padding/inset/wallpaper change
        // and window resize. Measured here to document the cost the async path moves
        // off the main thread; it scales with source pixels.
        var composeOpts = bg
        composeOpts.padding = 41
        ScreenshotBackgroundComposer.uiTestPhaseTimings = [:]
        ScreenshotBackgroundComposer.uiTestProfiling = true
        let tCompose = CACurrentMediaTime()
        _ = ScreenshotBackgroundComposer.composeIfNeeded(img, options: composeOpts)
        r["recomposeMs"] = (CACurrentMediaTime() - tCompose) * 1000
        ScreenshotBackgroundComposer.uiTestProfiling = false
        r["composePhases"] = ScreenshotBackgroundComposer.uiTestPhaseTimings
        // The display proxy the live canvas now uses: capped resolution, no grain.
        // This is the cost a wallpaper switch pays, and must be a fraction of export.
        let tDisp = CACurrentMediaTime()
        _ = ScreenshotBackgroundComposer.composeIfNeeded(img, options: composeOpts, quality: .display)
        r["recomposeDisplayMs"] = (CACurrentMediaTime() - tDisp) * 1000

        // Repro a heavy condition: a small-point shot whose pixels are 4x (a dense
        // Retina grab). The display cap then bites hard. Measure export vs display at
        // scale 4, and DUMP both composites so the appearance can be compared by eye
        // (grain-skip + res-cap must look the same at fit zoom).
        let superPts = NSSize(width: 1100, height: 690)
        if let cs = CGColorSpace(name: CGColorSpace.sRGB),
           let sctx = CGContext(data: nil, width: 4400, height: 2760, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            sctx.setFillColor(NSColor(srgbRed: 0.85, green: 0.12, blue: 0.10, alpha: 1).cgColor)
            sctx.fill(CGRect(x: 0, y: 0, width: 4400, height: 2760))
            if let scg = sctx.makeImage() {
                let superImg = NSImage(size: superPts)
                superImg.addRepresentation(NSBitmapImageRep(cgImage: scg))
                var so = composeOpts
                let tSE = CACurrentMediaTime()
                let exp = ScreenshotBackgroundComposer.composeIfNeeded(superImg, options: so, quality: .export)
                r["superExportMs"] = (CACurrentMediaTime() - tSE) * 1000
                so.padding = 42
                let tSD = CACurrentMediaTime()
                let dsp = ScreenshotBackgroundComposer.composeIfNeeded(superImg, options: so, quality: .display)
                r["superDisplayMs"] = (CACurrentMediaTime() - tSD) * 1000
                func dump(_ im: NSImage, _ path: String) {
                    guard let cg = im.bestCGImage,
                          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                dump(exp, "/tmp/krit-editor/compose-export.png")
                dump(dsp, "/tmp/krit-editor/compose-display.png")
            }
        }

        // THE fix proof: drop the presentation cache (the state every padding/inset/
        // wallpaper change and window resize lands in) and time the FIRST main-thread
        // draw. The old code ran composeIfNeeded INSIDE this draw, so it cost the full
        // recompose (seconds) and froze the editor. Async compose returns at once with
        // a placeholder, so this must now be well under the gate.
        canvas.uiTestInvalidatePresentationCache()
        let tMiss = CACurrentMediaTime()
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let missDraw = (CACurrentMediaTime() - tMiss) * 1000
        r["missDrawMs"] = missDraw
        // Let the off-main compose land, then confirm the real composite replaced the
        // placeholder (cache repopulated, draw cost back to the normal cached path).
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let tSettled = CACurrentMediaTime()
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        r["settledDrawMs"] = (CACurrentMediaTime() - tSettled) * 1000

        r["canvasSize"] = NSStringFromRect(canvas.bounds)
        r["msPerFrameFull"] = fullMin
        r["fpsFull"] = fullMin > 0 ? 1000.0 / fullMin : 0
        r["msPerFrameSlice"] = sliceMin
        r["fpsSlice"] = sliceMin > 0 ? 1000.0 / sliceMin : 0
        // Gate on the two smooth paths: the small-region drag redraw, and the
        // option-change/resize draw, which must NOT carry the multi-second compose
        // (async). 500ms is far above the ~95ms placeholder draw but far below the
        // ~4s a synchronous recompose would cost, so it fails loudly on regression.
        r["allPass"] = sliceMin < 16 && missDraw < 500
        return r
    }

    private static func runOverlayForeignVis() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let engine = appDelegate.uiTestCaptureEngine

        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            finder.activate()
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        r["frontmostBefore"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        r["appActiveBefore"] = NSApp.isActive
        r["policyBefore"] = "\(NSApp.activationPolicy().rawValue)"

        await engine.startAreaCapture(historyManager: appDelegate.historyManager)
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard let sel = engine.uiTestActiveSelection else {
            r["error"] = "no selection window"; r["allPass"] = false; return r
        }
        let vis = sel.uiTestOverlayVisibility()
        for (k, v) in vis { r[k] = v }
        r["frontmostDuring"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        r["appActiveDuring"] = NSApp.isActive

        sel.cancel()
        // Gate: every overlay must be genuinely on screen for the selection to
        // be usable. allOnScreen=false is the reproduction of the bug.
        r["allPass"] = (vis["allOnScreen"] as? Bool) ?? false
        return r
    }

    private static func runAreaDelayReal() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .captureArea),
              let key = shortcut.key else {
            r["error"] = "no area shortcut configured"; r["allPass"] = false; return r
        }
        AreaSelectionDiag.timeline = [:]

        // Put ANOTHER app frontmost (Finder), the real-world starting state.
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            finder.activate()
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        r["frontmostBefore"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        let code = CGKeyCode(key.rawValue)

        let t0 = CACurrentMediaTime()
        AreaSelectionDiag.timeline["hotkeyDownPosted"] = t0
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
            down.flags = flags; down.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)   // tecla segurada 60ms
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
            up.flags = flags; up.post(tap: .cghidEventTap)
        }
        AreaSelectionDiag.timeline["hotkeyUpPosted"] = CACurrentMediaTime()

        // Foco preservado: o app alvo (Finder) tem que CONTINUAR frontmost com a
        // seleção viva. O overlay é um painel não-ativante; se o KRIT aparecer
        // aqui, a seleção/realce do app do usuário muda no momento do print (o
        // bug relatado: "ele sempre tira de seleção onde eu estou").
        for _ in 0..<30 {
            if AreaSelectionDiag.timeline["becameKey"] != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let frontmostDuring = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        r["frontmostDuringSelection"] = frontmostDuring
        // KRIT now activates so the overlay shows in front of any app (an
        // inactive accessory app's panel didn't appear). Focus is intentionally
        // NOT kept anymore — reported for visibility, not gated.
        r["focusKeptInfo"] = frontmostDuring == (r["frontmostBefore"] as? String)

        // Wiggle the cursor like a hand so the first delivered mouseMoved (the
        // moment the crosshair goes live) is part of the timeline.
        let mouse = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var mp = CGPoint(x: mouse.x, y: primaryH - mouse.y)
        for _ in 0..<240 {   // até ~3s
            mp.x += (mp.x.truncatingRemainder(dividingBy: 2) == 0 ? 1 : -1)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mp, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            if AreaSelectionDiag.timeline["firstMouseMoved"] != nil { break }
            try? await Task.sleep(nanoseconds: 12_500_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Esc cancela a seleção.
        if let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) { esc.post(tap: .cghidEventTap) }
        if let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) { esc.post(tap: .cghidEventTap) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let tl = AreaSelectionDiag.timeline
        func delta(_ name: String) -> Int? { tl[name].map { Int(($0 - t0) * 1000) } }
        var deltas: [String: Int] = [:]
        for k in ["hotkeyUpPosted", "hotkeyFired", "startAreaCapture", "prepareEntry", "overlaysShown", "becameKey", "firstMouseMoved"] {
            if let d = delta(k) { deltas[k] = d }
        }
        r["timelineMs"] = deltas
        // O elo que o usuário sente é hotkey → janela de seleção key (overlay na
        // tela e recebendo eventos). firstMouseMoved continua reportado, mas só
        // prova fluxo de eventos: seu timestamp depende de QUANDO o harness
        // posta o wiggle sintético (sob carga o key-up já saiu a 600ms, inflando
        // a medida sem nenhum atraso do app).
        let hotkeyMs = deltas["hotkeyFired"] ?? -1
        let keyMs = deltas["becameKey"] ?? -1
        let live = (hotkeyMs >= 0 && keyMs >= hotkeyMs) ? keyMs - hotkeyMs : -1
        r["selectionLiveMs"] = live
        let mouseFlow = (deltas["firstMouseMoved"] ?? -1) >= 0
        r["mouseFlowPass"] = mouseFlow
        r["allPass"] = live >= 0 && live <= 450 && mouseFlow
        return r
    }

    /// Reproduces the "interaction works once, then I must click elsewhere"
    /// report with REAL synthesized mouse moves: hover the card (1st arm), drag
    /// it a little and snap back (interaction without executing anything), move
    /// the cursor away, hover again (2nd arm) and assert the card re-armed
    /// (hovered + controls visible + key restored).
    private static func runOverlayInteraction() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count

        // Spawn a card through the normal (slide) entrance.
        let img = NSImage(size: NSSize(width: 300, height: 200))
        img.lockFocus(); NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
        let tmpPath = "/tmp/krit-interaction-test.png"
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tmpPath))
        }
        let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: tmpPath,
                               thumbnailPath: tmpPath, captureRect: nil)
        QuickAccessOverlay.show(image: img, historyItem: item,
                                historyManager: appDelegate.historyManager, screen: NSScreen.main)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard QuickAccessOverlay.uiTestWindows.count > before,
              let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "card did not appear"; r["allPass"] = false; return r
        }

        // CG (top-left) coordinates of the card center for event posting.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func cgPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryH - p.y) }
        func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
        func moveTo(_ p: CGPoint) { post(.mouseMoved, p) }
        let center = cgPoint(NSPoint(x: card.frame.midX, y: card.frame.midY))
        let outside = CGPoint(x: center.x + card.frame.width * 2.2, y: center.y - 160)

        // 1st hover: arm.
        moveTo(CGPoint(x: center.x - 30, y: center.y)); try? await Task.sleep(nanoseconds: 120_000_000)
        moveTo(center); try? await Task.sleep(nanoseconds: 450_000_000)
        let hover1 = QuickAccessOverlay.uiTestHoverState()
        r["hover1"] = hover1

        // "Mexer sem executar": small drag inside the card and release (snaps back).
        post(.leftMouseDown, center)
        var p = center
        for _ in 0..<6 {
            p.x += 6; p.y -= 3
            post(.leftMouseDragged, p)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        post(.leftMouseUp, p)
        try? await Task.sleep(nanoseconds: 800_000_000)   // snap-back settle

        // Leave the card.
        moveTo(outside); try? await Task.sleep(nanoseconds: 500_000_000)
        let away = QuickAccessOverlay.uiTestHoverState()
        r["away"] = away

        // 2nd hover: this is the moment the user reports as dead.
        moveTo(CGPoint(x: center.x - 20, y: center.y + 10)); try? await Task.sleep(nanoseconds: 120_000_000)
        moveTo(center); try? await Task.sleep(nanoseconds: 600_000_000)
        let hover2 = QuickAccessOverlay.uiTestHoverState()
        r["hover2"] = hover2

        let armed1 = (hover1["hovered"] as? Bool ?? false)
        let disarmed = !(away["hovered"] as? Bool ?? true)
        r["armedOnFirstHover"] = armed1
        r["disarmedAway"] = disarmed

        // Behavioral proof on the 2nd hover: press SPACE for the quick-look
        // zoom. This is the interaction the user reports as dead.
        func postKey(_ code: CGKeyCode, down: Bool) {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
        postKey(49, down: true); postKey(49, down: false)   // Space
        try? await Task.sleep(nanoseconds: 700_000_000)
        // Space opens the COMPANION preview (QuickLookController), that is the
        // behavior the user exercises; the O5 in-place zoom is a different path.
        let previewOpened = QuickLookController.shared.isOpen
        r["spacePreviewOpenedOnSecondHover"] = previewOpened
        r["afterSpace"] = QuickAccessOverlay.uiTestHoverState()
        if previewOpened {
            postKey(49, down: true); postKey(49, down: false)   // Space closes it
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        r["allPass"] = armed1 && disarmed && previewOpened

        QuickAccessOverlay.uiTestCloseNewest()
        return r
    }

    /// Measures the hotkey-to-selection latency: fires the real area-capture
    /// path and polls until a SelectionOverlayWindow is visible. This was the
    /// "takes ~2 seconds to let me select" complaint; the scenario keeps it
    /// honest forever (fails above 600ms).
    private static func runAreaSelectionDelay() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        func selectionWindowVisible() -> Bool {
            NSApp.windows.contains {
                String(describing: type(of: $0)) == "SelectionOverlayWindow" && $0.isVisible
            }
        }
        let t0 = CACurrentMediaTime()
        appDelegate.captureArea()
        var shownMs = -1
        for _ in 0..<300 {   // poll a 10ms até 3s
            try? await Task.sleep(nanoseconds: 10_000_000)
            if selectionWindowVisible() {
                shownMs = Int((CACurrentMediaTime() - t0) * 1000)
                break
            }
        }
        r["selectionShownMs"] = shownMs
        // Dá um instante pros frozen grabs em paralelo despacharem, depois
        // cancela a seleção pra não deixar a UI armada na tela.
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) { esc.post(tap: .cghidEventTap) }
        if let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) { esc.post(tap: .cghidEventTap) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        r["dismissed"] = !selectionWindowVisible()
        r["allPass"] = shownMs >= 0 && shownMs <= 600 && (r["dismissed"] as? Bool ?? false)
        return r
    }

    /// Captures the visual entrance of the overlay card frame by frame: runs a
    /// REAL fullscreen capture (flash + fly-to-tray ghost + handoff card) and
    /// snapshots the bottom-right quadrant of the active screen every ~50ms via
    /// CGWindowList, so a glitchy first paint ("appears broken, then snaps
    /// right") can be seen and diagnosed instead of guessed at.
    private static func runOverlayEntranceFrames() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-entrance", withIntermediateDirectories: true)

        guard let primary = NSScreen.screens.first else {
            r["error"] = "no screens"; r["allPass"] = false; return r
        }

        let before = QuickAccessOverlay.uiTestWindows.count
        appDelegate.captureFullscreen()

        // Wait for the card object (capture takes a few hundred ms), then film
        // the region AROUND the card's real frame: the handoff card is parked
        // invisible at its slot, so filming starts before the reveal and catches
        // the whole ghost-landing + fade-in choreography wherever it happens.
        var card: NSWindow?
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let cards = QuickAccessOverlay.uiTestWindows
            if cards.count > before { card = cards.last; break }
        }
        guard let card else {
            r["error"] = "card never appeared"; r["allPass"] = false; return r
        }
        let cf = card.frame
        // Cocoa (bottom-left) -> CG (top-left) global coordinates, with a margin
        // of one card all around so the ghost's final approach is in frame too.
        // Clamped to the card's screen: CGWindowListCreateImage returns only the
        // on-screen intersection, which would silently shift the pixel mapping.
        let cardScreen = NSScreen.screens.first { $0.frame.intersects(cf) } ?? primary
        let sf = cardScreen.frame
        let cgScreenRect = CGRect(x: sf.origin.x, y: primary.frame.height - sf.origin.y - sf.height,
                                  width: sf.width, height: sf.height)
        let cardCG = CGRect(x: cf.origin.x, y: primary.frame.height - cf.origin.y - cf.height,
                            width: cf.width, height: cf.height)
        let margin: CGFloat = max(cf.width, cf.height)
        let region = cardCG.insetBy(dx: -margin, dy: -margin).intersection(cgScreenRect)
        var saved = 0
        let t0 = CACurrentMediaTime()
        for i in 0..<40 {
            if let cg = CGWindowListCreateImage(region, .optionAll, kCGNullWindowID, [.bestResolution]) {
                let ms = Int((CACurrentMediaTime() - t0) * 1000)
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: String(format: "/tmp/krit-entrance/f%02d-%04dms.png", i, ms)))
                    saved += 1
                }
                // Card-only crop, computed here where the geometry is known:
                // image pixels = (point in region) * (imageWidth / regionWidth).
                let pxPerPt = CGFloat(cg.width) / region.width
                let cardInRegion = CGRect(
                    x: (cardCG.minX - region.minX - 8) * pxPerPt,
                    y: (cardCG.minY - region.minY - 8) * pxPerPt,
                    width: (cf.width + 16) * pxPerPt,
                    height: (cf.height + 16) * pxPerPt
                )
                if let cardCG = cg.cropping(to: cardInRegion),
                   let cardData = NSBitmapImageRep(cgImage: cardCG).representation(using: .png, properties: [:]) {
                    try? cardData.write(to: URL(fileURLWithPath: String(format: "/tmp/krit-entrance/card%02d-%04dms.png", i, ms)))
                }
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        r["cardFrame"] = ["x": cf.origin.x, "y": cf.origin.y, "w": cf.width, "h": cf.height]
        r["framesSaved"] = saved
        r["framesDir"] = "/tmp/krit-entrance"
        r["allPass"] = saved > 20
        // Limpa o card de teste pra não poluir a tela do usuário.
        QuickAccessOverlay.uiTestCloseNewest()
        return r
    }

    /// Dumps the live wallpaper cache: the JPEG the compose path would use RIGHT
    /// NOW (pre), then a fresh grab and its result (post). Lets the visual gate
    /// see exactly what background a window shot composes over, separating a
    /// poisoned grab (ghost in the cache) from a compose-side artifact.
    private static func runWallpaperDump() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard #available(macOS 14.0, *) else {
            r["skipped"] = "needs macOS 14+"; r["allPass"] = false; return r
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-wallpaper", withIntermediateDirectories: true)

        if let pre = SystemWallpaperSource.cachedCurrentWallpaperData(for: screen) {
            try? pre.write(to: URL(fileURLWithPath: "/tmp/krit-wallpaper/cache-pre.jpg"))
            r["preCache"] = "/tmp/krit-wallpaper/cache-pre.jpg"
        } else {
            r["preCache"] = "empty"
        }

        await SystemWallpaperSource.refreshCurrentWallpaper(for: screen)
        r["grab"] = SystemWallpaperSource.uiTestLastWallpaperGrab
        r["grabDetail"] = SystemWallpaperSource.uiTestLastWallpaperGrabDetail

        if let post = SystemWallpaperSource.cachedCurrentWallpaperData(for: screen) {
            try? post.write(to: URL(fileURLWithPath: "/tmp/krit-wallpaper/cache-post.jpg"))
            r["postCache"] = "/tmp/krit-wallpaper/cache-post.jpg"
        } else {
            r["postCache"] = "empty"
        }
        // Diagnostic scenario: an empty cache is a finding (the live grab can
        // legitimately fail and fall back to desktopImageURL), not a harness
        // failure. The grab/grabDetail fields carry the actual story.
        r["allPass"] = true
        return r
    }

    /// Mean absolute RGB difference (0-255 scale) between two images rendered
    /// into the same small grid. Resolution-independent content comparison.
    private static func meanAbsDiff(_ a: CGImage, _ b: CGImage, grid: Int = 48) -> Double? {
        func sample(_ img: CGImage) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: grid * grid * 4)
            guard let ctx = CGContext(
                data: &buf, width: grid, height: grid, bitsPerComponent: 8,
                bytesPerRow: grid * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return buf
        }
        guard let pa = sample(a), let pb = sample(b) else { return nil }
        var total = 0
        var count = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<3 {
                total += abs(Int(pa[i + c]) - Int(pb[i + c]))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : nil
    }

    /// Opens the real record-window chooser, renders it offscreen and saves a
    /// snapshot for the visual gate. cacheDisplay approximates glass/blur (no
    /// live backdrop offscreen), so the probe checks layout + adaptive labels;
    /// the glass material itself is proven by the glass-renders scenario.
    private static func runChooserVisual() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let engine = appDelegate.uiTestCaptureEngine
        await engine.startWindowRecording()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard let win = NSApp.windows.first(where: {
            $0.isVisible && Int($0.frame.width) == 724 && Int($0.frame.height) == 560
        }) else {
            r["error"] = "chooser window not found (no recordable windows?)"
            r["allPass"] = false
            return r
        }
        defer {
            // Esc through the chooser's local key monitor so its close path
            // (handler + activation policy restore) runs like a real dismissal.
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        }

        // Grab the window THROUGH the WindowServer (SCK isolated grab), so the
        // snapshot shows the chooser exactly as rendered on screen: real glass,
        // real label contrast. cacheDisplay can't composite glass offscreen.
        var saved = false
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-chooser", withIntermediateDirectories: true)
        let path = "/tmp/krit-chooser/window-chooser.png"
        if #available(macOS 14.0, *),
           let image = await engine.uiTestIsolatedWindowImage(windowID: CGWindowID(win.windowNumber)),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            saved = FileManager.default.fileExists(atPath: path)
            r["snapshot"] = path
        }
        r["windowCount"] = NSApp.windows.filter { $0.isVisible }.count
        r["allPass"] = saved
        return r
    }

    /// Alpha byte (0-255) at a TOP-LEFT pixel coordinate in `cg`, drawing into a
    /// known premultiplied-RGBA buffer so the channel order is fixed regardless
    /// of the source bitmap layout. nil if out of bounds or unreadable.
    private static func alpha(at point: (x: Int, y: Int), in cg: CGImage) -> UInt8? {
        guard point.x >= 0, point.y >= 0, point.x < cg.width, point.y < cg.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Translate so the requested pixel lands at the 1x1 context origin.
        ctx.translateBy(x: CGFloat(-point.x), y: CGFloat(-(cg.height - 1 - point.y)))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixel[3]
    }

    // MARK: - Cenário: overlay-trace (diagnóstico do "flick" pós-captura)

    /// Dispara uma captura fullscreen REAL (som/flash/histórico acontecem) e
    /// grava uma série temporal do card recém-nascido: frame da janela e escala
    /// do layer (presentation) a cada 30ms por 1.5s. Aponta exatamente O QUE
    /// cresce/encolhe no "flick" relatado, em vez de chutar a causa.
    private static func runOverlayCaptureTrace() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        appDelegate.captureFullscreen()

        var card: NSWindow?
        for _ in 0..<40 {   // captura SCK leva algumas centenas de ms
            try? await Task.sleep(nanoseconds: 100_000_000)
            let cards = QuickAccessOverlay.uiTestWindows
            if cards.count > before { card = cards.last; break }
        }
        guard let card else {
            r["error"] = "card never appeared after capture"
            return r
        }

        var trace: [[String: Any]] = []
        let t0 = CACurrentMediaTime()
        for _ in 0..<50 {
            let pres = card.contentView?.layer?.presentation()
            let scale = (pres?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? -1
            trace.append([
                "t": Int((CACurrentMediaTime() - t0) * 1000),
                "x": card.frame.origin.x, "y": card.frame.origin.y,
                "w": card.frame.width, "h": card.frame.height,
                "scale": scale, "alpha": card.alphaValue,
            ])
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        r["trace"] = trace
        let ws = trace.compactMap { $0["w"] as? CGFloat }
        let scales = trace.compactMap { $0["scale"] as? CGFloat }.filter { $0 > 0 }
        r["frameWidthMin"] = ws.min() ?? -1
        r["frameWidthMax"] = ws.max() ?? -1
        r["scaleMin"] = scales.min() ?? -1
        r["scaleMax"] = scales.max() ?? -1

        QuickAccessOverlay.uiTestCloseNewest()
        return r
    }

    // MARK: - Cenário: ocr

    /// Prova de runtime do reconhecimento de texto (bug "OCR não funciona").
    /// Gera uma imagem determinística com "KRIT OCR 12345" (system 28pt, preto no
    /// branco), roda o MESMO `OCREngine.recognizeText(in:)` que `startOCRCapture`
    /// chama (sem a parte interativa de seleção) e percorre o resto do fluxo real:
    /// escreve o texto no NSPasteboard e relê pra provar que o clipboard recebeu.
    /// Sem mock, é o caminho de produção, só sem a área-seleção do usuário.
    private static func runOCRSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        // Determinística: NSImage costurada por NSBitmapImageRep, o mesmo backing
        // que `CaptureEngine.nsImage(from:)` produz pro fluxo real (representação
        // de bitmap que `bestCGImage` consome direto, sem re-render).
        let logical = NSSize(width: 360, height: 90)
        let scale = 2   // 2x, como uma captura SCK retina
        let pxW = Int(logical.width) * scale
        let pxH = Int(logical.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pxW * 4, bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            r["error"] = "could not build bitmap rep"
            return r
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pxW, height: pxH).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28 * CGFloat(scale)),
            .foregroundColor: NSColor.black,
        ]
        ("KRIT OCR 12345" as NSString).draw(at: NSPoint(x: 16 * scale, y: 28 * scale), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = logical
        let img = NSImage(size: logical)
        img.addRepresentation(rep)

        // Snapshot da imagem-fonte pra revisão visual do que entrou no Vision.
        let dir = "/tmp/krit-ocr"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            let p = "\(dir)/ocr-source.png"
            try? png.write(to: URL(fileURLWithPath: p))
            r["sourceImage"] = p
        }
        r["hasCGImage"] = (img.bestCGImage != nil)

        // Caminho real de reconhecimento (idêntico ao que startOCRCapture invoca).
        let text = await OCREngine.recognizeText(in: img)
        r["recognizedText"] = text
        let recognizedPass = text.contains("KRIT") && text.contains("12345")
        r["recognizedPass"] = recognizedPass

        // Caminho real de clipboard que startOCRCapture executa após reconhecer.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let pasted = pb.string(forType: .string) ?? ""
        r["clipboardText"] = pasted
        let clipboardPass = pasted == text && pasted.contains("KRIT") && pasted.contains("12345")
        r["clipboardPass"] = clipboardPass

        r["allPass"] = recognizedPass && clipboardPass
        return r
    }

    // MARK: - Cenário: onboarding

    /// Abre o onboarding de verdade (sem tocar no flag de primeira execução),
    /// percorre as 4 páginas, renderiza cada uma offscreen em PNG e valida que
    /// a CTA final virou "Start Capturing". PNGs em /tmp/krit-onboarding/.
    private static func runOnboardingSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        let savedFlag = Settings.hasLaunchedBefore

        let ctrl = WelcomeWindowController()
        ctrl.uiTestForceShow()
        guard let win = ctrl.uiTestWindow else {
            r["error"] = "onboarding window did not open"
            return r
        }
        r["windowVisible"] = win.isVisible
        r["pageCount"] = ctrl.uiTestPageCount

        let dir = "/tmp/krit-onboarding"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paths = await ctrl.uiTestRenderAllPages(toDirectory: dir)
        r["renderedPages"] = paths

        let allRendered = paths.count == 4 && paths.allSatisfy { p in
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue ?? 0
            return size > 10_000
        }
        r["renderPass"] = allRendered
        r["ctaPass"] = (ctrl.uiTestContinueTitle == "Start Capturing")

        ctrl.uiTestClose(restoringHasLaunchedBefore: savedFlag)
        r["flagRestored"] = (Settings.hasLaunchedBefore == savedFlag)
        r["allPass"] = allRendered
            && (r["ctaPass"] as? Bool ?? false)
            && (r["windowVisible"] as? Bool ?? false)
            && (r["flagRestored"] as? Bool ?? false)
        return r
    }

    // MARK: - Cenário: overlay-show

    /// Prova de runtime da ENTRADA do card de preview (bug "piscou e sumiu"):
    /// mostra um card real, espera a animação de entrada e afirma que o frame
    /// final caiu DENTRO do visibleFrame (não estacionado no off-edge), com
    /// alpha 1. Fecha só o card de teste ao final.
    private static func runOverlayShowSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            return r
        }
        let before = QuickAccessOverlay.uiTestWindows.count

        let img = NSImage(size: NSSize(width: 300, height: 200))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 200).fill()
        img.unlockFocus()
        let tmpPath = "/tmp/krit-overlay-test.png"
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: tmpPath))
        }
        let item = HistoryItem(
            id: UUID(), createdAt: Date(),
            imagePath: tmpPath, thumbnailPath: tmpPath, captureRect: nil
        )
        let screen = NSScreen.main
        QuickAccessOverlay.show(
            image: img, historyItem: item,
            historyManager: appDelegate.historyManager, screen: screen
        )

        // Entrada anima em 0.35s; 1.2s dá folga de sobra.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let cards = QuickAccessOverlay.uiTestWindows
        r["cardCount"] = cards.count
        guard cards.count == before + 1, let card = cards.last else {
            r["error"] = "card did not appear (before=\(before), after=\(cards.count))"
            return r
        }
        // The overlay follows the ACTIVE display (mouse) by design, which on a
        // multi-monitor setup is not necessarily the screen passed to show().
        // Judge the card against the visible frame of the screen it actually
        // landed on, otherwise this scenario false-fails whenever the cursor
        // sits on another monitor.
        let cardScreen = NSScreen.screens.first { $0.frame.intersects(card.frame) } ?? screen
        let vf = cardScreen?.visibleFrame ?? .zero
        r["cardFrame"] = ["x": card.frame.origin.x, "y": card.frame.origin.y,
                          "w": card.frame.width, "h": card.frame.height]
        r["visibleFrame"] = ["x": vf.origin.x, "y": vf.origin.y, "w": vf.width, "h": vf.height]
        let inside = vf.contains(card.frame)
        r["insideVisibleFramePass"] = inside
        r["alphaPass"] = (card.alphaValue >= 0.99)

        QuickAccessOverlay.uiTestCloseNewest()
        try? await Task.sleep(nanoseconds: 500_000_000)
        r["closedPass"] = (QuickAccessOverlay.uiTestWindows.count == before)

        r["allPass"] = inside
            && (r["alphaPass"] as? Bool ?? false)
            && (r["closedPass"] as? Bool ?? false)
        return r
    }

    // MARK: - Cenário: preferences

    /// Abre a janela de Preferences de verdade, percorre TODAS as seções,
    /// renderiza cada uma offscreen em PNG e valida que a janela abriu, a
    /// contagem de seções bate e cada PNG passou de 10KB. PNGs em /tmp/krit-prefs/.
    private static func runPreferencesSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        guard let win = ctrl.uiTestWindow else {
            r["error"] = "preferences window did not open"
            return r
        }
        r["windowVisible"] = win.isVisible
        r["sectionCount"] = ctrl.uiTestSectionCount

        let dir = "/tmp/krit-prefs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paths = await ctrl.uiTestRenderAllSections(toDirectory: dir)
        r["renderedSections"] = paths

        let expected = ctrl.uiTestSectionCount
        let allRendered = paths.count == expected && paths.allSatisfy { p in
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue ?? 0
            return size > 10_000
        }
        r["renderPass"] = allRendered

        ctrl.uiTestClose()
        r["allPass"] = allRendered
            && (r["windowVisible"] as? Bool ?? false)
            && (expected == PreferencesTab.allCases.count)
        return r
    }

    // MARK: - Cenário: editor completo

    private static func runEditorSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        // O assert "print comum abre cru" pressupõe NENHUM template default
        // (com default setado, a regra do produto manda abrir com ele aplicado).
        // Neutraliza o default do usuário durante o cenário e restaura no fim.
        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        TemplateStore.setDefault(name: nil)
        defer { TemplateStore.setDefault(name: savedDefaultTemplate) }

        // Imagem de teste 600×400 determinística.
        let img = NSImage(size: NSSize(width: 600, height: 400))
        img.lockFocus()
        NSColor(srgbRed: 0.15, green: 0.17, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        // Patch de cor distinta no topo-esquerdo: alvo do probe do eyedropper (2c).
        NSColor(srgbRed: 0.85, green: 0.30, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 300, width: 100, height: 100).fill()
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController,
              let window = ctrl.window else {
            r["error"] = "editor window did not open"
            return r
        }
        defer { window.close() }

        // 1. Nível da janela: precisa ser .normal (o bug do "fixado no topo").
        r["windowLevelRaw"] = window.level.rawValue
        r["windowLevelPass"] = (window.level == .normal)

        // 1b. Abertura: print comum abre CRU (regra do usuário: sem background e
        // sem checkerboard; fundo automático é exclusivo de window captures).
        // Snapshot do estado virgem pra prova visual + assert do estado.
        r["opensWithBackgroundPass"] = !ctrl.uiTestOptions.isEnabled
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        _ = Self.snapshotWindow(window, to: "/tmp/krit-editor/editor-open.png")

        // 2. Mover elemento arrastando o corpo.
        let canvas = ctrl.uiTestCanvas
        let arrow = ArrowAnnotation(start: CGPoint(x: 120, y: 220), end: CGPoint(x: 320, y: 120))
        arrow.lineWidth = 6
        canvas.objects.append(arrow)
        canvas.setSelection([arrow])
        canvas.needsDisplay = true
        try? await Task.sleep(nanoseconds: 200_000_000)

        let before = arrow.bounds.origin
        // Corpo da seta a 25% do caminho, LONGE dos 3 handles (start/end e o
        // handle de curvatura, que vive no ponto médio do traço).
        let bodyPoint = CGPoint(x: 120 + (320 - 120) * 0.25, y: 220 + (120 - 220) * 0.25)
        let target = CGPoint(x: bodyPoint.x + 60, y: bodyPoint.y + 40)
        r["diagContainsBody"] = arrow.contains(point: bodyPoint)
        await synthesizeDrag(in: window, canvas: canvas, from: bodyPoint, to: target)
        try? await Task.sleep(nanoseconds: 250_000_000)

        let after = arrow.bounds.origin
        let dx = after.x - before.x, dy = after.y - before.y
        r["moveDelta"] = ["dx": dx, "dy": dy]
        r["diagObjectsAfter"] = canvas.objects.count
        r["movePass"] = (abs(dx - 60) < 10 && abs(dy - 40) < 10)

        // Caso mais comum: mover um RETÂNGULO selecionado pelo interior.
        let rectAnn = RectangleAnnotation(rect: CGRect(x: 380, y: 240, width: 140, height: 90))
        rectAnn.lineWidth = 4
        canvas.objects.append(rectAnn)
        canvas.setSelection([rectAnn])
        canvas.needsDisplay = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        let rBefore = rectAnn.bounds.origin
        let rBody = CGPoint(x: 450, y: 285)   // interior, longe de handles/bordas
        await synthesizeDrag(in: window, canvas: canvas, from: rBody, to: CGPoint(x: rBody.x - 50, y: rBody.y + 30))
        try? await Task.sleep(nanoseconds: 250_000_000)
        let rdx = rectAnn.bounds.origin.x - rBefore.x, rdy = rectAnn.bounds.origin.y - rBefore.y
        r["rectMoveDelta"] = ["dx": rdx, "dy": rdy]
        r["rectMovePass"] = (abs(rdx + 50) < 10 && abs(rdy - 30) < 10)

        // 2c. Eyedropper: dois cliques mapeiam pros pixels certos da imagem
        // (patch topo-esquerdo vs base). Ground truth lido dos bytes da PRÓPRIA
        // imagem com o mesmo sampler: prova o mapeamento view→pixel e a cópia.
        var eyedropperPass = false
        if let cgBG = img.bestCGImage {
            let patchTruth = PixelSampler.hex(in: cgBG, x: cgBG.width / 20, y: cgBG.height / 20)
            let baseTruth  = PixelSampler.hex(in: cgBG, x: cgBG.width / 2,  y: (cgBG.height * 3) / 4)
            canvas.activeTool = .eyedropper
            NSPasteboard.general.clearContents()
            canvas.uiTestEyedrop(at: CGPoint(x: 30, y: 30))
            let pickedPatch = NSPasteboard.general.string(forType: .string)
            NSPasteboard.general.clearContents()
            canvas.uiTestEyedrop(at: CGPoint(x: 300, y: 300))
            let pickedBase = NSPasteboard.general.string(forType: .string)
            canvas.activeTool = .select
            r["eyedropper"] = ["patch": pickedPatch ?? "", "patchTruth": patchTruth ?? "",
                               "base": pickedBase ?? "", "baseTruth": baseTruth ?? ""]
            eyedropperPass = pickedPatch != nil && pickedPatch == patchTruth
                && pickedBase != nil && pickedBase == baseTruth && pickedPatch != pickedBase
        }
        r["eyedropperPass"] = eyedropperPass

        // 3. Sidebar: padding aplica e o canvas re-deriva sem distorcer.
        if ctrl.uiTestSidebar == nil || ctrl.uiTestSidebar?.isHidden != false {
            ctrl.uiTestToggleSidebar()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        var paddingPass = false, aspectPass = false
        if let sidebar = ctrl.uiTestSidebar,
           let slider = findView(in: sidebar, where: { ($0 as? NSSlider)?.maxValue == 240 }) as? NSSlider {
            slider.doubleValue = 120
            if let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            paddingPass = abs(ctrl.uiTestOptions.padding - 120) < 0.5
            let opts = ctrl.uiTestOptions
            if opts.isEnabled {
                let expected = ScreenshotBackgroundComposer.outputPointSize(for: NSSize(width: 600, height: 400), options: opts)
                let expectedRatio = expected.width / max(expected.height, 1)
                let actualRatio = canvas.frame.width / max(canvas.frame.height, 1)
                aspectPass = abs(expectedRatio - actualRatio) / expectedRatio < 0.02
                r["aspect"] = ["expected": expectedRatio, "actual": actualRatio]
            } else {
                // Sem fundo habilitado o canvas fica no tamanho da imagem.
                aspectPass = abs(canvas.frame.width / max(canvas.frame.height, 1) - 1.5) < 0.03
            }
        } else {
            r["sidebarError"] = "padding slider not found"
        }
        r["paddingPass"] = paddingPass
        r["aspectAfterPaddingPass"] = aspectPass
        // Regra nova (fit-to-stage): depois do padding mudar, a JANELA fica
        // parada e o canvas re-escala pra caber no palco, com escala <= 1.
        try? await Task.sleep(nanoseconds: 400_000_000)   // espera o re-fit diferido
        r["windowFollowsPass"] = ctrl.uiTestWindowFollowsCanvas
        let fit = ctrl.uiTestFitInfo
        r["fitInfo"] = fit
        let fitScale = fit["scale"] ?? -1
        r["fitPass"] = fitScale > 0 && fitScale <= 1.0001
            && (fit["canvasW"] ?? 0) * fitScale <= (fit["stageW"] ?? 0) + 2
            && (fit["canvasH"] ?? 0) * fitScale <= (fit["stageH"] ?? 0) + 2

        // 4. Wallpaper + toggle de blur.
        var wallpaperPass = false, blurPass = false
        if let sidebar = ctrl.uiTestSidebar,
           let wpLabel = findView(in: sidebar, where: { ($0 as? NSTextField)?.stringValue.caseInsensitiveCompare("Wallpapers") == .orderedSame }),
           let section = wpLabel.superview?.superview ?? wpLabel.superview {
            // Primeiro thumbnail clicável da seção (NSControl custom com mouseDown).
            if let thumb = findView(in: section, where: {
                String(describing: type(of: $0)).contains("ThumbnailButton") && $0.frame.width > 10
            }) {
                await synthesizeClick(in: window, view: thumb)
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // backgroundData é async
                let opts = ctrl.uiTestOptions
                wallpaperPass = opts.isEnabled && opts.style == .image && opts.customImageData != nil
                if let blurBox = findView(in: sidebar, where: { ($0 as? NSButton)?.title == "Blur background" }) as? NSButton {
                    blurBox.performClick(nil)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    blurPass = ctrl.uiTestOptions.style == .blurredImage
                }
            }
        }
        r["wallpaperSelectPass"] = wallpaperPass
        r["blurTogglePass"] = blurPass

        // 5. Caso reincidente: a font row da ferramenta de texto estourava o slot
        // de contexto e sobrepunha os vizinhos ("o texto quebra a toolbar").
        // Ativa a text tool ANTES do snapshot final: o probe garante que a
        // toolbar inteira cabe na janela com a row mais larga visível, e o PNG
        // do gate sai exatamente no estado que quebrava.
        var textToolHeaderPass = false
        if let tb = findView(in: window.contentView ?? NSView(), where: { $0 is AnnotationToolbar }) as? AnnotationToolbar {
            tb.selectToolExternally(.text)
            try? await Task.sleep(nanoseconds: 400_000_000)
            tb.layoutSubtreeIfNeeded()
            // What matters is that no button is CLIPPED by the edge, not that the
            // full design trailing inset survives. fittingWidth bakes in that inset
            // (desired breathing room); the content actually ends trailingInset
            // earlier. So the row clips only if (fittingWidth - trailingInset)
            // overflows the window. The snapshot confirms the visual.
            let contentRightEdge = tb.fittingWidth - AnnotationToolbar.trailingInset
            textToolHeaderPass = contentRightEdge <= window.frame.width + 0.5
            r["textToolFittingWidth"] = Double(tb.fittingWidth)
            r["textToolContentRightEdge"] = Double(contentRightEdge)
            r["textToolWindowWidth"] = Double(window.frame.width)
        }
        r["textToolHeaderPass"] = textToolHeaderPass

        // 6. Prova VISUAL: snapshot real da janela composta (glass/dark de verdade)
        // no estado final (sidebar aberta + background aplicado + text tool ativa).
        // Os asserts numéricos acima não enxergam moldura dupla, fio claro nem cor
        // vazando; o PNG é o gate de render, olhar antes de entregar.
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        let shotPath = "/tmp/krit-editor/editor-final.png"
        try? await Task.sleep(nanoseconds: 300_000_000)
        let shotOK = Self.snapshotWindow(window, to: shotPath)
        r["editorSnapshot"] = shotOK ? shotPath : "FAILED"
        r["snapshotPass"] = shotOK

        let passes = [r["windowLevelPass"], r["opensWithBackgroundPass"], r["movePass"], r["rectMovePass"], r["eyedropperPass"], r["paddingPass"], r["aspectAfterPaddingPass"], r["windowFollowsPass"], r["fitPass"], r["wallpaperSelectPass"], r["blurTogglePass"], r["textToolHeaderPass"], r["snapshotPass"]]
        r["allPass"] = passes.allSatisfy { ($0 as? Bool) == true }
        return r
    }

    /// Snapshot da janela como o WindowServer a compõe. Retorna true se o PNG
    /// foi escrito com conteúdo plausível (> 10KB).
    private static func snapshotWindow(_ window: NSWindow, to path: String) -> Bool {
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            return false
        }
        try? data.write(to: URL(fileURLWithPath: path))
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 10_000
    }

    /// Snapshots the on-screen composite of the window's region (everything the
    /// user actually sees there, glass included). A per-window grab cannot
    /// composite an NSGlassEffectView that sits IN FRONT of content, because the
    /// glass samples what is behind it at composite time; the screen region grab
    /// gets the WindowServer's final result. sharingType .none windows still
    /// need their lift before calling this.
    /// True when the image has real content (text, controls, contrast). A grab
    /// that failed to composite comes back as a flat placeholder, which a byte
    /// or size threshold cannot reliably distinguish from legitimate content;
    /// luminance spread can.
    private static func hasVisibleContrast(_ cg: CGImage, minSpread: Double = 24) -> Bool {
        guard let buf = rgbaPixels(cg) else { return false }
        var minLuma = 255.0, maxLuma = 0.0
        let stride = max(1, (cg.width * cg.height) / 4000)
        var i = 0
        while i < cg.width * cg.height {
            let p = i * 4
            let luma = 0.299 * Double(buf[p]) + 0.587 * Double(buf[p + 1]) + 0.114 * Double(buf[p + 2])
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
            i += stride
        }
        return maxLuma - minLuma > minSpread
    }

    private static func snapshotScreenRegion(of window: NSWindow, to path: String) -> CGImage? {
        guard let primary = NSScreen.screens.first else { return nil }
        let f = window.frame
        let cgRect = CGRect(x: f.origin.x, y: primary.frame.maxY - f.maxY,
                            width: f.width, height: f.height)
        guard let cg = CGWindowListCreateImage(cgRect, [.optionOnScreenOnly],
                                               kCGNullWindowID, [.bestResolution]),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            return nil
        }
        try? data.write(to: URL(fileURLWithPath: path))
        return cg
    }

    // MARK: - Cenário: editor-fit-large (auto-fit pra captura grande)

    /// Reproduces the "editor opens huge with no auto fit" complaint: a shot the
    /// size of a full screen must open with the zoom fitted so the whole
    /// composition is visible (scale < 1, canvas*scale inside the viewport),
    /// without the user hunting for 13% by hand.
    /// Reproduces the owner's bug: a tall (portrait) shot opened the editor almost
    /// fullscreen with a sea of black stage below the image. Asserts the window does
    /// NOT open near-fullscreen and the vertical stage hugs the scaled image (no
    /// excess black band), now that the window is sized to canvas*scale + chrome.
    private static func runEditorFitTallSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        let img = NSImage(size: NSSize(width: 900, height: 2600))
        img.lockFocus()
        NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 2600).fill()
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.window?.close() }
        let fit = ctrl.uiTestFitInfo
        r["fit"] = fit
        let winH = fit["windowH"] ?? 0
        let screenH = fit["screenH"] ?? 1
        let scale = fit["scale"] ?? 0
        // Both in VIEW points: the image on screen is canvasH(document) * scale, the
        // stage is the viewport frame height. Their difference is the real black band.
        let shownCanvasH = (fit["canvasH"] ?? 0) * scale
        let stageViewH = fit["stageViewH"] ?? 0
        // 1. Window is not near-fullscreen (the bug): under ~88% of screen height.
        let notFullscreen = winH <= screenH * 0.88
        r["notFullscreen"] = notFullscreen
        // 2. Vertical stage hugs the scaled image: leftover black band under ~96pt,
        //    not the huge void the owner saw.
        let verticalSlack = stageViewH - shownCanvasH
        r["verticalSlack"] = verticalSlack
        // Proportional, not absolute: the zoom-to-fit rounds down to a step
        // (38.6% ideal -> 35%), which alone leaves ~100pt of slack on a 2600pt
        // image and reads fine on screen. The bug this probe exists for (window
        // sized to ~10% occupancy) stays far below the threshold.
        let occupancy = shownCanvasH / max(stageViewH, 1)
        r["stageOccupancy"] = occupancy
        let hugsImage = occupancy >= 0.85
        r["hugsImage"] = hugsImage
        // 3. The image actually fits (scaled down to the tall envelope).
        let fits = scale > 0.05 && shownCanvasH <= stageViewH + 2
        r["fitsImage"] = fits
        // Visual proof of the framing (no sea of black below the image).
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        _ = Self.snapshotWindow(ctrl.window!, to: "/tmp/krit-editor/fit-tall.png")
        r["allPass"] = notFullscreen && hugsImage && fits
        return r
    }

    private static func runEditorFitLargeSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        let img = NSImage(size: NSSize(width: 3200, height: 2000))
        img.lockFocus()
        NSColor(srgbRed: 0.16, green: 0.18, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 3200, height: 2000).fill()
        img.unlockFocus()

        AnnotationCanvas.uiTestFitLog.removeAll()
        AnnotationWindowController.open(image: img)
        // The delayed settle re-fit runs at ~0.3s; 1.5s leaves slack.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"
            return r
        }
        defer { ctrl.window?.close() }
        let fit = ctrl.uiTestFitInfo
        r["fit"] = fit
        r["fitLog"] = AnnotationCanvas.uiTestFitLog
        let scale = fit["scale"] ?? 0
        let fitsW = (fit["canvasW"] ?? 1) * scale <= (fit["stageW"] ?? 0) + 2
        let fitsH = (fit["canvasH"] ?? 1) * scale <= (fit["stageH"] ?? 0) + 2
        r["allPass"] = scale > 0.05 && scale < 0.999 && fitsW && fitsH
        return r
    }

    // MARK: - Cenário: default-template (composição única, nunca dupla)

    /// Reproduces the bug hit on 2026-06-11: with a default template set, the
    /// editor applied the background a SECOND time on top of the already
    /// composed preview (two stacked wallpapers). Proof by geometry and pixels:
    /// with a green solid template (padding 50) and a raw red 400x300 shot,
    /// both the presented preview and the editor's flattened export must
    /// measure exactly raw + 2*padding (ONE frame, 500x400) and show green at
    /// the border with red at the centre. A double-composition regression
    /// measures 600x500 and fails the size assert.
    private static func runDefaultTemplateSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            return r
        }

        // Fake default template: flat green, padding 50, every other framing
        // effect off so the size math is exact.
        let savedDefault = TemplateStore.defaultTemplate?.name
        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = true
        bg.style = .solid
        bg.colorHex = "#00C84B"
        bg.padding = 50
        bg.inset = 0
        bg.cornerRadius = 0
        bg.shadow = 0
        bg.shadowStrength = 0
        let template = TemplateStore.add(name: "uiTest-default-template", background: bg)
        TemplateStore.setDefault(name: "uiTest-default-template")
        defer {
            if let template { TemplateStore.delete(id: template.id) }
            TemplateStore.setDefault(name: savedDefault)
        }

        // Raw red shot on disk + history item, the same shape finishCapture makes.
        let raw = NSImage(size: NSSize(width: 400, height: 300))
        raw.lockFocus()
        NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        raw.unlockFocus()
        let rawPath = "/tmp/krit-default-template-raw.png"
        if let tiff = raw.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: rawPath))
        }
        let item = HistoryItem(
            id: UUID(), createdAt: Date(),
            imagePath: rawPath, thumbnailPath: rawPath, captureRect: nil
        )

        // 1. The presented preview (overlay card / clipboard path) composes ONCE.
        var presentedPass = false
        if let options = TemplateStore.defaultBackgroundOptions() {
            let presented = ScreenshotBackgroundComposer.composeIfNeeded(raw, options: options)
            presentedPass = abs(presented.size.width - 500) < 1 && abs(presented.size.height - 400) < 1
            r["presentedSize"] = ["w": presented.size.width, "h": presented.size.height]
        }
        r["presentedPass"] = presentedPass

        // 2. The editor, opened from the RAW file exactly like the card's Edit
        // button does, applies the default template itself, once.
        let rawFromDisk = NSImage(contentsOfFile: item.imagePath) ?? raw
        AnnotationWindowController.open(image: rawFromDisk, historyItem: item, historyManager: appDelegate.historyManager)
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor did not open"
            r["allPass"] = false
            return r
        }
        defer { ctrl.window?.close() }

        let flat = ctrl.uiTestCanvas.flatten()
        r["flattenedSize"] = ["w": flat.size.width, "h": flat.size.height]
        let sizePass = abs(flat.size.width - 500) < 1 && abs(flat.size.height - 400) < 1

        var borderGreen = false, centreRed = false
        if let cg = flat.bestCGImage, let buf = rgbaPixels(cg) {
            let scaleX = CGFloat(cg.width) / flat.size.width
            let scaleY = CGFloat(cg.height) / flat.size.height
            func pixel(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
                let px = min(cg.width - 1, max(0, Int(x * scaleX)))
                let py = min(cg.height - 1, max(0, Int(y * scaleY)))
                let i = (py * cg.width + px) * 4
                return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
            }
            let border = pixel(12, 12)
            let centre = pixel(250, 200)
            r["borderPixel"] = ["r": border.0, "g": border.1, "b": border.2]
            r["centrePixel"] = ["r": centre.0, "g": centre.1, "b": centre.2]
            borderGreen = border.1 > 140 && border.0 < 110
            centreRed = centre.0 > 160 && centre.1 < 110
        }
        r["sizePass"] = sizePass
        r["borderGreenPass"] = borderGreen
        r["centreRedPass"] = centreRed
        r["allPass"] = presentedPass && sizePass && borderGreen && centreRed
        return r
    }

    // MARK: - Cenário: glass-renders (gate visual do Liquid Glass)

    /// Opens every glass chrome surface on-screen (recording preflight, recording
    /// HUD, All-in-One panel, toast, overlay card, history band, QR results) and
    /// snapshots the real windows via CGWindowListCreateImage, which composites
    /// Liquid Glass correctly (offscreen renders show a placeholder instead).
    /// Pure render gate: no recording starts and every surface closes afterwards.
    private static func runGlassRenders() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate, let screen = NSScreen.main else {
            r["error"] = "no app delegate or screen"
            return r
        }
        let engine = appDelegate.uiTestCaptureEngine
        let dir = "/tmp/krit-glass"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // 1. Recording preflight: the dock-scale glass bar with toggles.
        let fakeArea = CGRect(x: screen.frame.midX - 320, y: screen.frame.midY - 180,
                              width: 640, height: 360)
        var preflightPass = false
        if let win = engine.uiTestShowRecordingPreflight(rect: fakeArea, on: screen) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            preflightPass = snapshotWindow(win, to: "\(dir)/recording-preflight.png")
            engine.uiTestCloseRecordingPreflight()
        }
        r["preflightPass"] = preflightPass

        // 2. Recording HUD: panel-scale glass with timer and controls. The HUD
        // ships with sharingType .none so it never leaks into a recording; lift
        // it to .readOnly just for this snapshot, otherwise the grab is blank.
        // Region grab + contrast check: the per-window grab proved flaky while
        // the Mac is in active use (flat placeholder back), the on-screen
        // composite is what the user actually sees.
        let hud = RecordingHUDWindow()
        hud.configure(systemAudio: true, microphone: true, fps: 30, quality: "high")
        hud.show(on: screen)
        hud.sharingType = .readOnly
        try? await Task.sleep(nanoseconds: 500_000_000)
        var hudPass = false
        if let cg = snapshotScreenRegion(of: hud, to: "\(dir)/recording-hud.png") {
            hudPass = hasVisibleContrast(cg)
        }
        hud.sharingType = .none
        hud.closeHUD()
        r["hudPass"] = hudPass

        // 3. All-in-One panel: the glass cluster (six shapes merged into one mass).
        var aioPass = false
        let aio = AllInOneController(screen: screen, initialRect: fakeArea,
                                     onAction: { _, _, _ in }, onCancel: {})
        await aio.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let panel = aio.uiTestPanelWindow {
            aioPass = snapshotWindow(panel, to: "\(dir)/all-in-one.png")
        }
        aio.uiTestCancel()
        r["allInOnePass"] = aioPass

        // 4. Toast: panel-radius glass bubble. Same region grab + contrast
        // check as the HUD, and the newest toast wins (an earlier scenario's
        // dying toast must not be the one sampled).
        ToastWindow.show(message: "Liquid Glass render gate", duration: 2.5)
        try? await Task.sleep(nanoseconds: 500_000_000)
        var toastPass = false
        if let toast = NSApp.windows.compactMap({ $0 as? ToastWindow }).last {
            toastPass = snapshotScreenRegion(of: toast, to: "\(dir)/toast.png")
                .map { hasVisibleContrast($0) } ?? false
        }
        r["toastPass"] = toastPass

        // 5. Overlay card: frost controls and pills over a real capture thumb.
        var overlayPass = false
        let img = NSImage(size: NSSize(width: 360, height: 240))
        img.lockFocus()
        NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 360, height: 240).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 24, y: 24, width: 312, height: 192).fill()
        img.unlockFocus()
        let overlayImgPath = "\(dir)/overlay-source.png"
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: overlayImgPath))
        }
        let item = HistoryItem(
            id: UUID(), createdAt: Date(),
            imagePath: overlayImgPath, thumbnailPath: overlayImgPath, captureRect: nil
        )
        QuickAccessOverlay.show(
            image: img, historyItem: item,
            historyManager: appDelegate.historyManager, screen: screen
        )
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        r["overlayCardCount"] = QuickAccessOverlay.uiTestWindows.count
        if let card = QuickAccessOverlay.uiTestWindows.last {
            r["overlayCardFrame"] = ["w": card.frame.width, "h": card.frame.height]
            // Same sharingType lift as the HUD: cards never leak into captures.
            // The WindowServer needs a beat to propagate the change, otherwise
            // the grab still comes back blank.
            card.sharingType = .readOnly
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Region grab, not per-window: the card's hover frost is glass IN
            // FRONT of the thumb, which only composites in the on-screen result.
            // The pass is content-based: the centre pixel must be the test
            // image's orange, proving the thumb actually renders (this caught
            // the NSImageView-clobbers-layer.contents regression).
            if let cg = snapshotScreenRegion(of: card, to: "\(dir)/overlay-card.png"),
               let buf = rgbaPixels(cg) {
                let cx = cg.width / 2, cy = cg.height / 2
                let i = (cy * cg.width + cx) * 4
                let (red, green, blue) = (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
                r["overlayCenterPixel"] = ["r": red, "g": green, "b": blue]
                overlayPass = red > 200 && green > 110 && green < 190 && blue < 120
            }
            card.sharingType = .none
        }
        QuickAccessOverlay.uiTestCloseNewest()
        r["overlayPass"] = overlayPass

        // 6. History band: glass strip along the top edge. Same sharingType
        // story as the HUD: the band never leaks into captures, so lift it for
        // the duration of the grab.
        var historyPass = false
        HistoryPanelController.shared.show(historyManager: appDelegate.historyManager)
        // The band may take longer to land right after heavier scenarios
        // (recording smokes); poll for the window instead of one fixed sleep.
        var band: NSWindow?
        for _ in 0..<6 where band == nil {
            try? await Task.sleep(nanoseconds: 400_000_000)
            band = NSApp.windows.first { String(describing: type(of: $0)) == "HistoryBandWindow" }
        }
        if let band {
            band.sharingType = .readOnly
            try? await Task.sleep(nanoseconds: 300_000_000)
            historyPass = snapshotScreenRegion(of: band, to: "\(dir)/history-band.png")
                .map { hasVisibleContrast($0) } ?? false
            band.sharingType = .none
        }
        HistoryPanelController.shared.toggle(historyManager: appDelegate.historyManager)
        r["historyPass"] = historyPass

        // 7. QR results panel: concentric glass card inside a glass panel.
        var qrPass = false
        QRCodeResultWindow.show(results: [QRCodeResult(payload: "https://github.com/leonardocandiani/krit")])
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let qr = NSApp.windows.first(where: { String(describing: type(of: $0)) == "QRCodeResultWindow" }) {
            qrPass = snapshotWindow(qr, to: "\(dir)/qr-results.png")
            qr.orderOut(nil)
        }
        r["qrPass"] = qrPass

        r["allPass"] = preflightPass && hudPass && aioPass && toastPass
            && overlayPass && historyPass && qrPass
        return r
    }

    // MARK: - Cenário: blur-map (prova por pixels)

    /// Pixel-truth proof that blur/pixelate land exactly where drawn, not offset.
    /// Builds a deterministic 4-quadrant image (red/green/blue/yellow), opens the
    /// real editor with a background enabled (padding 72, inset 24, center),
    /// drops a PixelateAnnotation over the centre of the RED quadrant, flattens
    /// through the real export path (`canvas.flatten()`) and samples pixels:
    ///  (a) inside the region the colour is no longer the flat solid (effect hit),
    ///  (b) 30pt outside the region (same quadrant) the colour is still EXACT red
    ///      (effect did NOT bleed/offset). PNG saved for visual review.
    private static func runBlurMapSuite() async -> [String: Any] {
        var r: [String: Any] = [:]

        // 400x300, four solid quadrants. Top-left = red, in flipped canvas/image
        // space the red quadrant covers x:[0,200] y:[0,150].
        let imgW: CGFloat = 400, imgH: CGFloat = 300
        let img = NSImage(size: NSSize(width: imgW, height: imgH))
        img.lockFocusFlipped(true)   // top-left origin matches the editor canvas
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 200, height: 150).fill()        // red  TL
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill(); NSRect(x: 200, y: 0, width: 200, height: 150).fill()      // green TR
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill(); NSRect(x: 0, y: 150, width: 200, height: 150).fill()      // blue BL
        NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1).setFill(); NSRect(x: 200, y: 150, width: 200, height: 150).fill()    // yellow BR
        img.unlockFocus()

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor window did not open"; return r
        }
        defer { ctrl.window?.close() }
        let canvas = ctrl.uiTestCanvas

        // Real editor geometry: background ON, padding 72, inset 24, center.
        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = true
        bg.style = .gradient
        bg.padding = 72
        bg.inset = 24
        bg.alignment = .center
        bg.aspectPreset = nil

        // Drive the canvas through the same state applyBackgroundOptions sets:
        // options + composed frame size. flatten() reads exactly these.
        let canvasSize = ScreenshotBackgroundComposer.outputPointSize(for: img.size, options: bg)
        canvas.backgroundOptions = bg
        canvas.backgroundImage = img
        canvas.frame = NSRect(origin: .zero, size: canvasSize)

        // The slot is the single source of geometry; map image coords into it.
        let slot = ScreenshotBackgroundComposer.imageSlotRect(imageSize: img.size, canvasSize: canvasSize, options: bg)
        r["slot"] = ["x": slot.origin.x, "y": slot.origin.y, "w": slot.width, "h": slot.height]
        func canvasPoint(imageX ix: CGFloat, imageY iy: CGFloat) -> CGPoint {
            CGPoint(x: slot.minX + (ix / imgW) * slot.width,
                    y: slot.minY + (iy / imgH) * slot.height)
        }

        // Region: a 60x60 box straddling the red/blue HORIZONTAL border (image
        // y=150), horizontally at x=100 (inside the red/blue left column). The
        // horizontal border targets the exact symptom reported ("shifted DOWN"):
        // pixelate/blur MIX red (above) and blue (below) inside the region, so an
        // in-region sample is no longer exact red. A 30pt-ABOVE sample sits in pure
        // red and must stay exact red; a 30pt-BELOW sample sits in pure blue. If
        // the effect were shifted down/right, the mix would land off the border and
        // these outside samples would catch it.
        let center = canvasPoint(imageX: 100, imageY: 150)
        let region = CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60)
        // Gaussian blur, not pixelate: pixelate cells can align flush with the
        // red/blue border, average to the original solid colors, and read as
        // "no effect" even though it ran. A strong gaussian ALWAYS mixes across
        // the border, so the in-region sample provably changes.
        let fx = BlurAnnotation(rect: region)
        fx.radius = 24
        canvas.objects = [fx]
        canvas.needsDisplay = true
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Real export path (same flatten the Save/Share buttons call).
        let flat = canvas.flatten()
        guard let cg = flat.bestCGImage else { r["error"] = "flatten produced no image"; return r }
        try? FileManager.default.createDirectory(atPath: "/tmp/krit-editor", withIntermediateDirectories: true)
        if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/krit-editor/blur-map.png"))
        }
        r["flattenSnapshot"] = "/tmp/krit-editor/blur-map.png"

        // flatten() rasterises at nativeScale; map canvas points to pixels.
        let nativeScale = CGFloat(cg.width) / max(canvas.frame.width, 1)
        guard let pixels = Self.rgbaPixels(cg) else { r["error"] = "could not read pixels"; return r }
        let rowStride = cg.width * 4
        func sample(canvasX cx: CGFloat, canvasY cy: CGFloat) -> (Int, Int, Int)? {
            let sx = Int((cx * nativeScale).rounded())
            let sy = Int((cy * nativeScale).rounded())
            guard sx >= 0, sy >= 0, sx < cg.width, sy < cg.height else { return nil }
            let o = sy * rowStride + sx * 4
            return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
        }
        func isExactRed(_ c: (Int, Int, Int)?) -> Bool {
            guard let c else { return false }
            return c.0 > 245 && c.1 < 10 && c.2 < 10
        }

        func isExactBlue(_ c: (Int, Int, Int)?) -> Bool {
            guard let c else { return false }
            return c.0 < 10 && c.1 < 10 && c.2 > 245
        }

        // (a) INSIDE the region (on the red/blue border): the effect averaged the
        // two, so the centre is neither exact red nor exact blue. A solid (broken)
        // render would instead show a hard red|blue seam right here.
        let insideCenter = sample(canvasX: region.midX, canvasY: region.midY)
        let insideUpper = sample(canvasX: region.midX, canvasY: region.midY - 14)
        r["insideCenter"] = insideCenter.map { [$0.0, $0.1, $0.2] } ?? []
        r["insideUpper"] = insideUpper.map { [$0.0, $0.1, $0.2] } ?? []
        let regionAffected = (insideCenter != nil)
            && !isExactRed(insideCenter) && !isExactBlue(insideCenter)
        r["regionAffectedPass"] = regionAffected

        // (b) 30pt OUTSIDE the region: pure red ABOVE, pure blue BELOW. Both exact.
        // This is the offset guard, if the effect were shifted down/right (the bug)
        // the mix would reach one of these and they would no longer be exact.
        let outAbove = sample(canvasX: region.midX, canvasY: region.minY - 30)
        let outBelow = sample(canvasX: region.midX, canvasY: region.maxY + 30)
        r["outsideAbove"] = outAbove.map { [$0.0, $0.1, $0.2] } ?? []
        r["outsideBelow"] = outBelow.map { [$0.0, $0.1, $0.2] } ?? []
        let outsideUntouched = isExactRed(outAbove) && isExactBlue(outBelow)
        r["outsideUntouchedPass"] = outsideUntouched

        r["allPass"] = regionAffected && outsideUntouched
        return r
    }

    /// Reads an RGBA8 (premultiplied-last) byte buffer for `cg`, indexed TOP-LEFT
    /// so row 0 is the top of the image and matches the editor's flipped canvas
    /// coordinates (the flip is baked in here, not left to the caller).
    private static func rgbaPixels(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = buf.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        // No manual flip: CGContext.draw into a bitmap context already lands the
        // image's TOP row at buffer offset 0 (the CG coordinate flip is absorbed
        // by draw). The extra translate/scale here was double-flipping the buffer,
        // which made the above/below samples swap and falsely failed the gate,
        // the saved PNG of this very CGImage proved the content itself is upright.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    // MARK: - Cenário: som

    private static func runSoundProbe() -> [String: Any] {
        var r: [String: Any] = [:]
        let path = SoundManager.uiTestResolvedPath(.captureBigSur)
        r["resolvedPath"] = path ?? "NOT FOUND"
        guard let path else {
            r["pass"] = false
            return r
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id)
        r["createStatus"] = Int(status)
        if status == kAudioServicesNoError {
            AudioServicesPlaySystemSound(id)   // prova audível
        }
        r["playSoundsSetting"] = Settings.playSounds
        r["pass"] = (status == kAudioServicesNoError) && Settings.playSounds
        return r
    }

    // MARK: - Síntese de eventos (in-process, pipeline real)

    /// Clique completo (down+up) no centro de uma view, via window.sendEvent.
    private static func synthesizeClick(in window: NSWindow, view: NSView) async {
        let centerInWindow = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        send(.leftMouseDown, at: centerInWindow, in: window, click: 1)
        try? await Task.sleep(nanoseconds: 60_000_000)
        send(.leftMouseUp, at: centerInWindow, in: window, click: 1)
    }

    /// Arrasto: down no ponto A (coords do canvas), passos intermediários, up em B.
    private static func synthesizeDrag(in window: NSWindow, canvas: NSView, from: CGPoint, to: CGPoint) async {
        let start = canvas.convert(from, to: nil)
        let end = canvas.convert(to, to: nil)
        send(.leftMouseDown, at: start, in: window, click: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            send(.leftMouseDragged, at: p, in: window, click: 1)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        send(.leftMouseUp, at: end, in: window, click: 1)
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, click: Int) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: click,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        window.sendEvent(event)
    }

    /// Busca em profundidade na árvore de views.
    private static func findView(in root: NSView, where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(root) { return root }
        for sub in root.subviews {
            if let hit = findView(in: sub, where: predicate) { return hit }
        }
        return nil
    }
}
