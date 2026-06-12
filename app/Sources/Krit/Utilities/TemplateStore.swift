import AppKit

/// A named editing template: a snapshot of the background configuration the user
/// likes (gradient/wallpaper/solid + padding, corners, shadow, inset, alignment,
/// aspect). "Edit defaults" in the parity spec maps to this background config,
/// per-tool defaults (color/width/font) live at runtime on the canvas and are not
/// persisted, so they are intentionally out of scope here.
struct EditTemplate: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var background: ScreenshotBackgroundOptions

    init(id: UUID = UUID(), name: String, background: ScreenshotBackgroundOptions) {
        self.id = id
        self.name = name
        self.background = background
    }
}

/// Persistence + lookup for `EditTemplate`s. Mirrors the `enum Settings` pattern:
/// pure static API, no instance state. The encoded blob lives in
/// `Settings.editTemplatesData` (UserDefaults).
///
/// Note on size: a template carries the full `ScreenshotBackgroundOptions`,
/// including `customImageData` for uploaded backgrounds / decoded wallpapers,
/// which can be multiple MB. Several such templates in one UserDefaults blob is
/// heavy but acceptable for the parity scope; no external file storage is added.
enum TemplateStore {

    // The encoded blob can be multiple MB (it embeds customImageData). Decoding it
    // on every all() call, which the sidebar does several times per interaction and
    // per thumbnail-highlight pass, is wasteful, so decode once and cache. The
    // cache is invalidated on every write (save).
    @MainActor private static var cache: [EditTemplate]?

    @MainActor
    static func all() -> [EditTemplate] {
        if let cache { return cache }
        guard let data = Settings.editTemplatesData, !data.isEmpty else {
            cache = []
            return []
        }
        // Defensive at the persistence boundary: corrupt or schema-drifted data
        // decodes to [] (drops old templates) instead of crashing the editor.
        let decoded = (try? JSONDecoder().decode([EditTemplate].self, from: data)) ?? []
        cache = decoded
        return decoded
    }

    @MainActor
    private static func save(_ templates: [EditTemplate]) {
        Settings.editTemplatesData = try? JSONEncoder().encode(templates)
        cache = templates
    }

    /// Adds a template, or overwrites the existing one with the same (case-insensitive)
    /// name so saving twice under one name never produces a duplicate. Empty names
    /// are rejected (nil); the UI validates before calling.
    @MainActor @discardableResult
    static func add(name: String, background: ScreenshotBackgroundOptions) -> EditTemplate? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var templates = all()
        if let index = templates.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            templates[index].name = trimmed
            templates[index].background = background
            save(templates)
            return templates[index]
        }

        let template = EditTemplate(name: trimmed, background: background)
        templates.append(template)
        save(templates)
        return template
    }

    /// Overwrites the template identified by `id` with the current settings,
    /// optionally renaming it. Returns nil if the id is gone or the new name
    /// collides with a DIFFERENT template (the UI should surface that). When the
    /// updated template is the current default, the stored default name is kept in
    /// sync so a rename never silently orphans the default.
    @MainActor @discardableResult
    static func update(id: UUID, name: String? = nil, background: ScreenshotBackgroundOptions) -> EditTemplate? {
        var templates = all()
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return nil }

        let oldName = templates[index].name
        var newName = oldName
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let collides = templates.contains {
                $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            guard !collides else { return nil }
            newName = trimmed
        }

        templates[index].name = newName
        templates[index].background = background
        save(templates)

        if oldName.caseInsensitiveCompare(Settings.defaultTemplateName) == .orderedSame {
            Settings.defaultTemplateName = newName
        }
        if oldName.caseInsensitiveCompare(Settings.activePresetName) == .orderedSame {
            Settings.activePresetName = newName
        }
        return templates[index]
    }

    /// Renames a template, keeping its saved background untouched. Returns nil on
    /// empty name or a collision with another template.
    @MainActor @discardableResult
    static func rename(id: UUID, to name: String) -> EditTemplate? {
        guard let existing = all().first(where: { $0.id == id }) else { return nil }
        return update(id: id, name: name, background: existing.background)
    }

    @MainActor
    static func delete(id: UUID) {
        let templates = all()
        guard let removed = templates.first(where: { $0.id == id }) else { return }
        save(templates.filter { $0.id != id })
        // Deleting the default preset resets the default to None (parity E2).
        if removed.name.caseInsensitiveCompare(Settings.defaultTemplateName) == .orderedSame {
            Settings.defaultTemplateName = ""
        }
        // Deleting the selected preset drops the dropdown back to a custom state.
        if removed.name.caseInsensitiveCompare(Settings.activePresetName) == .orderedSame {
            Settings.activePresetName = ""
        }
    }

    @MainActor
    static func template(named name: String) -> EditTemplate? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    @MainActor
    static var defaultTemplate: EditTemplate? {
        template(named: Settings.defaultTemplateName)
    }

    /// The background config every new screenshot should open and present with, or
    /// nil when there's no default (the standard "raw shot" state). Only returns a
    /// config that's actually enabled, a default whose background is "None" is the
    /// same as having no default, so callers stay on the raw path. Single source of
    /// truth for the editor's initial options and the overlay/clipboard/save
    /// composition.
    @MainActor
    static func defaultBackgroundOptions(for screen: NSScreen? = nil) -> ScreenshotBackgroundOptions? {
        guard let background = defaultTemplate?.background, background.isEnabled else { return nil }
        // Desktop-tracking templates resolve the wallpaper of the screen they
        // are being applied on now, not the one embedded at save time.
        return background.resolvingDesktopWallpaper(for: screen)
    }

    /// True when the template is the one the "Saved template" window shot uses.
    @MainActor
    static func isDefault(id: UUID) -> Bool {
        guard let template = all().first(where: { $0.id == id }) else { return false }
        return template.name.caseInsensitiveCompare(Settings.defaultTemplateName) == .orderedSame
    }

    static func setDefault(name: String?) {
        Settings.defaultTemplateName = name ?? ""
    }
}

// MARK: - Active preset selection (sidebar dropdown)

extension TemplateStore {

    /// The named preset currently selected in the background dropdown, or nil when
    /// the background is a custom, unsaved state. Selection is tracked by name so a
    /// rename keeps following the same preset.
    @MainActor
    static var activePreset: EditTemplate? {
        let name = Settings.activePresetName
        guard !name.isEmpty else { return nil }
        return all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Marks `name` as the selected preset (empty clears the selection back to a
    /// custom state). The sidebar calls this when the user picks a preset and clears
    /// it when they edit the background by hand.
    static func setActive(name: String?) {
        Settings.activePresetName = name ?? ""
    }

    /// Snapshots the background that was active right before a preset is applied, so
    /// "Apply Previous Settings" can restore it.
    @MainActor
    static func recordPrevious(_ options: ScreenshotBackgroundOptions) {
        Settings.previousBackgroundData = try? JSONEncoder().encode(options)
    }

    /// The background captured by the most recent `recordPrevious`, or nil when none
    /// has been recorded yet.
    @MainActor
    static var previousOptions: ScreenshotBackgroundOptions? {
        guard let data = Settings.previousBackgroundData, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ScreenshotBackgroundOptions.self, from: data)
    }
}

// MARK: - Shared drag-out temp file vault

/// Writes a flattened PNG to a temp file for an `NSDraggingSession` and keeps it
/// alive past drag start, cleaning it up later. Shared by the overlay card, the
/// editor drag handle, and the pinned window (genuine reuse across 3 call sites,
/// not a speculative abstraction). The overlay keeps its own private copy for now;
/// the editor and pin route through this.
enum DragFileVault {
    private static var retainedFiles: Set<URL> = []
    private static let cleanupDelay: TimeInterval = 300

    @MainActor
    static func makeFile(data: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KritDrag", isDirectory: true)
        let filename = "\(ImageExporter.timestampedName)-\(UUID().uuidString.prefix(8)).png"
        let url = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            retainedFiles.insert(url)
            return url
        } catch {
            print("[KRIT] Drag export failed at \(url.path): \(error)")
            return nil
        }
    }

    @MainActor
    static func scheduleCleanup(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) {
            try? FileManager.default.removeItem(at: url)
            retainedFiles.remove(url)
        }
    }
}
