import AppKit

/// A named capture region with a fixed rect, output format, and a chain of
/// post-capture actions. Triggered by its own global hotkey (when enabled) for a
/// headless one-key shot, no selection overlay. The rect is stored in GLOBAL
/// TOP-LEFT points (origin at the primary display's top-left), the same
/// convention `krit://` and the automation port use, so a preset round-trips
/// cleanly with those tools.
struct SnapPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Capture rect in global top-left points.
    var rect: CGRect
    /// "png" or "jpg" (jpg honors the global JPEG quality on save).
    var format: String
    /// Post-capture chain, applied in order.
    var actions: [CaptureAction]
    /// Whether this preset's global hotkey is registered.
    var hotkeyEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        rect: CGRect,
        format: String = "png",
        actions: [CaptureAction] = [.copy],
        hotkeyEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.rect = rect
        self.format = format
        self.actions = actions
        self.hotkeyEnabled = hotkeyEnabled
    }
}

/// Persistence + CRUD for `SnapPreset`s. Mirrors `TemplateStore`: pure static
/// API, Codable JSON blob in UserDefaults (`Settings.snapPresetsData`), decoded
/// once and cached, cache invalidated on every write.
@MainActor
enum PresetStore {

    /// Called after any mutation so the hotkey manager can re-register the
    /// dynamic per-preset shortcuts. Wired up by AppDelegate at launch.
    static var onChange: (() -> Void)?

    private static var cache: [SnapPreset]?

    static func all() -> [SnapPreset] {
        if let cache { return cache }
        guard let data = Settings.snapPresetsData, !data.isEmpty else {
            cache = []
            return []
        }
        // Defensive at the persistence boundary: corrupt or schema-drifted data
        // decodes to [] instead of crashing the app.
        let decoded = (try? JSONDecoder().decode([SnapPreset].self, from: data)) ?? []
        cache = decoded
        return decoded
    }

    static func preset(id: UUID) -> SnapPreset? {
        all().first { $0.id == id }
    }

    private static func save(_ presets: [SnapPreset]) {
        Settings.snapPresetsData = try? JSONEncoder().encode(presets)
        cache = presets
        onChange?()
    }

    /// Appends a preset and returns it.
    @discardableResult
    static func add(_ preset: SnapPreset) -> SnapPreset {
        var presets = all()
        presets.append(preset)
        save(presets)
        return preset
    }

    /// Replaces the preset with the same id. No-op if the id is gone.
    static func update(_ preset: SnapPreset) {
        var presets = all()
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        save(presets)
    }

    static func delete(id: UUID) {
        save(all().filter { $0.id != id })
    }
}
