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

    static func showIfNeeded(isFirstLaunchThisSession: Bool = false) {
        let current = WhatsNewStore.appVersion
        if isFirstLaunchThisSession || !Settings.hasLaunchedBefore {
            Settings.lastWhatsNewVersion = current
            return
        }
        guard let notes = WhatsNewStore.load() else { return }
        guard shouldShow(current: current, lastSeen: Settings.lastWhatsNewVersion,
                         hasLaunched: Settings.hasLaunchedBefore, notesVersion: notes.version) else { return }
        present(notes: notes)
        Settings.lastWhatsNewVersion = current
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
        window.setContentSize(NSSize(width: 520, height: 600))
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

struct WhatsNewDocument: Equatable {
    struct Section: Equatable, Identifiable {
        let title: String
        let items: [String]

        var id: String { title }
    }

    let introduction: [String]
    let sections: [Section]

    static func parse(_ markdown: String) -> WhatsNewDocument {
        var introduction: [String] = []
        var sections: [Section] = []
        var title: String?
        var items: [String] = []

        func flushSection() {
            guard let title else { return }
            sections.append(Section(title: title, items: items))
            items.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("### ") || line.hasPrefix("## ") {
                flushSection()
                title = String(line.drop(while: { $0 == "#" || $0 == " " }))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2))
                if title == nil { introduction.append(item) } else { items.append(item) }
            } else if title == nil {
                introduction.append(line)
            } else {
                items.append(line)
            }
        }
        flushSection()
        return WhatsNewDocument(introduction: introduction, sections: sections)
    }
}

private struct WhatsNewView: View {
    let version: String
    let markdown: String
    let onClose: () -> Void

    private var document: WhatsNewDocument { .parse(markdown) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: KritSpacing.l) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: KritSpacing.xxs) {
                    Text("What's New")
                        .kritType(.largeTitle)
                    Text("KRIT \(version)")
                        .kritType(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, KritSpacing.xxxl)
            .padding(.top, KritSpacing.xxxl)
            .padding(.bottom, KritSpacing.xxl)

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: KritSpacing.l) {
                        ForEach(Array(document.introduction.enumerated()), id: \.offset) { _, paragraph in
                            inlineText(paragraph)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(document.sections) { section in
                            releaseSection(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KritSpacing.xxxl)
                    .padding(.top, KritSpacing.m)
                    .padding(.bottom, KritSpacing.xxl)
                }

                KritEdgeDissolve()
            }

            ZStack(alignment: .top) {
                KritEdgeDissolve(.up)
                    .offset(y: -10)

                HStack {
                    Text("Release notes for this update")
                        .kritType(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Continue", action: onClose)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, KritSpacing.xxxl)
                .padding(.vertical, KritSpacing.l)
            }
        }
        .frame(width: 520, height: 600)
        .kritTheme()
    }

    private func releaseSection(_ section: WhatsNewDocument.Section) -> some View {
        KritInsetCard {
            VStack(alignment: .leading, spacing: KritSpacing.m) {
                Text(section.title)
                    .kritType(.heading)

                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: KritSpacing.m) {
                        Circle()
                            .fill(Color.kritAccent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        inlineText(item)
                            .foregroundStyle(.primary.opacity(0.9))
                    }
                }
            }
        }
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s) {
            return Text(attr).kritType(.body)
        }
        return Text(s).kritType(.body)
    }
}
