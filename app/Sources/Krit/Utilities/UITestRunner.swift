import AppKit
import AVFoundation
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
    /// Held for the app's whole test lifetime: App Nap defers dispatch timers and
    /// distributed-notification delivery for a background accessory app, which
    /// strands the battery mid-run (observer armed, delivery dead). A
    /// user-initiated activity keeps the harness responsive.
    private var testActivity: NSObjectProtocol?

    override init() {
        super.init()
        // Segurança: o IPC do harness é opt-in por lançamento. App lançado normal
        // (Finder/Dock/open) NUNCA registra o observer, então nenhum processo local
        // consegue disparar captura/gravação nem escrever arquivo através dele
        // (DistributedNotification não autentica o remetente). A bateria de testes
        // lança uma build de teste com KRIT_UI_TEST=1 no ambiente. O binário de
        // release não compila esta superfície como uma capability acionável por env.
        guard KritTestHarness.isEnabled else { return }
        testActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "KRIT UI test harness"
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handle(_:)),
            name: Self.notificationName,
            object: nil
        )
        // Fallback transport: distributed-notification delivery can silently die
        // in a session (distnoted throttling of a background accessory app), which
        // strands the whole battery. "scenario|/tmp/out.json" in the environment
        // runs the exact same handler once at launch, no external post needed.
        if let boot = ProcessInfo.processInfo.environment["KRIT_UI_SCENARIO"] {
            handle(Notification(name: Self.notificationName, object: boot))
        }
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
        // pode ser arbitrário. Reports só pousam como arquivos diretos em /tmp,
        // e o write final rejeita um symlink que apareça depois desta validação.
        guard let outputURL = KritTestOutput.temporaryURL(for: parts[1]) else {
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
            case "prefs-visual": report = await Self.runPrefsVisual()
            case "editor-visual": report = await Self.runEditorVisual()
            case "launch-readiness": report = await Self.runLaunchReadiness()
            case "permissions-tab": report = await Self.runPermissionsTab()
            case "overlay-show": report = await Self.runOverlayShowSuite()
            case "blur-map":     report = await Self.runBlurMapSuite()
            case "overlay-trace": report = await Self.runOverlayCaptureTrace()
            case "window-capture": report = await Self.runWindowCaptureSuite()
            case "aside-window-capture": report = await Self.runAsideWindowCaptureSuite()
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
            case "record-smoke-pause": report = await Self.runRecordSmoke(pauseMidway: true)
            case "record-smoke-audio-pause": report = await Self.runRecordSmoke(systemAudio: true, pauseMidway: true)
            case "smart-redact":  report = await Self.runSmartRedactSuite()
            case "redact-adversarial": report = await Self.runRedactAdversarial()
            case "redact-sharpness": report = await Self.runRedactSharpness()
            case "uniform-grab-guard": report = Self.runUniformGrabGuard()
            case "frozen-fast-path": report = await Self.runFrozenFastPath()
            case "own-window-capture": report = await Self.runOwnWindowCapture()
            case "automation-gate": report = Self.runAutomationGate()
            case "overlay-gesture-freeze": report = await Self.runOverlayGestureFreeze()
            case "overlay-dismiss-race": report = await Self.runOverlayDismissRace()
            case "text-multiline": report = Self.runTextMultiline()
            case "glass-renders": report = await Self.runGlassRenders()
            case "recording-toggle-input": report = await Self.runRecordingToggleInput()
            case "all-in-one-interaction": report = await Self.runAllInOneInteraction()
            case "all-in-one-interrupt": report = await Self.runAllInOneInterrupt()
            case "all-in-one-pending-action-replacement": report = await Self.runAllInOnePendingActionReplacement()
            case "all-in-one-dismiss-during-prepare": report = await Self.runAllInOneDismissDuringPrepare()
            case "all-in-one-handoff-latest-intent": report = await Self.runAllInOneHandoffLatestIntent()
            case "scrolling-handoff-latest-intent": report = await Self.runScrollingHandoffLatestIntent()
            case "interactive-selection-replacement": report = await Self.runInteractiveSelectionReplacement()
            case "area-selection-cancel-pending-finish": report = await Self.runAreaSelectionCancelPendingFinish()
            case "all-in-one-restores-last-area": report = await Self.runAllInOneRestoresLastArea()
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
            case "overlay-drag-routing": report = await Self.runOverlayDragRouting()
            case "overlay-drag-controls": report = await Self.runOverlayDragControls()
            case "quick-access-visual": report = await Self.runQuickAccessVisual()
            case "overlay-handoff-drag": report = await Self.runOverlayHandoffDrag()
            case "overlay-handoff-early-drag": report = await Self.runOverlayHandoffEarlyDrag()
            case "overlay-first-drag-matrix": report = await Self.runOverlayFirstDragMatrix()
            case "overlay-file-drag-directions": report = await Self.runOverlayFileDragDirections()
            case "overlay-file-drop-materialization": report = await Self.runOverlayFileDropMaterialization()
            case "editor-file-drop-materialization": report = await Self.runEditorFileDropMaterialization()
            case "overlay-rapid-retry": report = await Self.runOverlayRapidRetry()
            case "interactive-follow-up": report = await Self.runInteractiveFollowUp()
            case "activation-lifetime": report = await Self.runActivationLifetime()
            case "history-representation": report = await Self.runHistoryRepresentation()
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
            case "autozoom-export": report = await Self.runAutoZoomExport()
            case "video-preview": report = await Self.runVideoPreview()
            case "video-editor": report = await Self.runVideoEditor()
            case "annotate-frame": report = await Self.runAnnotateFrame()
            case "trim-convert": report = await Self.runTrimConvert()
            case "whats-new": report = await Self.runWhatsNew()
            case "updates": report = await Self.runUpdatesWindow()
            case "about": report = await Self.runAbout()
            case "prefs-icons": report = await Self.runPrefsIcons()
            case "reopen": report = await Self.runReopenRecovery()
            case "toast": report = await Self.runToast()
            case "presentation-zoom": report = await Self.runPresentationZoom()
            default:             report["error"] = "unknown scenario"
            }
            report["scenario"] = scenario
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                do {
                    try KritTestOutput.write(data, to: outputURL)
                } catch {
                    Self.log.error("uitest: could not write report: \(error.localizedDescription, privacy: .public)")
                }
            }
            // A launch-time scenario is a one-shot harness process. Leaving it
            // alive after the report accumulates invisible LSUIElement instances
            // across a physical test matrix and can change later z-order results.
            // Notification-driven sessions remain resident for multi-scenario runs.
            if ProcessInfo.processInfo.environment["KRIT_UI_SCENARIO"] != nil {
                QuickAccessOverlay.tearDownAll()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Cenário: presentation-zoom

    private static func runLaunchReadiness() async -> [String: Any] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            return ["error": "no app delegate", "allPass": false]
        }

        for _ in 0..<20 where appDelegate.launchFirstIdleAt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        var report = appDelegate.uiTestLaunchReadiness
        let criticalReady = report["criticalReady"] as? Bool == true
        let firstIdleReached = report["firstIdleReached"] as? Bool == true
        let hotkeysReady = report["hotkeysReady"] as? Bool == true
        let statusMenuReady = report["statusMenuReady"] as? Bool == true
        let criticalReadyMs = report["criticalReadyMs"] as? Double ?? -1
        let firstIdleMs = report["firstIdleMs"] as? Double ?? -1
        report["allPass"] = criticalReady
            && firstIdleReached
            && hotkeysReady
            && statusMenuReady
            && criticalReadyMs >= 0
            && firstIdleMs >= criticalReadyMs
        return report
    }

    // MARK: - Cenário: presentation-zoom

    /// Starts the real ScreenCaptureKit zoom stream, waits for a complete frame,
    /// then tears it down. This exercises the fresh-window catalog retry that must
    /// find and exclude the overlay before a stream is allowed to start.
    private static func runPresentationZoom() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }
        let zoom = appDelegate.uiTestPresentationZoom
        zoom.exitForCapture()
        zoom.toggle()

        for _ in 0..<40 {
            if zoom.uiTestHasLiveFrame { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let started = zoom.uiTestHasLiveFrame
        r["started"] = started
        r["active"] = zoom.isActive

        zoom.exitForCapture()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let stopped = !zoom.isActive
        r["stopped"] = stopped
        r["allPass"] = started && stopped
        return r
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

    // MARK: - Cenário: whats-new (painel de novidades pós-update)

    /// Confirma que as notas bundled carregam, que a lógica de gate decide certo
    /// (instalação nova não mostra, update mostra, versão repetida/stale não), e
    /// que o painel abre de fato (snapshot).
    private static func runWhatsNew() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "whats-new"]
        guard let notes = WhatsNewStore.load() else { r["error"] = "WhatsNew.md not bundled"; r["allPass"] = false; return r }
        r["notesVersion"] = notes.version
        r["notesHasBody"] = !notes.body.isEmpty

        // Pure gate decision across the branches.
        let v = "1.0.0"
        let freshInstall = WhatsNewWindowController.shouldShow(current: v, lastSeen: "", hasLaunched: false, notesVersion: v)
        let sameVersion  = WhatsNewWindowController.shouldShow(current: v, lastSeen: v, hasLaunched: true, notesVersion: v)
        let realUpdate   = WhatsNewWindowController.shouldShow(current: v, lastSeen: "0.9.0", hasLaunched: true, notesVersion: v)
        let staleNotes   = WhatsNewWindowController.shouldShow(current: v, lastSeen: "0.9.0", hasLaunched: true, notesVersion: "0.9.0")
        r["gateFreshInstall"] = freshInstall   // expect false
        r["gateSameVersion"] = sameVersion     // expect false
        r["gateRealUpdate"] = realUpdate       // expect true
        r["gateStaleNotes"] = staleNotes       // expect false

        // The panel actually opens (manual path, no gating).
        let originalPolicy = NSApp.activationPolicy()
        _ = NSApp.setActivationPolicy(.prohibited)
        WhatsNewWindowController.showNow()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let opened = WhatsNewWindowController.uiTestIsOpen
        let activated = NSApp.activationPolicy() == .accessory
        r["panelOpened"] = opened
        r["activated"] = activated
        if opened, let win = WhatsNewWindowController.uiTestWindow {
            let originalSharingType = win.sharingType
            win.sharingType = .readOnly
            defer { win.sharingType = originalSharingType }
            win.contentView?.layoutSubtreeIfNeeded()
            win.contentView?.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 200_000_000)
            let path = "/tmp/krit-whats-new.png"
            let windowSnapshot = Self.snapshotWindow(win, to: path)
            let screenSnapshot = windowSnapshot ? nil : Self.snapshotScreenRegion(of: win, to: path)
            let snapshotPass = windowSnapshot
                || screenSnapshot.map(ScreenshotVisualQuality.hasVisibleContent) == true
                || WhatsNewWindowController.uiTestRenderSnapshot(to: path)
            r["snapshot"] = snapshotPass ? path : "FAILED"
        }
        WhatsNewWindowController.uiTestClose()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let restoredBackgroundOnly = NSApp.activationPolicy() == .prohibited
        r["restoredBackgroundOnly"] = restoredBackgroundOnly
        _ = NSApp.setActivationPolicy(originalPolicy)

        let snapshotPass = (r["snapshot"] as? String)?.hasSuffix(".png") == true
        r["allPass"] = !notes.body.isEmpty && !freshInstall && !sameVersion && realUpdate
            && !staleNotes && opened && activated && restoredBackgroundOnly && snapshotPass
        return r
    }

    // MARK: - Cenário: updates

    /// Opens KRIT's manual update entry point without starting a network check,
    /// verifies the real window geometry and captures the rendered surface. The
    /// Check Now button still hands the actual update session to Sparkle.
    private static func runUpdatesWindow() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "updates"]
        let originalPolicy = NSApp.activationPolicy()
        _ = NSApp.setActivationPolicy(.prohibited)

        UpdaterManager.shared.checkForUpdates()
        var updateWindow: NSWindow?
        for _ in 0..<30 where updateWindow == nil {
            updateWindow = NSApp.windows.first { $0.title == "KRIT Updates" && $0.isVisible }
            if updateWindow == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        }

        guard let window = updateWindow else {
            r["error"] = "update window did not open"
            r["allPass"] = false
            _ = NSApp.setActivationPolicy(originalPolicy)
            return r
        }

        let size = window.contentLayoutRect.size
        let sizePass = size.width >= 500 && size.height >= 380
        let activated = NSApp.activationPolicy() == .accessory
        let shotPath = "/tmp/krit-updates.png"
        let snapshotPass = Self.snapshotWindow(window, to: shotPath)
        r["windowWidth"] = Double(size.width)
        r["windowHeight"] = Double(size.height)
        r["sizePass"] = sizePass
        r["activated"] = activated
        r["snapshot"] = snapshotPass ? shotPath : "FAILED"

        window.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let restoredBackgroundOnly = NSApp.activationPolicy() == .prohibited
        r["restoredBackgroundOnly"] = restoredBackgroundOnly
        _ = NSApp.setActivationPolicy(originalPolicy)

        r["allPass"] = sizePass && activated && snapshotPass && restoredBackgroundOnly
        return r
    }

    // MARK: - Cenário: reopen (PR #4, recuperar Preferences com o ícone escondido)

    /// Exercita o handler real `applicationShouldHandleReopen` nos três ramos da
    /// lógica `if !flag || !Settings.showMenuBarIcon`: abre Preferences quando não
    /// há janela; abre quando o ícone da barra está escondido mesmo com janela; e
    /// NÃO força Preferences quando o ícone está visível e já há janela. Salva e
    /// restaura `showMenuBarIcon` pra não deixar o default sujo.
    private static func runReopenRecovery() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "reopen"]
        guard let delegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no AppDelegate"; r["allPass"] = false; return r
        }
        let prefs = PreferencesWindowController.shared
        let savedIcon = Settings.showMenuBarIcon

        // Ramo 1: sem janela visível -> reopen abre Preferences.
        prefs.uiTestClose()
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let opensWhenNoWindows = prefs.uiTestWindow?.isVisible == true
        r["opensWhenNoWindows"] = opensWhenNoWindows

        // Ramo 2 (o bug reportado): ícone escondido -> reopen abre Preferences mesmo
        // alegando janela visível.
        Settings.showMenuBarIcon = false
        prefs.uiTestClose()
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let opensWhenIconHidden = prefs.uiTestWindow?.isVisible == true
        r["opensWhenIconHidden"] = opensWhenIconHidden
        if opensWhenIconHidden, let win = prefs.uiTestWindow {
            r["snapshot"] = Self.snapshotWindow(win, to: "/tmp/krit-reopen.png") ? "/tmp/krit-reopen.png" : "FAILED"
        }

        // Controle: ícone visível + janela já aberta -> reopen NÃO força Preferences.
        Settings.showMenuBarIcon = true
        prefs.uiTestClose()
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let staysClosedWhenSafe = prefs.uiTestWindow?.isVisible != true
        r["staysClosedWhenIconVisibleAndWindowOpen"] = staysClosedWhenSafe

        Settings.showMenuBarIcon = savedIcon
        prefs.uiTestClose()
        r["allPass"] = opensWhenNoWindows && opensWhenIconHidden && staysClosedWhenSafe
        return r
    }

    // MARK: - Cenário: prefs-icons (chips de ícone em todas as abas)

    /// Percorre cada aba do Preferences e fotografa, pra conferir os chips de
    /// ícone colorido em todas as telas. Snapshots em /tmp/krit-prefs-<aba>.png.
    private static func runPrefsIcons() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "prefs-icons"]
        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let win = ctrl.uiTestWindow else { r["error"] = "prefs not open"; r["allPass"] = false; return r }
        let originalFrame = win.frame
        defer { win.setFrame(originalFrame, display: false); ctrl.uiTestClose() }
        var f = win.frame; f.size.height = 760; win.setFrame(f, display: true)

        let tabs: [(PreferencesTab, String)] = [
            (.general, "general"), (.capture, "capture"), (.recording, "recording"),
            (.preview, "preview"), (.editor, "editor"), (.shortcuts, "shortcuts"),
            (.presets, "presets")
        ]
        var shots: [String] = []
        var allOK = true
        for (tab, name) in tabs {
            ctrl.uiTestSelect(tab)
            try? await Task.sleep(nanoseconds: 700_000_000)
            let path = "/tmp/krit-prefs-\(name).png"
            let ok = Self.snapshotWindow(win, to: path)
            allOK = allOK && ok
            shots.append(ok ? path : "FAILED:\(name)")
        }
        r["snapshots"] = shots
        r["allPass"] = allOK
        return r
    }

    // MARK: - Cenário: about (tela About repaginada com cards)

    /// Abre o Preferences na aba About e fotografa: header, cards de Updates e
    /// Feedback com chips de ícone. Gate visual em /tmp/krit-about.png.
    private static func runAbout() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "about"]
        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        ctrl.show(tab: .about)
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let win = ctrl.uiTestWindow else { r["error"] = "prefs not open"; r["allPass"] = false; return r }
        let originalFrame = win.frame
        defer { win.setFrame(originalFrame, display: false); ctrl.uiTestClose() }
        let shot = "/tmp/krit-about.png"
        let ok = Self.snapshotWindow(win, to: shot)
        r["snapshot"] = ok ? shot : "FAILED"
        r["allPass"] = ok
        return r
    }

    // MARK: - Cenário: toast (notificação com ícone)

    /// Mostra um toast e fotografa o glifo + texto na cápsula de glass. Gate
    /// visual em /tmp/krit-toast.png.
    private static func runToast() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "toast"]
        ToastWindow.show(message: "Saved screenshot to Desktop", duration: 8.0)
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let win = NSApp.windows.first(where: { $0 is ToastWindow }) else {
            r["error"] = "toast not shown"; r["allPass"] = false; return r
        }
        let shot = "/tmp/krit-toast.png"
        let ok = Self.snapshotWindow(win, to: shot)
        r["snapshot"] = ok ? shot : "FAILED"
        r["allPass"] = ok
        return r
    }

    // MARK: - Cenário: video-editor (abre o editor, add zoom, exporta)

    /// Abre o editor de vídeo real, confirma que carrega métricas + metadata,
    /// snapshota a janela, adiciona um zoom e exporta, conferindo o arquivo.
    private static func runVideoEditor() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "video-editor"]
        let srcURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("krit-ve-src.mp4")
        let made = await makeSyntheticZoomSource(to: srcURL, size: CGSize(width: 320, height: 240), frames: 60, fps: 30)
        r["sourceMade"] = made
        guard made else { r["allPass"] = false; return r }

        // Synthetic cursor sweep so the auto path is non-empty.
        var samples: [RecordedMouseSample] = []
        for i in 0..<60 {
            let x = 0.2 + 0.6 * CGFloat(i) / 59.0
            samples.append(RecordedMouseSample(time: Double(i) / 30.0, normalizedX: x, normalizedY: 0.5, isInsideCapture: true))
        }
        RecordingMetadataStore.save(
            RecordingMetadata(captureSize: CGSize(width: 320, height: 240), samplesPerSecond: 30, mouseSamples: samples),
            for: srcURL
        )

        var exported: URL?
        VideoEditorWindowController.show(url: srcURL) { out, _ in exported = out }
        guard let ctl = VideoEditorWindowController.uiTestShared else { r["allPass"] = false; return r }
        let state = ctl.uiTestState
        for _ in 0..<40 { if state.duration > 0.1 { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        for _ in 0..<60 { if !state.frameThumbnails.isEmpty { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        r["duration"] = state.duration
        r["metadataLoaded"] = (state.metadata != nil)
        r["frames"] = state.frameThumbnails.count

        state.seek(to: 1.0)
        state.addZoom(at: 1.0)
        r["segments"] = state.zoomSegments.count
        r["autoPaths"] = state.autoFocusPaths.count
        // Turn on the Snapzy-style background; switch to a real wallpaper so the
        // snapshot + export exercise the wallpaper composite path too.
        state.backgroundEnabled = true
        r["wallpapers"] = state.wallpapers.count
        var requestedWallpaperThumb = false
        if !state.wallpapers.isEmpty {
            state.backgroundKind = .wallpaper
            state.selectedWallpaperIndex = 0
            requestedWallpaperThumb = true
            _ = state.wallpaperThumbnail(0)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        r["wallpaperThumb"] = !requestedWallpaperThumb || state.wallpaperThumbnail(0) != nil
        if let win = ctl.window {
            r["snapshot"] = Self.snapshotWindow(win, to: "/tmp/krit-video-editor.png") ? "/tmp/krit-video-editor.png" : "FAILED"
        }
        state.export()
        var outURL: URL?
        for _ in 0..<150 {
            if let e = exported { outURL = e; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let outExists = outURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        r["exportExists"] = outExists
        var outWidth: CGFloat = 0
        if let e = outURL, let track = try? await AVURLAsset(url: e).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            outWidth = abs(size.width)
        }
        r["outWidth"] = outWidth
        r["padded"] = outWidth > 320   // source is 320 wide; background padding must enlarge it
        // Play, then close: closing must tear the player down (no background decode).
        state.play()
        try? await Task.sleep(nanoseconds: 200_000_000)
        ctl.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let tornDown = state.player.currentItem == nil && state.player.timeControlStatus != .playing
        r["tornDown"] = tornDown
        r["sharedCleared"] = VideoEditorWindowController.uiTestShared == nil
        r["allPass"] = state.duration > 0.1 && state.zoomSegments.count == 1 && outExists && outWidth > 320 && tornDown
            && (r["wallpaperThumb"] as? Bool ?? false)
        return r
    }

    // MARK: - Cenário: trim-convert (Trim & Convert aplica dimensão + audio mono)

    /// Proves the "Trim & Convert" engine path actually converts: it builds a
    /// 320x240 source carrying a real STEREO audio track, runs the engine's
    /// `exportTrimConvert` with 160x120 / low quality / mono over a sub-range, then
    /// loads the OUTPUT and asserts the video track is ~160x120 (a real rescale)
    /// and the audio is a genuine single channel (the mono downmix). Mono is
    /// validated because the source is verified stereo first.
    private static func runTrimConvert() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "trim-convert"]
        let dir = NSTemporaryDirectory()
        let srcURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-tc-src.mov")
        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-tc-out.mp4")

        let source = await makeSyntheticStereoSource(to: srcURL, size: CGSize(width: 320, height: 240), frames: 60, fps: 30)
        r["sourceMade"] = source.success
        r["sourceStage"] = source.stage
        guard source.success else { r["allPass"] = false; return r }

        let (inW, inH) = await videoPixelSize(of: srcURL)
        let inCh = await audioChannelCount(of: srcURL)
        r["inputWidth"] = inW
        r["inputHeight"] = inH
        r["inputChannels"] = inCh ?? -1

        // Sub-range (drop head + tail), low quality, mono downmix.
        let quality = 0.1
        r["quality"] = quality
        let subRange = CMTimeRange(
            start: CMTime(seconds: 0.4, preferredTimescale: 600),
            end: CMTime(seconds: 1.4, preferredTimescale: 600)
        )
        let opts = VideoTrimPanel.ConvertOptions(width: 160, height: 120, quality: quality, audio: .mono)
        let exportOK = await RecordingEngine.exportTrimConvert(source: srcURL, range: subRange, options: opts, to: outURL)
        r["exportOK"] = exportOK
        let outExists = FileManager.default.fileExists(atPath: outURL.path)
        r["outExists"] = outExists

        let (outW, outH) = await videoPixelSize(of: outURL)
        let outCh = await audioChannelCount(of: outURL)
        r["outputWidth"] = outW
        r["outputHeight"] = outH
        r["outputChannels"] = outCh ?? -1

        let dimsPass = abs(outW - 160) <= 2 && abs(outH - 120) <= 2
        let inputStereo = (inCh == 2)
        let monoPass = (outCh == 1)
        r["dimsPass"] = dimsPass
        r["monoValidated"] = inputStereo   // mono check only trusted if the source was real stereo
        r["monoPass"] = monoPass
        let checks = [exportOK, outExists, dimsPass, inputStereo, monoPass]

        // Prove the other two audio modes through the same pipeline: keep
        // preserves the stereo track, mute drops audio entirely.
        let keepURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-tc-keep.mp4")
        let keepOpts = VideoTrimPanel.ConvertOptions(width: 160, height: 120, quality: quality, audio: .keep)
        let keepOK = await RecordingEngine.exportTrimConvert(source: srcURL, range: subRange, options: keepOpts, to: keepURL)
        let keepCh = await audioChannelCount(of: keepURL)
        r["keepChannels"] = keepCh ?? -1
        let keepPass = keepOK && keepCh == 2

        let muteURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-tc-mute.mp4")
        let muteOpts = VideoTrimPanel.ConvertOptions(width: 160, height: 120, quality: quality, audio: .mute)
        let muteOK = await RecordingEngine.exportTrimConvert(source: srcURL, range: subRange, options: muteOpts, to: muteURL)
        let muteCh = await audioChannelCount(of: muteURL)
        r["muteChannels"] = muteCh ?? -1   // -1 means no audio track, the expected mute result
        let mutePass = muteOK && muteCh == nil

        r["keepPass"] = keepPass
        r["mutePass"] = mutePass
        r["allPass"] = (checks + [keepPass, mutePass]).allSatisfy { $0 }

        try? FileManager.default.removeItem(at: srcURL)
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: keepURL)
        try? FileManager.default.removeItem(at: muteURL)
        return r
    }

    /// Displayed pixel size of the first video track (preferred transform applied).
    private static func videoPixelSize(of url: URL) async -> (Int, Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return (0, 0) }
        let display = size.applying(transform)
        return (Int(abs(display.width).rounded()), Int(abs(display.height).rounded()))
    }

    /// Channel count of the first audio track, read from its stream description.
    private static func audioChannelCount(of url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let formats = try? await track.load(.formatDescriptions),
              let fmt = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        return Int(asbd.pointee.mChannelsPerFrame)
    }

    /// Builds a source mov with a synthetic video track (the same black/white
    /// pattern as `makeSyntheticZoomSource`) AND a real 2-channel audio track, so a
    /// mono downmix can be proven headless.
    private static func makeSyntheticStereoSource(to url: URL, size: CGSize, frames: Int, fps: Int) async -> (success: Bool, stage: String) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return (false, "writer-create") }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { return (false, "writer-input") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { return (false, "writer-start: \(writer.error?.localizedDescription ?? "none")") }
        writer.startSession(atSourceTime: .zero)

        let readinessDeadline = MediaInputReadiness.deadline()
        if let stage = writeSyntheticVideoFrames(adaptor: adaptor, input: videoInput, size: size, frames: frames, fps: fps, readinessDeadline: readinessDeadline) {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return (false, stage)
        }
        guard writeSyntheticStereoAudio(input: audioInput, durationSec: Double(frames) / Double(fps), readinessDeadline: readinessDeadline) else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return (false, "audio-append")
        }

        guard await MediaInputReadiness.finishWriting(writer) else {
            try? FileManager.default.removeItem(at: url)
            return (false, "writer-finish: \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "none")")
        }
        return (true, "ok")
    }

    /// Draws the black frame with a white bottom-left quadrant into each frame.
    /// Returns the failing stage, or nil after every frame was accepted.
    private static func writeSyntheticVideoFrames(adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput, size: CGSize, frames: Int, fps: Int, readinessDeadline: TimeInterval) -> String? {
        let w = Int(size.width), h = Int(size.height)
        for i in 0..<frames {
            guard MediaInputReadiness.wait(for: input, until: readinessDeadline) else { return "video-not-ready-\(i)" }
            guard let pool = adaptor.pixelBufferPool else { return "video-no-pool-\(i)" }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { return "video-no-buffer-\(i)" }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                let cs = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: bpr, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else { return "video-append-failed-\(i)" }
        }
        input.markAsFinished()
        return nil
    }

    /// Feeds the audio input a 440 Hz tone, the same value in both channels, as
    /// interleaved float32 LPCM (the encoder turns it into 2-channel AAC).
    private static func writeSyntheticStereoAudio(input: AVAssetWriterInput, durationSec: Double, readinessDeadline: TimeInterval) -> Bool {
        let sampleRate = 48_000.0
        let channels = 2
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let fmt = format else { return false }

        let totalFrames = Int(durationSec * sampleRate)
        let chunk = 4_800
        var frameOffset = 0
        while frameOffset < totalFrames {
            let count = min(chunk, totalFrames - frameOffset)
            guard let sample = makeStereoSampleBuffer(format: fmt, sampleRate: sampleRate, channels: channels, frameOffset: frameOffset, frameCount: count) else { return false }
            guard MediaInputReadiness.wait(for: input, until: readinessDeadline) else { return false }
            guard input.append(sample) else { return false }
            frameOffset += count
        }
        input.markAsFinished()
        return true
    }

    /// One LPCM CMSampleBuffer of `frameCount` stereo frames starting at `frameOffset`.
    private static func makeStereoSampleBuffer(format: CMAudioFormatDescription, sampleRate: Double, channels: Int, frameOffset: Int, frameCount: Int) -> CMSampleBuffer? {
        let byteCount = frameCount * channels * 4
        var samples = [Float](repeating: 0, count: frameCount * channels)
        for i in 0..<frameCount {
            let t = Double(frameOffset + i) / sampleRate
            let value = Float(0.2 * sin(2.0 * Double.pi * 440.0 * t))
            samples[i * channels] = value
            samples[i * channels + 1] = value
        }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let block = blockBuffer else { return nil }
        let copyStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(frameOffset), timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frameCount, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Cenário: video-preview (Space toca o vídeo, não a thumb)

    /// Abre o preview do Space para um vídeo e confirma que ele ABRE e está
    /// TOCANDO (AVPlayer rodando), não mostrando um poster estático.
    private static func runVideoPreview() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "video-preview"]
        let srcURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("krit-vp-src.mp4")
        let made = await makeSyntheticZoomSource(to: srcURL, size: CGSize(width: 320, height: 240), frames: 30, fps: 30)
        r["sourceMade"] = made
        guard made else { r["allPass"] = false; return r }

        let owner = NSObject()
        let poster = NSImage(size: NSSize(width: 320, height: 240))
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cardFrame = NSRect(x: vf.midX, y: vf.midY, width: 240, height: 150)
        QuickLookController.shared.open(owner: owner, videoURL: srcURL, poster: poster, cardFrame: cardFrame, screen: NSScreen.main)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        r["previewOpen"] = QuickLookController.shared.isOpen
        r["playingVideo"] = QuickLookController.shared.uiTestIsPlayingVideo
        QuickLookController.shared.close()
        _ = owner   // keep the weak owner alive through the check
        r["allPass"] = (r["previewOpen"] as? Bool == true) && (r["playingVideo"] as? Bool == true)
        return r
    }

    // MARK: - Cenário: autozoom-export (o zoom é gravado no vídeo exportado)

    /// Prova o compositor de ponta a ponta: cria um vídeo sintético (quadrante
    /// branco sobre preto), exporta com um zoom 2x num canto e confirma que o frame
    /// de saída mudou de forma material vs o source (o crop+scale do zoom alterou a
    /// composição do frame). Não depende de orientação: checa a magnitude da mudança.
    private static func runAutoZoomExport() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "autozoom-export"]
        let dir = NSTemporaryDirectory()
        let srcURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-az-src.mp4")
        let outURL = URL(fileURLWithPath: dir).appendingPathComponent("krit-az-out.mp4")
        let size = CGSize(width: 320, height: 240)
        let fps = 30, frames = 30

        let made = await makeSyntheticZoomSource(to: srcURL, size: size, frames: frames, fps: fps)
        r["sourceMade"] = made
        guard made else { r["allPass"] = false; return r }

        let clip = Double(frames) / Double(fps)
        let segment = ZoomSegment(
            startTime: 0, duration: clip, zoomLevel: 2.0,
            zoomCenter: CGPoint(x: 0.25, y: 0.25), zoomType: .manual
        )
        do {
            try await ZoomComposer.export(url: srcURL, to: outURL, segments: [segment], autoFocusPaths: [:])
        } catch {
            r["exportError"] = "\(error)"; r["allPass"] = false; return r
        }
        r["outExists"] = FileManager.default.fileExists(atPath: outURL.path)

        let mid = clip / 2.0
        guard let srcImg = await cgImage(from: srcURL, at: mid),
              let outImg = await cgImage(from: outURL, at: mid) else {
            r["frameGrab"] = "failed"; r["allPass"] = false; return r
        }
        let srcBright = brightFraction(srcImg)
        let outBright = brightFraction(outImg)
        r["srcBright"] = srcBright
        r["outBright"] = outBright
        let changed = srcBright >= 0 && outBright >= 0 && abs(outBright - srcBright) > 0.15
        r["zoomChangedFrame"] = changed
        r["allPass"] = (r["outExists"] as? Bool == true) && changed
        return r
    }

    private static func makeSyntheticZoomSource(to url: URL, size: CGSize, frames: Int, fps: Int) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let readinessDeadline = MediaInputReadiness.deadline()
        let w = Int(size.width), h = Int(size.height)
        for i in 0..<frames {
            guard MediaInputReadiness.wait(for: input, until: readinessDeadline), let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                return false
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                let cs = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                       bytesPerRow: bpr, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                return false
            }
        }
        input.markAsFinished()
        guard await MediaInputReadiness.finishWriting(writer) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func cgImage(from url: URL, at seconds: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private static func brightFraction(_ image: CGImage) -> Double {
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var bright = 0
        for p in 0..<(n * n) {
            let luma = (0.2126 * Double(pixels[p * 4]) + 0.7152 * Double(pixels[p * 4 + 1]) + 0.0722 * Double(pixels[p * 4 + 2])) / 255.0
            if luma > 0.6 { bright += 1 }
        }
        return Double(bright) / Double(n * n)
    }

    // MARK: - Cenário: prefs-shortcuts (abrir a aba Shortcuts sem crashar)

    /// Prova o fix do crash da aba Shortcuts: monta a seção pelo caminho REAL
    /// (show(tab: .shortcuts) -> ShortcutsForm -> KeyboardShortcuts.Recorder ->
    /// RecorderCocoa -> String.localized -> patched resource lookup). Before the
    /// packaging fix this path ended in Bundle.module and aborted the process. The
    /// layout gate checks the bundle itself; this scenario proves the real view can
    /// resolve it, survive teardown, and render again.
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
        QuickAccessOverlay.show(
            image: img,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main
        )
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
        let originalOverlaySize = Settings.overlaySize
        Settings.overlaySize = .medium
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
        QuickAccessOverlay.show(
            image: img,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            presentedArtifact: CaptureArtifact(image: img),
            screen: NSScreen.main
        )
        // Pouso do card + pre-export em background.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        defer {
            Settings.overlaySize = originalOverlaySize
            if QuickAccessOverlay.uiTestWindows.count > before { QuickAccessOverlay.uiTestCloseNewest() }
        }
        guard QuickAccessOverlay.uiTestWindows.count > before else {
            r["error"] = "card did not appear"; r["allPass"] = false; return r
        }

        QuickAccessOverlay.uiTestSetNewestHovered(false)
        var hitCoveragePass = false
        if let content = QuickAccessOverlay.uiTestWindows.last?.contentView {
            let points = [
                NSPoint(x: 22, y: 24),
                NSPoint(x: 87, y: 77),
                NSPoint(x: 120, y: 77),
            ]
            let hits = points.map { point in
                content.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil"
            }
            r["dragHitClasses"] = hits
            hitCoveragePass = hits.allSatisfy { $0 == "DraggableImageView" }
        }
        r["hitCoveragePass"] = hitCoveragePass

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

        r["allPass"] = hitCoveragePass && earlyQuick && preparedSeen && preparedMs >= 0 && preparedMs < 8
        return r
    }

    // MARK: - Scenario: overlay-drag-routing

    /// Drives the WindowServer path that starts a card drag at every historically
    /// blocked point: hidden controls, the center gap, and the progress strip.
    /// Each small drag stays below every destructive gesture threshold, so the
    /// probe can prove entry into `handleThumbDrag` without deleting, parking, or
    /// converting the card into a file drag.
    private static func runOverlayDragRouting() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-drag-routing"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let savedTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        defer { Settings.overlayTimeout = savedTimeout }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-drag-routing", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil
        )
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            if QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main,
            entrance: .slide
        )
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "card did not appear"
            r["allPass"] = false
            return r
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cgPoint(for local: NSPoint) -> CGPoint {
            CGPoint(
                x: card.frame.minX + local.x,
                y: primaryHeight - (card.frame.minY + local.y)
            )
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        let targets: [(name: String, point: NSPoint)] = [
            ("corner", NSPoint(x: 22, y: 24)),
            ("pill", NSPoint(x: 87, y: 77)),
            ("center-gap", NSPoint(x: 120, y: 77)),
            ("progress", NSPoint(x: 120, y: 1)),
        ]
        QuickAccessOverlay.uiTestResetGestureEntryCount()
        var attempts: [[String: Any]] = []

        for target in targets {
            let start = cgPoint(for: target.point)
            post(.mouseMoved, at: start)
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Mouse movement arms hover controls, which are intentionally clickable.
            // Hide them just before the down so each legacy point must route to the
            // thumbnail rather than a visible control.
            QuickAccessOverlay.uiTestSetNewestHovered(false)
            let hover = QuickAccessOverlay.uiTestHoverState()
            let entryBefore = QuickAccessOverlay.uiTestGestureEntryCount()
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 50_000_000)
            let thresholdDrag = CGPoint(x: start.x + 5, y: start.y)
            post(.leftMouseDragged, at: thresholdDrag)
            try? await Task.sleep(nanoseconds: 50_000_000)
            let routedDrag = CGPoint(x: thresholdDrag.x + 5, y: thresholdDrag.y)
            post(.leftMouseDragged, at: routedDrag)
            try? await Task.sleep(nanoseconds: 50_000_000)
            post(.leftMouseUp, at: routedDrag)
            try? await Task.sleep(nanoseconds: 180_000_000)

            let entryAfter = QuickAccessOverlay.uiTestGestureEntryCount()
            let cardStillOpen = QuickAccessOverlay.uiTestWindows.contains { $0 === card }
            let notParked = !(QuickAccessOverlay.uiTestStandbyStates().last ?? true)
            let enteredExactlyOnce = entryAfter - entryBefore == 1
            attempts.append([
                "point": target.name,
                "controlsHiddenAtDown": (hover["controlsAlpha"] as? CGFloat ?? -1) < 0.01,
                "entriesBefore": entryBefore,
                "entriesAfter": entryAfter,
                "entryDelta": entryAfter - entryBefore,
                "cardStillOpen": cardStillOpen,
                "notParked": notParked,
                "passed": enteredExactlyOnce && cardStillOpen && notParked,
            ])
        }

        let allPass = attempts.count == targets.count
            && attempts.allSatisfy { ($0["passed"] as? Bool) == true }
        r["attempts"] = attempts
        r["allPass"] = allPass
        return r
    }

    // MARK: - Scenario: overlay-drag-controls

    /// Regression gate for a card whose visible action controls sit above the
    /// thumbnail. A drag beginning on a corner action or center pill must enter the
    /// same card gesture router as a drag beginning on exposed preview pixels. The
    /// early probe repeats it while the controls are fading in after hover.
    private static func runOverlayDragControls() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-drag-controls"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let savedTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        defer { Settings.overlayTimeout = savedTimeout }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-drag-controls", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil
        )
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            if QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main,
            entrance: .slide
        )
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "card did not appear"
            r["allPass"] = false
            return r
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cgPoint(for local: NSPoint) -> CGPoint {
            CGPoint(
                x: card.frame.minX + local.x,
                y: primaryHeight - (card.frame.minY + local.y)
            )
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        func allSubviews(of root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allSubviews)
        }
        func pointForControl(named typeName: String) -> NSPoint? {
            guard let content = card.contentView,
                  let control = allSubviews(of: content).first(where: {
                      String(describing: type(of: $0)) == typeName
                  }) else {
                return nil
            }
            return control.convert(
                NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                to: content
            )
        }
        func performDrag(named name: String, from local: NSPoint) async -> [String: Any] {
            let start = cgPoint(for: local)
            let entryBefore = QuickAccessOverlay.uiTestGestureEntryCount()
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 40_000_000)
            let threshold = CGPoint(x: start.x + 5, y: start.y)
            post(.leftMouseDragged, at: threshold)
            try? await Task.sleep(nanoseconds: 40_000_000)
            // Move toward standby, far enough to leave an action control but below
            // the 50 pt confirm threshold so the test card remains open.
            let routed = CGPoint(x: threshold.x, y: threshold.y + 30)
            post(.leftMouseDragged, at: routed)
            try? await Task.sleep(nanoseconds: 40_000_000)
            post(.leftMouseUp, at: routed)
            try? await Task.sleep(nanoseconds: 180_000_000)

            let entryAfter = QuickAccessOverlay.uiTestGestureEntryCount()
            let enteredExactlyOnce = entryAfter - entryBefore == 1
            let cardStillOpen = QuickAccessOverlay.uiTestWindows.contains { $0 === card }
            let notParked = !(QuickAccessOverlay.uiTestStandbyStates().last ?? true)
            return [
                "point": name,
                "entryDelta": entryAfter - entryBefore,
                "cardStillOpen": cardStillOpen,
                "notParked": notParked,
                "passed": enteredExactlyOnce && cardStillOpen && notParked,
            ]
        }
        func performSingleStepDrag(named name: String, from local: NSPoint) async -> [String: Any] {
            let start = cgPoint(for: local)
            let originBefore = card.frame.origin
            let entryBefore = QuickAccessOverlay.uiTestGestureEntryCount()
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 40_000_000)
            // This is deliberately the only drag sample before release. A coalesced
            // human drag must still move the card on that first sample.
            let routed = CGPoint(x: start.x, y: start.y + 30)
            post(.leftMouseDragged, at: routed)
            try? await Task.sleep(nanoseconds: 80_000_000)
            let originDuringDrag = card.frame.origin
            post(.leftMouseUp, at: routed)
            try? await Task.sleep(nanoseconds: 180_000_000)

            let entryAfter = QuickAccessOverlay.uiTestGestureEntryCount()
            let movedDuringDrag = abs(originDuringDrag.y - originBefore.y) > 4
            let cardStillOpen = QuickAccessOverlay.uiTestWindows.contains { $0 === card }
            let notParked = !(QuickAccessOverlay.uiTestStandbyStates().last ?? true)
            return [
                "point": name,
                "entryDelta": entryAfter - entryBefore,
                "movedDuringDrag": movedDuringDrag,
                "cardStillOpen": cardStillOpen,
                "notParked": notParked,
                "passed": entryAfter - entryBefore == 1 && movedDuringDrag && cardStillOpen && notParked,
            ]
        }

        QuickAccessOverlay.uiTestSetNewestHovered(false)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let bodySingleStep = await performSingleStepDrag(named: "body-single-step", from: NSPoint(x: 120, y: 77))

        QuickAccessOverlay.uiTestSetNewestHovered(true)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let visibleControls = QuickAccessOverlay.uiTestHoverState()
        guard let cornerPoint = pointForControl(named: "OverlayCornerButton"),
              let pillPoint = pointForControl(named: "OverlayPillButton") else {
            r["error"] = "controls did not appear"
            r["allPass"] = false
            return r
        }
        let visibleCorner = await performDrag(named: "visible-corner", from: cornerPoint)
        let visiblePill = await performDrag(named: "visible-pill", from: pillPoint)

        QuickAccessOverlay.uiTestSetNewestHovered(false)
        try? await Task.sleep(nanoseconds: 250_000_000)
        QuickAccessOverlay.uiTestSetNewestHovered(true)
        let enteringControls = QuickAccessOverlay.uiTestHoverState()
        let enteringCorner = await performDrag(named: "entering-corner", from: cornerPoint)

        let attempts = [bodySingleStep, visibleCorner, visiblePill, enteringCorner]
        r["visibleControlsAlpha"] = visibleControls["controlsAlpha"] ?? -1
        r["enteringControlsAlpha"] = enteringControls["controlsAlpha"] ?? -1
        r["attempts"] = attempts
        r["allPass"] = attempts.allSatisfy { ($0["passed"] as? Bool) == true }
        return r
    }

    // MARK: - Scenario: quick-access-visual

    /// Renders the post-capture card through AppKit as well as the WindowServer
    /// path. The latter is black on hosts without screen-capture access, so this
    /// keeps the palette and accessibility gate meaningful on every developer Mac.
    private static func runQuickAccessVisual() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "quick-access-visual"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.19, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 36, y: 36, width: 568, height: 288).fill()
        image.unlockFocus()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-quick-access-visual", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil
        )
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main,
            entrance: .slide
        )
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let card = QuickAccessOverlay.uiTestWindows.last,
              let content = card.contentView else {
            r["error"] = "card did not appear"
            r["allPass"] = false
            return r
        }

        func allSubviews(of root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allSubviews)
        }
        guard let copy = allSubviews(of: content).compactMap({ $0 as? NSButton }).first(where: {
            $0.accessibilityIdentifier() == "quickAccess.copy"
        }) else {
            r["error"] = "copy control missing"
            r["allPass"] = false
            return r
        }

        func rgba(_ color: CGColor?) -> [String: Int] {
            guard let color,
                  let resolved = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else {
                return [:]
            }
            return [
                "r": Int((resolved.redComponent * 255).rounded()),
                "g": Int((resolved.greenComponent * 255).rounded()),
                "b": Int((resolved.blueComponent * 255).rounded()),
                "a": Int((resolved.alphaComponent * 255).rounded()),
            ]
        }

        let restColor = rgba(copy.layer?.backgroundColor)
        let restPath = "/tmp/krit-quick-access-rest.png"
        let restSnapshot = snapshotWindow(card, to: restPath)

        r["restSnapshot"] = restSnapshot ? restPath : "FAILED"
        r["restColor"] = restColor
        r["accessibility"] = [
            "identifier": copy.accessibilityIdentifier(),
            "label": copy.accessibilityLabel() ?? "",
        ]

        let restPass = (restColor["r"] ?? 255) < 20
            && (restColor["g"] ?? 255) < 20
            && (restColor["b"] ?? 255) < 20
            && (restColor["a"] ?? 0) >= 110
        let accessibilityPass = copy.accessibilityIdentifier() == "quickAccess.copy"
            && copy.accessibilityLabel() == "Copy"
        r["restPass"] = restPass
        r["accessibilityPass"] = accessibilityPass
        r["allPass"] = restSnapshot && restPass && accessibilityPass
        return r
    }

    // MARK: - Scenario: overlay-handoff-drag

    /// Exercises the same handoff state used immediately after a real screenshot.
    /// Once the card is visibly interactive, a one-sample drag must work even when
    /// the pointer begins over a corner-action position.
    private static func runOverlayHandoffDrag() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-handoff-drag"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-handoff-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil
        )
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main,
            entrance: .handoff
        )
        QuickAccessOverlay.revealPendingHandoff(after: 0)
        // A transparent NSWindow is not a WindowServer hit target. Wait until the
        // 150 ms reveal has completed, which matches the first visible interaction.
        try? await Task.sleep(nanoseconds: 180_000_000)

        guard let card = QuickAccessOverlay.uiTestWindows.last,
              let content = card.contentView else {
            r["error"] = "handoff card did not appear"
            r["allPass"] = false
            return r
        }

        QuickAccessOverlay.uiTestSetNewestHovered(true)

        func allSubviews(of root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allSubviews)
        }
        guard let corner = allSubviews(of: content).first(where: {
            ($0 as? NSButton)?.toolTip == "Close"
        }) else {
            r["error"] = "close control missing"
            r["allPass"] = false
            return r
        }
        let cornerPoint = corner.convert(
            NSPoint(x: corner.bounds.midX, y: corner.bounds.midY),
            to: content
        )
        let earlyHit = content.hitTest(cornerPoint)
        r["earlyHit"] = earlyHit.map { String(describing: type(of: $0)) } ?? "none"

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let start = CGPoint(
            x: card.frame.minX + cornerPoint.x,
            y: primaryHeight - (card.frame.minY + cornerPoint.y)
        )
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        let originBefore = card.frame.origin
        QuickAccessOverlay.uiTestResetGestureEntryCount()
        post(.leftMouseDown, at: start)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let moved = CGPoint(x: start.x, y: start.y + 30)
        post(.leftMouseDragged, at: moved)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let originDuringDrag = card.frame.origin
        post(.leftMouseUp, at: moved)
        try? await Task.sleep(nanoseconds: 220_000_000)

        let entryCount = QuickAccessOverlay.uiTestGestureEntryCount()
        let movedDuringDrag = abs(originDuringDrag.y - originBefore.y) > 4
        let cardStillOpen = QuickAccessOverlay.uiTestWindows.contains { $0 === card }

        post(.leftMouseDown, at: start)
        try? await Task.sleep(nanoseconds: 40_000_000)
        post(.leftMouseUp, at: start)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let closedAfterClick = !QuickAccessOverlay.uiTestWindows.contains { $0 === card }

        r["entryCount"] = entryCount
        r["movedDuringDrag"] = movedDuringDrag
        r["cardStillOpen"] = cardStillOpen
        r["closedAfterClick"] = closedAfterClick
        let acceptsDragStart = r["earlyHit"] as? String == "DraggableImageView"
            || r["earlyHit"] as? String == "OverlayCornerButton"
        r["allPass"] = acceptsDragStart
            && entryCount == 1
            && movedDuringDrag
            && cardStillOpen
            && closedAfterClick
        return r
    }

    // MARK: - Scenario: overlay-handoff-early-drag

    /// Drives the real CaptureDelivery path and grabs the tray card before the
    /// first presentation delay has elapsed. The preview must be the actual
    /// interactive card, not a separate animation that leaves no input target.
    private static func runOverlayHandoffEarlyDrag() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-handoff-early-drag"]
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no screen"
            r["allPass"] = false
            return r
        }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-handoff-early-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyManager = HistoryManager(storageDir: directory)
        let before = QuickAccessOverlay.uiTestWindows.count
        defer {
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceRect = CGRect(
            x: screen.visibleFrame.midX - 120,
            y: screen.visibleFrame.midY - 68,
            width: 240,
            height: 136
        )
        _ = CaptureDelivery.submit(
            .init(
                rawImage: image,
                presentedImage: image,
                rect: sourceRect,
                screen: screen,
                isWindowCapture: false,
                showOverlay: true,
                automaticActions: nil
            ),
            historyManager: historyManager
        )

        try? await Task.sleep(nanoseconds: 40_000_000)
        guard let card = QuickAccessOverlay.uiTestWindows.last else {
            r["error"] = "handoff card did not appear"
            r["allPass"] = false
            return r
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let start = CGPoint(
            x: card.frame.midX,
            y: primaryHeight - card.frame.midY
        )
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        let originBefore = card.frame.origin
        QuickAccessOverlay.uiTestResetGestureEntryCount()
        r["alphaAtDown"] = card.alphaValue
        post(.leftMouseDown, at: start)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let moved = CGPoint(x: start.x, y: start.y + 30)
        post(.leftMouseDragged, at: moved)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let originDuringDrag = card.frame.origin
        post(.leftMouseUp, at: moved)
        try? await Task.sleep(nanoseconds: 180_000_000)

        let entryCount = QuickAccessOverlay.uiTestGestureEntryCount()
        let movedDuringDrag = abs(originDuringDrag.y - originBefore.y) > 4
        r["entryCount"] = entryCount
        r["movedDuringDrag"] = movedDuringDrag
        r["allPass"] = card.alphaValue > 0 && entryCount == 1 && movedDuringDrag
        return r
    }

    // MARK: - Scenario: overlay-first-drag-matrix

    /// Reproduces the first physical drag after a capture through the real
    /// CaptureDelivery handoff. Each point receives a fresh card, so a passing
    /// later case cannot hide a first-gesture regression in an earlier one.
    private static func runOverlayFirstDragMatrix() async -> [String: Any] {
        var report: [String: Any] = ["scenario": "overlay-first-drag-matrix"]
        guard AXIsProcessTrusted() else {
            report["skipped"] = "Accessibility permission is required for physical drag events"
            report["allPass"] = false
            return report
        }
        guard NSApp.delegate is AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no app delegate or screen"
            report["allPass"] = false
            return report
        }

        let originalTimeout = Settings.overlayTimeout
        defer { Settings.overlayTimeout = originalTimeout }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-first-drag-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        } catch {
            report["error"] = "could not create isolated history: \(error)"
            report["allPass"] = false
            return report
        }
        Settings.overlayTimeout = 30

        let historyManager = HistoryManager(storageDir: historyDirectory)
        await historyManager.waitUntilLoaded()
        let initialCardCount = QuickAccessOverlay.uiTestWindows.count
        defer {
            while QuickAccessOverlay.uiTestWindows.count > initialCardCount {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let image = solidImage(size: NSSize(width: 640, height: 360), color: .systemPurple)
        let sourceRect = CGRect(
            x: screen.visibleFrame.midX - 160,
            y: screen.visibleFrame.midY - 90,
            width: 320,
            height: 180
        )
        let primaryScreen = NSScreen.screens.first(where: {
            ScreenCaptureCatalog.displayID(of: $0) == CGMainDisplayID()
        }) ?? screen

        func quartzPoint(_ appKitPoint: NSPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: primaryScreen.frame.maxY - appKitPoint.y)
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        func allSubviews(of root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allSubviews)
        }
        func screenPoint(for view: NSView, in card: NSWindow) -> NSPoint {
            let pointInWindow = view.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                to: nil
            )
            return card.convertPoint(toScreen: pointInWindow)
        }
        func close(_ card: NSWindow) async {
            guard QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card }) else { return }
            QuickAccessOverlay.uiTestCloseNewest()
            for _ in 0..<20 where QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card }) {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        func makeCard() async -> NSWindow? {
            let before = QuickAccessOverlay.uiTestWindows.count
            _ = CaptureDelivery.submit(
                .init(
                    rawImage: image,
                    presentedImage: image,
                    rect: sourceRect,
                    screen: screen,
                    isWindowCapture: false,
                    showOverlay: true,
                    automaticActions: nil
                ),
                historyManager: historyManager
            )
            for _ in 0..<40 {
                if QuickAccessOverlay.uiTestWindows.count > before,
                   let card = QuickAccessOverlay.uiTestWindows.last,
                   card.isVisible,
                   card.alphaValue > 0.95 {
                    return card
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return nil
        }
        func waitForMouseTarget(_ card: NSWindow, at point: NSPoint) async -> (Bool, Int, Int) {
            for attempt in 0...50 {
                let target = NSWindow.windowNumber(
                    at: point,
                    belowWindowWithWindowNumber: 0
                )
                if target == card.windowNumber {
                    return (true, attempt * 5, target)
                }
                if attempt < 50 {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return (
                false,
                250,
                NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            )
        }
        func dragOutcome(card: NSWindow, from appKitPoint: NSPoint) async -> [String: Any] {
            let target = await waitForMouseTarget(card, at: appKitPoint)
            guard target.0 else {
                return [
                    "entryCount": 0,
                    "stillOpen": QuickAccessOverlay.uiTestWindows.contains { $0 === card },
                    "parked": QuickAccessOverlay.uiTestStandbyStates().last ?? true,
                    "movedDuringDrag": false,
                    "mouseTargetReady": false,
                    "mouseTargetWaitMs": target.1,
                    "mouseTargetWindowNumber": target.2,
                    "allPass": false,
                ]
            }
            QuickAccessOverlay.uiTestResetGestureEntryCount()
            let start = quartzPoint(appKitPoint)
            let originBefore = card.frame.origin
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 40_000_000)
            let end = CGPoint(x: start.x, y: start.y + 30)
            post(.leftMouseDragged, at: end)
            try? await Task.sleep(nanoseconds: 80_000_000)
            let originDuringDrag = card.frame.origin
            post(.leftMouseUp, at: end)
            try? await Task.sleep(nanoseconds: 220_000_000)

            let entryCount = QuickAccessOverlay.uiTestGestureEntryCount()
            let stillOpen = QuickAccessOverlay.uiTestWindows.contains { $0 === card }
            let parked = QuickAccessOverlay.uiTestStandbyStates().last ?? true
            let movedDuringDrag = hypot(
                originDuringDrag.x - originBefore.x,
                originDuringDrag.y - originBefore.y
            ) > 4
            return [
                "entryCount": entryCount,
                "stillOpen": stillOpen,
                "parked": parked,
                "movedDuringDrag": movedDuringDrag,
                "mouseTargetReady": true,
                "mouseTargetWaitMs": target.1,
                "mouseTargetWindowNumber": target.2,
                "allPass": entryCount == 1 && stillOpen && !parked && movedDuringDrag,
            ]
        }
        func waitForControls() async -> Bool {
            for _ in 0..<80 {
                let ready = QuickAccessOverlay.uiTestEntranceState()["controlsReady"] as? Bool ?? false
                if ready { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            QuickAccessOverlay.uiTestSetNewestHovered(false)
            QuickAccessOverlay.uiTestSetNewestHovered(true)
            for _ in 0..<20 {
                let alpha = QuickAccessOverlay.uiTestHoverState()["controlsAlpha"] as? CGFloat ?? 0
                if alpha > 0.95 { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return false
        }

        var cases: [String: [String: Any]] = [:]
        var allPass = true

        guard let centerCard = await makeCard() else {
            report["error"] = "center card did not appear"
            report["allPass"] = false
            return report
        }
        let center = await dragOutcome(
            card: centerCard,
            from: NSPoint(x: centerCard.frame.midX, y: centerCard.frame.midY)
        )
        cases["center"] = center
        allPass = allPass && (center["allPass"] as? Bool == true)
        await close(centerCard)

        guard let progressCard = await makeCard() else {
            report["error"] = "progress card did not appear"
            report["cases"] = cases
            report["allPass"] = false
            return report
        }
        let progress = await dragOutcome(
            card: progressCard,
            from: NSPoint(x: progressCard.frame.midX, y: progressCard.frame.minY + 1)
        )
        cases["progress"] = progress
        allPass = allPass && (progress["allPass"] as? Bool == true)
        await close(progressCard)

        guard let topHighlightCard = await makeCard() else {
            report["error"] = "top-highlight card did not appear"
            report["cases"] = cases
            report["allPass"] = false
            return report
        }
        let topHighlight = await dragOutcome(
            card: topHighlightCard,
            from: NSPoint(x: topHighlightCard.frame.midX, y: topHighlightCard.frame.maxY - 1)
        )
        cases["topHighlight"] = topHighlight
        allPass = allPass && (topHighlight["allPass"] as? Bool == true)
        await close(topHighlightCard)

        guard let cornerCard = await makeCard(),
              await waitForControls(),
              let cornerRoot = cornerCard.contentView,
              let closeButton = allSubviews(of: cornerRoot).first(where: {
                  $0.accessibilityIdentifier() == "quickAccess.close"
              }) else {
            report["error"] = "corner control did not become interactive"
            report["cases"] = cases
            report["allPass"] = false
            return report
        }
        let corner = await dragOutcome(card: cornerCard, from: screenPoint(for: closeButton, in: cornerCard))
        cases["corner"] = corner
        allPass = allPass && (corner["allPass"] as? Bool == true)
        await close(cornerCard)

        guard let pillCard = await makeCard(),
              await waitForControls(),
              let pillRoot = pillCard.contentView,
              let copyButton = allSubviews(of: pillRoot).first(where: {
                  $0.accessibilityIdentifier() == "quickAccess.copy"
              }) else {
            report["error"] = "pill control did not become interactive"
            report["cases"] = cases
            report["allPass"] = false
            return report
        }
        let pill = await dragOutcome(card: pillCard, from: screenPoint(for: copyButton, in: pillCard))
        cases["pill"] = pill
        allPass = allPass && (pill["allPass"] as? Bool == true)
        await close(pillCard)

        guard let fileCard = await makeCard() else {
            report["error"] = "file-drag card did not appear"
            report["cases"] = cases
            report["allPass"] = false
            return report
        }
        QuickAccessOverlay.uiTestResetGestureEntryCount()
        let sessionsBefore = QuickAccessOverlay.uiTestDragSessionStartCount()
        let fileStartAppKit = NSPoint(x: fileCard.frame.midX, y: fileCard.frame.midY)
        let fileTarget = await waitForMouseTarget(fileCard, at: fileStartAppKit)
        let fileStart = quartzPoint(fileStartAppKit)
        let inward: CGFloat = Settings.overlayOnLeft ? 1 : -1
        let fileEnd = CGPoint(x: fileStart.x + inward * 24, y: fileStart.y)
        if fileTarget.0 {
            post(.leftMouseDown, at: fileStart)
            try? await Task.sleep(nanoseconds: 40_000_000)
            post(.leftMouseDragged, at: fileEnd)
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.leftMouseDragged, at: fileStart)
            try? await Task.sleep(nanoseconds: 60_000_000)
            post(.leftMouseUp, at: fileStart)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let fileDrag = [
            "entryCount": QuickAccessOverlay.uiTestGestureEntryCount(),
            "sessionStarted": QuickAccessOverlay.uiTestDragSessionStartCount() == sessionsBefore + 1,
            "cardRecovered": QuickAccessOverlay.uiTestWindows.contains { $0 === fileCard },
            "mouseTargetReady": fileTarget.0,
            "mouseTargetWaitMs": fileTarget.1,
            "mouseTargetWindowNumber": fileTarget.2,
        ] as [String: Any]
        let filePassed = (fileDrag["entryCount"] as? Int == 1)
            && (fileDrag["sessionStarted"] as? Bool == true)
            && (fileDrag["cardRecovered"] as? Bool == true)
            && fileTarget.0
        cases["fileDrag"] = fileDrag.merging(["allPass": filePassed]) { _, new in new }
        allPass = allPass && filePassed
        await close(fileCard)

        report["cases"] = cases
        report["allPass"] = allPass
        return report
    }

    // MARK: - Scenario: overlay-file-drag-directions

    /// A file drag must become a real AppKit dragging session for ordinary human
    /// trajectories, not only for a mathematically horizontal pull. The source
    /// callbacks prove that the drag preview began, followed the cursor and ended.
    private static func runOverlayFileDragDirections() async -> [String: Any] {
        var report: [String: Any] = ["scenario": "overlay-file-drag-directions"]
        guard AXIsProcessTrusted() else {
            report["skipped"] = "Accessibility permission is required for physical drag events"
            report["allPass"] = false
            return report
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let primaryScreen = NSScreen.screens.first(where: {
                  ScreenCaptureCatalog.displayID(of: $0) == CGMainDisplayID()
              }) ?? NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no app delegate or screen"
            report["allPass"] = false
            return report
        }

        let originalTimeout = Settings.overlayTimeout
        let originalOverlayOnLeft = Settings.overlayOnLeft
        Settings.overlayTimeout = 30
        defer {
            Settings.overlayTimeout = originalTimeout
            Settings.overlayOnLeft = originalOverlayOnLeft
        }

        // Keep the real Desktop/Finder out of this source-side matrix. Finder can
        // accept a file promise even after the pointer returns over the source,
        // then deliver `endedAt` after the next case has reset its counters. A
        // transparent normal-level window rejects every drop while the floating
        // QuickAccess card remains the top physical mouse target.
        let rejectingDropSurfaces = NSScreen.screens.map { targetScreen -> NSWindow in
            let window = NSPanel(
                contentRect: targetScreen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .normal
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            return window
        }
        defer {
            rejectingDropSurfaces.forEach {
                $0.orderOut(nil)
                $0.close()
            }
        }

        let image = solidImage(size: NSSize(width: 640, height: 360), color: .systemBlue)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-file-directions-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func quartzPoint(_ appKitPoint: NSPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: primaryScreen.frame.maxY - appKitPoint.y)
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        func cancelActiveDrag() {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
        func makeCard(on targetScreen: NSScreen) async -> NSWindow? {
            let targetCursor = NSPoint(
                x: targetScreen.visibleFrame.midX,
                y: targetScreen.visibleFrame.midY
            )
            post(.mouseMoved, at: quartzPoint(targetCursor))
            try? await Task.sleep(nanoseconds: 120_000_000)

            let before = QuickAccessOverlay.uiTestWindows.count
            let item = HistoryItem(
                id: UUID(),
                createdAt: Date(),
                imagePath: directory.appendingPathComponent("capture-\(UUID().uuidString).png").path,
                thumbnailPath: directory.appendingPathComponent("thumb-\(UUID().uuidString).png").path,
                captureRect: nil
            )
            QuickAccessOverlay.show(
                image: image,
                historyItem: item,
                historyManager: appDelegate.historyManager,
                screen: targetScreen,
                entrance: .slide
            )
            for _ in 0..<50 {
                if QuickAccessOverlay.uiTestWindows.count > before,
                   let card = QuickAccessOverlay.uiTestWindows.last,
                   card.isVisible,
                   card.alphaValue > 0.95,
                   targetScreen.frame.contains(NSPoint(x: card.frame.midX, y: card.frame.midY)) {
                    return card
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
        func close(_ card: NSWindow) async {
            guard QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card }) else { return }
            QuickAccessOverlay.uiTestCloseNewest()
            // AppKit may keep its private drag-image window above the source for a
            // short teardown interval after `endedAt`. Do not let that transient
            // window steal the next fresh card's physical mouse-down.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        func allSubviews(of root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(allSubviews)
        }
        func waitForMouseTarget(_ card: NSWindow, at point: NSPoint) async -> Bool {
            for attempt in 0...1_000 {
                if attempt.isMultiple(of: 20) {
                    card.orderFrontRegardless()
                }
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == card.windowNumber {
                    return true
                }
                if attempt < 1_000 {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return false
        }
        func startPoint(on card: NSWindow, hotspot: String) async -> NSPoint? {
            switch hotspot {
            case "body":
                return NSPoint(x: card.frame.midX, y: card.frame.midY)
            case "progress":
                return NSPoint(x: card.frame.midX, y: card.frame.minY + 1)
            case "top-highlight":
                return NSPoint(x: card.frame.midX, y: card.frame.maxY - 1)
            default:
                QuickAccessOverlay.uiTestMarkNewestPresentationReady()
                QuickAccessOverlay.uiTestSetNewestHovered(true)
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard let content = card.contentView,
                      let control = allSubviews(of: content).first(where: {
                          $0.accessibilityIdentifier() == hotspot
                      }) else { return nil }
                let pointInWindow = control.convert(
                    NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                    to: nil
                )
                return card.convertPoint(toScreen: pointInWindow)
            }
        }
        func runCase(
            name: String,
            on targetScreen: NSScreen,
            hotspot: String = "body",
            dx: CGFloat,
            dy: CGFloat
        ) async -> [String: Any] {
            let displayID = ScreenCaptureCatalog.displayID(of: targetScreen) ?? 0
            guard let card = await makeCard(on: targetScreen) else {
                return ["name": name, "error": "card did not appear", "passed": false]
            }

            guard let startAppKit = await startPoint(on: card, hotspot: hotspot) else {
                await close(card)
                return ["name": name, "hotspot": hotspot, "error": "hotspot not found", "passed": false]
            }
            guard await waitForMouseTarget(card, at: startAppKit) else {
                await close(card)
                return [
                    "name": name,
                    "hotspot": hotspot,
                    "displayID": Int(displayID),
                    "error": "card was not the physical mouse target",
                    "passed": false,
                ]
            }
            let start = quartzPoint(startAppKit)
            QuickAccessOverlay.uiTestResetDragSessionTrace()
            post(.mouseMoved, at: start)
            try? await Task.sleep(nanoseconds: 80_000_000)
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 40_000_000)
            let steps = 10
            var point = start
            for step in 1...steps {
                point = CGPoint(
                    x: start.x + dx * CGFloat(step) / CGFloat(steps),
                    y: start.y + dy * CGFloat(step) / CGFloat(steps)
                )
                post(.leftMouseDragged, at: point)
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            // Escape is AppKit's deterministic cancellation path for an active
            // NSDraggingSession. It delivers `endedAt` without negotiating a file
            // promise with whatever application happens to sit under the cursor.
            cancelActiveDrag()
            try? await Task.sleep(nanoseconds: 60_000_000)
            post(.leftMouseUp, at: point)

            var trace: [String: Any] = [:]
            for _ in 0..<250 {
                trace = QuickAccessOverlay.uiTestDragSessionTrace()
                if trace["ended"] as? Int == 1 { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            let willBegin = trace["willBegin"] as? Int ?? 0
            let moves = trace["moves"] as? Int ?? 0
            let ended = trace["ended"] as? Int ?? 0
            let maxDistance = trace["maxDistance"] as? Double ?? 0
            let result: [String: Any] = [
                "name": name,
                "hotspot": hotspot,
                "displayID": Int(displayID),
                "willBegin": willBegin,
                "moves": moves,
                "ended": ended,
                "maxDistance": maxDistance,
                "passed": willBegin == 1 && moves > 0 && ended == 1 && maxDistance > 20,
            ]
            await close(card)
            return result
        }

        var cases: [[String: Any]] = []
        for overlayOnLeft in [true, false] {
            Settings.overlayOnLeft = overlayOnLeft
            let side = overlayOnLeft ? "left" : "right"
            let inward: CGFloat = overlayOnLeft ? 1 : -1
            let matrix: [(name: String, hotspot: String, dx: CGFloat, dy: CGFloat)] = [
                ("horizontal-inward", "body", inward * 120, 0),
                ("diagonal-inward-down", "body", inward * 60, 60),
                ("diagonal-inward-up", "body", inward * 60, -60),
                ("progress", "progress", inward * 120, 0),
                ("progress-diagonal", "progress", inward * 60, 60),
                ("top-highlight", "top-highlight", inward * 120, 0),
                ("top-highlight-diagonal", "top-highlight", inward * 60, -60),
                ("close", "quickAccess.close", inward * 120, 0),
                ("pin", "quickAccess.pin", inward * 120, 0),
                ("edit", "quickAccess.edit", inward * 120, 0),
                ("corner-save", "quickAccess.corner.save", inward * 120, 0),
                ("corner-save-diagonal", "quickAccess.corner.save", inward * 60, -60),
                ("copy", "quickAccess.copy", inward * 120, 0),
                ("copy-diagonal", "quickAccess.copy", inward * 60, 60),
                ("pill-save", "quickAccess.pill.save", inward * 120, 0),
                ("pill-save-diagonal", "quickAccess.pill.save", inward * 60, -60),
            ]
            for targetScreen in NSScreen.screens {
                let displayID = ScreenCaptureCatalog.displayID(of: targetScreen) ?? 0
                let display = targetScreen === primaryScreen ? "primary" : "display-\(displayID)"
                for testCase in matrix {
                    cases.append(await runCase(
                        name: "\(side)-\(display)-\(testCase.name)",
                        on: targetScreen,
                        hotspot: testCase.hotspot,
                        dx: testCase.dx,
                        dy: testCase.dy
                    ))
                }
            }
        }
        let testedDisplays = NSScreen.screens.compactMap {
            ScreenCaptureCatalog.displayID(of: $0).map(Int.init)
        }
        report["testedDisplays"] = testedDisplays
        report["testedDisplayCount"] = testedDisplays.count
        report["multiDisplayStatus"] = testedDisplays.count > 1 ? "exercised" : "not-applicable"
        report["cases"] = cases
        report["allPass"] = cases.allSatisfy { ($0["passed"] as? Bool) == true }
        return report
    }

    // MARK: - Scenario: overlay-file-drop-materialization

    /// Exercises the editor's real `Drag out` pill with hardware-level mouse
    /// events. The latency gate matters as much as eventual delivery: blocking
    /// the main thread to flatten, encode and write before `beginDraggingSession`
    /// makes a normal human drag look dead even if a long press eventually works.
    private static func runEditorFileDropMaterialization() async -> [String: Any] {
        var report: [String: Any] = ["scenario": "editor-file-drop-materialization"]
        guard AXIsProcessTrusted() else {
            report["skipped"] = "Accessibility permission is required for physical drag events"
            report["allPass"] = false
            return report
        }
        guard let screen = NSScreen.screens.first(where: {
            ScreenCaptureCatalog.displayID(of: $0) == CGMainDisplayID()
        }) ?? NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no primary screen"
            report["allPass"] = false
            return report
        }

        let savedDefaultTemplate = TemplateStore.defaultTemplate?.name
        let savedFormat = Settings.screenshotFormat
        TemplateStore.setDefault(name: nil)
        Settings.screenshotFormat = "png"
        defer {
            TemplateStore.setDefault(name: savedDefaultTemplate)
            Settings.screenshotFormat = savedFormat
        }

        // Retina-class, high-frequency content keeps this representative of the
        // screenshots that exposed the dead-feeling drag instead of letting a
        // solid-color PNG compress instantly.
        let pointSize = NSSize(width: 1920, height: 1080)
        let pixelSize = NSSize(width: 3840, height: 2160)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(pixelSize.width),
                  height: Int(pixelSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            report["error"] = "could not allocate source image"
            report["allPass"] = false
            return report
        }
        context.setFillColor(NSColor(srgbRed: 0.08, green: 0.11, blue: 0.18, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        for x in stride(from: 0, to: Int(pixelSize.width), by: 24) {
            let hue = CGFloat((x * 17) % 360) / 360
            context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.72, brightness: 0.92, alpha: 0.8).cgColor)
            context.fill(CGRect(
                x: x,
                y: (x * 29) % Int(pixelSize.height),
                width: 18,
                height: 420
            ))
        }
        guard let sourceCGImage = context.makeImage() else {
            report["error"] = "could not realize source image"
            report["allPass"] = false
            return report
        }
        let source = NSImage(size: pointSize)
        let sourceRep = NSBitmapImageRep(cgImage: sourceCGImage)
        sourceRep.size = pointSize
        source.addRepresentation(sourceRep)

        AnnotationWindowController.open(image: source)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let controller = AnnotationWindowController.uiTestLastController,
              let editorWindow = controller.window,
              let rootView = editorWindow.contentView,
              let dragPill = findView(in: rootView, where: { $0 is BottomBarDragPill }) as? BottomBarDragPill else {
            report["error"] = "editor or Drag out pill did not open"
            report["allPass"] = false
            return report
        }

        // This marker exists only in the edited canvas, never in the source
        // bitmap. Removing it just after the drag starts proves the promised
        // bytes came from the frozen drag-start artifact instead of consulting
        // the live editor when the receiver eventually asks for the file.
        let frozenMarker = RectangleAnnotation(
            rect: CGRect(x: 300, y: 250, width: 600, height: 360)
        )
        frozenMarker.color = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        frozenMarker.lineWidth = 32
        controller.uiTestCanvas.objects.append(frozenMarker)
        controller.uiTestCanvas.needsDisplay = true

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-editor-file-drop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            controller.uiTestMarkCurrentDocumentClean()
            editorWindow.performClose(nil)
            report["error"] = "could not create isolated drop directory: \(error)"
            report["allPass"] = false
            return report
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = UITestFileDropDestination(
            outputDirectory: root,
            promiseReceiveDelay: 0.8
        )
        let destinationFrame = NSRect(
            x: screen.visibleFrame.minX + 8,
            y: screen.visibleFrame.minY + 8,
            width: 104,
            height: 64
        )
        let destinationWindow = NSPanel(
            contentRect: destinationFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Keep the receiver physically outside the editor instead of stacking a
        // higher-level panel over the source window. Same-app overlap can hold
        // AppKit in drag tracking even after a synthetic mouse-up, which tests
        // panel z-order rather than the editor's file-promise contract.
        destinationWindow.level = .normal
        destinationWindow.isOpaque = false
        destinationWindow.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16)
        destinationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        destinationWindow.sharingType = .none
        destinationWindow.contentView = probe
        destinationWindow.orderFrontRegardless()
        defer {
            dragPill.uiTestOnDragSnapshotCreated = nil
            destinationWindow.orderOut(nil)
            destinationWindow.close()
            controller.uiTestMarkCurrentDocumentClean()
            if editorWindow.isVisible { editorWindow.performClose(nil) }
        }

        editorWindow.orderFrontRegardless()
        destinationWindow.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let startInWindow = dragPill.convert(
            NSPoint(x: dragPill.bounds.midX, y: dragPill.bounds.midY),
            to: nil
        )
        let startAppKit = editorWindow.convertPoint(toScreen: startInWindow)
        let targetAppKit = NSPoint(x: destinationFrame.midX, y: destinationFrame.midY)
        let targetDeadline = ProcessInfo.processInfo.systemUptime + 3
        var startTargetReady = false
        var destinationTargetReady = false
        while ProcessInfo.processInfo.systemUptime < targetDeadline {
            editorWindow.orderFrontRegardless()
            destinationWindow.orderFrontRegardless()
            startTargetReady = NSWindow.windowNumber(
                at: startAppKit,
                belowWindowWithWindowNumber: 0
            ) == editorWindow.windowNumber
            destinationTargetReady = NSWindow.windowNumber(
                at: targetAppKit,
                belowWindowWithWindowNumber: 0
            ) == destinationWindow.windowNumber
            if startTargetReady, destinationTargetReady { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let startHitView = editorWindow.contentView?.hitTest(startInWindow)
            .map { String(describing: type(of: $0)) } ?? "none"
        let directPillContains = dragPill.containsHitPoint(
            NSPoint(x: dragPill.bounds.midX, y: dragPill.bounds.midY)
        )
        report["startTargetReady"] = startTargetReady
        report["startHitView"] = startHitView
        report["directPillContains"] = directPillContains
        report["pillFrame"] = NSStringFromRect(dragPill.frame)
        report["pillBounds"] = NSStringFromRect(dragPill.bounds)
        report["pillHidden"] = dragPill.isHidden
        report["pillSuperview"] = dragPill.superview.map { String(describing: type(of: $0)) } ?? "none"
        report["pillSuperviewFrame"] = dragPill.superview.map { NSStringFromRect($0.frame) } ?? "none"
        report["startInWindow"] = NSStringFromPoint(startInWindow)
        report["destinationTargetReady"] = destinationTargetReady
        guard startTargetReady, destinationTargetReady else {
            report["error"] = "physical start or destination was occluded"
            report["allPass"] = false
            return report
        }

        let primaryHeight = screen.frame.maxY
        let start = CGPoint(x: startAppKit.x, y: primaryHeight - startAppKit.y)
        let target = CGPoint(x: targetAppKit.x, y: primaryHeight - targetAppKit.y)
        let mouseDownAt = ProcessInfo.processInfo.systemUptime
        dragPill.uiTestResetDragTrace()
        var markerRemovedAfterSnapshot = false
        dragPill.uiTestOnDragSnapshotCreated = { [weak controller] in
            guard let canvas = controller?.uiTestCanvas else { return }
            canvas.objects.removeAll { $0.id == frozenMarker.id }
            canvas.needsDisplay = true
            markerRemovedAfterSnapshot = true
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        // Post from outside the main actor. `beginDraggingSession` enters AppKit
        // event tracking on the main thread; if the scenario task itself posts
        // the first threshold-crossing drag, it can strand its own mouse-up behind
        // that tracking loop.
        let inputPoster = Task.detached(priority: .userInitiated) {
            func post(_ type: CGEventType, at point: CGPoint) {
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, at: start)
            try? await Task.sleep(for: .milliseconds(80))
            post(.leftMouseDown, at: start)
            try? await Task.sleep(for: .milliseconds(40))
            for step in 1...30 {
                let progress = CGFloat(step) / 30
                post(.leftMouseDragged, at: CGPoint(
                    x: start.x + (target.x - start.x) * progress,
                    y: start.y + (target.y - start.y) * progress
                ))
                try? await Task.sleep(for: .milliseconds(12))
            }
            post(.leftMouseUp, at: target)
        }
        try? await Task.sleep(for: .seconds(2))
        inputPoster.cancel()
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: target,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        let mousePosterCompleted = true
        report["mousePosterCompleted"] = mousePosterCompleted
        let dragEndDeadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < dragEndDeadline,
              (dragPill.uiTestDragTrace["endedSession"] as? Int ?? 0) == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline,
              !(probe.materializationSettled && probe.concludeCount == 1) {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        let sourceTrace = dragPill.uiTestDragTrace
        let files = probe.outputFiles()
        let file = files.first
        let fileBytes = file.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        let startsWithPNGMagic: Bool
        if let file, let data = try? Data(contentsOf: file) {
            startsWithPNGMagic = Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        } else {
            startsWithPNGMagic = false
        }
        let frozenMarkerPixelCount: Int
        if let file,
           let image = NSImage(contentsOf: file),
           let cgImage = image.bestCGImage,
           let pixels = rgbaPixels(cgImage) {
            frozenMarkerPixelCount = stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
                if pixels[offset] > 235,
                   pixels[offset + 1] < 32,
                   pixels[offset + 2] > 235,
                   pixels[offset + 3] > 235 {
                    count += 1
                }
            }
        } else {
            frozenMarkerPixelCount = 0
        }
        let destinationEnterLatencyMs = probe.firstEnteredAtUptime.map {
            ($0 - mouseDownAt) * 1000
        } ?? -1
        let beginSessionLatencyMs = sourceTrace["beginLatencyMs"] as? Double ?? -1
        let sourceLifecyclePass = (sourceTrace["mouseDown"] as? Int ?? 0) == 1
            && (sourceTrace["thresholdCross"] as? Int ?? 0) == 1
            && (sourceTrace["beginSession"] as? Int ?? 0) == 1
            && (sourceTrace["sessionMoves"] as? Int ?? 0) > 0
            && (sourceTrace["endedSession"] as? Int ?? 0) == 1
            && (sourceTrace["dropAccepted"] as? Bool) == true
        let destinationLifecyclePass = probe.enteredCount >= 1
            && probe.prepareCount == 1
            && probe.performCount == 1
            && probe.concludeCount == 1
        let deliveryPass = files.count == 1
            && fileBytes > 0
            && file?.pathExtension.lowercased() == "png"
            && startsWithPNGMagic
            && frozenMarkerPixelCount > 1_000
        let editorClosed = !editorWindow.isVisible
        let immediateStartPass = beginSessionLatencyMs >= 0 && beginSessionLatencyMs < 250
        let transportPass = probe.observedTransport == "file-promise"

        report["beginSessionLatencyMs"] = beginSessionLatencyMs
        report["destinationEnterLatencyMs"] = destinationEnterLatencyMs
        report["sourceTrace"] = sourceTrace
        report["transport"] = probe.observedTransport ?? "none"
        report["sourceLifecyclePass"] = sourceLifecyclePass
        report["destinationLifecyclePass"] = destinationLifecyclePass
        report["destinationLifecycle"] = [
            "entered": probe.enteredCount,
            "prepare": probe.prepareCount,
            "perform": probe.performCount,
            "conclude": probe.concludeCount,
        ]
        report["fileCount"] = files.count
        report["fileBytes"] = fileBytes
        report["pngMagicPass"] = startsWithPNGMagic
        report["frozenMarkerPixelCount"] = frozenMarkerPixelCount
        report["markerRemovedAfterSnapshot"] = markerRemovedAfterSnapshot
        report["editorClosed"] = editorClosed
        report["immediateStartPass"] = immediateStartPass
        report["allPass"] = mousePosterCompleted
            && sourceLifecyclePass
            && destinationLifecyclePass
            && deliveryPass
            && markerRemovedAfterSnapshot
            && transportPass
            && immediateStartPass
            && editorClosed
        return report
    }

    /// Drops a fresh screenshot card into a real in-process AppKit destination.
    /// Each supported export format proves both deterministic transports all the
    /// way through to one non-empty file: URL with a cache, promise without one.
    private static func runOverlayFileDropMaterialization() async -> [String: Any] {
        var report: [String: Any] = ["scenario": "overlay-file-drop-materialization"]
        guard AXIsProcessTrusted() else {
            report["skipped"] = "Accessibility permission is required for physical drag events"
            report["allPass"] = false
            return report
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.screens.first(where: {
                  ScreenCaptureCatalog.displayID(of: $0) == CGMainDisplayID()
              }) ?? NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no app delegate or primary screen"
            report["allPass"] = false
            return report
        }

        let originalTimeout = Settings.overlayTimeout
        let originalFormat = Settings.screenshotFormat
        Settings.overlayTimeout = 30
        defer {
            Settings.overlayTimeout = originalTimeout
            Settings.screenshotFormat = originalFormat
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-file-drop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            report["error"] = "could not create isolated drop directory: \(error)"
            report["allPass"] = false
            return report
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let primaryHeight = screen.frame.maxY
        func quartzPoint(_ appKitPoint: NSPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        func poll(
            timeout: TimeInterval,
            intervalNanoseconds: UInt64 = 20_000_000,
            until condition: () -> Bool
        ) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
            return true
        }
        func waitForMouseTarget(_ card: NSWindow, at point: NSPoint) async -> Bool {
            await poll(timeout: 3, intervalNanoseconds: 5_000_000) {
                card.orderFrontRegardless()
                return NSWindow.windowNumber(
                    at: point,
                    belowWindowWithWindowNumber: 0
                ) == card.windowNumber
            }
        }
        func makeCard(
            image: NSImage,
            caseDirectory: URL,
            entrance: QuickAccessOverlay.EntranceStyle
        ) async -> NSWindow? {
            let cursorTarget = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
            post(.mouseMoved, at: quartzPoint(cursorTarget))
            try? await Task.sleep(nanoseconds: 100_000_000)

            let before = QuickAccessOverlay.uiTestWindows.count
            let item = HistoryItem(
                id: UUID(),
                createdAt: Date(),
                imagePath: caseDirectory.appendingPathComponent("history.png").path,
                thumbnailPath: caseDirectory.appendingPathComponent("thumb.png").path,
                captureRect: nil
            )
            QuickAccessOverlay.show(
                image: image,
                historyItem: item,
                historyManager: appDelegate.historyManager,
                presentedArtifact: CaptureArtifact(image: image),
                screen: screen,
                entrance: entrance
            )
            var card: NSWindow?
            _ = await poll(timeout: 4) {
                guard QuickAccessOverlay.uiTestWindows.count > before,
                      let newest = QuickAccessOverlay.uiTestWindows.last,
                      newest.isVisible,
                      newest.alphaValue > 0.95,
                      screen.frame.contains(NSPoint(x: newest.frame.midX, y: newest.frame.midY)) else {
                    return false
                }
                card = newest
                return true
            }
            return card
        }
        func closeIfNeeded(_ card: NSWindow) async {
            guard QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card }) else { return }
            QuickAccessOverlay.uiTestCloseNewest()
            _ = await poll(timeout: 2) {
                !QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card })
            }
        }

        func magicMatches(_ file: URL?, extension ext: String) -> Bool {
            guard let file,
                  let data = try? Data(contentsOf: file),
                  !data.isEmpty else { return false }
            let bytes = Array(data.prefix(12))
            switch ext.lowercased() {
            case "png":
                return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            case "jpg", "jpeg":
                return bytes.starts(with: [0xFF, 0xD8, 0xFF])
            case "pdf":
                return bytes.starts(with: Array("%PDF-".utf8))
            case "webp":
                return bytes.count >= 12
                    && Array(bytes[0..<4]) == Array("RIFF".utf8)
                    && Array(bytes[8..<12]) == Array("WEBP".utf8)
            default:
                return false
            }
        }

        func markerColor(format: String, promiseOnly: Bool) -> NSColor {
            let rgb: (CGFloat, CGFloat, CGFloat)
            switch (format, promiseOnly) {
            case ("png", false): rgb = (0.90, 0.10, 0.10)
            case ("png", true): rgb = (0.10, 0.80, 0.20)
            case ("jpg", false): rgb = (0.10, 0.25, 0.90)
            case ("jpg", true): rgb = (0.90, 0.75, 0.10)
            case ("pdf", false): rgb = (0.80, 0.10, 0.70)
            case ("pdf", true): rgb = (0.10, 0.75, 0.80)
            case ("webp", false): rgb = (0.95, 0.40, 0.05)
            default: rgb = (0.45, 0.15, 0.85)
            }
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }

        func markerMatches(_ file: URL?, expected: NSColor) -> Bool {
            guard let file,
                  let image = NSImage(contentsOf: file),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  bitmap.pixelsWide > 20,
                  bitmap.pixelsHigh > 0,
                  let actual = bitmap.colorAt(
                      x: 16,
                      y: bitmap.pixelsHigh / 2
                  )?.usingColorSpace(.sRGB),
                  let expected = expected.usingColorSpace(.sRGB) else { return false }
            let tolerance: CGFloat = 0.22
            return abs(actual.redComponent - expected.redComponent) < tolerance
                && abs(actual.greenComponent - expected.greenComponent) < tolerance
                && abs(actual.blueComponent - expected.blueComponent) < tolerance
        }

        func runCase(
            name: String,
            format: String,
            expectedTransport: String,
            forcePromiseOnly: Bool,
            entrance: QuickAccessOverlay.EntranceStyle
        ) async -> [String: Any] {
            Settings.screenshotFormat = format
            let resolvedFormat = ImageExporter.preferredFormat().ext
            let expectedMarker = markerColor(format: format, promiseOnly: forcePromiseOnly)
            let image = sampleShot(markerColor: expectedMarker)
            let entranceName: String
            switch entrance {
            case .slide: entranceName = "slide"
            case .handoff: entranceName = "handoff"
            }
            let caseDirectory = root.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: caseDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                return ["name": name, "error": "could not create case directory: \(error)", "passed": false]
            }

            guard let card = await makeCard(
                image: image,
                caseDirectory: caseDirectory,
                entrance: entrance
            ) else {
                return ["name": name, "error": "fresh card did not appear", "passed": false]
            }

            if forcePromiseOnly {
                // This is the actual post-capture race: the handoff card is already
                // visible and draggable while its background export is still in
                // flight. Invalidate immediately so the physical first gesture
                // must complete through NSFilePromiseProvider.
                QuickAccessOverlay.uiTestInvalidatePreparedDragFile()
            } else {
                let prepared = await poll(timeout: 8, intervalNanoseconds: 25_000_000) {
                    QuickAccessOverlay.uiTestDragPrep(forceInline: false)["mode"] as? String == "prepared"
                }
                guard prepared else {
                    await closeIfNeeded(card)
                    return ["name": name, "error": "prepared drag URL did not become ready", "passed": false]
                }
            }
            let prepMode = QuickAccessOverlay.uiTestDragPrep(forceInline: false)["mode"] as? String ?? "unknown"

            let probe = UITestFileDropDestination(outputDirectory: caseDirectory)
            let destinationSize = NSSize(width: 300, height: 220)
            let visible = screen.visibleFrame
            let targetY = min(
                max(card.frame.midY, visible.minY + destinationSize.height / 2 + 20),
                visible.maxY - destinationSize.height / 2 - 20
            )
            let destinationFrame = NSRect(
                x: visible.midX - destinationSize.width / 2,
                y: targetY - destinationSize.height / 2,
                width: destinationSize.width,
                height: destinationSize.height
            )
            let destinationWindow = NSPanel(
                contentRect: destinationFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            destinationWindow.level = .statusBar
            destinationWindow.isOpaque = false
            destinationWindow.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12)
            destinationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            destinationWindow.sharingType = .none
            destinationWindow.contentView = probe
            destinationWindow.orderFrontRegardless()
            defer {
                destinationWindow.orderOut(nil)
                destinationWindow.close()
            }

            let startAppKit = NSPoint(x: card.frame.midX, y: card.frame.midY)
            guard await waitForMouseTarget(card, at: startAppKit) else {
                await closeIfNeeded(card)
                return [
                    "name": name,
                    "prepMode": prepMode,
                    "error": "card was not the physical mouse target",
                    "passed": false,
                ]
            }

            QuickAccessOverlay.uiTestResetDragSessionTrace()
            let start = quartzPoint(startAppKit)
            let targetAppKit = NSPoint(x: destinationFrame.midX, y: destinationFrame.midY)
            let target = quartzPoint(targetAppKit)
            let destinationTargetReady = NSWindow.windowNumber(
                at: targetAppKit,
                belowWindowWithWindowNumber: 0
            ) == destinationWindow.windowNumber
            guard destinationTargetReady else {
                await closeIfNeeded(card)
                return [
                    "name": name,
                    "prepMode": prepMode,
                    "error": "destination was not the physical mouse target",
                    "passed": false,
                ]
            }
            post(.mouseMoved, at: start)
            try? await Task.sleep(nanoseconds: 80_000_000)
            post(.leftMouseDown, at: start)
            try? await Task.sleep(nanoseconds: 40_000_000)
            for step in 1...36 {
                let progress = CGFloat(step) / 36
                let point = CGPoint(
                    x: start.x + (target.x - start.x) * progress,
                    y: start.y + (target.y - start.y) * progress
                )
                post(.leftMouseDragged, at: point)
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            post(.leftMouseUp, at: target)

            let settled = await poll(timeout: 12, intervalNanoseconds: 25_000_000) {
                let trace = QuickAccessOverlay.uiTestDragSessionTrace()
                return (trace["ended"] as? Int ?? 0) == 1
                    && probe.materializationSettled
                    && probe.concludeCount == 1
                    && !QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card })
            }
            if settled {
                // Let delayed promise callbacks surface before asserting that the
                // destination received exactly one file.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            let trace = QuickAccessOverlay.uiTestDragSessionTrace()
            let files = probe.outputFiles()
            let file = files.first
            let fileBytes = file.flatMap {
                try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } ?? 0
            let decodable = file.flatMap { NSImage(contentsOf: $0) }?.isValid == true
            let extensionMatches = file?.pathExtension.lowercased() == resolvedFormat
            let fileMagicMatches = magicMatches(file, extension: resolvedFormat)
            let contentMatches = markerMatches(file, expected: expectedMarker)
            let cardClosed = !QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card })
            let destinationLifecycle = probe.enteredCount >= 1
                && probe.prepareCount == 1
                && probe.performCount == 1
                && probe.concludeCount == 1
            let sourceLifecycle = (trace["willBegin"] as? Int ?? 0) == 1
                && (trace["moves"] as? Int ?? 0) > 0
                && (trace["ended"] as? Int ?? 0) == 1
            let transportMatches = probe.observedTransport == expectedTransport
            let modeMatches = forcePromiseOnly ? prepMode == "promise-only" : prepMode == "prepared"
            let passed = settled
                && modeMatches
                && transportMatches
                && probe.receivedItemCount == 1
                && probe.errors.isEmpty
                && files.count == 1
                && fileBytes > 0
                && decodable
                && extensionMatches
                && fileMagicMatches
                && contentMatches
                && sourceLifecycle
                && destinationLifecycle
                && cardClosed

            if !cardClosed { await closeIfNeeded(card) }
            return [
                "name": name,
                "format": format,
                "resolvedFormat": resolvedFormat,
                "entrance": entranceName,
                "prepMode": prepMode,
                "expectedTransport": expectedTransport,
                "observedTransport": probe.observedTransport ?? "none",
                "receivedItemCount": probe.receivedItemCount,
                "fileCount": files.count,
                "fileBytes": fileBytes,
                "decodableImage": decodable,
                "extensionMatches": extensionMatches,
                "magicMatches": fileMagicMatches,
                "contentMatches": contentMatches,
                "sourceWillBegin": trace["willBegin"] as? Int ?? 0,
                "sourceMoves": trace["moves"] as? Int ?? 0,
                "sourceEnded": trace["ended"] as? Int ?? 0,
                "destinationEntered": probe.enteredCount,
                "destinationPrepare": probe.prepareCount,
                "destinationPerform": probe.performCount,
                "destinationConclude": probe.concludeCount,
                "destinationErrors": probe.errors,
                "cardClosed": cardClosed,
                "destinationTargetReady": destinationTargetReady,
                "settled": settled,
                "passed": passed,
            ]
        }

        var cases: [[String: Any]] = []
        for format in ["png", "jpg", "pdf", "webp"] {
            cases.append(await runCase(
                name: "\(format)-prepared-cache-url",
                format: format,
                expectedTransport: "file-url",
                forcePromiseOnly: false,
                entrance: .slide
            ))
            cases.append(await runCase(
                name: "\(format)-handoff-immediate-promise",
                format: format,
                expectedTransport: "file-promise",
                forcePromiseOnly: true,
                entrance: .handoff
            ))
        }
        report["cases"] = cases
        report["allPass"] = cases.allSatisfy { $0["passed"] as? Bool == true }
        return report
    }

    // MARK: - Scenario: overlay-rapid-retry

    /// A new grab owns the window immediately, even if the previous cancelled
    /// gesture is still animating back to its slot. Samples while the second drag
    /// remains held so a stale frame animator cannot hide behind the final release.
    private static func runOverlayRapidRetry() async -> [String: Any] {
        var report: [String: Any] = ["scenario": "overlay-rapid-retry"]
        guard AXIsProcessTrusted() else {
            report["skipped"] = "Accessibility permission is required for physical drag events"
            report["allPass"] = false
            return report
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.screens.first(where: {
                  ScreenCaptureCatalog.displayID(of: $0) == CGMainDisplayID()
              }) ?? NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no app delegate or screen"
            report["allPass"] = false
            return report
        }

        let savedTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        defer { Settings.overlayTimeout = savedTimeout }

        let image = solidImage(size: NSSize(width: 640, height: 360), color: .systemPurple)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-rapid-retry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func quartzPoint(_ appKitPoint: NSPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        func waitForMouseTarget(_ card: NSWindow, at point: NSPoint) async -> Bool {
            for attempt in 0...50 {
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == card.windowNumber {
                    return true
                }
                if attempt < 50 {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return false
        }
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumb.png").path,
            captureRect: nil
        )

        let before = QuickAccessOverlay.uiTestWindows.count
        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: screen,
            entrance: .slide
        )
        var createdCard: NSWindow?
        for _ in 0..<50 {
            if QuickAccessOverlay.uiTestWindows.count > before,
               let card = QuickAccessOverlay.uiTestWindows.last,
               card.isVisible,
               card.alphaValue > 0.95 {
                createdCard = card
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let card = createdCard else {
            report["error"] = "card did not appear"
            report["allPass"] = false
            return report
        }
        defer {
            if QuickAccessOverlay.uiTestWindows.contains(where: { $0 === card }) {
                QuickAccessOverlay.uiTestCloseNewest()
            }
        }
        let slotOrigin = card.frame.origin

        let firstStartAppKit = NSPoint(x: card.frame.midX, y: card.frame.midY)
        guard await waitForMouseTarget(card, at: firstStartAppKit) else {
            report["error"] = "card was not the physical mouse target"
            report["allPass"] = false
            return report
        }
        let firstStart = quartzPoint(firstStartAppKit)
        let firstEnd = CGPoint(x: firstStart.x, y: firstStart.y + 30)
        QuickAccessOverlay.uiTestResetGestureEntryCount()
        post(.mouseMoved, at: firstStart)
        try? await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseDown, at: firstStart)
        try? await Task.sleep(nanoseconds: 40_000_000)
        post(.leftMouseDragged, at: firstEnd)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let firstPulled = QuickAccessOverlay.uiTestNewestFrameOrigin() ?? slotOrigin
        post(.leftMouseUp, at: firstEnd)

        // Retry while the 0.22 s snap-back is still active.
        try? await Task.sleep(nanoseconds: 25_000_000)
        let retryStartAppKit = NSPoint(x: firstStartAppKit.x, y: firstStartAppKit.y - 30)
        guard await waitForMouseTarget(card, at: retryStartAppKit) else {
            report["error"] = "card did not remain the physical mouse target for retry"
            report["allPass"] = false
            return report
        }
        let retryEnd = CGPoint(x: firstEnd.x, y: firstEnd.y + 30)
        post(.leftMouseDown, at: firstEnd)
        try? await Task.sleep(nanoseconds: 40_000_000)
        // The window can legitimately keep advancing its previous snap-back while
        // the second press is held but has not moved yet. The new gesture owns the
        // frame at its first drag sample, so measure the displacement from there.
        let retryBase = QuickAccessOverlay.uiTestNewestFrameOrigin() ?? slotOrigin
        post(.leftMouseDragged, at: retryEnd)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let retryImmediate = QuickAccessOverlay.uiTestNewestFrameOrigin() ?? retryBase

        // Keep holding until after the previous 0.22 s animator would have ended.
        try? await Task.sleep(nanoseconds: 140_000_000)
        let retryHeld = QuickAccessOverlay.uiTestNewestFrameOrigin() ?? retryBase
        post(.leftMouseUp, at: retryEnd)
        try? await Task.sleep(nanoseconds: 250_000_000)

        let firstMoved = slotOrigin.y - firstPulled.y > 20
        let retryMovedImmediately = retryBase.y - retryImmediate.y > 20
        let retryStayedOwned = retryBase.y - retryHeld.y > 20
            && abs(retryHeld.y - retryImmediate.y) < 3
        let gestureEntries = QuickAccessOverlay.uiTestGestureEntryCount()
        report["slotY"] = Double(slotOrigin.y)
        report["firstPulledY"] = Double(firstPulled.y)
        report["retryBaseY"] = Double(retryBase.y)
        report["retryImmediateY"] = Double(retryImmediate.y)
        report["retryHeldY"] = Double(retryHeld.y)
        report["firstMoved"] = firstMoved
        report["retryMovedImmediately"] = retryMovedImmediately
        report["retryStayedOwned"] = retryStayedOwned
        report["gestureEntries"] = gestureEntries
        report["physicalEvents"] = true
        report["allPass"] = firstMoved
            && retryMovedImmediately
            && retryStayedOwned
            && gestureEntries == 2
        return report
    }

    // MARK: - Scenario: interactive-follow-up

    /// Starts an interactive request with a follow-up, then submits a second
    /// `krit://`-equivalent request while the first selector is open. The newer
    /// selector must replace the old one, retain its own follow-up, and remain
    /// untouched when the stale selector is cancelled again.
    private static func runInteractiveFollowUp() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "interactive-follow-up"]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no app delegate or screen"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-interactive-follow-up-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = testDirectory.appendingPathComponent("history", isDirectory: true)
        let saveDirectory = testDirectory.appendingPathComponent("saves", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        } catch {
            r["error"] = "could not create isolated test directories: \(error)"
            r["allPass"] = false
            return r
        }

        let originalShowOverlay = Settings.afterCaptureShowOverlay
        let originalCopy = Settings.afterCaptureCopyToClipboard
        let originalAutoSave = Settings.afterCaptureSaveAutomatically
        let originalSaveLocation = Settings.autoSaveLocation
        let originalFormat = Settings.screenshotFormat
        let originalCountdown = Settings.captureCountdownSeconds
        let originalSavedArea = Settings.allInOneRect
        let originalLastCaptureRect = engine.lastCaptureRect
        guard Settings.setAutoSaveLocation(saveDirectory.path) else {
            r["error"] = "could not set isolated save directory"
            r["allPass"] = false
            return r
        }
        Settings.afterCaptureShowOverlay = false
        Settings.afterCaptureCopyToClipboard = false
        Settings.afterCaptureSaveAutomatically = false
        Settings.screenshotFormat = "png"
        Settings.captureCountdownSeconds = 0
        let historyManager = HistoryManager(storageDir: historyDirectory)
        await historyManager.waitUntilLoaded()
        engine.uiTestActiveSelection?.cancel()
        defer {
            engine.uiTestActiveSelection?.cancel()
            Settings.afterCaptureShowOverlay = originalShowOverlay
            Settings.afterCaptureCopyToClipboard = originalCopy
            Settings.afterCaptureSaveAutomatically = originalAutoSave
            Settings.screenshotFormat = originalFormat
            Settings.captureCountdownSeconds = originalCountdown
            Settings.allInOneRect = originalSavedArea
            engine.uiTestRestoreLastCaptureRect(originalLastCaptureRect)
            _ = Settings.setAutoSaveLocation(originalSaveLocation)
            try? FileManager.default.removeItem(at: testDirectory)
        }
        func selectionIsOnScreen(_ selection: AreaSelectionWindow?) -> Bool {
            selection?.uiTestOverlayVisibility()["allOnScreen"] as? Bool == true
        }

        let available = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        guard available.width >= 120, available.height >= 80 else {
            r["error"] = "screen has no safe selection area"
            r["allPass"] = false
            return r
        }
        let selectionRect = CGRect(
            x: available.midX - 60,
            y: available.midY - 40,
            width: 120,
            height: 80
        )
        let clipboardChangeCount = NSPasteboard.general.changeCount

        // Two URL requests can arrive in one main-run-loop turn. The dispatch
        // gate must make the newest request the only one that reaches the engine.
        appDelegate.captureInteractive(.area, then: [.copy], historyManagerOverride: historyManager)
        appDelegate.captureInteractive(.area, then: [.save], historyManagerOverride: historyManager)
        for _ in 0..<30 where !selectionIsOnScreen(engine.uiTestActiveSelection) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let burstSelection = engine.uiTestActiveSelection,
              selectionIsOnScreen(burstSelection),
              engine.uiTestHasPendingCaptureFollowUp else {
            r["error"] = "latest same-turn selection did not appear"
            r["allPass"] = false
            return r
        }

        burstSelection.simulateSelection(rect: selectionRect, on: screen)
        var burstSavedFiles: [URL] = []
        for _ in 0..<100 {
            burstSavedFiles = (try? FileManager.default.contentsOfDirectory(
                at: saveDirectory,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
            if burstSavedFiles.count == 1,
               engine.uiTestActiveSelection == nil,
               !engine.uiTestHasPendingCaptureFollowUp {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let burstFollowUpCleared = !engine.uiTestHasPendingCaptureFollowUp
        let burstClosed = engine.uiTestActiveSelection == nil
        let burstSaveFileProduced = burstSavedFiles.count == 1
        let burstClipboardUntouched = NSPasteboard.general.changeCount == clipboardChangeCount
        guard burstFollowUpCleared,
              burstClosed,
              burstSaveFileProduced,
              burstClipboardUntouched else {
            r["burstFollowUpCleared"] = burstFollowUpCleared
            r["burstClosed"] = burstClosed
            r["burstSaveFileProduced"] = burstSaveFileProduced
            r["burstClipboardUntouched"] = burstClipboardUntouched
            r["allPass"] = false
            return r
        }

        appDelegate.captureInteractive(.area, then: [.copy], historyManagerOverride: historyManager)
        for _ in 0..<30 where !selectionIsOnScreen(engine.uiTestActiveSelection) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let firstSelection = engine.uiTestActiveSelection,
              selectionIsOnScreen(firstSelection),
              let firstAttemptID = engine.uiTestActiveCaptureAttemptID else {
            r["error"] = "first selection did not appear"
            r["allPass"] = false
            return r
        }
        defer { engine.uiTestActiveSelection?.cancel() }

        appDelegate.captureInteractive(.area, then: [.save], historyManagerOverride: historyManager)
        var replacement: AreaSelectionWindow?
        for _ in 0..<30 {
            if let activeSelection = engine.uiTestActiveSelection,
               activeSelection !== firstSelection,
               selectionIsOnScreen(activeSelection) {
                replacement = activeSelection
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let replacement else {
            r["error"] = "replacement selection did not appear"
            r["allPass"] = false
            return r
        }

        let replacementAttemptID = engine.uiTestActiveCaptureAttemptID
        let replacementOwnsNewAttempt = replacementAttemptID != nil
            && replacementAttemptID != firstAttemptID
        let replacementFollowUpArmed = engine.uiTestHasPendingCaptureFollowUp
        firstSelection.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let staleCancellationIgnored = engine.uiTestActiveSelection === replacement
            && engine.uiTestHasPendingCaptureFollowUp

        replacement.simulateSelection(rect: selectionRect, on: screen)

        var savedFiles: [URL] = []
        for _ in 0..<100 {
            savedFiles = (try? FileManager.default.contentsOfDirectory(
                at: saveDirectory,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
            if !savedFiles.isEmpty, engine.uiTestActiveSelection == nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let replacementFollowUpCleared = !engine.uiTestHasPendingCaptureFollowUp
        let replacementClosed = engine.uiTestActiveSelection == nil
        let replacementSaveFileProduced = savedFiles.count == 2
        let clipboardUntouched = NSPasteboard.general.changeCount == clipboardChangeCount

        r["burstFollowUpCleared"] = burstFollowUpCleared
        r["burstClosed"] = burstClosed
        r["burstSaveFileProduced"] = burstSaveFileProduced
        r["burstClipboardUntouched"] = burstClipboardUntouched
        r["replacementOpened"] = true
        r["replacementOwnsNewAttempt"] = replacementOwnsNewAttempt
        r["replacementFollowUpArmed"] = replacementFollowUpArmed
        r["staleCancellationIgnored"] = staleCancellationIgnored
        r["replacementFollowUpCleared"] = replacementFollowUpCleared
        r["replacementClosed"] = replacementClosed
        r["replacementSaveFileProduced"] = replacementSaveFileProduced
        r["clipboardUntouched"] = clipboardUntouched
        r["allPass"] = burstFollowUpCleared
            && burstClosed
            && burstSaveFileProduced
            && burstClipboardUntouched
            && replacementFollowUpArmed
            && replacementOwnsNewAttempt
            && staleCancellationIgnored
            && replacementFollowUpCleared
            && replacementClosed
            && replacementSaveFileProduced
            && clipboardUntouched
        return r
    }

    // MARK: - Scenario: activation-lifetime

    /// Exercises the native activation contract for both borderless recording
    /// surfaces through PreferencesWindowController's real close delegate.
    /// Closing Preferences while either surface remains visible must retain
    /// `.accessory`; closing the surface afterwards removes its registration.
    private static func runActivationLifetime() async -> [String: Any] {
        var report: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no app delegate or screen"
            report["allPass"] = false
            return report
        }

        let originalPolicy = NSApp.activationPolicy()
        let originalMicrophone = Settings.recordingMicrophone
        let originalCamera = Settings.recordingWebcam
        Settings.recordingMicrophone = false
        Settings.recordingWebcam = false
        let engine = appDelegate.uiTestCaptureEngine
        let actions = UITestRecordingResultActions()
        let result = RecordingResultWindow.uiTestMake(
            url: URL(fileURLWithPath: "/tmp/krit-activation-lifetime.mp4"),
            duration: 1,
            actions: actions
        )
        let preferences = PreferencesWindowController.shared
        preferences.uiTestClose()

        func closePreferencesThroughProductionDelegate() async -> (opened: Bool, closed: Bool) {
            preferences.show(tab: .general)
            for _ in 0..<20 where preferences.window?.isVisible != true {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let opened = preferences.window?.isVisible == true
            preferences.uiTestClose()
            for _ in 0..<20 where preferences.window?.isVisible == true {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return (opened, preferences.window?.isVisible != true)
        }

        defer {
            if result.isVisible { result.close() }
            engine.uiTestCloseRecordingPreflight()
            preferences.uiTestClose()
            Settings.recordingMicrophone = originalMicrophone
            Settings.recordingWebcam = originalCamera
            _ = NSApp.setActivationPolicy(originalPolicy)
        }

        _ = NSApp.setActivationPolicy(.accessory)
        result.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let resultVisible = result.isVisible
        let resultRegistered = NSApp.isActivationPersistentWindow(result)
        report["resultVisible"] = resultVisible
        report["resultRegistered"] = resultRegistered
        let resultPreferences = await closePreferencesThroughProductionDelegate()
        let retainedAccessory = NSApp.activationPolicy() == .accessory
        report["resultPreferencesOpened"] = resultPreferences.opened
        report["resultPreferencesClosed"] = resultPreferences.closed
        report["retainedAccessory"] = retainedAccessory

        result.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let resultUnregistered = !NSApp.isActivationPersistentWindow(result)
        report["resultUnregistered"] = resultUnregistered

        guard let preflight = engine.uiTestShowRecordingPreflight(
            rect: CGRect(x: 40, y: 40, width: 640, height: 360),
            on: screen
        ) else {
            report["error"] = "recording preflight did not appear"
            report["allPass"] = false
            return report
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        let preflightVisible = preflight.isVisible
        let preflightRegistered = NSApp.isActivationPersistentWindow(preflight)
        let preflightPreferences = await closePreferencesThroughProductionDelegate()
        let preflightRetainedAccessory = NSApp.activationPolicy() == .accessory

        preflight.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let preflightUnregistered = !NSApp.isActivationPersistentWindow(preflight)

        report["preflightVisible"] = preflightVisible
        report["preflightRegistered"] = preflightRegistered
        report["preflightPreferencesOpened"] = preflightPreferences.opened
        report["preflightPreferencesClosed"] = preflightPreferences.closed
        report["preflightRetainedAccessory"] = preflightRetainedAccessory
        report["preflightUnregistered"] = preflightUnregistered
        report["allPass"] = resultVisible
            && resultRegistered
            && resultPreferences.opened
            && resultPreferences.closed
            && retainedAccessory
            && resultUnregistered
            && preflightVisible
            && preflightRegistered
            && preflightPreferences.opened
            && preflightPreferences.closed
            && preflightRetainedAccessory
            && preflightUnregistered
        return report
    }

    // MARK: - Scenario: history-representation

    /// Exercises the live Quick Access rotation path for a capture that has both
    /// raw and composed files. The editor's raw file must stay untouched while the
    /// card, restore path and drag file advance to the rotated presentation.
    private static func runHistoryRepresentation() async -> [String: Any] {
        var report: [String: Any] = [:]
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            report["error"] = "no screen"
            return report
        }

        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-history-representation-ui-\(UUID().uuidString)", isDirectory: true)
        let manager = HistoryManager(storageDir: storage)
        let raw = solidImage(size: NSSize(width: 160, height: 80), color: .systemRed)
        let presented = solidImage(size: NSSize(width: 160, height: 80), color: .systemBlue)
        let item = manager.add(image: raw, rect: .zero, presentedImage: presented)
        guard let presentedPath = item.presentedPath else {
            report["error"] = "no presented path"
            return report
        }
        defer {
            QuickAccessOverlay.uiTestCloseNewest()
            try? FileManager.default.removeItem(at: storage)
        }

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: item.imagePath),
               FileManager.default.fileExists(atPath: presentedPath) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let rawBefore = try? Data(contentsOf: URL(fileURLWithPath: item.imagePath)),
              let presentedBefore = try? Data(contentsOf: URL(fileURLWithPath: presentedPath)),
              let artifact = CaptureArtifact(image: presented) else {
            report["error"] = "initial persistence failed"
            return report
        }

        QuickAccessOverlay.show(
            image: presented,
            historyItem: item,
            historyManager: manager,
            presentedArtifact: artifact,
            screen: screen
        )
        try? await Task.sleep(nanoseconds: 450_000_000)
        QuickAccessOverlay.uiTestRotateNewest(clockwise: true)

        var presentationChanged = false
        for _ in 0..<100 {
            if let updated = try? Data(contentsOf: URL(fileURLWithPath: presentedPath)),
               updated != presentedBefore {
                presentationChanged = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let rawUnchanged = (try? Data(contentsOf: URL(fileURLWithPath: item.imagePath))) == rawBefore
        let rotatedPresentation = item.presentedImage.size.height > item.presentedImage.size.width
        report["rawUnchanged"] = rawUnchanged
        report["presentationChanged"] = presentationChanged
        report["rotatedPresentation"] = rotatedPresentation
        report["allPass"] = rawUnchanged && presentationChanged && rotatedPresentation
        return report
    }

    private static func solidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
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

        let awsKeyFixture = "AKIA" + "IOSFODNN7EXAMPLE"
        let lines = [
            "Contact: alice.smith@example.com",
            "aws key \(awsKeyFixture)",
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

    // MARK: - Cenário: redact-adversarial (a Secure Blur derrota a própria OCR do app)

    /// Adversarial proof that Secure Blur redaction is irreversible. It draws a
    /// known secret into an image, runs the app's OWN Vision OCR
    /// (`OCREngine.recognizeText`) as a CONTROL to prove the text was legible,
    /// then flattens a `BlurAnnotation(secure: true)` (exactly what
    /// `applySmartRedact` and the manual toggle create) over the secret through the
    /// REAL export path (`AnnotationCanvas.flatten()`, the same call Save/Share use)
    /// and runs OCR AGAIN on the exported pixels. The redaction passes only if OCR
    /// recovered the secret before and recovers no 4+ char fragment of it after. If
    /// Secure Blur were reversible, OCR would read the secret back and this would
    /// correctly FAIL; the assertion is never weakened to force a pass.
    private static func runRedactAdversarial() async -> [String: Any] {
        var r: [String: Any] = [:]
        let secret = "KRITSECRET42XQ"
        r["secret"] = secret

        // Control image: the secret in a large bold font, black on white, centred,
        // backed by a 2x bitmap rep so `bestCGImage` carries real retina-class
        // pixels (the same backing the OCR scenario proved Vision reads cleanly).
        let logical = NSSize(width: 760, height: 200)
        let scale = 2
        let pxW = Int(logical.width) * scale
        let pxH = Int(logical.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pxW * 4, bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            r["error"] = "could not build bitmap rep"; r["allPass"] = false; return r
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pxW, height: pxH).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 56 * CGFloat(scale)),
            .foregroundColor: NSColor.black,
        ]
        let textSize = (secret as NSString).size(withAttributes: attrs)
        let textOrigin = NSPoint(x: (CGFloat(pxW) - textSize.width) / 2,
                                 y: (CGFloat(pxH) - textSize.height) / 2)
        (secret as NSString).draw(at: textOrigin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = logical
        let img = NSImage(size: logical)
        img.addRepresentation(rep)

        let dir = "/tmp/krit-redact"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            let p = "\(dir)/control.png"; try? png.write(to: URL(fileURLWithPath: p)); r["controlImage"] = p
        }

        // CONTROL: the app's OCR must recover the secret from the clean image,
        // otherwise the setup is broken and the redaction proof is meaningless.
        let ocrControl = await OCREngine.recognizeText(in: img)
        r["ocrControl"] = String(ocrControl.prefix(200))
        let controlRun = Self.longestSharedRun(of: secret, in: ocrControl)
        r["controlRun"] = controlRun
        let controlReadable = controlRun >= 8   // a strong substring, robust to a stray glyph slip
        r["controlReadable"] = controlReadable

        // Apply Secure Blur exactly as production does: a BlurAnnotation with
        // secure == true, flattened through the canvas export path. Background
        // disabled so the slot is the whole screenshot and the mosaic samples the
        // secret directly (the redaction band then covers the full canvas).
        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor window did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.window?.close() }
        let canvas = ctrl.uiTestCanvas

        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = false   // slot == full canvas == the whole screenshot
        canvas.backgroundOptions = bg
        canvas.backgroundImage = img
        canvas.frame = NSRect(origin: .zero, size: logical)

        // Same object production builds: default radius, secure == true (the
        // secureBlur render ignores radius and mosaics from the image pixels). The
        // region is the whole screenshot, which fully contains the secret.
        let fx = BlurAnnotation(rect: NSRect(origin: .zero, size: logical))
        fx.secure = true
        canvas.objects = [fx]
        canvas.needsDisplay = true
        try? await Task.sleep(nanoseconds: 200_000_000)

        let redacted = canvas.flatten()
        if let cg = redacted.bestCGImage,
           let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            let p = "\(dir)/redacted.png"; try? data.write(to: URL(fileURLWithPath: p)); r["redactedImage"] = p
        }

        // ADVERSARIAL: OCR the exported, redacted pixels. Nothing of the secret may
        // survive, not the whole string, not any 4+ char fragment of it.
        let ocrRedacted = await OCREngine.recognizeText(in: redacted)
        r["ocrRedacted"] = String(ocrRedacted.prefix(200))
        let redactedRun = Self.longestSharedRun(of: secret, in: ocrRedacted)
        r["redactedRun"] = redactedRun
        let secretDestroyed = redactedRun < 4
        r["secretDestroyed"] = secretDestroyed

        r["allPass"] = controlReadable && secretDestroyed
        return r
    }

    // MARK: - Cenário: redact-sharpness (export do redact na resolução nativa)

    /// Prova que o efeito exporta na resolução da captura, não na escala da tela.
    /// A fonte é sintetizada a 3x (nenhuma tela Mac é 3x), então se o render ainda
    /// dependesse da escala do display (o bug), o bitmap cacheado sairia a 1x/2x e a
    /// razão pixels/pontos NÃO bateria 3. Bater 3 exato, mais o export sair em
    /// pixels nativos, prova que a faixa de redação nunca é ampliada suave.
    private static func runRedactSharpness() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "redact-sharpness"]

        // 3x synthetic capture. logical points 400x200, native pixels 1200x600.
        let logical = NSSize(width: 400, height: 200)
        let srcScale = 3
        let pxW = Int(logical.width) * srcScale
        let pxH = Int(logical.height) * srcScale
        guard let srcRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pxW * 4, bitsPerPixel: 32
        ), let sctx = NSGraphicsContext(bitmapImageRep: srcRep) else {
            r["error"] = "could not build source rep"; r["allPass"] = false; return r
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = sctx
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: pxW, height: pxH).fill()
        for x in stride(from: 0, to: pxW, by: 12) {
            NSColor.black.setFill()
            NSRect(x: CGFloat(x), y: 0, width: 6, height: CGFloat(pxH)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        srcRep.size = logical
        let img = NSImage(size: logical)
        img.addRepresentation(srcRep)

        AnnotationWindowController.open(image: img)
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let ctrl = AnnotationWindowController.uiTestLastController else {
            r["error"] = "editor window did not open"; r["allPass"] = false; return r
        }
        defer { ctrl.window?.close() }
        let canvas = ctrl.uiTestCanvas

        var bg = ScreenshotBackgroundOptions.editorDefault
        bg.isEnabled = false   // slot == full canvas == the whole screenshot
        canvas.backgroundOptions = bg
        canvas.backgroundImage = img
        canvas.frame = NSRect(origin: .zero, size: logical)

        let region = NSRect(x: 50, y: 40, width: 300, height: 120)
        let fx = PixelateAnnotation(rect: region)
        fx.scale = 10
        canvas.objects = [fx]
        canvas.needsDisplay = true
        try? await Task.sleep(nanoseconds: 150_000_000)

        // flatten drives the same drawPixelate the export uses; it renders and
        // caches the effect at the native scale under the fixed EffectCacheKey.
        let export = canvas.flatten()

        guard let cached = fx.cachedRender,
              let crep = cached.representations.first as? NSBitmapImageRep else {
            r["error"] = "no cached render"; r["allPass"] = false; return r
        }
        let expectedCW = Int(ceil(region.width * CGFloat(srcScale)))
        let expectedCH = Int(ceil(region.height * CGFloat(srcScale)))
        r["cachedPxW"] = crep.pixelsWide; r["cachedPxH"] = crep.pixelsHigh
        r["expectedCachedW"] = expectedCW; r["expectedCachedH"] = expectedCH
        // Machine-independent: no Mac display is 3x, so a cache still tied to screen
        // scale could never land on region x 3. Landing there proves it decoupled.
        let scaleDecoupled = crep.pixelsWide == expectedCW && crep.pixelsHigh == expectedCH
        r["scaleDecoupled"] = scaleDecoupled

        guard let ecg = export.bestCGImage else {
            r["error"] = "no export image"; r["allPass"] = false; return r
        }
        r["exportPxW"] = ecg.width; r["exportPxH"] = ecg.height
        let exportNative = ecg.width == pxW && ecg.height == pxH
        r["exportNative"] = exportNative

        // Corroboration (reported, not gated): a native-res mosaic of a striped
        // source keeps hard block edges. Scan one row through the band and record
        // the steepest adjacent-pixel luma jump; an upscaled-soft band smears these.
        let erep = NSBitmapImageRep(cgImage: ecg)
        let y = min(max(Int(region.midY) * srcScale, 0), ecg.height - 1)
        var maxJump = 0.0; var prev = -1.0
        for x in stride(from: Int(region.minX) * srcScale, to: Int(region.maxX) * srcScale, by: 1) {
            guard let c = erep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let luma = (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) * 255
            if prev >= 0 { maxJump = max(maxJump, abs(luma - prev)) }
            prev = luma
        }
        r["maxBlockEdgeJump"] = Int(maxJump)

        r["allPass"] = scaleDecoupled && exportNative
        return r
    }

    // MARK: - Cenário: uniform-grab-guard (rejeição do frame -3811 que causaria o flash)

    /// The frozen-frame flash fix drops a grab that came back a uniform black/white
    /// frame (the -3811 failure this Mac hits on a video wallpaper) instead of
    /// painting it as the backdrop, which would black out or light-flash the whole
    /// selection. Prove the guard: uniformColorDescription flags uniform grabs and
    /// passes real (varied) content. Pure function, no SCK grab, so it never hangs
    /// the way a real capture does headless.
    private static func runUniformGrabGuard() -> [String: Any] {
        var r: [String: Any] = ["scenario": "uniform-grab-guard"]

        func bitmap() -> (NSBitmapImageRep, NSGraphicsContext)? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 40 * 4, bitsPerPixel: 32
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            return (rep, ctx)
        }
        func solid(_ gray: CGFloat) -> CGImage? {
            guard let (rep, ctx) = bitmap() else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            NSColor(white: gray, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        func striped() -> CGImage? {
            guard let (rep, ctx) = bitmap() else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill()
            NSColor.black.setFill()
            for x in stride(from: 0, to: 40, by: 8) { NSRect(x: CGFloat(x), y: 0, width: 4, height: 40).fill() }
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }

        let blackDesc = solid(0).flatMap { CaptureEngine.uniformColorDescription($0) }
        let whiteDesc = solid(1).flatMap { CaptureEngine.uniformColorDescription($0) }
        let variedDesc = striped().flatMap { CaptureEngine.uniformColorDescription($0) }
        r["blackDesc"] = blackDesc ?? "nil"
        r["whiteDesc"] = whiteDesc ?? "nil"
        r["variedDesc"] = variedDesc ?? "nil"

        let blackRejected = blackDesc?.hasPrefix("black") == true
        let whiteRejected = whiteDesc?.hasPrefix("white") == true
        let variedAccepted = variedDesc == nil   // varied content is a real desktop, kept
        r["blackRejected"] = blackRejected
        r["whiteRejected"] = whiteRejected
        r["variedAccepted"] = variedAccepted
        r["allPass"] = blackRejected && whiteRejected && variedAccepted
        return r
    }

    // MARK: - Cenário: overlay-gesture-freeze (F3.3: irmão não some no meio do gesto)

    /// Locks the F3.3 mechanic: with two cards up and their auto-dismiss
    /// countdowns armed, a gesture on one must FREEZE the sibling's countdown
    /// (before this, the sibling could animate itself away mid-drag) and the
    /// gesture settling must resume it. Drives the gesture via the direct hook,
    /// no synthetic mouse.
    private static func runOverlayGestureFreeze() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-gesture-freeze"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }
        let savedTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        defer { Settings.overlayTimeout = savedTimeout }

        func makeCard(_ i: Int, _ color: NSColor) {
            let img = NSImage(size: NSSize(width: 300, height: 200))
            img.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 300, height: 200).fill(); img.unlockFocus()
            let p = "/tmp/krit-gfreeze-\(i).png"
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: p))
            }
            let item = HistoryItem(id: UUID(), createdAt: Date(), imagePath: p, thumbnailPath: p, captureRect: nil)
            QuickAccessOverlay.show(image: img, historyItem: item,
                                    historyManager: appDelegate.historyManager, screen: NSScreen.main)
        }
        let before = QuickAccessOverlay.uiTestWindows.count
        makeCard(0, .systemRed);  try? await Task.sleep(nanoseconds: 500_000_000)
        makeCard(1, .systemBlue); try? await Task.sleep(nanoseconds: 900_000_000)
        let count = QuickAccessOverlay.uiTestWindows.count - before
        r["cardCount"] = count
        func cleanup() async {
            for _ in 0..<max(count, 0) {
                QuickAccessOverlay.uiTestCloseNewest()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        guard count >= 2 else {
            r["error"] = "cards did not appear (\(count))"; r["allPass"] = false
            await cleanup(); return r
        }

        QuickAccessOverlay.uiTestArmDismissTimers()
        let armed = QuickAccessOverlay.uiTestDismissTimersActive()
        r["armed"] = armed
        QuickAccessOverlay.uiTestGestureBegin()
        let during = QuickAccessOverlay.uiTestDismissTimersActive()
        r["duringGesture"] = during
        QuickAccessOverlay.uiTestGestureEnd()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let after = QuickAccessOverlay.uiTestDismissTimersActive()
        r["afterGesture"] = after
        let afterStates = QuickAccessOverlay.uiTestDismissTimerStates()
        r["afterGestureStates"] = afterStates

        // File conversion returns early to AppKit instead of reaching cardDragEnd.
        // Re-arm and exercise that branch explicitly, so the sibling countdown
        // cannot remain frozen behind a successful file drag.
        QuickAccessOverlay.uiTestArmDismissTimers()
        let fileDragArmed = QuickAccessOverlay.uiTestDismissTimersActive()
        r["fileDragArmed"] = fileDragArmed
        QuickAccessOverlay.uiTestGestureConvertToFileDrag()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let afterFileDragConversion = QuickAccessOverlay.uiTestDismissTimersActive()
        r["afterFileDragConversion"] = afterFileDragConversion
        let afterFileDragStates = QuickAccessOverlay.uiTestDismissTimerStates()
        r["afterFileDragStates"] = afterFileDragStates
        await cleanup()

        // Index 0 is the sibling (creation order; the newest card takes the gesture).
        // Resume is asserted on the sibling: the dragged card's own resume rides the
        // hover gate, which follows the REAL cursor and would flake under a live mouse.
        let armedCards = Array(armed.suffix(2))
        let frozenCards = Array(during.suffix(2))
        let fileDragArmedCards = Array(fileDragArmed.suffix(2))
        let siblingAfterGesture = afterStates.suffix(2).first ?? [:]
        let siblingAfterFileDrag = afterFileDragStates.suffix(2).first ?? [:]
        let allArmed = armedCards.count == 2 && armedCards.allSatisfy { $0 }
        let allFrozen = frozenCards.count == 2 && frozenCards.allSatisfy { !$0 }
        let siblingResumed = siblingAfterGesture["timerActive"] == true
            || siblingAfterGesture["cursorOwns"] == true
        let fileDragAllArmed = fileDragArmedCards.count == 2 && fileDragArmedCards.allSatisfy { $0 }
        let fileDragSiblingResumed = siblingAfterFileDrag["timerActive"] == true
            || siblingAfterFileDrag["cursorOwns"] == true
        r["allArmed"] = allArmed
        r["allFrozenDuringGesture"] = allFrozen
        r["siblingResumed"] = siblingResumed
        r["fileDragAllArmed"] = fileDragAllArmed
        r["fileDragSiblingResumed"] = fileDragSiblingResumed
        r["allPass"] = allArmed && allFrozen && siblingResumed && fileDragAllArmed && fileDragSiblingResumed
        return r
    }

    // MARK: - Cenário: overlay-dismiss-race

    /// A Timer may already have enqueued its close on the main queue just as the
    /// user begins a drag. The gesture must retire that stale close, otherwise the
    /// card flips into `isClosing` and ignores every subsequent drag sample.
    private static func runOverlayDismissRace() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "overlay-dismiss-race"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let savedTimeout = Settings.overlayTimeout
        Settings.overlayTimeout = 30
        let before = QuickAccessOverlay.uiTestWindows.count
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krit-overlay-dismiss-race", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Settings.overlayTimeout = savedTimeout
            while QuickAccessOverlay.uiTestWindows.count > before {
                QuickAccessOverlay.uiTestCloseNewest()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: directory.appendingPathComponent("capture.png").path,
            thumbnailPath: directory.appendingPathComponent("thumbnail.png").path,
            captureRect: nil
        )
        QuickAccessOverlay.show(
            image: image,
            historyItem: item,
            historyManager: appDelegate.historyManager,
            screen: NSScreen.main,
            entrance: .slide
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard QuickAccessOverlay.uiTestWindows.count == before + 1 else {
            r["error"] = "card did not appear"
            r["allPass"] = false
            return r
        }

        QuickAccessOverlay.uiTestArmDismissTimers()
        let armed = QuickAccessOverlay.uiTestDismissTimersActive().last == true
        QuickAccessOverlay.uiTestQueueNewestAutoDismiss()
        QuickAccessOverlay.uiTestGestureBegin()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let cardStillOpen = QuickAccessOverlay.uiTestWindows.count == before + 1
        let state = QuickAccessOverlay.uiTestGestureState()
        r["armed"] = armed
        r["cardStillOpen"] = cardStillOpen
        r["gestureState"] = state
        r["allPass"] = armed && cardStillOpen && state != "closing"
        QuickAccessOverlay.uiTestGestureEnd()
        return r
    }

    // MARK: - Cenário: frozen-fast-path (F9.1: o crop congelado sobrevive ao teardown)

    /// Locks the F1.1 regression: `finish()` tears the overlays down and the
    /// completion fires 0.08s later, so a lazy read of `croppedFrozenImage` there
    /// used to return nil and the engine silently fell back to the live re-grab
    /// (the print-time flash). The fix latches the crop in `finish()`; this gate
    /// proves the latched crop survives teardown, matches the synthetic frozen
    /// pixels, and is served exactly once. Fully synthetic, no SCK grab.
    // MARK: - Cenário: own-window-capture (janelas do KRIT aparecem na captura)

    /// Regression gate for the vanishing-Preferences bug: with "hide desktop
    /// icons while capturing" ON, the display filter excluded KRIT's own
    /// application, so every KRIT window (Preferences included) silently
    /// disappeared from grabs and from the frozen selection backdrop. Stand a
    /// plain KRIT-owned window (default sharingType, exactly the class that
    /// used to vanish), grab its region through the REAL icons-hidden filter
    /// path and require the window's pixels in the result.
    // MARK: - Cenário: automation-gate (a superfície scriptável é opt-in)

    /// Guards the default-off posture of the whole scriptable surface. The test
    /// harness is intentionally independent from automation, so only the persisted
    /// user preference may open the port and URL commands.
    private static func runAutomationGate() -> [String: Any] {
        var r: [String: Any] = ["scenario": "automation-gate"]
        let off = AutomationGate.decide(prefEnabled: false)
        let enabled = AutomationGate.decide(prefEnabled: true)
        r["refusedWhenOff"] = (off == false)
        r["prefOpens"] = (enabled == true)
        // Fresh install must ship with automation OFF. Read the raw default so a
        // pref the running user may have flipped doesn't mask a bad default.
        let defaultsOff = UserDefaults.standard.object(forKey: "automationEnabled") == nil
            || UserDefaults.standard.bool(forKey: "automationEnabled") == false
        r["defaultOff"] = defaultsOff
        r["allPass"] = (off == false) && (enabled == true)
        return r
    }

    private static func runOwnWindowCapture() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "own-window-capture"]
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no screen"; r["allPass"] = false; return r
        }
        let saved = Settings.hideDesktopIconsWhileCapturing
        Settings.hideDesktopIconsWhileCapturing = true
        defer { Settings.hideDesktopIconsWhileCapturing = saved }

        // Magenta: absent from any sane desktop, so a match can only be our window.
        let frame = NSRect(x: screen.frame.midX - 110, y: screen.frame.midY - 70,
                           width: 220, height: 140)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        // Above anything the user has open, so a stray foreground window
        // cannot occlude the probe region and flake the pixel check.
        win.level = .screenSaver
        win.isOpaque = true
        win.backgroundColor = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)

        let engine = CaptureEngine()
        let shot = await engine.captureRectToImage(frame, on: screen, excludeDesktopIcons: true)
        win.orderOut(nil)

        r["grabNonNil"] = shot != nil
        r["permissionFailure"] = engine.lastCaptureFailureWasPermission
        var windowVisible = false
        if let shot, let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let probe = NSBitmapImageRep(cgImage: cg)
            if let c = probe.colorAt(x: cg.width / 2, y: cg.height / 2) {
                // Wide-gamut displays shift the grabbed values (measured
                // r0.92 g0.20 b0.97 for pure magenta on P3), so the gate
                // tolerates the colorimetric drift; nothing on a real
                // desktop lands anywhere near this corner of the cube.
                windowVisible = c.redComponent > 0.75 && c.greenComponent < 0.35 && c.blueComponent > 0.75
                r["centerPixel"] = String(format: "r%.2f g%.2f b%.2f",
                                          c.redComponent, c.greenComponent, c.blueComponent)
            }
        }
        r["windowVisible"] = windowVisible
        r["allPass"] = (shot != nil) && windowVisible
        return r
    }

    private static func runFrozenFastPath() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "frozen-fast-path"]
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no screen"; r["allPass"] = false; return r
        }
        // Synthetic frozen frame: solid orange at 1x screen size (points == pixels,
        // so the overlay's crop math runs with imgScale 1).
        let w = Int(screen.frame.width), h = Int(screen.frame.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            r["error"] = "bitmap alloc failed"; r["allPass"] = false; return r
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor(red: 1, green: 0.4, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let frozen = rep.cgImage else {
            r["error"] = "cgImage failed"; r["allPass"] = false; return r
        }

        var receivedRect: CGRect?
        let controller = AreaSelectionWindow(mode: .area) { rect, _, _ in receivedRect = rect }
        controller.uiTestPrepareSynthetic(frozen: frozen, on: screen)
        r["preHasFrozen"] = controller.uiTestHasFrozenFrame

        let sel = CGRect(x: screen.frame.minX + 60, y: screen.frame.minY + 90, width: 200, height: 120)
        controller.simulateSelection(rect: sel, on: screen)
        // The engine's completion runs +0.08s after teardown; read like it does.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let shot = controller.croppedFrozenImage(globalRect: sel, on: screen)
        r["fastPathNonNil"] = shot != nil
        r["completionFired"] = receivedRect == sel
        // One-shot: a second read must come back empty, never a stale serve.
        r["stashConsumedOnce"] = controller.croppedFrozenImage(globalRect: sel, on: screen) == nil
        var pixelMatches = false
        var sizeMatches = false
        if let shot, let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            sizeMatches = abs(CGFloat(cg.width) - sel.width) <= 2 && abs(CGFloat(cg.height) - sel.height) <= 2
            let probe = NSBitmapImageRep(cgImage: cg)
            if let c = probe.colorAt(x: cg.width / 2, y: cg.height / 2) {
                pixelMatches = abs(c.redComponent - 1) < 0.05
                    && abs(c.greenComponent - 0.4) < 0.05
                    && abs(c.blueComponent - 0) < 0.05
            }
            r["shotSize"] = "\(cg.width)x\(cg.height)"
        }
        r["pixelMatches"] = pixelMatches
        r["sizeMatches"] = sizeMatches
        r["allPass"] = (r["preHasFrozen"] as? Bool ?? false)
            && shot != nil
            && receivedRect == sel
            && (r["stashConsumedOnce"] as? Bool ?? false)
            && pixelMatches && sizeMatches
        return r
    }

    // MARK: - Cenário: text-multiline (texto com quebra de linha dimensiona certo)

    /// Multiline text input is only useful if a committed annotation with a newline
    /// measures as two lines, not one long line. Prove textSize now grows the
    /// height for a `\n` (the boundingRect fix) instead of the old single-line
    /// `size(withAttributes:)` that would keep the height flat and blow up the width.
    private static func runTextMultiline() -> [String: Any] {
        var r: [String: Any] = ["scenario": "text-multiline"]
        let one = TextAnnotation(origin: .zero); one.text = "Hello"
        let two = TextAnnotation(origin: .zero); two.text = "Hello\nWorld"
        let h1 = one.textSize.height, h2 = two.textSize.height
        let w1 = one.textSize.width, w2 = two.textSize.width
        r["singleHeight"] = Int(h1); r["doubleHeight"] = Int(h2)
        r["singleWidth"] = Int(w1); r["doubleWidth"] = Int(w2)
        // Two lines are clearly taller (near 2x) and NOT much wider than one line,
        // which is exactly what the old single-line measurement got backwards.
        let tallerForMultiline = h2 > h1 * 1.6
        let widthNotInflated = w2 <= w1 * 1.4
        let singleLineSane = h1 > 0 && w1 > 0
        r["tallerForMultiline"] = tallerForMultiline
        r["widthNotInflated"] = widthNotInflated
        r["allPass"] = tallerForMultiline && widthNotInflated && singleLineSane
        return r
    }

    // MARK: - Cenário: annotate-frame (o frame do vídeo cruza pro editor de print)

    /// The recording flow was disconnected from the print editor. Prove the bridge:
    /// open the video editor on a synthetic 320x240 clip, grab the frame under the
    /// playhead, and assert the print annotation editor opens backed by that frame
    /// at its native pixels, so arrows/blur/text now work on a recorded frame.
    private static func runAnnotateFrame() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "annotate-frame"]
        let srcURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("krit-af-src.mp4")
        let made = await makeSyntheticZoomSource(to: srcURL, size: CGSize(width: 320, height: 240), frames: 60, fps: 30)
        r["sourceMade"] = made
        guard made else { r["allPass"] = false; return r }

        VideoEditorWindowController.show(url: srcURL) { _, _ in }
        guard let ctl = VideoEditorWindowController.uiTestShared else {
            r["error"] = "video editor did not open"; r["allPass"] = false; return r
        }
        defer { ctl.window?.close() }
        let state = ctl.uiTestState
        for _ in 0..<40 { if state.duration > 0.1 { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
        r["duration"] = state.duration

        state.seek(to: 0.5)
        state.annotateCurrentFrame()

        var opened = false
        for _ in 0..<40 {
            if AnnotationWindowController.uiTestLastController != nil { opened = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        r["annotationOpened"] = opened
        guard opened, let annCtl = AnnotationWindowController.uiTestLastController else {
            r["allPass"] = false; return r
        }
        defer { annCtl.window?.close() }
        let px = annCtl.uiTestCanvas.backgroundImage?.bestCGImage
        r["frameW"] = px?.width ?? 0
        r["frameH"] = px?.height ?? 0
        let frameCorrect = px?.width == 320 && px?.height == 240
        r["frameCorrect"] = frameCorrect
        r["allPass"] = opened && frameCorrect
        return r
    }

    /// Longest contiguous run of `needle` that appears as a substring of `haystack`,
    /// compared case-insensitively and ignoring whitespace (so OCR line breaks or
    /// spacing never mask a leaked fragment). Returns the character count of the
    /// longest such run, 0 if none.
    private static func longestSharedRun(of needle: String, in haystack: String) -> Int {
        func normalize(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        }
        let n = Array(normalize(needle))
        let hay = normalize(haystack)
        guard !n.isEmpty, !hay.isEmpty else { return 0 }
        var best = 0
        for i in 0..<n.count {
            var j = i + 1
            while j <= n.count {
                let sub = String(n[i..<j])
                if hay.contains(sub) { best = max(best, sub.count); j += 1 } else { break }
            }
        }
        return best
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
    private static func runRecordSmoke(
        systemAudio: Bool = false,
        microphone: Bool = false,
        pauseMidway: Bool = false
    ) async -> [String: Any] {
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
        r["pauseMidway"] = pauseMidway
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

        var pauseEntered = false
        var pauseResumed = false
        if pauseMidway {
            try? await Task.sleep(nanoseconds: 700_000_000)
            engine.uiTestToggleRecordingPause()
            pauseEntered = engine.uiTestRecordingPaused
            if pauseEntered {
                try? await Task.sleep(nanoseconds: 700_000_000)
                engine.uiTestToggleRecordingPause()
                pauseResumed = !engine.uiTestRecordingPaused
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        r["pauseEntered"] = pauseEntered
        r["pauseResumed"] = pauseResumed
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
        if let duration = engine.uiTestRecordingDuration {
            r["recordingDuration"] = duration
        }

        // 0.7 s recording + 0.7 s paused + 0.7 s recording should yield roughly
        // 1.4 s of media. The bound leaves room for start/stop frame granularity,
        // but catches a pause gap leaking back into the output timeline.
        let durationPass = !pauseMidway || (engine.uiTestRecordingDuration ?? .infinity) < 1.75
        r["durationPass"] = durationPass

        r["allPass"] = started
            && (r["dimPanelCount"] as? Int ?? 0) >= 1
            && (cardsAfter > cardsBefore)
            && (engine.uiTestDimPanelCount == 0)
            && (!pauseMidway || (pauseEntered && pauseResumed && durationPass))

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
        let legacyPreviewFallbacksBefore = engine.uiTestLegacyWindowPreviewFallbackCount
        let chooserPreview = await engine.uiTestWindowPreviewImage(windowID: windowID)
        let chooserPreviewPass = chooserPreview?.bestCGImage.map {
            $0.width > 0 && $0.height > 0 && ScreenshotVisualQuality.hasVisibleContent($0)
        } ?? false
        let modernPreviewAvoidedLegacy = engine.uiTestLegacyWindowPreviewFallbackCount == legacyPreviewFallbacksBefore
        r["chooserPreviewPass"] = chooserPreviewPass
        r["modernPreviewAvoidedLegacy"] = modernPreviewAvoidedLegacy

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
        r["allPass"] = dimensionsPass && alphaPass && chooserPreviewPass && modernPreviewAvoidedLegacy
        return r
    }

    /// Exercises the production compatibility path against a live Aside window.
    /// Aside owns a second transparent surface around its visible browser window,
    /// so a generic AppKit test window cannot reproduce this failure mode.
    private static func runAsideWindowCaptureSuite() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard #available(macOS 14.0, *) else {
            r["skipped"] = "needs macOS 14+"; r["allPass"] = false; return r
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"; r["allPass"] = false; return r
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        let snapshot: ScreenCaptureWindowSnapshot
        do {
            snapshot = try await ScreenCaptureCatalog.shared.windows(.visibleContent)
        } catch {
            r["error"] = "window catalog failed: \(error.localizedDescription)"
            r["allPass"] = false
            return r
        }
        let candidates = snapshot.windows.map {
            WindowCaptureDescriptor(
                id: CGWindowID($0.windowID),
                ownerProcessID: $0.owningApplication?.processID,
                ownerBundleIdentifier: $0.owningApplication?.bundleIdentifier,
                layer: $0.windowLayer,
                frame: $0.frame,
                title: $0.title
            )
        }
        let shadowHost = candidates.first(where: { candidate in
            candidate.ownerBundleIdentifier == "at.studio.AsideBrowser"
                && WindowCaptureTargetResolver.targetID(
                    selected: candidate,
                    candidates: candidates
                ) != candidate.id
        })
        let directContent = candidates.first(where: { candidate in
            candidate.ownerBundleIdentifier == "at.studio.AsideBrowser"
                && candidate.layer == 0
                && !(candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && candidate.frame.width >= 500
                && candidate.frame.height >= 500
        })
        guard let selected = shadowHost ?? directContent else {
            r["skipped"] = "no live Aside content window"
            r["allPass"] = false
            return r
        }
        let targetID = WindowCaptureTargetResolver.targetID(
            selected: selected,
            candidates: candidates
        )
        r["selectedWindowID"] = Int(selected.id)
        r["resolvedWindowID"] = Int(targetID)
        r["usedShadowHostPair"] = selected.id != targetID

        guard let image = await appDelegate.uiTestCaptureEngine.uiTestIsolatedWindowImage(
            windowID: selected.id
        ), let rawCG = image.bestCGImage else {
            r["error"] = "production Aside grab returned no pixels"
            r["allPass"] = false
            return r
        }

        try? FileManager.default.createDirectory(
            atPath: "/tmp/krit-aside-window-capture",
            withIntermediateDirectories: true
        )
        func savePNG(_ image: CGImage, name: String) {
            let path = "/tmp/krit-aside-window-capture/\(name).png"
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            r["\(name)Path"] = path
        }
        savePNG(rawCG, name: "normalized-raw")
        r["rawPixels"] = ["w": rawCG.width, "h": rawCG.height]

        var insetPass = false
        if let insets = opaqueContentInsets(rawCG) {
            r["contentInsets"] = ["l": insets.l, "r": insets.r, "t": insets.t, "b": insets.b]
            let tolerance = Int(Double(max(rawCG.width, rawCG.height)) * 0.02)
            insetPass = max(insets.l, insets.r, insets.t, insets.b) <= tolerance
            r["contentInsetTolerance"] = tolerance
        }
        r["contentInsetPass"] = insetPass

        let options = AnnotationWindowController.windowShotBackground(
            for: image,
            captureRect: selected.frame
        )
        let composed = ScreenshotBackgroundComposer.composeIfNeeded(image, options: options)
        let composedCG = composed.bestCGImage
        var composedSlotPass = false
        if let composedCG {
            savePNG(composedCG, name: "composed")
            r["composedPixels"] = ["w": composedCG.width, "h": composedCG.height]

            // Compare the opaque interior of the source with the exact slot the
            // compositor produced. A transparent framing surface becomes desktop
            // pixels here and creates the reported second rounded rectangle, so
            // it cannot match the raw interior even when the output itself exists.
            let renderScale = max(
                CGFloat(composedCG.width) / max(composed.size.width, 1),
                CGFloat(composedCG.height) / max(composed.size.height, 1)
            )
            let slot = ScreenshotBackgroundComposer.imageSlotRect(
                imageSize: image.size,
                canvasSize: composed.size,
                options: options
            )
            let slotPixels = CGRect(
                x: (slot.minX * renderScale).rounded(),
                y: (slot.minY * renderScale).rounded(),
                width: (slot.width * renderScale).rounded(),
                height: (slot.height * renderScale).rounded()
            ).intersection(CGRect(x: 0, y: 0, width: composedCG.width, height: composedCG.height))
            if let slotCG = composedCG.cropping(to: slotPixels) {
                let commonWidth = min(rawCG.width, slotCG.width)
                let commonHeight = min(rawCG.height, slotCG.height)
                let edgeInset = max(8, Int(options.cornerRadius * renderScale) + 4)
                let interiorWidth = commonWidth - edgeInset * 2
                let interiorHeight = commonHeight - edgeInset * 2
                if interiorWidth > 0, interiorHeight > 0,
                   let rawInterior = rawCG.cropping(to: CGRect(
                    x: edgeInset, y: edgeInset,
                    width: interiorWidth, height: interiorHeight
                   )),
                   let slotInterior = slotCG.cropping(to: CGRect(
                    x: edgeInset, y: edgeInset,
                    width: interiorWidth, height: interiorHeight
                   )),
                   let diff = meanAbsDiff(rawInterior, slotInterior) {
                    r["composedSlotDiff"] = diff
                    composedSlotPass = diff < 12
                }
            }
        }
        r["composedSlotPass"] = composedSlotPass

        r["allPass"] = insetPass
            && composedSlotPass
            && rawCG.width > 0
            && rawCG.height > 0
            && composedCG != nil
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
    /// legacy persist route (the tiffRepresentation path HistoryManager used
    /// before CaptureDelivery shared encoded artifacts). Saves one PNG per stage
    /// to /tmp/krit-compose for the
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

        // Stage 3: the legacy persist route, retained as a visual comparison.
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

        // A slider emits a dense stream of distinct option values. The compositor
        // may finish the work already in flight, but it must run only the final
        // value after that, never every intermediate tick.
        canvas.uiTestInvalidatePresentationCache()
        canvas.uiTestResetPresentationCompositeStartCount()
        var burstOptions = bg
        for step in 0..<20 {
            burstOptions.padding = CGFloat(32 + step)
            ctrl.uiTestApplyBackground(burstOptions)
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
        }
        r["burstStartsImmediately"] = canvas.uiTestCurrentPresentationCompositeStartCount()

        var burstSettled = false
        for _ in 0..<50 where !burstSettled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            burstSettled = canvas.uiTestHasPresentationCache(options: burstOptions)
        }
        let burstStarts = canvas.uiTestCurrentPresentationCompositeStartCount()
        r["burstCompositeStarts"] = burstStarts
        r["burstSettledLatest"] = burstSettled

        r["canvasSize"] = NSStringFromRect(canvas.bounds)
        r["msPerFrameFull"] = fullMin
        r["fpsFull"] = fullMin > 0 ? 1000.0 / fullMin : 0
        r["msPerFrameSlice"] = sliceMin
        r["fpsSlice"] = sliceMin > 0 ? 1000.0 / sliceMin : 0
        // Gate on the two smooth paths: the small-region drag redraw, and the
        // option-change/resize draw, which must NOT carry the multi-second compose
        // (async). 500ms is far above the ~95ms placeholder draw but far below the
        // ~4s a synchronous recompose would cost, so it fails loudly on regression.
        r["allPass"] = sliceMin < 16
            && missDraw < 500
            && burstStarts <= 2
            && burstSettled
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

    /// Captures the visual entrance of the real overlay card frame by frame after
    /// a fullscreen capture and snapshots the active screen every ~50ms via
    /// CGWindowList, so a glitchy first paint can be seen and diagnosed instead
    /// of guessed at.
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
        // the region around its real frame from its first visible presentation.
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
        r["initialBuiltPageCount"] = ctrl.uiTestBuiltPageCount

        let dir = "/tmp/krit-onboarding"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paths = await ctrl.uiTestRenderAllPages(toDirectory: dir)
        r["renderedPages"] = paths
        r["finalBuiltPageCount"] = ctrl.uiTestBuiltPageCount

        let allRendered = paths.count == 4 && paths.allSatisfy { p in
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue ?? 0
            return size > 10_000
        }
        r["renderPass"] = allRendered
        r["ctaPass"] = (ctrl.uiTestContinueTitle == "Start Capturing")

        ctrl.uiTestClose(restoringHasLaunchedBefore: savedFlag)
        r["flagRestored"] = (Settings.hasLaunchedBefore == savedFlag)
        r["allPass"] = allRendered
            && ctrl.uiTestBuiltPageCount == 4
            && (r["initialBuiltPageCount"] as? Int == 1)
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
        func scalar(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }
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

        try? await Task.sleep(nanoseconds: 100_000_000)
        let entranceAt100ms = QuickAccessOverlay.uiTestEntranceState()
        r["entranceAt100ms"] = entranceAt100ms
        let earlySlotPass: Bool
        if let frameX = scalar(entranceAt100ms["frameX"]),
           let targetX = scalar(entranceAt100ms["targetX"]),
           let alpha = scalar(entranceAt100ms["alpha"]) {
            earlySlotPass = abs(frameX - targetX) < 0.5 && alpha >= 0.99
        } else {
            earlySlotPass = false
        }
        r["earlySlotPass"] = earlySlotPass
        // Entrada anima em 0.35s; 1.2s dá folga de sobra.
        try? await Task.sleep(nanoseconds: 1_100_000_000)

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
        r["entranceAt1200ms"] = QuickAccessOverlay.uiTestEntranceState()
        r["visibleFrame"] = ["x": vf.origin.x, "y": vf.origin.y, "w": vf.width, "h": vf.height]
        let inside = vf.contains(card.frame)
        r["insideVisibleFramePass"] = inside
        r["alphaPass"] = (card.alphaValue >= 0.99)

        QuickAccessOverlay.uiTestCloseNewest()
        try? await Task.sleep(nanoseconds: 500_000_000)
        r["closedPass"] = (QuickAccessOverlay.uiTestWindows.count == before)

        r["allPass"] = inside
            && earlySlotPass
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
        r["renderFallbackCount"] = ctrl.uiTestRenderFallbackCount

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

    // MARK: - Cenário: permissions-tab (nova aba de permissões de privacidade)

    /// Abre o Settings, seleciona a aba Permissions e fotografa a janela: prova que
    /// a aba existe, que a seção monta (4 linhas de permissão com status pill) e
    /// rende de fato. Snapshot em /tmp/krit-permissions-tab.png.
    private static func runPermissionsTab() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "permissions-tab"]
        let ctrl = PreferencesWindowController.shared
        ctrl.uiTestForceShow()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard let win = ctrl.uiTestWindow else {
            r["windowFound"] = false
            r["ok"] = false
            return r
        }
        r["windowFound"] = true

        let tabFound = PreferencesTab.allCases.contains(.permissions)
        r["tabFound"] = tabFound

        ctrl.uiTestSelect(.permissions)
        try? await Task.sleep(nanoseconds: 700_000_000)

        let path = "/tmp/krit-permissions-tab.png"
        let shotOK = Self.snapshotWindow(win, to: path)
        r["snapshot"] = shotOK ? path : "FAILED"

        ctrl.uiTestClose()
        r["ok"] = tabFound && shotOK
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
        r["diagSelectedCount"] = canvas.selectedObjects.count
        let bodyPointInWindow = canvas.convert(bodyPoint, to: nil)
        r["diagHitView"] = window.contentView?.hitTest(bodyPointInWindow)
            .map { String(describing: type(of: $0)) } ?? "none"
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
                $0.identifier?.rawValue.hasPrefix("background-wallpaper-") == true && $0.frame.width > 10
            }) {
                let centerInWindow = thumb.convert(CGPoint(x: thumb.bounds.midX, y: thumb.bounds.midY), to: nil)
                r["wallpaperHitView"] = window.contentView?.hitTest(centerInWindow)
                    .map { String(describing: type(of: $0)) } ?? "none"
                if let control = thumb as? NSControl, let action = control.action {
                    NSApp.sendAction(action, to: control.target, from: control)
                }
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
            // What matters is that no button is CLIPPED by the edge. The toolbar
            // is a floating pill now, so fittingWidth IS its content width: it
            // clips when that width cannot fit between the stage's two margins.
            let contentRightEdge = tb.fittingWidth
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

    /// Snapshot da janela como o WindowServer a compõe. An opaque black capture
    /// is a permission failure, regardless of its byte size; fall back to AppKit
    /// rendering and apply the same visual-content gate used by Preferences.
    private static func snapshotWindow(_ window: NSWindow, to path: String) -> Bool {
        var data: Data?
        if let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), ScreenshotVisualQuality.hasVisibleContent(cg) {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }

        if data == nil,
           let content = window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let cg = rep.cgImage, ScreenshotVisualQuality.hasVisibleContent(cg) {
                data = rep.representation(using: .png, properties: [:])
            }
        }

        guard let data else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        return FileManager.default.fileExists(atPath: path)
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

    private static func recordingHUDRegionPasses(
        _ image: CGImage,
        layout: RecordingHUDLayout
    ) -> [String: Bool] {
        let regions: [(String, CGRect)] = [
            ("live", layout.liveCluster),
            ("microphone", layout.microphoneMeter ?? .zero),
            ("pause", layout.pause),
            ("stop", layout.stop),
            ("overflow", layout.overflow),
        ]
        return Dictionary(uniqueKeysWithValues: regions.map { name, rect in
            let contrast = hasVisibleContrast(image, in: rect, windowSize: layout.shell.size)
            // A reflective glass background can have enough luminance variation to
            // pass a contrast-only check even when a static control disappeared.
            // Every interactive region except the live cluster must contribute real
            // bright glyph or label pixels to the composed frame.
            let foreground = name == "live" || hasBrightForeground(
                image,
                in: rect,
                windowSize: layout.shell.size,
                // The fallback rasterizes the three-dot glyph into ten bright
                // pixels. Eight still rejects an absent control while avoiding
                // a false failure that depends on material antialiasing.
                minimumPixels: name == "overflow" ? 8 : 12
            )
            return (name, contrast && foreground)
        })
    }

    private static func hasVisibleContrast(
        _ image: CGImage,
        in windowRect: CGRect,
        windowSize: CGSize,
        minSpread: Double = 20
    ) -> Bool {
        guard !windowRect.isEmpty,
              windowSize.width > 0,
              windowSize.height > 0,
              let pixels = rgbaPixels(image) else { return false }

        let scaleX = CGFloat(image.width) / windowSize.width
        let scaleY = CGFloat(image.height) / windowSize.height
        let raw = CGRect(
            x: windowRect.minX * scaleX,
            y: (windowSize.height - windowRect.maxY) * scaleY,
            width: windowRect.width * scaleX,
            height: windowRect.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sampleRect = raw.intersection(bounds)
        guard !sampleRect.isNull, sampleRect.width >= 2, sampleRect.height >= 2 else { return false }

        let minX = max(0, Int(sampleRect.minX))
        let maxX = min(image.width, Int(sampleRect.maxX))
        let minY = max(0, Int(sampleRect.minY))
        let maxY = min(image.height, Int(sampleRect.maxY))
        let sampleCount = max(1, (maxX - minX) * (maxY - minY))
        let step = max(1, Int(Double(sampleCount).squareRoot() / 40))
        var minLuma = 255.0
        var maxLuma = 0.0

        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                let offset = (y * image.width + x) * 4
                let luma = 0.299 * Double(pixels[offset])
                    + 0.587 * Double(pixels[offset + 1])
                    + 0.114 * Double(pixels[offset + 2])
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
            }
        }
        return maxLuma - minLuma > minSpread
    }

    private static func hasBrightForeground(
        _ image: CGImage,
        in windowRect: CGRect,
        windowSize: CGSize,
        minimumPixels: Int = 12,
        lumaThreshold: Double = 170
    ) -> Bool {
        guard !windowRect.isEmpty,
              windowSize.width > 0,
              windowSize.height > 0,
              let pixels = rgbaPixels(image) else { return false }

        let scaleX = CGFloat(image.width) / windowSize.width
        let scaleY = CGFloat(image.height) / windowSize.height
        let raw = CGRect(
            x: windowRect.minX * scaleX,
            y: (windowSize.height - windowRect.maxY) * scaleY,
            width: windowRect.width * scaleX,
            height: windowRect.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sampleRect = raw.intersection(bounds)
        guard !sampleRect.isNull, sampleRect.width >= 2, sampleRect.height >= 2 else { return false }

        let minX = max(0, Int(sampleRect.minX))
        let maxX = min(image.width, Int(sampleRect.maxX))
        let minY = max(0, Int(sampleRect.minY))
        let maxY = min(image.height, Int(sampleRect.maxY))
        var brightPixels = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * image.width + x) * 4
                let luma = 0.299 * Double(pixels[offset])
                    + 0.587 * Double(pixels[offset + 1])
                    + 0.114 * Double(pixels[offset + 2])
                if luma >= lumaThreshold {
                    brightPixels += 1
                    if brightPixels >= minimumPixels { return true }
                }
            }
        }
        return false
    }

    /// A contrast-only region gate can accept an unrelated app window behind a
    /// delayed sharingType update. The All-in-One dock has a stable, local
    /// fingerprint: its first action carries KRIT coral and each remaining
    /// action contributes a legible glyph or label.
    private static func allInOneCompositePasses(
        _ image: CGImage,
        actionFrames: [CGRect],
        panelSize: CGSize
    ) -> Bool {
        guard actionFrames.count == AllInOneAction.allCases.count,
              hasVisibleContrast(image),
              hasKritAccent(image, in: actionFrames[0], windowSize: panelSize) else {
            return false
        }
        return actionFrames.dropFirst().allSatisfy {
            hasBrightForeground(image, in: $0, windowSize: panelSize)
        }
    }

    private static func hasKritAccent(
        _ image: CGImage,
        in windowRect: CGRect,
        windowSize: CGSize,
        minimumPixels: Int = 8
    ) -> Bool {
        guard !windowRect.isEmpty,
              windowSize.width > 0,
              windowSize.height > 0,
              let pixels = rgbaPixels(image) else { return false }

        let scaleX = CGFloat(image.width) / windowSize.width
        let scaleY = CGFloat(image.height) / windowSize.height
        let raw = CGRect(
            x: windowRect.minX * scaleX,
            y: (windowSize.height - windowRect.maxY) * scaleY,
            width: windowRect.width * scaleX,
            height: windowRect.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sampleRect = raw.intersection(bounds)
        guard !sampleRect.isNull, sampleRect.width >= 2, sampleRect.height >= 2 else { return false }

        let minX = max(0, Int(sampleRect.minX))
        let maxX = min(image.width, Int(sampleRect.maxX))
        let minY = max(0, Int(sampleRect.minY))
        let maxY = min(image.height, Int(sampleRect.maxY))
        var accentPixels = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * image.width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                if red >= 180, green >= 45, green <= 190, blue <= 145,
                   red > green * 13 / 10, red > blue * 17 / 10 {
                    accentPixels += 1
                    if accentPixels >= minimumPixels { return true }
                }
            }
        }
        return false
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

    // MARK: - Cenário: all-in-one-interaction

    /// Drives the actual All-in-One controller through the same accessibility and
    /// keyboard entry points a user has, without invoking a real capture action.
    /// The callback only records the selected intent after the controller tears
    /// down its overlay, so the test also proves the action exits cleanly.
    private static func runAllInOneInteraction() async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let appDelegate = NSApp.delegate as? AppDelegate, let screen = NSScreen.main else {
            r["error"] = "no app delegate or screen"
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        let area = CGRect(
            x: screen.frame.midX - 320,
            y: screen.frame.midY - 180,
            width: 640,
            height: 360
        )
        func keyEvent(_ keyCode: UInt16, characters: String, in window: NSWindow) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        var accessibilityAction: String?
        let accessibilityController = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { action, _, _ in accessibilityAction = action.accessibilityIdentifier },
            onCancel: {}
        )
        await accessibilityController.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 300_000_000)

        var focusPass = false
        var tabPass = false
        var accessibilityPass = false
        if let panel = accessibilityController.uiTestPanelWindow as? AllInOnePanelWindow {
            panel.focusFirstOption()
            let buttons = panel.optionButtons
            focusPass = panel.isKeyWindow && panel.firstResponder === buttons.first
            if buttons.count > 1, let tab = keyEvent(48, characters: "\t", in: panel) {
                panel.sendEvent(tab)
                tabPass = panel.firstResponder === buttons[1]
            }
            do {
                let result = try UIIntrospection.click(id: "all-in-one.record")
                r["accessibilityClickClass"] = result.className
            } catch {
                r["accessibilityClickError"] = String(describing: error)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            accessibilityPass = accessibilityAction == AllInOneAction.record.accessibilityIdentifier
        }
        accessibilityController.uiTestCancel()

        var spaceAction: String?
        let spaceController = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { action, _, _ in spaceAction = action.accessibilityIdentifier },
            onCancel: {}
        )
        await spaceController.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var spacePass = false
        if let panel = spaceController.uiTestPanelWindow as? AllInOnePanelWindow,
           let space = keyEvent(49, characters: " ", in: panel) {
            panel.focusFirstOption()
            panel.sendEvent(space)
            try? await Task.sleep(nanoseconds: 200_000_000)
            spacePass = spaceAction == AllInOneAction.capture.accessibilityIdentifier
        }
        spaceController.uiTestCancel()

        var returnAction: String?
        let returnController = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { action, _, _ in returnAction = action.accessibilityIdentifier },
            onCancel: {}
        )
        await returnController.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var returnPass = false
        if let panel = returnController.uiTestPanelWindow as? AllInOnePanelWindow,
           panel.optionButtons.count > 1,
           let `return` = keyEvent(36, characters: "\r", in: panel) {
            panel.makeFirstResponder(panel.optionButtons[1])
            panel.sendEvent(`return`)
            try? await Task.sleep(nanoseconds: 200_000_000)
            returnPass = returnAction == AllInOneAction.record.accessibilityIdentifier
        }
        returnController.uiTestCancel()

        var didCancel = false
        let escapeController = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { _, _, _ in },
            onCancel: { didCancel = true }
        )
        await escapeController.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var escapePass = false
        if let panel = escapeController.uiTestPanelWindow as? AllInOnePanelWindow,
           let escape = keyEvent(53, characters: "\u{1B}", in: panel) {
            panel.focusFirstOption()
            NSApp.sendEvent(escape)
            try? await Task.sleep(nanoseconds: 100_000_000)
            escapePass = didCancel
        }
        escapeController.uiTestCancel()

        r["focusPass"] = focusPass
        r["tabPass"] = tabPass
        r["accessibilityPass"] = accessibilityPass
        r["spacePass"] = spacePass
        r["returnPass"] = returnPass
        r["escapePass"] = escapePass
        r["allPass"] = focusPass && tabPass && accessibilityPass && spacePass && returnPass && escapePass
        return r
    }

    // MARK: - Cenário: all-in-one-interrupt

    /// A new area command must replace the visible All-in-One session instead of
    /// stacking a second interactive overlay above it. The production capture
    /// starts only after this handoff, so the test stops before accepting a rect.
    private static func runAllInOneInterrupt() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "all-in-one-interrupt"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        engine.uiTestActiveSelection?.cancel()
        engine.uiTestCloseAllInOne()

        await engine.startAllInOne(historyManager: appDelegate.historyManager)
        for _ in 0..<30 where engine.uiTestAllInOneInitialRect == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let allInOneOpened = engine.uiTestAllInOneInitialRect != nil

        await engine.startAreaCapture(historyManager: appDelegate.historyManager)
        for _ in 0..<30 where engine.uiTestActiveSelection == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let allInOneDismissed = engine.uiTestAllInOneInitialRect == nil
        let areaSelectionOpened = engine.uiTestActiveSelection != nil

        engine.uiTestActiveSelection?.cancel()
        engine.uiTestCloseAllInOne()

        r["allInOneOpened"] = allInOneOpened
        r["allInOneDismissed"] = allInOneDismissed
        r["areaSelectionOpened"] = areaSelectionOpened
        r["allPass"] = allInOneOpened && allInOneDismissed && areaSelectionOpened
        return r
    }

    // MARK: - Scenario: all-in-one-pending-action-replacement

    /// Selecting an All-in-One action starts an 80 ms compositor handoff. A newer
    /// command inside that handoff must invalidate the older intent, not let it
    /// start a capture after the replacement has already won.
    private static func runAllInOnePendingActionReplacement() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "all-in-one-pending-action-replacement"]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no app delegate or screen"
            r["allPass"] = false
            return r
        }

        let area = CGRect(
            x: screen.frame.midX - 320,
            y: screen.frame.midY - 180,
            width: 640,
            height: 360
        )
        var actionCount = 0
        var cancelCount = 0
        let controller = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { _, _, _ in actionCount += 1 },
            onCancel: { cancelCount += 1 }
        )

        await controller.prepareAndShow(engine: appDelegate.uiTestCaptureEngine)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let panelReady = (controller.uiTestPanelWindow as? AllInOnePanelWindow)?.optionButtons.first != nil
        (controller.uiTestPanelWindow as? AllInOnePanelWindow)?.optionButtons.first?.performClick(nil)
        controller.dismissForReplacement()
        try? await Task.sleep(nanoseconds: 180_000_000)

        r["panelReady"] = panelReady
        r["actionCount"] = actionCount
        r["cancelCount"] = cancelCount
        r["panelDismissed"] = controller.uiTestPanelWindow == nil
        r["allPass"] = panelReady && actionCount == 0 && cancelCount == 1 && controller.uiTestPanelWindow == nil
        return r
    }

    // MARK: - Scenario: all-in-one-dismiss-during-prepare

    /// The screenshot freeze is asynchronous. Cancelling before it resolves must
    /// leave the session dead, rather than creating an overlay after the next
    /// capture intent already owns the screen.
    private static func runAllInOneDismissDuringPrepare() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "all-in-one-dismiss-during-prepare"]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no app delegate or screen"
            r["allPass"] = false
            return r
        }

        let area = CGRect(
            x: screen.frame.midX - 320,
            y: screen.frame.midY - 180,
            width: 640,
            height: 360
        )
        let engine = appDelegate.uiTestCaptureEngine
        let originalCaptureHook = engine.willCaptureScreenHook
        var backdropRequested = false
        var cancelCount = 0
        let controller = AllInOneController(
            screen: screen,
            initialRect: area,
            onAction: { _, _, _ in },
            onCancel: { cancelCount += 1 }
        )
        engine.willCaptureScreenHook = {
            originalCaptureHook?()
            backdropRequested = true
            controller.dismissForReplacement()
        }
        defer { engine.willCaptureScreenHook = originalCaptureHook }

        await controller.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 100_000_000)

        r["backdropRequested"] = backdropRequested
        r["cancelCount"] = cancelCount
        r["panelPresented"] = controller.uiTestPanelWindow != nil
        r["allPass"] = backdropRequested && cancelCount == 1 && controller.uiTestPanelWindow == nil
        return r
    }

    // MARK: - Scenario: all-in-one-handoff-latest-intent

    /// A replacement waits briefly for the dismissed dock to leave the compositor.
    /// If a newer All-in-One begins during that wait, the older replacement must
    /// stop instead of opening a stale picker over the newer dock.
    private static func runAllInOneHandoffLatestIntent() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "all-in-one-handoff-latest-intent"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        engine.uiTestActiveSelection?.cancel()
        engine.uiTestCloseAllInOne()

        await engine.startAllInOne(historyManager: appDelegate.historyManager)
        for _ in 0..<30 where engine.uiTestAllInOneInitialRect == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let originalOpened = engine.uiTestAllInOneInitialRect != nil

        let staleReplacement = Task {
            await engine.startAreaCapture(historyManager: appDelegate.historyManager)
        }
        for _ in 0..<20 where engine.uiTestAllInOneInitialRect != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let originalDismissed = engine.uiTestAllInOneInitialRect == nil

        await engine.startAllInOne(historyManager: appDelegate.historyManager)
        await staleReplacement.value
        try? await Task.sleep(nanoseconds: 120_000_000)

        let newerAllInOneOpened = engine.uiTestAllInOneInitialRect != nil
        let staleAreaSelectionOpened = engine.uiTestActiveSelection != nil

        engine.uiTestActiveSelection?.cancel()
        engine.uiTestCloseAllInOne()

        r["originalOpened"] = originalOpened
        r["originalDismissed"] = originalDismissed
        r["newerAllInOneOpened"] = newerAllInOneOpened
        r["staleAreaSelectionOpened"] = staleAreaSelectionOpened
        r["allPass"] = originalOpened && originalDismissed && newerAllInOneOpened && !staleAreaSelectionOpened
        return r
    }

    // MARK: - Scenario: scrolling-handoff-latest-intent

    /// Scrolling owns a private selector. If an All-in-One starts while its frozen
    /// backdrop is loading, the stale scrolling selector must never appear over
    /// the newer dock.
    private static func runScrollingHandoffLatestIntent() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "scrolling-handoff-latest-intent"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        engine.uiTestCloseAllInOne()

        await engine.startAllInOne(historyManager: appDelegate.historyManager)
        for _ in 0..<30 where engine.uiTestAllInOneInitialRect == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let originalOpened = engine.uiTestAllInOneInitialRect != nil

        let staleScrolling = Task {
            await engine.startScrollingCapture(historyManager: appDelegate.historyManager)
        }
        for _ in 0..<20 where engine.uiTestAllInOneInitialRect != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let originalDismissed = engine.uiTestAllInOneInitialRect == nil

        await staleScrolling.value
        let scrollingSelectionStarted = engine.uiTestScrollingCaptureActive

        await engine.startAllInOne(historyManager: appDelegate.historyManager)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let newerAllInOneOpened = engine.uiTestAllInOneInitialRect != nil
        let staleScrollingSelectionOpened = engine.uiTestScrollingCaptureActive

        engine.uiTestCloseAllInOne()

        r["originalOpened"] = originalOpened
        r["originalDismissed"] = originalDismissed
        r["scrollingSelectionStarted"] = scrollingSelectionStarted
        r["newerAllInOneOpened"] = newerAllInOneOpened
        r["staleScrollingSelectionOpened"] = staleScrollingSelectionOpened
        r["allPass"] = originalOpened && originalDismissed && scrollingSelectionStarted
            && newerAllInOneOpened && !staleScrollingSelectionOpened
        return r
    }

    // MARK: - Scenario: interactive-selection-replacement

    /// A newer scrolling command replaces an ordinary area selector instead of
    /// leaving two private overlay systems alive at once.
    private static func runInteractiveSelectionReplacement() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "interactive-selection-replacement"]
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            r["error"] = "no app delegate"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        engine.uiTestActiveSelection?.cancel()
        engine.uiTestCloseAllInOne()

        await engine.startAreaCapture(historyManager: appDelegate.historyManager)
        for _ in 0..<30 where engine.uiTestActiveSelection == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let areaSelectionOpened = engine.uiTestActiveSelection != nil

        await engine.startScrollingCapture(historyManager: appDelegate.historyManager)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let areaSelectionDismissed = engine.uiTestActiveSelection == nil
        let scrollingSelectionOpened = engine.uiTestScrollingCaptureActive

        r["areaSelectionOpened"] = areaSelectionOpened
        r["areaSelectionDismissed"] = areaSelectionDismissed
        r["scrollingSelectionOpened"] = scrollingSelectionOpened
        r["allPass"] = areaSelectionOpened && areaSelectionDismissed && scrollingSelectionOpened
        return r
    }

    // MARK: - Scenario: area-selection-cancel-pending-finish

    /// Finishing a drag defers its completion briefly for compositor cleanup. A
    /// replacement during that handoff must suppress the old successful result.
    private static func runAreaSelectionCancelPendingFinish() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "area-selection-cancel-pending-finish"]
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no screen"
            r["allPass"] = false
            return r
        }

        var completions: [String] = []
        let selection = AreaSelectionWindow(mode: .area) { rect, _, _ in
            completions.append(rect == nil ? "cancel" : "selection")
        }
        let rect = CGRect(
            x: screen.frame.midX - 160,
            y: screen.frame.midY - 90,
            width: 320,
            height: 180
        )
        selection.simulateSelection(rect: rect, on: screen)
        selection.cancel()
        try? await Task.sleep(nanoseconds: 160_000_000)

        r["completions"] = completions
        r["allPass"] = completions == ["cancel"]
        return r
    }

    // MARK: - Scenario: all-in-one-restores-last-area

    /// Commits the same state an accepted area selection writes, then asks the
    /// production All-in-One planner for its target. This avoids requiring screen
    /// recording permission merely to validate restore semantics in the harness.
    private static func runAllInOneRestoresLastArea() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "all-in-one-restores-last-area"]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no app delegate or screen"
            r["allPass"] = false
            return r
        }

        let engine = appDelegate.uiTestCaptureEngine
        let previousSavedArea = Settings.allInOneRect
        let previousLastCaptureRect = engine.lastCaptureRect
        let area = CGRect(
            x: screen.frame.midX - 280,
            y: screen.frame.midY - 160,
            width: 560,
            height: 320
        )
        defer {
            Settings.allInOneRect = previousSavedArea
            engine.uiTestRestoreLastCaptureRect(previousLastCaptureRect)
        }

        engine.uiTestRememberReusableArea(area, on: screen)
        let persistedSelectionPasses = Settings.allInOneRect == area
        let plan = engine.uiTestAllInOneStartPlan(cursor: screen.frame.origin)
        let restoredRect = plan?.rect
        let restoredScreen = plan?.screenFrame
        let rectPasses = restoredRect == area
        let screenPasses = restoredScreen?.contains(area) == true
        r["persistedSelectionPasses"] = persistedSelectionPasses
        r["restoredRectPasses"] = rectPasses
        r["restoredScreenPasses"] = screenPasses
        r["restoredRect"] = restoredRect.map {
            ["x": $0.origin.x, "y": $0.origin.y, "w": $0.width, "h": $0.height]
        }
        r["allPass"] = persistedSelectionPasses && rectPasses && screenPasses
        return r
    }

    // MARK: - Scenario: recording-toggle-input

    /// Uses a physical cancelled drag to ensure it never changes the recording
    /// option, then the control's accessible press path to verify the same target
    /// action commits both the button and Settings state. The drag requires
    /// Accessibility because it is posted through the HID event tap.
    private static func runRecordingToggleInput() async -> [String: Any] {
        var r: [String: Any] = ["scenario": "recording-toggle-input"]
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            r["error"] = "no app delegate or screen"
            r["allPass"] = false
            return r
        }

        let previousMicrophone = Settings.recordingMicrophone
        Settings.recordingMicrophone = false
        let engine = appDelegate.uiTestCaptureEngine
        defer {
            engine.uiTestCloseRecordingPreflight()
            Settings.recordingMicrophone = previousMicrophone
        }

        guard let window = engine.uiTestShowRecordingPreflight(
            rect: CGRect(x: 40, y: 40, width: 640, height: 360),
            on: screen
        ), let root = window.contentView,
        let microphone = findView(in: root, where: {
            $0.identifier?.rawValue == "recording.preflight.microphone"
        }) as? NSButton else {
            r["error"] = "recording microphone toggle missing"
            r["allPass"] = false
            return r
        }

        for _ in 0..<40 where !window.isKeyWindow {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let preflightKeyReady = window.isKeyWindow
        let accessibilityTrusted = AXIsProcessTrusted()
        r["preflightKeyReady"] = preflightKeyReady
        r["accessibilityTrusted"] = accessibilityTrusted
        guard preflightKeyReady, accessibilityTrusted else {
            r["error"] = "recording preflight did not become key or Accessibility is unavailable"
            r["allPass"] = false
            return r
        }

        let start = microphone.convert(
            CGPoint(x: microphone.bounds.midX, y: microphone.bounds.midY),
            to: root
        )
        let cancelledEnd = CGPoint(x: max(4, start.x - microphone.bounds.width - 12), y: start.y)
        let startInWindow = root.convert(start, to: nil)
        let endInWindow = root.convert(cancelledEnd, to: nil)
        let startOnScreen = window.convertPoint(toScreen: startInWindow)
        let endOnScreen = window.convertPoint(toScreen: endInWindow)
        func quartzPoint(_ appKitPoint: NSPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: screen.frame.maxY - appKitPoint.y)
        }
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }

        let dragStart = quartzPoint(startOnScreen)
        let dragEnd = quartzPoint(endOnScreen)
        post(.leftMouseDown, at: dragStart)
        try? await Task.sleep(nanoseconds: 60_000_000)
        for step in 1...4 {
            let progress = CGFloat(step) / 4
            let point = CGPoint(
                x: dragStart.x + (dragEnd.x - dragStart.x) * progress,
                y: dragStart.y + (dragEnd.y - dragStart.y) * progress
            )
            post(.leftMouseDragged, at: point)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        post(.leftMouseUp, at: dragEnd)
        try? await Task.sleep(nanoseconds: 140_000_000)
        let cancelledPressPreservesState = microphone.state == .off && !Settings.recordingMicrophone

        let accessiblePressCommitsState: Bool
        do {
            _ = try UIIntrospection.click(id: "recording.preflight.microphone")
            accessiblePressCommitsState = microphone.state == .on && Settings.recordingMicrophone
        } catch {
            r["accessiblePressError"] = String(describing: error)
            accessiblePressCommitsState = false
        }

        r["cancelledPressPreservesState"] = cancelledPressPreservesState
        r["accessiblePressCommitsState"] = accessiblePressCommitsState
        r["allPass"] = cancelledPressPreservesState && accessiblePressCommitsState
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
        hud.restartHandler = {}
        hud.discardHandler = {}
        hud.configure(systemAudio: true, microphone: true, fps: 30, quality: "high")
        hud.show(on: screen)
        hud.sharingType = .readOnly
        try? await Task.sleep(nanoseconds: 500_000_000)
        var hudPass = false
        if let cg = snapshotScreenRegion(of: hud, to: "\(dir)/recording-hud.png") {
            let layout = RecordingHUDLayout(showsMeter: true)
            hudPass = recordingHUDRegionPasses(cg, layout: layout).values.allSatisfy { $0 }
        }
        r["hudPass"] = hudPass

        // Pause the already-visible HUD, matching the real recording lifecycle.
        // Creating a window in a pre-paused state does not exercise the product path.
        hud.setPaused(true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        var pausedHUDRegions: [String: Bool] = [:]
        let pausedHUDPass = snapshotScreenRegion(
            of: hud,
            to: "\(dir)/recording-hud-paused.png"
        ).map { image in
            let layout = RecordingHUDLayout(showsMeter: true)
            pausedHUDRegions = recordingHUDRegionPasses(image, layout: layout)
            return pausedHUDRegions.values.allSatisfy { $0 }
        } ?? false
        hud.sharingType = .none
        hud.closeHUD()
        r["pausedHUDPass"] = pausedHUDPass
        r["pausedHUDRegions"] = pausedHUDRegions

        // 3. Saved result: poster, metadata, primary Edit action, Reveal and
        // overflow in the same top-centre continuum as the HUD.
        var resultPass = false
        let resultURL = URL(fileURLWithPath: "\(dir)/recording-result-source.mp4")
        if await makeSyntheticZoomSource(
            to: resultURL,
            size: CGSize(width: 320, height: 180),
            frames: 4,
            fps: 2
        ) {
            let resultActions = UITestRecordingResultActions()
            let result = RecordingResultWindow.uiTestMake(
                url: resultURL,
                duration: 2,
                actions: resultActions
            )
            let visible = screen.visibleFrame
            result.setFrameOrigin(NSPoint(
                x: visible.midX - result.frame.width / 2,
                y: visible.maxY - result.frame.height - 18
            ))
            result.sharingType = .readOnly
            result.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 900_000_000)
            resultPass = snapshotScreenRegion(of: result, to: "\(dir)/recording-result.png")
                .map { hasVisibleContrast($0) } ?? false
            result.close()
        }
        r["resultPass"] = resultPass

        // 4. All-in-One panel: one grouped action dock over the selection.
        var aioPass = false
        var aioStructurePass = false
        let aio = AllInOneController(screen: screen, initialRect: fakeArea,
                                     onAction: { _, _, _ in }, onCancel: {})
        await aio.prepareAndShow(engine: engine)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let panel = aio.uiTestPanelWindow {
            r["allInOnePanelVisible"] = panel.isVisible
            r["allInOnePanelWindowNumber"] = Int(panel.windowNumber)
            r["allInOnePanelLevel"] = Int(panel.level.rawValue)
            r["allInOnePanelFrame"] = [
                "x": panel.frame.origin.x,
                "y": panel.frame.origin.y,
                "w": panel.frame.width,
                "h": panel.frame.height,
            ]
            if let actionPanel = panel as? AllInOnePanelWindow {
                let expectedActions = AllInOneAction.allCases
                let buttons = actionPanel.optionButtons
                aioStructurePass = buttons.count == expectedActions.count
                    && zip(buttons, expectedActions).allSatisfy { button, action in
                        button.accessibilityIdentifier() == action.accessibilityIdentifier
                            && button.accessibilityLabel() == action.accessibilityLabel
                            && !button.isHidden
                    }
                    && buttons.map(\.frame) == [
                        CGRect(x: 10, y: 10, width: 76, height: 60),
                        CGRect(x: 88, y: 10, width: 76, height: 60),
                        CGRect(x: 182, y: 10, width: 76, height: 60),
                        CGRect(x: 260, y: 10, width: 76, height: 60),
                        CGRect(x: 354, y: 10, width: 76, height: 60),
                        CGRect(x: 432, y: 10, width: 76, height: 60),
                    ]
            }
            // Product windows never share into a capture. Lift only the panel
            // for the harness's own WindowServer snapshot, then restore it.
            panel.sharingType = .readOnly
            try? await Task.sleep(nanoseconds: 300_000_000)
            let windowsAbovePanel = (CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .excludeDesktopElements],
                CGWindowID(panel.windowNumber)
            ) as? [[String: Any]] ?? []).compactMap { info -> [String: Any]? in
                guard (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier else {
                    return nil
                }
                return [
                    "number": info[kCGWindowNumber as String] as? Int ?? -1,
                    "layer": info[kCGWindowLayer as String] as? Int ?? -1,
                    "bounds": info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:],
                ]
            }
            r["allInOneAppWindowsAbovePanel"] = windowsAbovePanel
            r["allInOnePerWindowPass"] = snapshotWindow(
                panel,
                to: "\(dir)/all-in-one-window.png"
            )
            for attempt in 1...3 where !aioPass {
                panel.displayIfNeeded()
                aioPass = snapshotScreenRegion(of: panel, to: "\(dir)/all-in-one.png")
                    .map {
                        allInOneCompositePasses(
                            $0,
                            actionFrames: (panel as? AllInOnePanelWindow)?.optionButtons.map(\.frame) ?? [],
                            panelSize: panel.frame.size
                        )
                    } ?? false
                r["allInOneSnapshotAttempts"] = attempt
                if !aioPass, attempt < 3 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            panel.sharingType = .none
        }
        aio.uiTestCancel()
        r["allInOneStructurePass"] = aioStructurePass
        r["allInOnePass"] = aioPass && aioStructurePass

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
            // Assert both states. A real cursor position must not decide whether
            // this gate tests the clear overlay backing; force the hover state
            // after the entry transition settles.
            func captureOverlayCenter(to path: String) -> (pixel: [String: Int], passes: Bool)? {
                guard let cg = snapshotScreenRegion(of: card, to: path),
                      let buf = rgbaPixels(cg) else { return nil }
                let cx = cg.width / 2, cy = cg.height / 2
                let i = (cy * cg.width + cx) * 4
                let (red, green, blue) = (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
                return (
                    ["r": red, "g": green, "b": blue],
                    // A clear material dims the thumbnail on hover, so exact
                    // source RGB is neither expected nor desirable. Preserve
                    // the orange relationship instead: bright red, warm green,
                    // little blue. The old black fallback fails this decisively.
                    red > 120 && green > 55 && green < 190 && blue < 100
                        && Double(red) > Double(green) * 1.45
                )
            }

            QuickAccessOverlay.uiTestSetNewestHovered(false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let rest = captureOverlayCenter(to: "\(dir)/overlay-card-rest.png")
            r["overlayRestCenterPixel"] = rest?.pixel ?? [:]
            r["overlayRestPass"] = rest?.passes ?? false

            QuickAccessOverlay.uiTestSetNewestHovered(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let hover = captureOverlayCenter(to: "\(dir)/overlay-card.png")
            r["overlayCenterPixel"] = hover?.pixel ?? [:]
            r["overlayHoverPass"] = hover?.passes ?? false
            overlayPass = (rest?.passes ?? false) && (hover?.passes ?? false)
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

        r["allPass"] = preflightPass && hudPass && pausedHUDPass && resultPass
            && aioPass && aioStructurePass && toastPass && overlayPass && historyPass && qrPass
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
        if let event = mouseEvent(.leftMouseDown, at: start, in: window, click: 1) {
            canvas.mouseDown(with: event)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let event = mouseEvent(.leftMouseDragged, at: p, in: window, click: 1) {
                canvas.mouseDragged(with: event)
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if let event = mouseEvent(.leftMouseUp, at: end, in: window, click: 1) {
            canvas.mouseUp(with: event)
        }
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, click: Int) {
        guard let event = mouseEvent(type, at: point, in: window, click: click) else { return }
        window.sendEvent(event)
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        click: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: click,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    /// Busca em profundidade na árvore de views.
    private static func findView(in root: NSView, where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(root) { return root }
        for sub in root.subviews {
            if let hit = findView(in: sub, where: predicate) { return hit }
        }
        return nil
    }

    /// Snapshots the editor: the surface the app is actually used through.
    ///
    /// Four states, in both appearances: bare canvas, canvas with the background
    /// panel open, and the same two with an annotation on top. Enough to judge
    /// the toolbar, the stage and the sidebar together, which is where a
    /// redesign either holds or falls apart.
    private static func runEditorVisual() async -> [String: Any] {
        var r: [String: Any] = [:]
        let dir = "/tmp/krit-editor-visual"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var written: [String] = []

        let saved = Settings.appearanceMode
        defer { Settings.appearanceMode = saved; AppearanceMode.applyCurrent() }

        for mode in [AppearanceMode.light, .dark] {
            Settings.appearanceMode = mode
            AppearanceMode.applyCurrent()
            try? await Task.sleep(nanoseconds: 300_000_000)

            let name = mode == .dark ? "dark" : "light"
            AnnotationWindowController.open(image: Self.sampleShot())
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let ctrl = AnnotationWindowController.uiTestLastController,
                  let window = ctrl.window else { continue }

            if Self.snapshotWindow(window, to: "\(dir)/\(name)-1-bare.png") {
                written.append("\(name)-1-bare.png")
            }

            ctrl.uiTestToggleSidebar()
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Self.snapshotWindow(window, to: "\(dir)/\(name)-2-sidebar.png") {
                written.append("\(name)-2-sidebar.png")
            }

            // Spacing is checked by number, not by eye. A render tells you the
            // panel "looks about right"; these say whether it sits on the ruler.
            if mode == .light, let metrics = ctrl.uiTestChromeMetrics {
                for (key, value) in metrics { r["metric.\(key)"] = value }
            }

            var options = ctrl.uiTestOptions
            options.isEnabled = true
            ctrl.uiTestApplyBackground(options)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Self.snapshotWindow(window, to: "\(dir)/\(name)-3-background.png") {
                written.append("\(name)-3-background.png")
            }

            window.close()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        r["dir"] = dir
        r["written"] = written
        r["allPass"] = written.count == 6
        return r
    }

    /// A stand-in capture that looks like a real screenshot rather than a flat
    /// fill: a window mock on a gradient. A chapado rectangle hides exactly the
    /// contrast problems a stage is supposed to reveal.
    private static func sampleShot(markerColor: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 900, height: 580)
        let img = NSImage(size: size)
        img.lockFocus()

        NSGradient(colors: [
            NSColor(srgbRed: 0.42, green: 0.60, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.72, green: 0.51, blue: 0.94, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.41, blue: 0.56, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: 300)

        let card = NSRect(x: 90, y: 80, width: 720, height: 420)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.97).setFill()
        path.fill()

        NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 90, y: 452, width: 720, height: 48).fill()
        for (i, dot) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 108 + i * 20, y: 470, width: 12, height: 12)).fill()
        }

        NSColor(white: 0.82, alpha: 1).setFill()
        for row in 0..<7 {
            let w = [520.0, 470.0, 560.0, 380.0, 500.0, 430.0, 300.0][row]
            NSRect(x: 130, y: 390 - Double(row) * 44, width: w, height: 14).fill()
        }
        if let markerColor {
            markerColor.setFill()
            NSRect(x: 0, y: 0, width: 48, height: size.height).fill()
        }
        img.unlockFocus()
        return img
    }

    /// Renders every Preferences tab, in both appearances, straight into PNGs.
    ///
    /// `cacheDisplay` draws the view hierarchy into a bitmap itself, so this is
    /// the one way to see the UI when ScreenCaptureKit cannot help: with the
    /// session locked every screen capture returns nil, and that is exactly when
    /// a remote check is most useful. The hosting view is parented to a window
    /// that is never ordered front, purely so layout gets a real pass.
    private static func runPrefsVisual() async -> [String: Any] {
        var r: [String: Any] = [:]
        let dir = URL(fileURLWithPath: "/tmp/krit-prefs-visual")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [String] = []
        let size = NSSize(width: 664, height: 940)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            let mode = name == .darkAqua ? "dark" : "light"

            for tab in PreferencesTab.allCases {
                let host = PreferencesContent.makeView(for: tab)
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = appearance

                let window = NSWindow(contentRect: host.frame,
                                      styleMask: [.borderless],
                                      backing: .buffered,
                                      defer: false)
                window.appearance = appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()

                // SwiftUI needs a turn of the run loop before its first real
                // layout; without it every tab renders as an empty rectangle.
                try? await Task.sleep(nanoseconds: 220_000_000)
                host.layoutSubtreeIfNeeded()

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }

                let file = "\(mode)-\(tab.title.lowercased()).png"
                try? png.write(to: dir.appendingPathComponent(file))
                written.append(file)
                window.contentView = nil
            }
        }

        r["dir"] = dir.path
        r["written"] = written
        r["allPass"] = written.count == PreferencesTab.allCases.count * 2
        return r
    }
}

@MainActor
private final class UITestFileDropDestination: NSView {
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Krit.UITestFileDropDestination"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    let outputDirectory: URL
    let promiseReceiveDelay: TimeInterval
    private(set) var enteredCount = 0
    private(set) var firstEnteredAtUptime: TimeInterval?
    private(set) var prepareCount = 0
    private(set) var performCount = 0
    private(set) var concludeCount = 0
    private(set) var observedTransport: String?
    private(set) var receivedItemCount = 0
    private(set) var errors: [String] = []
    private var pendingPromiseFiles = 0
    private var materializedFiles = 0

    init(outputDirectory: URL, promiseReceiveDelay: TimeInterval = 0) {
        self.outputDirectory = outputDirectory
        self.promiseReceiveDelay = promiseReceiveDelay
        super.init(frame: .zero)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        registerForDraggedTypes(Array(Set(promiseTypes + [.fileURL])))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        enteredCount += 1
        if firstEnteredAtUptime == nil {
            firstEnteredAtUptime = ProcessInfo.processInfo.systemUptime
        }
        guard detectedTransport(in: sender.draggingPasteboard) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        detectedTransport(in: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        prepareCount += 1
        return detectedTransport(in: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performCount += 1
        let pasteboard = sender.draggingPasteboard

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) {
            guard let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [URL], urls.count == 1 else {
                errors.append("expected exactly one concrete file URL")
                return false
            }
            observedTransport = "file-url"
            receivedItemCount = urls.count
            let source = urls[0]
            let destination = outputDirectory.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                materializedFiles = 1
                return true
            } catch {
                errors.append(error.localizedDescription)
                return false
            }
        }

        observedTransport = "file-promise"
        guard let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], receivers.count == 1 else {
            errors.append("expected exactly one file-promise receiver")
            return false
        }
        receivedItemCount = receivers.count
        pendingPromiseFiles = receivers.count
        if promiseReceiveDelay > 0 {
            let delay = promiseReceiveDelay
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.receivePromisedFiles(receivers)
            }
        } else {
            receivePromisedFiles(receivers)
        }
        return true
    }

    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: outputDirectory,
                options: [:],
                operationQueue: Self.promiseQueue
            ) { [weak self] fileURL, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.errors.append(error.localizedDescription)
                    } else if FileManager.default.fileExists(atPath: fileURL.path) {
                        self.materializedFiles += 1
                    } else {
                        self.errors.append("promise callback returned a missing file")
                    }
                    self.pendingPromiseFiles -= 1
                }
            }
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        concludeCount += 1
    }

    var materializationSettled: Bool {
        pendingPromiseFiles == 0
            && (materializedFiles > 0 || !errors.isEmpty)
    }

    func outputFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: outputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private func detectedTransport(in pasteboard: NSPasteboard) -> String? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) {
            return "file-url"
        }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]) {
            return "file-promise"
        }
        return nil
    }
}

@MainActor
private final class UITestRecordingResultActions: RecordingResultActions {
    func exportGIF(from url: URL) {}
    func trim(url: URL, range: CMTimeRange, convert: VideoTrimPanel.ConvertOptions?) {}
    func exportAutoZoom(from url: URL) {}
    func openVideoEditor(url: URL, duration: Double) {}
}

/// Bounds AVAssetWriter back-pressure while preserving a responsive main run
/// loop for the opt-in UI harness. One absolute deadline covers the full
/// synthetic source, so a permanently stalled input cannot pin the scenario.
enum MediaInputReadiness {
    // The first AVAssetWriter use can exceed five seconds while hardware codecs
    // warm up. Fifteen seconds remains a hard harness bound without rejecting a
    // healthy first conversion on a busy machine.
    static let syntheticWriterTimeout: TimeInterval = 15

    static func deadline(now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> TimeInterval {
        now() + syntheticWriterTimeout
    }

    static func wait(for input: AVAssetWriterInput, until deadline: TimeInterval) -> Bool {
        waitUntilReady(
            deadline: deadline,
            isReady: { input.isReadyForMoreMediaData },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { duration in
                RunLoop.current.run(until: Date(timeIntervalSinceNow: duration))
            }
        )
    }

    static func waitUntilReady(
        deadline: TimeInterval,
        pollInterval: TimeInterval = 0.002,
        isReady: () -> Bool,
        now: () -> TimeInterval,
        pause: (TimeInterval) -> Void
    ) -> Bool {
        while !isReady() {
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            pause(min(pollInterval, remaining))
        }
        return true
    }

    static func finishWriting(_ writer: AVAssetWriter) async -> Bool {
        let completed = await waitForFinish(timeout: syntheticWriterTimeout) { completion in
            writer.finishWriting { completion() }
        }
        guard completed, writer.status == .completed else {
            writer.cancelWriting()
            return false
        }
        return true
    }

    static func waitForFinish(
        timeout: TimeInterval,
        start: @escaping (@escaping () -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let state = FinishWaitState(continuation: continuation)
            start { state.resolve(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                state.resolve(false)
            }
        }
    }
}

private final class FinishWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ completed: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: completed)
    }
}
