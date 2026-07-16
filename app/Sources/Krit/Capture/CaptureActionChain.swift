import AppKit

/// One post-capture action applied to a finished image. Shared by the `krit://`
/// URL router (`then=` chain) and Snap Presets so the two never drift: a `copy`
/// means the exact same clipboard write in both paths.
enum CaptureAction: String, Codable, CaseIterable, Sendable {
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
    @discardableResult
    static func apply(
        _ actions: [CaptureAction],
        to image: NSImage,
        format: String? = nil,
        artifact suppliedArtifact: CaptureArtifact? = nil
    ) -> Task<Void, Never> {
        let ext = format ?? Settings.screenshotFormat
        let dir = Settings.autoSaveLocation
        let request = CaptureActionRequest(
            actions: actions,
            format: ext,
            jpegQuality: Settings.jpegQuality,
            saveURL: URL(fileURLWithPath: dir)
                .appendingPathComponent("\(ImageExporter.timestampedName).\(ext)")
        )
        let artifact = suppliedArtifact ?? CaptureArtifact(image: image)

        return Task { @MainActor in
            guard let artifact else {
                // A malformed bitmap cannot be copied or saved, but UI actions
                // still receive the original AppKit image.
                for action in actions {
                    switch action {
                    case .edit: LiveCaptureActionSink.shared.edit(image)
                    case .pin: LiveCaptureActionSink.shared.pin(image)
                    case .copy, .save: continue
                    }
                }
                return
            }
            await run(
                request,
                image: image,
                artifact: artifact,
                sink: LiveCaptureActionSink.shared
            )
        }
    }

    static func run(
        _ request: CaptureActionRequest,
        image: NSImage,
        artifact: CaptureArtifact,
        sink: any CaptureActionSink
    ) async {
        for action in request.actions {
            switch action {
            case .copy:
                if let capture = await artifact.encoded(as: .png) {
                    sink.copyPNG(capture.data)
                }
            case .save:
                let encoding = CaptureEncoding.fileFormat(
                    extension: request.format,
                    jpegQuality: request.jpegQuality
                )
                if let capture = await artifact.encoded(as: encoding) {
                    _ = await sink.save(capture, to: request.saveURL)
                }
            case .edit:
                sink.edit(image)
            case .pin:
                sink.pin(image)
            }
        }
    }
}
