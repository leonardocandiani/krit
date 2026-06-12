import AppKit

/// One post-capture action applied to a finished image. Shared by the `krit://`
/// URL router (`then=` chain) and Snap Presets so the two never drift: a `copy`
/// means the exact same clipboard write in both paths.
enum CaptureAction: String, Codable, CaseIterable {
    case copy
    case save
    case edit
    case pin
}

/// Runs an ordered list of `CaptureAction`s against an image. Pure, no UI of its
/// own beyond what each action opens (editor window, pin window). `save` honors
/// a per-call format override (presets store their own png/jpg), falling back to
/// the global `Settings.screenshotFormat` when none is given.
@MainActor
enum CaptureActionChain {

    /// Applies `actions` to `image` in order. `format` (e.g. "png", "jpg") sets
    /// the save extension for this run; nil uses the user's global format.
    static func apply(_ actions: [CaptureAction], to image: NSImage, format: String? = nil) {
        for action in actions {
            switch action {
            case .copy:
                ImageExporter.copyToClipboard(image: image)
            case .save:
                let dir = Settings.autoSaveLocation
                let name = ImageExporter.timestampedName
                let ext = format ?? Settings.screenshotFormat
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).\(ext)")
                _ = ImageExporter.save(image: image, to: url)
            case .edit:
                AnnotationWindowController.open(image: image)
                NSApp.activate(ignoringOtherApps: true)
            case .pin:
                PinnedWindow.pin(image: image)
            }
        }
    }
}
