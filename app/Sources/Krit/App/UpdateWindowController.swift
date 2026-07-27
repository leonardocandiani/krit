import AppKit
import SwiftUI

struct UpdateWindowContent: Equatable {
    let appName: String
    let version: String
    let build: String
    var automaticChecks: Bool
    let hasWhatsNew: Bool

    var versionLine: String { "Version \(version) (\(build))" }

    var automaticChecksLine: String {
        automaticChecks
            ? "KRIT checks for verified releases in the background."
            : "Background checks are off. You can still check manually."
    }

    static func current(automaticChecks: Bool) -> UpdateWindowContent {
        from(
            info: Bundle.main.infoDictionary ?? [:],
            automaticChecks: automaticChecks,
            hasWhatsNew: WhatsNewStore.load() != nil
        )
    }

    static func from(
        info: [String: Any],
        automaticChecks: Bool,
        hasWhatsNew: Bool = true
    ) -> UpdateWindowContent {
        let name = nonEmpty(info["CFBundleDisplayName"] as? String)
            ?? nonEmpty(info["CFBundleName"] as? String)
            ?? "KRIT"
        let version = nonEmpty(info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = nonEmpty(info["CFBundleVersion"] as? String) ?? "local"
        return UpdateWindowContent(
            appName: name,
            version: version,
            build: build,
            automaticChecks: automaticChecks,
            hasWhatsNew: hasWhatsNew
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct UpdateWindowActions {
    var checkNow: () -> Void
    var setAutomaticChecks: (Bool) -> Void
    var showWhatsNew: () -> Void
}

@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: UpdateWindowViewModel
    var onClose: (() -> Void)?

    init(content: UpdateWindowContent, actions: UpdateWindowActions) {
        let viewModel = UpdateWindowViewModel(content: content)
        self.viewModel = viewModel
        let rootView = UpdateWindowRootView(viewModel: viewModel, actions: actions)

        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView.kritTheme()))
        window.title = "KRIT Updates"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 520, height: 456))
        window.minSize = NSSize(width: 500, height: 420)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.accessory)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(content: UpdateWindowContent) {
        viewModel.content = content
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded(excluding: notification.object as? NSWindow)
    }
}

@MainActor
private final class UpdateWindowViewModel: ObservableObject {
    @Published var content: UpdateWindowContent

    init(content: UpdateWindowContent) {
        self.content = content
    }
}

@MainActor
private struct UpdateWindowRootView: View {
    @ObservedObject var viewModel: UpdateWindowViewModel
    private let actions: UpdateWindowActions

    init(viewModel: UpdateWindowViewModel, actions: UpdateWindowActions) {
        self.viewModel = viewModel
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.top, KritSpacing.xl)

            VStack(alignment: .leading, spacing: KritSpacing.xl) {
                status
                automaticChecks
                releaseNotes
            }
            .padding(.top, KritSpacing.xl)

            Spacer(minLength: KritSpacing.xl)

            footer
        }
        .padding(KritSpacing.xxxl)
        .frame(width: 520, height: 456, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: KritSpacing.l) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: KritSpacing.xxs) {
                Text("\(viewModel.content.appName) Updates")
                    .kritType(.largeTitle)
                    .foregroundStyle(.primary)
                Text(viewModel.content.versionLine)
                    .kritType(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: KritSpacing.l)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: KritSpacing.s) {
            Text("Keep KRIT current")
                .kritType(.heading)
            Text("Check for the latest release. KRIT verifies each download before handing it to the installer.")
                .kritType(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var automaticChecks: some View {
        VStack(alignment: .leading, spacing: KritSpacing.s) {
            Toggle(isOn: automaticChecksBinding) {
                Text("Check for updates automatically")
                    .kritType(.bodyEmphasis)
            }
            .toggleStyle(.switch)
            .accessibilityHint(Text("Changes Sparkle's background update check preference."))

            Text(viewModel.content.automaticChecksLine)
                .kritType(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var releaseNotes: some View {
        HStack(spacing: KritSpacing.l) {
            VStack(alignment: .leading, spacing: KritSpacing.s) {
                Text("Release notes")
                    .kritType(.bodyEmphasis)
                Text("Open the notes bundled with this build.")
                    .kritType(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("What's New", action: actions.showWhatsNew)
                .disabled(!viewModel.content.hasWhatsNew)
                .accessibilityLabel("Open what's new")
        }
    }

    private var footer: some View {
        HStack(spacing: KritSpacing.l) {
            Text("The update window will guide you through download and installation.")
                .kritType(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: KritSpacing.l)

            Button("Check Now", action: actions.checkNow)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Check for updates now")
        }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding {
            viewModel.content.automaticChecks
        } set: { enabled in
            viewModel.content.automaticChecks = enabled
            actions.setAutomaticChecks(enabled)
        }
    }
}
