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
    private let notesVersion: String
    private let notesMarkdown: String

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
        notesVersion = version
        notesMarkdown = notes.body
        let root = WhatsNewView(version: version, markdown: notes.body) { Self.shared?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "What's New"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 600, height: 640))
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

    static func uiTestRenderSnapshot(to path: String) -> Bool {
        guard let controller = shared else { return false }
        let root = WhatsNewView(
            version: controller.notesVersion,
            markdown: controller.notesMarkdown,
            onClose: {}
        )
        let renderer = ImageRenderer(content: root.snapshotBody.environment(\.colorScheme, .dark))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.proposedSize = ProposedViewSize(width: 600, height: 640)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - View

struct WhatsNewDocument: Equatable {
    enum Block: Equatable {
        case paragraph(String)
        case bullet(String)
        case code(language: String?, body: String)

        var text: String {
            switch self {
            case .paragraph(let text), .bullet(let text): return text
            case .code(_, let body): return body
            }
        }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let blocks: [Block]

        var id: String { title }

        var items: [String] {
            blocks.compactMap {
                if case .bullet(let item) = $0 { return item }
                return nil
            }
        }

        func bulletNumber(at blockIndex: Int) -> Int {
            blocks.prefix(blockIndex + 1).reduce(0) { count, block in
                if case .bullet = block { return count + 1 }
                return count
            }
        }
    }

    let introduction: [String]
    let sections: [Section]

    var summary: String {
        introduction.first ?? sections.first?.blocks.first?.text ?? "A focused KRIT update."
    }

    var supportingIntroduction: [String] {
        Array(introduction.dropFirst())
    }

    var chapterTitles: [String] {
        sections.map(\.title)
    }

    static func parse(_ markdown: String) -> WhatsNewDocument {
        var introduction: [String] = []
        var sections: [Section] = []
        var title: String?
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var isInCodeBlock = false
        var codeLanguage: String?
        var codeLines: [String] = []

        func flushSection() {
            flushParagraph()
            guard let title else { return }
            sections.append(Section(title: title, blocks: blocks))
            blocks.removeAll(keepingCapacity: true)
        }

        func flushParagraph() {
            let paragraph = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            guard !paragraph.isEmpty else { return }
            if title == nil {
                introduction.append(paragraph)
            } else {
                blocks.append(.paragraph(paragraph))
            }
        }

        func flushCode() {
            let body = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            codeLines.removeAll(keepingCapacity: true)
            isInCodeBlock = false
            defer { codeLanguage = nil }
            guard !body.isEmpty else { return }
            blocks.append(.code(language: codeLanguage, body: body))
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isInCodeBlock {
                if line.hasPrefix("```") {
                    flushCode()
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                isInCodeBlock = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if codeLanguage?.isEmpty == true { codeLanguage = nil }
                continue
            }

            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") || line.hasPrefix("## ") {
                flushSection()
                title = String(line.drop(while: { $0 == "#" || $0 == " " }))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                let item = String(line.dropFirst(2))
                if title == nil { introduction.append(item) } else { blocks.append(.bullet(item)) }
            } else if title == nil {
                paragraphLines.append(line)
            } else {
                paragraphLines.append(line)
            }
        }
        if isInCodeBlock {
            flushCode()
        }
        flushParagraph()
        flushSection()
        return WhatsNewDocument(introduction: introduction, sections: sections)
    }
}

private struct WhatsNewView: View {
    let version: String
    let markdown: String
    let onClose: () -> Void

    private enum Metrics {
        static let windowWidth: CGFloat = 600
        static let windowHeight: CGFloat = 640
        static let readingWidth: CGFloat = 456
        static let iconSize: CGFloat = 38
    }

    private var document: WhatsNewDocument { .parse(markdown) }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack(alignment: .top) {
                ScrollView {
                    documentContent
                }

                KritEdgeDissolve()
            }

            footer
        }
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight)
        .kritTheme()
    }

    var snapshotBody: some View {
        VStack(spacing: 0) {
            header
            documentContent
                .frame(height: 470, alignment: .top)
                .clipped()
            footer
        }
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight, alignment: .top)
        .kritTheme()
    }

    private var documentContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            digestLead

            if !document.supportingIntroduction.isEmpty {
                VStack(alignment: .leading, spacing: KritSpacing.m) {
                    ForEach(Array(document.supportingIntroduction.enumerated()), id: \.offset) { _, paragraph in
                        inlineText(paragraph)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, KritSpacing.xl)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(document.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 {
                        hairline
                            .padding(.vertical, KritSpacing.xxl)
                    } else {
                        Spacer()
                            .frame(height: KritSpacing.xxl)
                    }
                    releaseSection(section)
                }
            }
        }
        .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, KritSpacing.xl)
        .padding(.bottom, KritSpacing.xxxl)
    }

    private var footer: some View {
        ZStack(alignment: .top) {
            KritEdgeDissolve(.up)
                .offset(y: -10)

            HStack {
                Text("KRIT \(version) release digest")
                    .kritType(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Continue", action: onClose)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close what's new")
            }
            .padding(.horizontal, KritSpacing.xxxl)
            .padding(.vertical, KritSpacing.l)
        }
    }

    private var header: some View {
        HStack(spacing: KritSpacing.l) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: KritSpacing.xxs) {
                Text("What's New")
                    .kritType(.title)
                Text("KRIT \(version)")
                    .kritType(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, KritSpacing.xxxl)
        .padding(.top, KritSpacing.xxl)
        .padding(.bottom, KritSpacing.l)
        .accessibilityElement(children: .combine)
    }

    private var digestLead: some View {
        VStack(alignment: .leading, spacing: KritSpacing.m) {
            Text("Release digest")
                .kritType(.caption)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            inlineText(document.summary)
                .kritType(.largeTitle)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func releaseSection(_ section: WhatsNewDocument.Section) -> some View {
        VStack(alignment: .leading, spacing: KritSpacing.l) {
            Text(section.title)
                .kritType(.heading)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: KritSpacing.m) {
                ForEach(Array(section.blocks.enumerated()), id: \.offset) { index, block in
                    sectionBlock(block, bulletNumber: section.bulletNumber(at: index))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionBlock(_ block: WhatsNewDocument.Block, bulletNumber: Int) -> some View {
        switch block {
        case .paragraph(let paragraph):
            inlineText(paragraph)
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let item):
            HStack(alignment: .firstTextBaseline, spacing: KritSpacing.l) {
                Text(String(format: "%02d", bulletNumber))
                    .kritType(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .leading)
                    .accessibilityHidden(true)
                inlineText(item)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(_, let body):
            codeBlock(body)
        }
    }

    private func codeBlock(_ body: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(body)
                .font(KritType.mono.font)
                .foregroundStyle(.primary.opacity(0.88))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(KritSpacing.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ChromeFactory.Radius.card, style: .continuous)
                .fill(Color.kritInsetSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChromeFactory.Radius.card, style: .continuous)
                .stroke(Color.kritInsetSurfaceStroke, lineWidth: 1)
        )
    }

    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s) {
            return Text(attr).kritType(.body)
        }
        return Text(s).kritType(.body)
    }
}
