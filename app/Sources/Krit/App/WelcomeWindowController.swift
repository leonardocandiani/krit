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
    private var pages: [NSView] = []
    private var pageIndex = 0
    private var pageContainer: NSView!
    private var dotLayers: [CALayer] = []
    private var backButton: NSButton!
    private var continueButton: NSButton!
    private var skipButton: NSButton!

    // Live permission status (page 2)
    private var permissionTimer: Timer?
    private var permissionStatusDot: NSView?
    private var permissionStatusLabel: NSTextField?
    private var permissionGrantButton: NSButton?

    private let cardWidth: CGFloat = 640
    private let cardHeight: CGFloat = 470
    private let footerHeight: CGFloat = 64

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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

        pages = [makeWelcomePage(), makePermissionPage(), makeShortcutsPage(), makeAgentPage()]
    }

    private func buildFooter(in container: NSView) {
        // Hairline above the footer
        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: 24, y: footerHeight, width: cardWidth - 48, height: 1)
        container.addSubview(sep)

        skipButton = NSButton(title: "Skip", target: self, action: #selector(skipClicked))
        skipButton.bezelStyle = .inline
        skipButton.isBordered = false
        skipButton.font = .systemFont(ofSize: 12)
        skipButton.contentTintColor = .tertiaryLabelColor
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
        for i in 0..<4 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * (dotSize + dotGap), y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dotsHost.layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
        container.addSubview(dotsHost)

        backButton = NSButton(title: "Back", target: self, action: #selector(backClicked))
        backButton.bezelStyle = .rounded
        backButton.frame = NSRect(x: cardWidth - 24 - 132 - 8 - 76, y: (footerHeight - 32) / 2, width: 76, height: 32)
        container.addSubview(backButton)

        continueButton = makeCoralButton(title: "Continue", action: #selector(continueClicked))
        continueButton.keyEquivalent = "\r"
        continueButton.frame = NSRect(x: cardWidth - 24 - 132, y: (footerHeight - 34) / 2, width: 132, height: 34)
        container.addSubview(continueButton)
    }

    private func showPage(_ index: Int, animated: Bool, forward: Bool = true) {
        guard index >= 0, index < pages.count else { return }
        let incoming = pages[index]
        let outgoing = pageContainer.subviews.first
        pageIndex = index

        incoming.frame = pageContainer.bounds
        pageContainer.addSubview(incoming)

        if animated, !reduceMotion, let outgoing, outgoing !== incoming {
            let shift: CGFloat = 36
            incoming.alphaValue = 0
            incoming.frame.origin.x = forward ? shift : -shift
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
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
        if index == 1 { startPermissionPolling() } else { stopPermissionPolling() }
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
    }

    // MARK: - Pages

    private var pageBounds: NSRect {
        NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight - footerHeight)
    }

    /// Page 1, hero icon, title, and a 2×3 grid of feature rows.
    private func makeWelcomePage() -> NSView {
        let page = NSView(frame: pageBounds)
        page.wantsLayer = true
        let w = page.bounds.width
        var y = page.bounds.height - 28

        let iconSize: CGFloat = 76
        let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.identifier = NSUserInterfaceItemIdentifier("onboarding-hero-icon")
        page.addSubview(iconView)
        y -= iconSize + 10

        let title = NSTextField(labelWithString: "Welcome to KRIT")
        title.font = .boldSystemFont(ofSize: 26)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: y - 30, width: w - 40, height: 30)
        page.addSubview(title)
        y -= 36

        let tagline = NSTextField(labelWithString: "Beautiful screenshots, built for you and your AI agent.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.frame = NSRect(x: 20, y: y - 18, width: w - 40, height: 18)
        page.addSubview(tagline)
        y -= 40

        let features: [(String, String)] = [
            ("viewfinder",                "Area, window & full-screen capture"),
            ("record.circle",             "Screen recording, GIF & webcam"),
            ("text.viewfinder",           "OCR: copy text from anything"),
            ("qrcode.viewfinder",         "QR code scanning"),
            ("pin",                       "Pin shots floating anywhere"),
            ("clock.arrow.circlepath",    "Local capture history"),
        ]
        let colWidth = (w - 96) / 2
        let rowHeight: CGFloat = 34
        for (i, feature) in features.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = 48 + CGFloat(col) * colWidth
            let rowY = y - CGFloat(row + 1) * rowHeight

            let chipSize: CGFloat = 24
            let chip = ChromeFactory.backing(
                frame: NSRect(x: x, y: rowY + (rowHeight - chipSize) / 2 - 2, width: chipSize, height: chipSize),
                cornerRadius: ChromeFactory.Radius.pill,
                tint: KritColors.accent.withAlphaComponent(0.14)
            )
            page.addSubview(chip)

            let icon = NSImageView(frame: NSRect(x: x + 4, y: rowY + (rowHeight - 16) / 2 - 2, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: feature.0, accessibilityDescription: nil)
            icon.contentTintColor = KritColors.accent
            page.addSubview(icon)

            let label = NSTextField(labelWithString: feature.1)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: x + chipSize + 10, y: rowY + (rowHeight - 16) / 2 - 2, width: colWidth - chipSize - 14, height: 16)
            page.addSubview(label)
        }

        return page
    }

    /// Page 2, Screen Recording permission with a live status card.
    private func makePermissionPage() -> NSView {
        let page = NSView(frame: pageBounds)
        let w = page.bounds.width
        var y = page.bounds.height - 44

        y = addHero(symbol: "lock.shield", title: "Allow Screen Recording", to: page, topY: y)

        let desc = NSTextField(wrappingLabelWithString: "KRIT needs the macOS Screen Recording permission to capture screenshots, record your screen, read text with OCR, and scan QR codes. Nothing ever leaves your Mac.")
        desc.font = .systemFont(ofSize: 12.5)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 84, y: y - 50, width: w - 168, height: 50)
        page.addSubview(desc)
        y -= 70

        // Status card: dot + label on the left, grant button on the right.
        let cardW: CGFloat = w - 168
        let cardH: CGFloat = 58
        let card = ChromeFactory.backing(
            frame: NSRect(x: 84, y: y - cardH, width: cardW, height: cardH),
            cornerRadius: ChromeFactory.Radius.card,
            tint: NSColor.white.withAlphaComponent(0.04)
        )
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
        note.textColor = .tertiaryLabelColor
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

        y = addHero(symbol: "keyboard", title: "Capture from anywhere", to: page, topY: y)
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
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 84, y: y - 30, width: w - 168, height: 30)
        page.addSubview(note)

        return page
    }

    /// Page 4, the agent-native story (CLI + MCP).
    private func makeAgentPage() -> NSView {
        let page = NSView(frame: pageBounds)
        let w = page.bounds.width
        var y = page.bounds.height - 44

        y = addHero(symbol: "sparkles", title: "Works with your AI agent", to: page, topY: y)

        let desc = NSTextField(wrappingLabelWithString: "KRIT ships a CLI and an MCP server, so Claude Code, Cursor, and any MCP client can take screenshots, read text on screen, and annotate, hands-free.")
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

    /// Shared hero block: coral chip + symbol + title. Returns the next y.
    private func addHero(symbol: String, title: String, to page: NSView, topY: CGFloat) -> CGFloat {
        let w = page.bounds.width
        var y = topY

        let chipSize: CGFloat = 56
        let chip = ChromeFactory.backing(
            frame: NSRect(x: (w - chipSize) / 2, y: y - chipSize, width: chipSize, height: chipSize),
            cornerRadius: ChromeFactory.Radius.card,
            tint: KritColors.accent.withAlphaComponent(0.16)
        )
        page.addSubview(chip)

        let icon = NSImageView(frame: NSRect(x: (w - 28) / 2, y: y - chipSize + 14, width: 28, height: 28))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        icon.contentTintColor = KritColors.accent
        page.addSubview(icon)
        y -= chipSize + 14

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 21)
        titleField.alignment = .center
        titleField.frame = NSRect(x: 20, y: y - 26, width: w - 40, height: 26)
        page.addSubview(titleField)
        y -= 34

        return y
    }

    // MARK: - Hero entrance

    /// Welcome icon springs in on first show; skipped under Reduce Motion.
    private func animateHeroEntrance() {
        guard !reduceMotion,
              let icon = pages.first?.subviews.first(where: {
                  $0.identifier?.rawValue == "onboarding-hero-icon"
              }) else { return }
        icon.wantsLayer = true
        guard let layer = icon.layer else { return }

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.6
        spring.toValue = 1.0
        spring.stiffness = 300
        spring.damping = 20
        spring.initialVelocity = 4
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3

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

    private func setCoralTitle(_ btn: NSButton, _ title: String) {
        btn.title = title
    }

    // MARK: - Actions

    @objc private func continueClicked() {
        if pageIndex == pages.count - 1 {
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
}

// MARK: - UI test hooks

extension WelcomeWindowController {

    /// Test-only: forces the window up regardless of the first-launch flag,
    /// without touching Settings.
    func uiTestForceShow() { showWindow() }

    var uiTestPageCount: Int { pages.count }
    var uiTestContinueTitle: String { continueButton?.title ?? "" }
    var uiTestWindow: NSWindow? { window }

    /// Walks every page (no animation) and snapshots the REAL window as the
    /// WindowServer composites it (glass, dark mode, vibrancy), cacheDisplay
    /// can't render those, so it lies about what the user sees. Falls back to
    /// cacheDisplay when window capture is unavailable.
    func uiTestRenderAllPages(toDirectory dir: String) async -> [String] {
        guard let window, let content = window.contentView else { return [] }
        var paths: [String] = []
        for i in 0..<pages.count {
            showPage(i, animated: false)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            // Give the WindowServer a beat to composite the new page.
            try? await Task.sleep(nanoseconds: 250_000_000)

            let winID = CGWindowID(window.windowNumber)
            var data: Data?
            if let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, winID,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            } else if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            let path = (dir as NSString).appendingPathComponent("onboarding-page\(i + 1).png")
            if let data, (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                paths.append(path)
            }
        }
        return paths
    }

    /// Test-only teardown that bypasses the "seen" flag side effect by
    /// clearing the close handler first.
    func uiTestClose(restoringHasLaunchedBefore value: Bool) {
        onClose = nil
        window?.close()
        Settings.hasLaunchedBefore = value
    }
}
