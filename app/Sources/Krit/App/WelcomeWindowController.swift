import AppKit

/// First-launch onboarding: a paged glass card that introduces KRIT, walks
/// through the Screen Recording permission (with a live status check), shows
/// the capture shortcuts, and closes on the agent-native story.
///
/// Public surface is unchanged from the single-page version: AppDelegate calls
/// `showIfNeeded(onClose:)` and the close handler still triggers the native
/// shortcut prompt afterwards.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    // Paging
    private var pages: [NSView?] = Array(repeating: nil, count: 4)
    private var pageIndex = 0
    private var pageContainer: NSView!
    private var dotLayers: [CALayer] = []
    private var pageIndicator: NSView!
    private var backButton: NSButton!
    private var continueButton: NSButton!
    private var skipButton: NSButton!

    // Live permission status (page 2)
    private var permissionTimer: Timer?
    private var permissionStatusDot: NSView?
    private var permissionStatusLabel: NSTextField?
    private var permissionGrantButton: NSButton?
    private var completedWelcome = false

    private let cardWidth: CGFloat = 640
    private let cardHeight: CGFloat = 470
    private let footerHeight: CGFloat = 64

    private let pageTitles = [
        "Capture, polish, and deliver screen work",
        "Allow Screen Recording",
        "Capture from anywhere",
        "Automate capture when the job calls for it",
    ]

    @discardableResult
    func showIfNeeded(onClose: (() -> Void)? = nil) -> Bool {
        guard !Settings.hasLaunchedBefore else { return false }
        self.onClose = onClose
        showWindow()
        return true
    }

    private func showWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to KRIT"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        // Liquid Glass panel backing for the whole onboarding card.
        // ChromeFactory guards #available internally, macOS 26 gets
        // NSGlassEffectView; older builds keep the HUD blur fallback.
        let background = ChromeFactory.backing(
            frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight),
            cornerRadius: ChromeFactory.Radius.panel
        )
        win.contentView = background

        buildPages(in: background)
        buildFooter(in: background)
        showPage(0, animated: false)
        animateHeroEntrance()

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    // MARK: - Page scaffolding

    private func buildPages(in container: NSView) {
        pageContainer = NSView(frame: NSRect(
            x: 0, y: footerHeight,
            width: cardWidth, height: cardHeight - footerHeight
        ))
        pageContainer.wantsLayer = true
        container.addSubview(pageContainer)

        // Build only the visible page. The first launch should not construct all
        // four AppKit trees, SF Symbols and glass surfaces before showing the
        // welcome screen; later pages are materialized when navigation reaches
        // them and then cached for Back navigation.
        pages = Array(repeating: nil, count: pages.count)
        permissionStatusDot = nil
        permissionStatusLabel = nil
        permissionGrantButton = nil
    }

    private func buildFooter(in container: NSView) {
        let dissolve = KritEdgeDissolveView(
            frame: NSRect(x: 0, y: footerHeight, width: cardWidth, height: 12),
            direction: .up
        )
        dissolve.autoresizingMask = [.width]
        container.addSubview(dissolve)

        skipButton = NSButton(title: "Skip", target: self, action: #selector(skipClicked))
        skipButton.bezelStyle = .inline
        skipButton.isBordered = false
        skipButton.font = KritType.callout.nsFont
        skipButton.contentTintColor = .secondaryLabelColor
        skipButton.frame = NSRect(x: 24, y: (footerHeight - 28) / 2, width: 60, height: 28)
        container.addSubview(skipButton)

        // Page dots, centered
        let dotSize: CGFloat = 7
        let dotGap: CGFloat = 9
        let dotsWidth = CGFloat(4) * dotSize + CGFloat(3) * dotGap
        let dotsHost = NSView(frame: NSRect(
            x: (cardWidth - dotsWidth) / 2, y: (footerHeight - dotSize) / 2,
            width: dotsWidth, height: dotSize
        ))
        dotsHost.wantsLayer = true
        dotsHost.setAccessibilityElement(true)
        dotsHost.setAccessibilityRole(.group)
        for i in 0..<4 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * (dotSize + dotGap), y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dotsHost.layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
        pageIndicator = dotsHost
        container.addSubview(dotsHost)

        backButton = NSButton(title: "Back", target: self, action: #selector(backClicked))
        backButton.bezelStyle = .rounded
        backButton.setAccessibilityLabel("Previous welcome page")
        backButton.frame = NSRect(x: cardWidth - 24 - 132 - 8 - 76, y: (footerHeight - 32) / 2, width: 76, height: 32)
        container.addSubview(backButton)

        continueButton = makeCoralButton(title: "Continue", action: #selector(continueClicked))
        continueButton.keyEquivalent = "\r"
        continueButton.setAccessibilityLabel("Continue welcome")
        continueButton.frame = NSRect(x: cardWidth - 24 - 132, y: (footerHeight - 34) / 2, width: 132, height: 34)
        container.addSubview(continueButton)
    }

    private func showPage(_ index: Int, animated: Bool, forward: Bool = true) {
        guard index >= 0, index < pages.count else { return }
        let incoming = page(at: index)
        let outgoing = pageContainer.subviews.first
        pageIndex = index

        incoming.frame = pageContainer.bounds
        pageContainer.addSubview(incoming)

        if animated, !Motion.reduced, let outgoing, outgoing !== incoming {
            let shift: CGFloat = 36
            incoming.alphaValue = 0
            incoming.frame.origin.x = forward ? shift : -shift
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.pageTransitionDuration(reduceMotion: Motion.reduced)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                incoming.animator().alphaValue = 1
                incoming.animator().frame.origin.x = 0
                outgoing.animator().alphaValue = 0
                outgoing.animator().frame.origin.x = forward ? -shift : shift
            }, completionHandler: {
                outgoing.removeFromSuperview()
                outgoing.alphaValue = 1
                outgoing.frame.origin.x = 0
            })
        } else {
            if let outgoing, outgoing !== incoming { outgoing.removeFromSuperview() }
            incoming.alphaValue = 1
            incoming.frame.origin.x = 0
        }

        refreshChrome()
        updateAccessibilityForCurrentPage()
        if index == 1 { startPermissionPolling() } else { stopPermissionPolling() }
    }

    private func page(at index: Int) -> NSView {
        if let page = pages[index] { return page }

        let page: NSView
        switch index {
        case 0: page = makeWelcomePage()
        case 1: page = makePermissionPage()
        case 2: page = makeShortcutsPage()
        default: page = makeAgentPage()
        }
        configureAccessibility(for: page, index: index)
        pages[index] = page
        return page
    }

    /// Footer state for the current page: dots, Back visibility, CTA label.
    private func refreshChrome() {
        for (i, dot) in dotLayers.enumerated() {
            dot.backgroundColor = (i == pageIndex)
                ? KritColors.accent.cgColor
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.4).cgColor
        }
        backButton.isHidden = pageIndex == 0
        skipButton.isHidden = pageIndex == pages.count - 1
        setCoralTitle(continueButton, pageIndex == pages.count - 1 ? "Start Capturing" : "Continue")
        continueButton.setAccessibilityLabel(pageIndex == pages.count - 1 ? "Start capturing" : "Continue welcome")
        pageIndicator.setAccessibilityLabel(accessibilityPageSummary(for: pageIndex))
    }

    // MARK: - Pages

    private var pageBounds: NSRect {
        NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight - footerHeight)
    }

    /// Page 1, app identity plus the three real workflows KRIT supports.
    private func makeWelcomePage() -> NSView {
        let page = NSView(frame: pageBounds)
        page.wantsLayer = true
        let w = page.bounds.width
        let contentX: CGFloat = 64
        let contentW = w - contentX * 2
        var y = page.bounds.height - 36

        let iconSize: CGFloat = 54
        let iconView = NSImageView(frame: NSRect(x: contentX, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.identifier = NSUserInterfaceItemIdentifier("onboarding-hero-icon")
        iconView.setAccessibilityLabel("KRIT app icon")
        page.addSubview(iconView)

        let title = NSTextField(wrappingLabelWithString: pageTitles[0])
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .left
        title.frame = NSRect(x: contentX + iconSize + 18, y: y - 30, width: contentW - iconSize - 18, height: 30)
        page.addSubview(title)

        let summary = NSTextField(wrappingLabelWithString: "KRIT keeps the messy screen-to-share loop in one native Mac tool: precise capture, built-in cleanup, and output that lands where the work continues.")
        summary.font = KritType.body.nsFont
        summary.textColor = .secondaryLabelColor
        summary.alignment = .left
        summary.frame = NSRect(x: contentX + iconSize + 18, y: y - 90, width: contentW - iconSize - 18, height: 54)
        page.addSubview(summary)
        y -= 120

        let surfaceH: CGFloat = 214
        let surface = makeInsetSurface(frame: NSRect(x: contentX, y: y - surfaceH, width: contentW, height: surfaceH))
        surface.identifier = NSUserInterfaceItemIdentifier("onboarding-workflow-list")
        page.addSubview(surface)

        let workflows: [(String, String, String)] = [
            ("01", "Capture", "Area, window, full screen, scrolling, OCR, and QR without leaving the keyboard."),
            ("02", "Polish", "Annotate, crop, blur sensitive text, pin results, and keep the original in history."),
            ("03", "Deliver", "Copy, save, paste into the next app, or hand the same capture flow to the CLI.")
        ]
        let rowH: CGFloat = surfaceH / CGFloat(workflows.count)
        for (index, workflow) in workflows.enumerated() {
            addWorkflowRow(
                number: workflow.0,
                title: workflow.1,
                detail: workflow.2,
                to: surface,
                frame: NSRect(
                    x: 0,
                    y: surfaceH - CGFloat(index + 1) * rowH,
                    width: contentW,
                    height: rowH
                )
            )
            if index < workflows.count - 1 {
                addHairline(
                    to: surface,
                    frame: NSRect(x: 22, y: surfaceH - CGFloat(index + 1) * rowH, width: contentW - 44, height: 1)
                )
            }
        }

        return page
    }

    /// Page 2, Screen Recording permission with a live status card.
    private func makePermissionPage() -> NSView {
        let page = NSView(frame: pageBounds)
        let w = page.bounds.width
        var y = page.bounds.height - 44

        y = addHero(symbol: "lock.shield", title: pageTitles[1], to: page, topY: y)

        let desc = NSTextField(wrappingLabelWithString: "KRIT needs the macOS Screen Recording permission to capture screenshots, record your screen, read text with OCR, and scan QR codes. Captures stay on your Mac unless you choose to share them.")
        desc.font = .systemFont(ofSize: 12.5)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 84, y: y - 50, width: w - 168, height: 50)
        page.addSubview(desc)
        y -= 70

        // Status card: dot + label on the left, grant button on the right.
        let cardW: CGFloat = w - 168
        let cardH: CGFloat = 58
        let card = makeInsetSurface(frame: NSRect(x: 84, y: y - cardH, width: cardW, height: cardH))
        page.addSubview(card)

        let dot = NSView(frame: NSRect(x: 18, y: (cardH - 10) / 2, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        card.addSubview(dot)
        permissionStatusDot = dot

        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.frame = NSRect(x: 38, y: (cardH - 18) / 2, width: 220, height: 18)
        card.addSubview(status)
        permissionStatusLabel = status

        let grant = makeCoralButton(title: "Grant Permission", action: #selector(grantClicked))
        grant.frame = NSRect(x: cardW - 150 - 14, y: (cardH - 30) / 2, width: 150, height: 30)
        card.addSubview(grant)
        permissionGrantButton = grant

        y -= cardH + 18

        let note = NSTextField(wrappingLabelWithString: "macOS may ask you to reopen KRIT after enabling it in System Settings.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 84, y: y - 28, width: w - 168, height: 28)
        page.addSubview(note)

        return page
    }

    /// Page 3, capture shortcuts as keycap rows.
    private func makeShortcutsPage() -> NSView {
        let page = NSView(frame: pageBounds)
        let w = page.bounds.width
        var y = page.bounds.height - 44

        y = addHero(symbol: "keyboard", title: pageTitles[2], to: page, topY: y)
        y -= 6

        let shortcuts: [(String, String)] = [
            ("⌘ ⇧ 4", "Capture area"),
            ("⌘ ⇧ 5", "Capture window"),
            ("⌘ ⇧ 3", "Capture full screen"),
            ("⌘ ⇧ 7", "Repeat last area"),
            ("⌘ ⇧ O", "Capture text (OCR)"),
            ("⌘ ⇧ S", "Scrolling capture"),
        ]
        let colWidth = (w - 128) / 2
        let rowHeight: CGFloat = 38
        for (i, item) in shortcuts.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = 64 + CGFloat(col) * colWidth
            let rowY = y - CGFloat(row + 1) * rowHeight

            let keycapW: CGFloat = 74
            let keycap = NSTextField(labelWithString: item.0)
            keycap.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            keycap.alignment = .center
            keycap.wantsLayer = true
            keycap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            keycap.layer?.cornerRadius = ChromeFactory.Radius.pill
            keycap.layer?.borderWidth = 1
            keycap.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            keycap.frame = NSRect(x: x, y: rowY + 6, width: keycapW, height: 24)
            page.addSubview(keycap)

            let label = NSTextField(labelWithString: item.1)
            label.font = .systemFont(ofSize: 12.5)
            label.frame = NSRect(x: x + keycapW + 12, y: rowY + 9, width: colWidth - keycapW - 16, height: 17)
            page.addSubview(label)
        }
        y -= CGFloat(3) * rowHeight + 18

        let note = NSTextField(wrappingLabelWithString: "KRIT uses the shortcuts you already know. After this, it offers to take over the overlapping macOS ones so captures never double-trigger.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 84, y: y - 30, width: w - 168, height: 30)
        page.addSubview(note)

        return page
    }

    /// Page 4, the agent-native story (CLI + MCP).
    private func makeAgentPage() -> NSView {
        let page = NSView(frame: pageBounds)
        let w = page.bounds.width
        var y = page.bounds.height - 58

        let title = NSTextField(wrappingLabelWithString: pageTitles[3])
        title.font = KritType.largeTitle.nsFont
        title.alignment = .center
        title.frame = NSRect(x: 72, y: y - 30, width: w - 144, height: 30)
        page.addSubview(title)
        y -= 42

        let desc = NSTextField(wrappingLabelWithString: "Use the same local capture engine from scripts and MCP clients: grab an area, run OCR, and pass the result into the next step without an external service.")
        desc.font = .systemFont(ofSize: 12.5)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 84, y: y - 50, width: w - 168, height: 50)
        page.addSubview(desc)
        y -= 72

        // Terminal-style chip with a real command.
        let chipW: CGFloat = 360
        let chipH: CGFloat = 40
        let chip = NSView(frame: NSRect(x: (w - chipW) / 2, y: y - chipH, width: chipW, height: chipH))
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        chip.layer?.cornerRadius = ChromeFactory.Radius.control
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        page.addSubview(chip)

        let prompt = NSTextField(labelWithString: "$")
        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        prompt.textColor = KritColors.accent
        prompt.frame = NSRect(x: 16, y: (chipH - 18) / 2, width: 14, height: 18)
        chip.addSubview(prompt)

        let cmd = NSTextField(labelWithString: "krit capture --area --ocr")
        cmd.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        cmd.textColor = NSColor.white.withAlphaComponent(0.92)
        cmd.frame = NSRect(x: 34, y: (chipH - 18) / 2, width: chipW - 50, height: 18)
        chip.addSubview(cmd)

        y -= chipH + 20

        let ready = NSTextField(labelWithString: "You're all set.")
        ready.font = .systemFont(ofSize: 13, weight: .semibold)
        ready.alignment = .center
        ready.frame = NSRect(x: 20, y: y - 20, width: w - 40, height: 20)
        page.addSubview(ready)

        return page
    }

    /// Shared hero block: one meaningful symbol and title. Returns the next y.
    private func addHero(symbol: String, title: String, to page: NSView, topY: CGFloat) -> CGFloat {
        let w = page.bounds.width
        var y = topY

        let iconSize: CGFloat = 34
        let icon = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: y - iconSize, width: iconSize, height: iconSize))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        icon.contentTintColor = KritColors.accent
        icon.identifier = NSUserInterfaceItemIdentifier("onboarding-hero-symbol-\(symbol)")
        page.addSubview(icon)
        y -= iconSize + 16

        let titleField = NSTextField(labelWithString: title)
        titleField.font = KritType.largeTitle.nsFont
        titleField.alignment = .center
        titleField.frame = NSRect(x: 20, y: y - 26, width: w - 40, height: 26)
        page.addSubview(titleField)
        y -= 34

        return y
    }

    private func addWorkflowRow(number: String, title: String, detail: String, to parent: NSView, frame: NSRect) {
        let numberField = NSTextField(labelWithString: number)
        numberField.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        numberField.textColor = KritColors.accent
        numberField.alignment = .left
        numberField.frame = NSRect(x: 24, y: frame.maxY - 28, width: 34, height: 16)
        parent.addSubview(numberField)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.alignment = .left
        titleField.frame = NSRect(x: 68, y: frame.maxY - 29, width: frame.width - 92, height: 18)
        parent.addSubview(titleField)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .left
        detailField.frame = NSRect(x: 68, y: frame.minY + 8, width: frame.width - 92, height: 30)
        parent.addSubview(detailField)
    }

    private func addHairline(to parent: NSView, frame: NSRect) {
        let line = NSView(frame: frame)
        line.wantsLayer = true
        line.layer?.backgroundColor = KritColors.insetSurfaceStroke.withAlphaComponent(0.75).cgColor
        parent.addSubview(line)
    }

    // MARK: - Hero entrance

    /// Welcome icon springs in on first show; skipped under Reduce Motion.
    private func animateHeroEntrance() {
        guard !Motion.reduced,
              let firstPage = pages.first ?? nil,
              let icon = firstPage.subviews.first(where: {
                  $0.identifier?.rawValue == "onboarding-hero-icon"
              }) else { return }
        icon.wantsLayer = true
        guard let layer = icon.layer else { return }

        let spring = Motion.gentle()
        spring.keyPath = "transform.scale"
        spring.fromValue = 0.9
        spring.toValue = 1.0
        spring.initialVelocity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.Duration.quick

        // Scale from the icon's center.
        layer.position = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.add(spring, forKey: "entranceScale")
        layer.add(fade, forKey: "entranceFade")
    }

    // MARK: - Permission polling

    private func startPermissionPolling() {
        refreshPermissionStatus()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshPermissionStatus() }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func refreshPermissionStatus() {
        let granted = PermissionsManager.hasScreenRecordingPermission
        permissionStatusDot?.layer?.backgroundColor =
            (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        permissionStatusLabel?.stringValue = granted ? "Screen Recording granted" : "Permission not granted yet"
        permissionGrantButton?.isHidden = granted
    }

    // MARK: - Coral primary button

    /// Native rounded push button tinted with the brand coral via `bezelColor`,
    /// the same accent treatment QRCodeResultWindow gives its default button.
    /// AppKit owns the bezel, height and label contrast.
    private func makeCoralButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.bezelColor = KritColors.accent
        return btn
    }

    private func makeInsetSurface(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = KritColors.insetSurface.cgColor
        view.layer?.cornerRadius = ChromeFactory.Radius.card
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = KritColors.insetSurfaceStroke.cgColor
        return view
    }

    private func setCoralTitle(_ btn: NSButton, _ title: String) {
        btn.title = title
    }

    // MARK: - Actions

    @objc private func continueClicked() {
        if pageIndex == pages.count - 1 {
            completedWelcome = true
            Settings.hasLaunchedBefore = true
            closeWindow()
        } else {
            showPage(pageIndex + 1, animated: true, forward: true)
        }
    }

    @objc private func backClicked() {
        showPage(pageIndex - 1, animated: true, forward: false)
    }

    @objc private func grantClicked() {
        let granted = PermissionsManager.requestScreenRecordingPermission()
        if granted {
            refreshPermissionStatus()
            return
        }
        if Settings.didRequestScreenRecordingPermission {
            showRestartAfterPermissionAlert()
        } else {
            PermissionsManager.openScreenRecordingSettings()
        }
    }

    @objc private func skipClicked() {
        Settings.hasLaunchedBefore = true
        closeWindow()
    }

    private func showRestartAfterPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Finish Permission in System Settings"
        alert.informativeText = "After enabling KRIT in Screen & System Audio Recording, quit and reopen KRIT so macOS applies the permission."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.openScreenRecordingSettings()
        }
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing via the traffic light counts as "seen" too, never re-show.
        Settings.hasLaunchedBefore = true
        stopPermissionPolling()
        window = nil
        let closeHandler = onClose
        onClose = nil
        closeHandler?()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }

    private func configureAccessibility(for page: NSView, index: Int) {
        page.identifier = NSUserInterfaceItemIdentifier("onboarding-page-\(index + 1)")
        page.setAccessibilityElement(true)
        page.setAccessibilityRole(.group)
        page.setAccessibilityLabel(accessibilityPageSummary(for: index))
    }

    private func updateAccessibilityForCurrentPage() {
        let page = page(at: pageIndex)
        page.setAccessibilityLabel(accessibilityPageSummary(for: pageIndex))
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, self.window != nil else { return }
            self.window?.makeFirstResponder(self.continueButton)
            NSAccessibility.post(element: page, notification: .focusedUIElementChanged)
        }
    }

    private func accessibilityPageSummary(for index: Int) -> String {
        let safeIndex = min(max(index, 0), pageTitles.count - 1)
        return "\(pageTitles[safeIndex]), page \(safeIndex + 1) of \(pages.count)"
    }

    private static func pageTransitionDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : Motion.Duration.standard
    }
}

// MARK: - UI test hooks

extension WelcomeWindowController {

    /// Test-only: forces the window up regardless of the first-launch flag,
    /// without touching Settings.
    func uiTestForceShow() {
        showWindow()
        window?.sharingType = .readOnly
    }

    var uiTestPageCount: Int { pages.count }
    var uiTestBuiltPageCount: Int { pages.compactMap(\.self).count }
    var uiTestContinueTitle: String { continueButton?.title ?? "" }
    var uiTestWindow: NSWindow? { window }
    var uiTestPageIndicatorAccessibilityLabel: String? { pageIndicator?.accessibilityLabel() }
    var uiTestCurrentPageAccessibilityLabel: String? {
        page(at: pageIndex).accessibilityLabel()
    }

    static func uiTestPageTransitionDuration(reduceMotion: Bool) -> TimeInterval {
        pageTransitionDuration(reduceMotion: reduceMotion)
    }

    func uiTestContinue() {
        continueClicked()
    }

    func uiTestSkip() {
        skipClicked()
    }

    func uiTestTextContent(onPage index: Int) -> [String] {
        collectText(in: page(at: index))
    }

    func uiTestViewIdentifiers(onPage index: Int) -> [String] {
        collectIdentifiers(in: page(at: index))
    }

    var uiTestWorkflowTextDoesNotOverlap: Bool {
        guard let surface = findView(
            in: page(at: 0),
            identifier: "onboarding-workflow-list"
        ) else { return false }
        let fields = surface.subviews.compactMap { $0 as? NSTextField }
        for leftIndex in fields.indices {
            for rightIndex in fields.indices where rightIndex > leftIndex {
                if fields[leftIndex].frame.intersects(fields[rightIndex].frame) { return false }
            }
        }
        return true
    }

    /// Walks every page (no animation) and snapshots the REAL window as the
    /// WindowServer composites it (glass, dark mode, vibrancy), cacheDisplay
    /// can't render those, so it lies about what the user sees. Falls back to
    /// cacheDisplay when window capture is unavailable.
    func uiTestRenderAllPages(toDirectory dir: String) async -> [String] {
        guard let window, let content = window.contentView else { return [] }
        var paths: [String] = []
        for i in 0..<pages.count {
            let visiblePage = page(at: i)
            showPage(i, animated: false)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            visiblePage.layoutSubtreeIfNeeded()
            visiblePage.displayIfNeeded()
            // Give the WindowServer a beat to composite the new page.
            try? await Task.sleep(nanoseconds: 250_000_000)

            let winID = CGWindowID(window.windowNumber)
            var data: Data?
            if let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, winID,
                [.boundsIgnoreFraming, .bestResolution]
            ), ScreenshotVisualQuality.hasVisibleContent(cg) {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            if data == nil {
                data = uiTestFallbackSnapshotData(of: visiblePage)
            }

            let path = (dir as NSString).appendingPathComponent("onboarding-page\(i + 1).png")
            if let data, (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                paths.append(path)
            }
        }
        return paths
    }

    private func uiTestFallbackSnapshotData(of view: NSView) -> Data? {
        guard let sourceRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: sourceRep)
        guard let sourceImage = sourceRep.cgImage else { return nil }

        let pixelWidth = max(1, Int(view.bounds.width))
        let pixelHeight = max(1, Int(view.bounds.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        NSImage(cgImage: sourceImage, size: view.bounds.size).draw(
            in: view.bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage, ScreenshotVisualQuality.hasVisibleContent(cg) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Test-only teardown that bypasses the "seen" flag side effect by
    /// clearing the close handler first.
    func uiTestClose(restoringHasLaunchedBefore value: Bool) {
        onClose = nil
        window?.close()
        Settings.hasLaunchedBefore = value
    }

    private func collectText(in view: NSView) -> [String] {
        let own: [String]
        if let label = view as? NSTextField, !label.stringValue.isEmpty {
            own = [label.stringValue]
        } else {
            own = []
        }
        return own + view.subviews.flatMap { collectText(in: $0) }
    }

    private func collectIdentifiers(in view: NSView) -> [String] {
        let own = view.identifier.map { [$0.rawValue] } ?? []
        return own + view.subviews.flatMap { collectIdentifiers(in: $0) }
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let match = findView(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}
