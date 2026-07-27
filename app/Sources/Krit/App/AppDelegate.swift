import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var didBuildStatusMenu = false
    private var menuBarObserver: NSObjectProtocol?
    private var captureEngine: CaptureEngine!
    var hotkeyManager: HotkeyManager!
    var historyManager: HistoryManager!
    private let welcomeController = WelcomeWindowController()
    private var didRegisterHotkeys = false
    private var captureTrigger: CaptureTrigger?
    private var automationPort: AutomationPort?
    private var uiTestRunner: UITestRunner?
    private var presentationZoom: PresentationZoomController!
    private var liveAnnotation: LiveAnnotationController!
    private var featureTour: FeatureTourController!
    private var launchStartedAt = ProcessInfo.processInfo.systemUptime
    private(set) var launchCriticalReadyAt: TimeInterval?
    private(set) var launchFirstIdleAt: TimeInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchStartedAt = ProcessInfo.processInfo.systemUptime
        KritTrace.installPanicCapture()
        // Pin the chosen appearance (System / Light / Dark) before any window opens.
        AppearanceMode.applyCurrent()
        captureEngine = CaptureEngine()
        hotkeyManager = HotkeyManager()
        historyManager = HistoryManager()
        presentationZoom = PresentationZoomController()
        liveAnnotation = LiveAnnotationController()
        featureTour = FeatureTourController()
        liveAnnotation.captureEngine = captureEngine
        liveAnnotation.presentationZoom = presentationZoom
        // The camera button on the annotation toolbar shoots the same
        // fullscreen path the ⌘⇧3 hotkey and menu item use, so the annotated
        // live screen (ink included) lands in history like any other shot.
        liveAnnotation.onCaptureRequested = { [weak self] in self?.captureFullscreen() }
        // Reverse direction of the mutex above: engaging the zoom steps
        // annotation out of interactive drawing (see PresentationZoomController.start()).
        presentationZoom.liveAnnotation = liveAnnotation
        // Scripted captures (krit:// URL commands, automation port) funnel
        // straight into the engine, bypassing the hotkey/menu layer that
        // normally drops the presentation zoom first; hook them here so a
        // programmatic grab never includes the magnifier overlay.
        captureEngine.willCaptureScreenHook = { [weak self] in
            self?.presentationZoom.exitForCapture()
            self?.liveAnnotation.exitDrawModeKeepingAnnotations()
        }
        if CaptureTrigger.isEnabled() {
            captureTrigger = CaptureTrigger(engine: captureEngine)
        }
        uiTestRunner = UITestRunner()
        refreshAutomationPort()
        setupStatusItem()
        registerHotkeys()
        launchCriticalReadyAt = ProcessInfo.processInfo.systemUptime
        schedulePostFirstIdleWork()
        if KritBundleRuntimeProbe.isRequested {
            KritBundleRuntimeProbe.run()
            return
        }
        // Re-bind the dynamic per-preset hotkeys whenever a preset is added,
        // edited, or removed in Preferences.
        PresetStore.onChange = { [weak self] in self?.hotkeyManager.registerPresets() }
        // A harness launch owns the visible surface for its scenario. First-run,
        // shortcut, and release-note windows would cover that surface and make
        // the result depend on whichever preferences domain the temp bundle uses.
        guard !KritTestHarness.isEnabled else { return }
        let onWelcomeClose = { [weak self] in
            guard let self else { return }
            self.promptForNativeShortcuts()
        }
        let isFirstLaunch = welcomeController.showIfNeeded(onClose: onWelcomeClose)
        if !isFirstLaunch {
            // Reading the global macOS shortcut domain can touch cfprefsd and the
            // resulting alert enters a modal session. Neither belongs inside
            // applicationDidFinishLaunching, after capture is already ready.
            DispatchQueue.main.async { [weak self] in
                self?.promptForNativeShortcuts()
            }
        }
        // After an update, surface the release notes once (gated on a version
        // change; skipped on a fresh install, where the welcome runs instead).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            WhatsNewWindowController.showIfNeeded(isFirstLaunchThisSession: isFirstLaunch)
        }
    }

    /// Returns control to the first run-loop idle before initializing optional
    /// services. The status item and global capture hotkeys are already live at
    /// this point; Sparkle validation and sound resource I/O cannot delay them.
    private func schedulePostFirstIdleWork() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.launchFirstIdleAt = ProcessInfo.processInfo.systemUptime
            self.installStatusMenuIfNeeded()
            _ = UpdaterManager.shared
            CaptureEngine.warmCaptureSound()
        }
    }

    private func promptForNativeShortcuts() {
        NativeShortcutManager.promptIfNeeded { [weak self] in
            self?.registerHotkeys()
            self?.showReadyToastIfNeeded(delay: 2.2)
        }
    }

    /// Brings the automation port up or down to match the persisted user opt-in.
    /// Called at launch and again whenever the Preferences toggle flips, so enabling
    /// automation takes effect without a relaunch and disabling it tears the port
    /// down immediately.
    func refreshAutomationPort() {
        guard AutomationGate.isEnabled else {
            automationPort?.stop()
            automationPort = nil
            return
        }
        guard automationPort == nil else { return }
        let port = AutomationPort(service: AutomationService(engine: captureEngine, liveAnnotation: liveAnnotation))
        if port.start() { automationPort = port }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Parked overlay cards stay in openWindows with a live handle window even
        // after orderOut; tear them all down so nothing leaks past quit.
        QuickAccessOverlay.tearDownAll()
    }

    /// KRIT is a menu-bar (LSUIElement) app with no Dock icon and no main window,
    /// so relaunching it — Spotlight, `open -a KRIT`, double-click in Finder while
    /// it already runs — has no natural target; macOS routes that intent here.
    /// Open Preferences when nothing of KRIT's is on screen, OR whenever the menu
    /// bar icon is hidden: with the icon off, this reopen is the ONLY way back to
    /// Preferences (where the toggle to restore the icon lives), so without this
    /// hook, hiding the icon would strand the user with no way into settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !Settings.showMenuBarIcon {
            openPreferences()
        }
        return true
    }

    /// Two entry points share this callback:
    ///   - `krit://` automation URLs (URL scheme) route to the command router.
    ///   - "Open With KRIT" file URLs (Finder, Dock drop) open in the editor.
    /// They are split so a malformed automation URL never gets misread as a file.
    func application(_ application: NSApplication, open urls: [URL]) {
        var openedAny = false
        for url in urls {
            if url.scheme?.lowercased() == URLCommandRouter.scheme {
                URLCommandRouter.handle(url, appDelegate: self)
                continue
            }
            guard let image = NSImage(contentsOf: url) else {
                SoundManager.play(.error)
                continue
            }
            AnnotationWindowController.open(image: image)
            openedAny = true
        }
        if openedAny { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - URL scheme wrappers (krit://)

    /// Headless rect capture for `krit://capture/rect`. Takes a TOP-LEFT global
    /// rect in points (the automation convention) and hands the produced image to
    /// `completion` so the URL router can run its `then` chain. The whole grab runs
    /// without the area-selection overlay; it does NOT go through finishCapture, so
    /// it skips history/flash/overlay by design (a scripted shot is silent).
    func captureRectHeadless(topLeft rect: CGRect, completion: @escaping (NSImage?) -> Void) {
        guard captureEngine != nil else { completion(nil); return }
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert()
            completion(nil)
            return
        }
        guard let screen = screenForTopLeftRect(rect) else { completion(nil); return }
        let appKit = CoordinateSpace.appKitRect(fromTopLeft: rect)
        Task {
            let image = await captureEngine.captureRectToImage(appKit, on: screen)
            completion(image)
        }
    }

    /// Headless rect recording for `krit://record/start`. Skips the preflight
    /// controls panel (a scripted call has no one to click Record) and starts the
    /// production recording engine directly on the converted rect.
    func startRectRecordingHeadless(topLeft rect: CGRect) {
        guard captureEngine != nil else { return }
        guard PermissionsManager.hasScreenRecordingPermission else {
            PermissionsManager.showPermissionDeniedAlert()
            return
        }
        guard captureEngine.recordingActionsEnabled else {
            ToastWindow.show(message: "Finish or stop the current recording first")
            return
        }
        guard let screen = screenForTopLeftRect(rect) else { return }
        let appKit = CoordinateSpace.appKitRect(fromTopLeft: rect)
        Task { await captureEngine.uiTestStartRecording(rect: appKit, on: screen) }
    }

    /// Stops an in-flight recording for `krit://record/stop`.
    func stopRecordingFromURL() {
        guard captureEngine != nil else { return }
        captureEngine.stopRecording()
    }

    /// The interactive capture flows the `krit://` router can drive with a `then=`
    /// chain (each routes through the engine's finishCapture, which fires the
    /// one-shot completion).
    enum InteractiveCaptureKind {
        case area
        case window
        case fullscreen
    }

    /// Triggers an interactive capture and gives its `then` chain to the engine as
    /// part of that request. A newer request replaces a pending selector and owns
    /// its own follow-up. Once a capture attempt is accepted, a rejected request
    /// cannot replace that attempt's chain. The harness may inject an isolated
    /// history manager so its end-to-end capture never writes user history.
    func captureInteractive(
        _ kind: InteractiveCaptureKind,
        then: [URLCommandRouter.ThenAction],
        historyManagerOverride: HistoryManager? = nil
    ) {
        guard let engine = captureEngine, let liveHistoryManager = historyManager else { return }
        let targetHistoryManager = historyManagerOverride ?? liveHistoryManager
        let chain = then.compactMap { $0.captureAction }
        let followUp: ((CaptureDeliveryReceipt) -> Void)? = chain.isEmpty
            ? nil
            : { receipt in
                CaptureActionChain.apply(
                    chain,
                    to: receipt.presentedImage,
                    artifact: receipt.presentedArtifact
                )
            }

        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        engine.enqueueInteractiveRequest {
            switch kind {
            case .area:
                await engine.startAreaCapture(
                    historyManager: targetHistoryManager,
                    followUp: followUp
                )
            case .window:
                await engine.startWindowCapture(
                    historyManager: targetHistoryManager,
                    followUp: followUp
                )
            case .fullscreen:
                await engine.captureFullscreen(
                    historyManager: targetHistoryManager,
                    followUp: followUp
                )
            }
        }
    }

    // MARK: - Snap Presets (Preferences bridge)

    /// Opens the interactive area selection to DEFINE a preset's rect (no capture).
    /// The Preferences "New preset from selection" button calls this; the closure
    /// receives the chosen region as a global top-left rect, or nil if cancelled.
    func selectPresetRect(completion: @escaping (CGRect?) -> Void) {
        guard captureEngine != nil else { completion(nil); return }
        Task { await captureEngine.selectRectForPreset(completion: completion) }
    }

    /// Fires a saved preset on demand (Preferences "Test" / preview affordance).
    func runPreset(_ preset: SnapPreset) {
        guard captureEngine != nil else { return }
        Task { await captureEngine.runPreset(preset, historyManager: historyManager) }
    }

    /// macOS global top-left space (origin at the primary display's top-left) to
    private func screenForTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let appKit = CoordinateSpace.appKitRect(fromTopLeft: rect)
        return NSScreen.screens.first(where: { $0.frame.intersects(appKit) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func registerHotkeys() {
        hotkeyManager.register(
            captureEngine: captureEngine,
            historyManager: historyManager,
            presentationZoom: presentationZoom,
            liveAnnotation: liveAnnotation,
            onToggleHistory: { [weak self] in
                guard let self else { return }
                HistoryPanelController.shared.toggle(historyManager: self.historyManager)
            }
        )
        didRegisterHotkeys = true
    }

    private func showReadyToastIfNeeded(delay: TimeInterval = 0) {
        let show = { @MainActor in
            guard Settings.hasLaunchedBefore,
                  !Settings.didShowReadyToast,
                  PermissionsManager.hasScreenRecordingPermission,
                  !NativeShortcutManager.nativeShortcutsEnabled else { return }

            Settings.didShowReadyToast = true
            ToastWindow.show(message: "KRIT is ready to use!", duration: 3.0, anchorView: self.statusItem?.button)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                show()
            }
        } else {
            show()
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        // Toggling the preference at runtime adds/removes the item live; the global
        // hotkeys keep working even when the icon is hidden.
        menuBarObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStatusItemVisibility() }
        }
        syncStatusItemVisibility()
    }

    private func syncStatusItemVisibility() {
        if Settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
                let icon = NSImage(systemSymbolName: "crop", accessibilityDescription: "KRIT")?
                    .withSymbolConfiguration(config)
                icon?.isTemplate = true
                button.image = icon
            }
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            didBuildStatusMenu = false
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        populateStatusMenu(menu)
        return menu
    }

    private func installStatusMenuIfNeeded() {
        guard !didBuildStatusMenu, let menu = statusItem?.menu else { return }
        populateStatusMenu(menu)
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        guard !didBuildStatusMenu else { return }
        didBuildStatusMenu = true
        menu.removeAllItems()
        // Delegate refreshes the "Recent Captures" section on every open
        // (menuNeedsUpdate) so it always mirrors the current history.
        menu.delegate = self

        let about = NSMenuItem(title: "About KRIT", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let updates = NSMenuItem(title: "Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let whatsNew = NSMenuItem(title: "What's New", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNew.target = self
        menu.addItem(whatsNew)

        let featureTourItem = NSMenuItem(title: "Feature Tour", action: #selector(showFeatureTour), keyEquivalent: "")
        featureTourItem.target = self
        menu.addItem(featureTourItem)
        menu.addItem(.separator())

        menu.addItem(header: "Capture")
        menu.addItem(title: "All-in-One",           key: "a", action: #selector(allInOne), icon: "square.dashed.inset.filled")
        menu.addItem(title: "Capture Area",         key: "4", action: #selector(captureArea), icon: "rectangle.dashed")
        menu.addItem(title: "Capture Window",       key: "5", action: #selector(captureWindow), icon: "macwindow")
        menu.addItem(title: "Capture Fullscreen",   key: "6", action: #selector(captureFullscreen), icon: "rectangle.on.rectangle")
        menu.addItem(title: "Capture Previous Area",key: "7",  action: #selector(capturePrevious), icon: "arrow.counterclockwise.rectangle")
        menu.addItem(title: "Snap and Paste",       key: "p",  action: #selector(snapAndPaste), icon: "doc.on.clipboard")
        menu.addItem(title: "Scrolling Capture",    key: "s",  action: #selector(captureScrolling), icon: "scroll")
        menu.addItem(.separator())

        menu.addItem(header: "Record")
        menu.addItem(title: "Record Area",          key: "", action: #selector(recordArea), icon: "record.circle")
        menu.addItem(title: "Record Window",        key: "", action: #selector(recordWindow), icon: "macwindow.badge.plus")
        menu.addItem(title: "Record Fullscreen",    key: "", action: #selector(recordFullscreen), icon: "rectangle.fill.on.rectangle.fill")
        menu.addItem(title: "Stop Recording",       key: "", action: #selector(stopRecording), icon: "stop.circle")
        menu.addItem(title: "Reopen Last Recording",key: "", action: #selector(reopenLastRecording), icon: "arrow.uturn.backward.circle")
        menu.addItem(.separator())

        menu.addItem(header: "Tools")
        menu.addItem(title: "Capture Text (OCR)",   key: "o",  action: #selector(captureText), icon: "text.viewfinder")
        menu.addItem(title: "Pick Color",           key: "",  action: #selector(pickColor), icon: "eyedropper")
        menu.addItem(title: "Presentation Zoom",    key: "8",  action: #selector(togglePresentationZoom), icon: "plus.magnifyingglass")
        menu.addItem(title: "Annotate Screen",      key: "d",  action: #selector(toggleLiveAnnotation), icon: "scribble")
        menu.addItem(title: "Scan QR Code",         key: "",  action: #selector(scanQRCode), icon: "qrcode.viewfinder")
        menu.addItem(title: "Open History",         key: "",  action: #selector(openHistory), icon: "clock.arrow.circlepath")
        menu.addItem(title: "Show Editor",          key: "",  action: #selector(showEditor), icon: "pencil.and.outline")
        menu.addItem(title: "Annotate Last Screenshot", key: "", action: #selector(annotateLastScreenshot), icon: "pencil.tip.crop.circle")
        menu.addItem(.separator())

        let hideIconsItem = NSMenuItem(title: "Hide Desktop Icons", action: #selector(toggleDesktopIcons), keyEquivalent: "")
        hideIconsItem.target = self
        hideIconsItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        menu.addItem(hideIconsItem)

        // Anchor separator: the recent-captures section is injected right after
        // this item each time the menu opens. Tagged so the rebuild can find it.
        let recentsAnchor = NSMenuItem.separator()
        recentsAnchor.tag = Self.recentCapturesAnchorTag
        menu.addItem(recentsAnchor)

        // Preferences uses the standard ⌘, (not a ⌘⇧ global hotkey), so build it
        // directly rather than through the ⌘⇧ capture-item helper.
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)

        let quit = NSMenuItem(title: "Quit KRIT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // Test-only: exposes the capture engine so the UI-test harness can exercise
    // the isolated window-capture path against a real KRIT window.
    var uiTestCaptureEngine: CaptureEngine { captureEngine }
    var uiTestPresentationZoom: PresentationZoomController { presentationZoom }
    var uiTestLaunchReadiness: [String: Any] {
        let critical = launchCriticalReadyAt.map { ($0 - launchStartedAt) * 1_000 }
        let firstIdle = launchFirstIdleAt.map { ($0 - launchStartedAt) * 1_000 }
        return [
            "criticalReady": launchCriticalReadyAt != nil,
            "firstIdleReached": launchFirstIdleAt != nil,
            "hotkeysReady": didRegisterHotkeys,
            "statusMenuReady": didBuildStatusMenu,
            "criticalReadyMs": critical ?? -1,
            "firstIdleMs": firstIdle ?? -1,
        ]
    }

    // MARK: - Actions

    private func enqueueInteractiveCapture(
        _ operation: @escaping @MainActor (CaptureEngine, HistoryManager) async -> Void
    ) {
        guard let engine = captureEngine, let manager = historyManager else { return }
        engine.enqueueInteractiveRequest {
            await operation(engine, manager)
        }
    }

    private func enqueueInteractiveEngineAction(
        _ operation: @escaping @MainActor (CaptureEngine) async -> Void
    ) {
        guard let engine = captureEngine else { return }
        engine.enqueueInteractiveRequest {
            await operation(engine)
        }
    }

    @objc func allInOne() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.startAllInOne(historyManager: manager)
        }
    }

    @objc func captureArea() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.startAreaCapture(historyManager: manager)
        }
    }

    @objc func captureWindow() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.startWindowCapture(historyManager: manager)
        }
    }

    @objc func captureFullscreen() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.captureFullscreen(historyManager: manager)
        }
    }

    @objc func capturePrevious() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.capturePreviousArea(historyManager: manager)
        }
    }

    @objc func snapAndPaste() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.startSnapAndPaste(historyManager: manager)
        }
    }

    @objc func captureScrolling() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveCapture { engine, manager in
            await engine.startScrollingCapture(historyManager: manager)
        }
    }

    @objc func recordArea() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startAreaRecording()
        }
    }

    @objc func recordWindow() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startWindowRecording()
        }
    }

    @objc func recordFullscreen() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startFullscreenRecording()
        }
    }
    @objc func stopRecording()       { captureEngine.stopRecording() }
    @objc func reopenLastRecording() { captureEngine.reopenLastRecording() }
    @objc func captureText() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startOCRCapture()
        }
    }

    @objc func pickColor() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startColorPick()
        }
    }

    @objc func scanQRCode() {
        presentationZoom.exitForCapture()
        liveAnnotation.exitDrawModeKeepingAnnotations()
        enqueueInteractiveEngineAction { engine in
            await engine.startQRCodeCapture()
        }
    }
    @objc func togglePresentationZoom() { presentationZoom.toggle() }
    @objc func toggleLiveAnnotation() { liveAnnotation.toggleDrawMode() }
    @objc func showEditor()          { AnnotationWindowController.bringOpenEditorsToFront() }
    @objc func annotateLastScreenshot() {
        guard let last = historyManager.items.first else { return }
        AnnotationWindowController.open(image: last.fullImage, historyItem: last, historyManager: historyManager)
    }
    @objc func openHistory()         { HistoryPanelController.shared.toggle(historyManager: historyManager) }
    @objc func toggleDesktopIcons()  { DesktopIconsManager.toggle() }
    @objc func openPreferences()     { PreferencesWindowController.shared.show(tab: .general) }
    @objc func openAbout()           { PreferencesWindowController.shared.show(tab: .about) }
    @objc func checkForUpdates()     { UpdaterManager.shared.checkForUpdates() }
    @objc func showWhatsNew()        { WhatsNewWindowController.showNow() }
    @objc func showFeatureTour()     { presentationZoom.exitForCapture(); liveAnnotation.exitDrawModeKeepingAnnotations(); featureTour.show() }

    // MARK: - Recent captures (status item menu section)

    private static let recentCapturesAnchorTag = 0x4B52 // separator the section is inserted after
    private static let recentCapturesItemTag   = 0x4B53 // every item belonging to the section

    private static let recentTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()

    private static let recentDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        if !didBuildStatusMenu {
            populateStatusMenu(menu)
        }
        rebuildRecentCapturesSection(in: menu)
    }

    /// Rebuilds only the block between the tagged anchor separator and
    /// Preferences: old section items are removed first, so reopening the
    /// menu never duplicates the section.
    private func rebuildRecentCapturesSection(in menu: NSMenu) {
        for item in menu.items where item.tag == Self.recentCapturesItemTag {
            menu.removeItem(item)
        }
        guard let anchorIndex = menu.items.firstIndex(where: { $0.tag == Self.recentCapturesAnchorTag }) else { return }

        var section: [NSMenuItem] = []

        let header = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "Recent Captures",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        section.append(header)

        let recents = historyManager.items.prefix(3)
        if recents.isEmpty {
            // No action and no target leaves the item disabled automatically.
            let title = historyManager.isLoading ? "Loading captures…" : "No captures yet"
            section.append(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        } else {
            for item in recents {
                section.append(makeRecentCaptureMenuItem(for: item))
            }
        }
        section.append(.separator())

        for (offset, menuItem) in section.enumerated() {
            menuItem.tag = Self.recentCapturesItemTag
            menu.insertItem(menuItem, at: anchorIndex + 1 + offset)
        }
    }

    private func makeRecentCaptureMenuItem(for item: HistoryItem) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: recentCaptureTitle(for: item),
            action: #selector(openRecentCapture(_:)),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.representedObject = item
        menuItem.image = recentCaptureThumbnail(for: item)

        // Clicking the row opens the editor where AppKit sends the parent
        // action; the submenu keeps Open reachable everywhere and adds the
        // secondary actions.
        let submenu = NSMenu()
        submenu.addItem(recentCaptureAction(title: "Open in Editor", action: #selector(openRecentCapture(_:)), item: item))
        submenu.addItem(recentCaptureAction(title: "Copy", action: #selector(copyRecentCapture(_:)), item: item))
        submenu.addItem(recentCaptureAction(title: "Show in Finder", action: #selector(showRecentCaptureInFinder(_:)), item: item))
        submenu.addItem(.separator())
        submenu.addItem(recentCaptureAction(title: "Delete", action: #selector(deleteRecentCapture(_:)), item: item))
        menuItem.submenu = submenu
        return menuItem
    }

    private func recentCaptureAction(title: String, action: Selector, item: HistoryItem) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item
        return menuItem
    }

    private func recentCaptureTitle(for item: HistoryItem) -> String {
        let time = Self.recentTimeFormatter.string(from: item.createdAt)
        if Calendar.current.isDateInToday(item.createdAt) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(item.createdAt) { return "Yesterday at \(time)" }
        return "\(Self.recentDateFormatter.string(from: item.createdAt)) at \(time)"
    }

    /// 44×28 aspect-fill thumbnail with rounded corners for the menu row.
    private func recentCaptureThumbnail(for item: HistoryItem) -> NSImage {
        let source = historyManager.cachedThumbnail(for: item) ?? item.thumbnail
        let size = NSSize(width: 44, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            let srcSize = source.size
            guard srcSize.width > 0, srcSize.height > 0 else { return true }
            let scale = max(rect.width / srcSize.width, rect.height / srcSize.height)
            let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
            let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
            source.draw(
                in: NSRect(origin: origin, size: drawSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    @objc private func openRecentCapture(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HistoryItem else { return }
        AnnotationWindowController.open(image: item.fullImage, historyItem: item, historyManager: historyManager)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyRecentCapture(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HistoryItem else { return }
        ImageExporter.copyToClipboard(image: item.presentedImage)
    }

    @objc private func showRecentCaptureInFinder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HistoryItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.presentedFileURL])
    }

    @objc private func deleteRecentCapture(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HistoryItem else { return }
        historyManager.delete(item)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(stopRecording) {
            return captureEngine?.recordingActive ?? false
        }
        if menuItem.action == #selector(recordArea)
            || menuItem.action == #selector(recordWindow)
            || menuItem.action == #selector(recordFullscreen) {
            return captureEngine?.recordingActionsEnabled ?? false
        }
        if menuItem.action == #selector(showEditor) {
            return AnnotationWindowController.hasOpenEditors
        }
        if menuItem.action == #selector(reopenLastRecording) {
            return captureEngine?.hasLastRecording ?? false
        }
        return true
    }
}

// MARK: - NSMenu convenience

private extension NSMenu {
    func addItem(header text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        addItem(item)
    }

    @discardableResult
    func addItem(title: String, key: String, action: Selector, icon: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = NSApp.delegate
        // The global hotkeys are all ⌘⇧<key> (HotkeyManager); without the explicit
        // mask AppKit renders these as ⌘-only and teaches the wrong shortcut.
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        if let iconName = icon {
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        }
        addItem(item)
        return item
    }
}
