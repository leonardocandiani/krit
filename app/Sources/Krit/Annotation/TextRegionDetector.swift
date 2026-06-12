import AppKit
import Vision

/// Detects text lines in the canvas screenshot so the highlighter can snap onto
/// the actual writing instead of leaving a free, crooked stroke.
///
/// Vision returns one observation per text line. Each observation carries a
/// `boundingBox` that is normalized [0,1] with a BOTTOM-LEFT origin, expressed
/// relative to the source IMAGE (not the canvas). Mapping those boxes onto the
/// flipped, top-left canvas is the part that bit blur/pixelate before, so the
/// canvas does the conversion through the exact same slot rect those effects use
/// (see `AnnotationCanvas.backgroundImageRect`). This type only owns detection
/// plus a per-image cache; it deliberately knows nothing about canvas geometry.
@MainActor
final class TextRegionDetector {

    /// One detected text line, in Vision's normalized image space (bottom-left
    /// origin, [0,1]). The canvas converts these into view rects at draw/drag
    /// time so the snapped highlight lands exactly over the writing.
    struct TextLine {
        /// Normalized bounding box, origin bottom-left, relative to the image.
        let normalizedBox: CGRect
        /// The recognized string for this line (top Vision candidate), used by
        /// Smart Redact to classify what the line contains. The highlighter
        /// ignores it and works off `normalizedBox` alone, so adding it here is
        /// transparent to the snapping path.
        let text: String
    }

    /// The cache is keyed on the image instance. Our screenshots are never
    /// mutated in place (crop/undo swap in a different NSImage), so identity is a
    /// sufficient and cheap invalidation signal: a new document means a new image
    /// reference, which misses the cache and triggers a fresh detection.
    private var cachedImage: NSImage?
    private var cachedLines: [TextLine]?
    /// In-flight detection for the current image, so repeated tool toggles or
    /// rapid drags do not kick off duplicate Vision passes for the same shot.
    private var inFlightImage: NSImage?

    /// Cached result for `image`, or nil if detection has not finished yet.
    /// Returning nil is the signal for the caller to fall back to the free stroke.
    func lines(for image: NSImage) -> [TextLine]? {
        if cachedImage === image { return cachedLines }
        return nil
    }

    /// Kicks off background detection for `image` if it is not already cached or
    /// running. `onReady` fires on the main actor once results land for the image
    /// that is still current, so the caller can refresh any live preview.
    func detect(in image: NSImage, onReady: @escaping () -> Void) {
        if cachedImage === image { onReady(); return }
        if inFlightImage === image { return }
        guard let cgImage = image.bestCGImage else { return }

        inFlightImage = image
        Task { [weak self] in
            let lines = await Self.recognizeLines(in: cgImage)
            guard let self else { return }
            // Drop stale results: the document may have changed (crop/undo) while
            // Vision was working.
            guard self.inFlightImage === image else { return }
            self.cachedImage = image
            self.cachedLines = lines
            self.inFlightImage = nil
            onReady()
        }
    }

    /// Async convenience for Smart Redact: returns the recognized lines for
    /// `image`, running (or awaiting) one detection pass. Rides the same cache as
    /// `detect(in:onReady:)`, so a warm highlighter cache is reused for free and a
    /// cold one is filled once. Returns an empty array if the image has no pixels.
    func recognizedLines(for image: NSImage) async -> [TextLine] {
        if cachedImage === image, let cached = cachedLines { return cached }
        guard let cgImage = image.bestCGImage else { return [] }
        let lines = await Self.recognizeLines(in: cgImage)
        // Only adopt as the cache if no newer document took over while we worked.
        if inFlightImage == nil || inFlightImage === image {
            cachedImage = image
            cachedLines = lines
        }
        return lines
    }

    /// Clears the cache so the next `detect` re-runs. Called when the document
    /// changes (e.g. undo/redo restores a different background image).
    func invalidate() {
        cachedImage = nil
        cachedLines = nil
        inFlightImage = nil
    }

    private static func recognizeLines(in cgImage: CGImage) async -> [TextLine] {
        await withCheckedContinuation { continuation in
            var didResume = false
            let request = VNRecognizeTextRequest { request, error in
                guard !didResume else { return }
                didResume = true
                if error != nil { continuation.resume(returning: []); return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.map {
                    TextLine(
                        normalizedBox: $0.boundingBox,
                        text: $0.topCandidates(1).first?.string ?? ""
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: [])
            }
        }
    }
}
