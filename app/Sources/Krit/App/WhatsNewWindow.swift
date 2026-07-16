import AppKit
import SwiftUI
import os

// "What's New" panel shown once after the app updates to a new version. The notes
// ship in a bundled WhatsNew.md (rewritten by scripts/release/release.sh on every
// release, so it always matches the build), gated on a version change so it never
// nags and never shows stale notes.

enum WhatsNewStore {
    struct Notes { let version: String; let body: String }
    private static let log = Logger(subsystem: "com.krit.app", category: "whats-new")

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Parses the bundled WhatsNew.md: a leading `version: X.Y.Z` line, then the
    /// markdown body. Returns nil when missing or empty.
    static func load() -> Notes? {
        guard let url = resourceURL(), let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.components(separatedBy: "\n")
        var version = ""
        if let first = lines.first, first.lowercased().hasPrefix("version:") {
            version = String(first.dropFirst("version:".count)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return Notes(version: version, body: body)
    }

    private static func resourceURL() -> URL? {
        let bundleName = "Krit_KritKit.bundle"
        for root in KritResourceBundleLocator.candidates(named: bundleName) {
            if let bundle = Bundle(url: root), let url = bundle.url(forResource: "WhatsNew", withExtension: "md") {
                return url
            }
            let direct = root.appendingPathComponent("WhatsNew.md")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        return nil
    }
}

// MARK: - Window controller

@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WhatsNewWindowController?

    /// Pure decision: show once per version, only after an update (never on a fresh
    /// install, where the welcome runs instead) and never for stale/mismatched notes.
    static func shouldShow(current: String, lastSeen: String, hasLaunched: Bool, notesVersion: String) -> Bool {
        guard hasLaunched else { return false }
        guard !current.isEmpty, lastSeen != current else { return false }
        return notesVersion == current
    }

    static func showIfNeeded() {
        let current = WhatsNewStore.appVersion
        defer { Settings.lastWhatsNewVersion = current }   // mark current as seen in every path
        guard let notes = WhatsNewStore.load() else { return }
        guard shouldShow(current: current, lastSeen: Settings.lastWhatsNewVersion,
                         hasLaunched: Settings.hasLaunchedBefore, notesVersion: notes.version) else { return }
        present(notes: notes)
    }

    /// Manual entry (menu): always shows whatever ships in this build.
    static func showNow() {
        guard let notes = WhatsNewStore.load() else { return }
        present(notes: notes)
    }

    private static func present(notes: WhatsNewStore.Notes) {
        shared?.close()
        let controller = WhatsNewWindowController(notes: notes)
        shared = controller
        NSApp.setActivationPolicy(.accessory)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(notes: WhatsNewStore.Notes) {
        let version = notes.version.isEmpty ? WhatsNewStore.appVersion : notes.version
        let root = WhatsNewView(version: version, markdown: notes.body) { Self.shared?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "What's New"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 460, height: 560))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if Self.shared === self { Self.shared = nil }
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: window)
    }

    /// GUI test hook: the panel is open and visible.
    static var uiTestIsOpen: Bool { shared?.window?.isVisible == true }
    static var uiTestWindow: NSWindow? { shared?.window }
    static func uiTestClose() { shared?.close() }
}

// MARK: - View

private struct WhatsNewView: View {
    let version: String
    let markdown: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("What's New")
                    .font(.system(size: 22, weight: .bold))
                Text("KRIT \(version)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }

            Divider()
            Button(action: onClose) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    // Minimal markdown: ## headings, - bullets, blank-line spacing, **bold** inline.
    private struct Block { let view: AnyView }

    private var blocks: [Block] {
        var result: [Block] = []
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("## ") {
                let text = String(line.dropFirst(3))
                result.append(Block(view: AnyView(
                    Text(text).font(.system(size: 14, weight: .semibold)).padding(.top, 6)
                )))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let text = String(line.dropFirst(2))
                result.append(Block(view: AnyView(
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 6)
                        inlineText(text)
                    }
                )))
            } else {
                result.append(Block(view: AnyView(inlineText(line))))
            }
        }
        return result
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s) {
            return Text(attr).font(.system(size: 13)).foregroundColor(.primary.opacity(0.9))
        }
        return Text(s).font(.system(size: 13))
    }
}
