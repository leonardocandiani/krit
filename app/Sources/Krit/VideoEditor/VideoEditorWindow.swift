import AppKit
import AVFoundation
import Combine
import SwiftUI

// A real video editor (Snapzy-style) for recordings: an AVPlayer preview that
// shows the zoom live, a timeline with trim handles and a zoom lane you edit
// directly, and an export that bakes the zoom into the file via ZoomComposer.
// Replaces the menu-action "Auto-Zoom & Export" with an interactive editor.

@MainActor
final class VideoEditorState: ObservableObject {
    let url: URL
    let player: AVPlayer

    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var naturalSize: CGSize = CGSize(width: 16, height: 9)

    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0

    @Published var zoomSegments: [ZoomSegment] = []
    @Published var selectedZoomId: UUID?

    @Published var frameThumbnails: [NSImage] = []
    @Published var isExtractingFrames = false

    private(set) var metadata: RecordingMetadata?
    private(set) var autoFocusPaths: [UUID: [AutoFocusCameraSample]] = [:]

    @Published var isExporting = false

    private var timeObserver: Any?
    var onExported: ((URL, Double) -> Void)?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        self.metadata = RecordingMetadataStore.load(for: url)
        addTimeObserver()
        Task { await loadMetrics() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            if self.isPlaying, self.currentTime >= self.trimEnd - 0.02 {
                self.pause()
                self.seek(to: self.trimStart)
            }
        }
    }

    private func loadMetrics() async {
        let asset = AVURLAsset(url: url)
        let dur = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? nil
        await MainActor.run {
            self.duration = max(dur, 0.01)
            self.trimEnd = self.duration
            if let size { self.naturalSize = CGSize(width: abs(size.width), height: abs(size.height)) }
        }
        await extractFrames(count: 24, duration: max(dur, 0.01))
    }

    /// Filmstrip thumbnails across the clip, for the timeline.
    private func extractFrames(count: Int, duration: Double) async {
        await MainActor.run { self.isExtractingFrames = true }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var images: [NSImage] = []
        for i in 0..<count {
            let t = duration * Double(i) / Double(max(count - 1, 1))
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        await MainActor.run {
            self.frameThumbnails = images
            self.isExtractingFrames = false
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if currentTime >= trimEnd - 0.02 { seek(to: trimStart) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Zoom segments

    /// Resolved camera at the current time, for the live preview transform.
    func camera(at time: Double) -> CameraState {
        AutoFocusEngine.resolvedCameraState(
            at: time, segments: zoomSegments.filter(\.isEnabled), autoFocusPaths: autoFocusPaths,
            transitionDuration: ZoomCalculator.defaultTransitionDuration
        )
    }

    func addZoomAtPlayhead() {
        let start = min(max(currentTime, 0), max(duration - ZoomSegment.minDuration, 0))
        let dur = min(ZoomSegment.defaultDuration, max(duration - start, ZoomSegment.minDuration))
        // Auto when we have cursor data, else a centered manual zoom.
        let type: ZoomType = (metadata?.mouseSamples.count ?? 0) >= 2 ? .auto : .manual
        let segment = ZoomSegment(startTime: start, duration: dur, zoomLevel: 2.0, zoomType: type)
        zoomSegments.append(segment)
        zoomSegments.sort { $0.startTime < $1.startTime }
        selectedZoomId = segment.id
        rebuildAutoPaths()
    }

    func removeSelectedZoom() {
        guard let id = selectedZoomId else { return }
        zoomSegments.removeAll { $0.id == id }
        autoFocusPaths[id] = nil
        selectedZoomId = nil
    }

    func updateSelected(_ transform: (inout ZoomSegment) -> Void) {
        guard let id = selectedZoomId, let idx = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        transform(&zoomSegments[idx])
        rebuildAutoPaths()
    }

    /// Add a zoom centered on `time` (Snapzy's click-to-add on the track).
    func addZoom(at time: Double) {
        let dur = min(ZoomSegment.defaultDuration, max(duration, ZoomSegment.minDuration))
        let start = min(max(time - dur / 2, 0), max(duration - dur, 0))
        let type: ZoomType = (metadata?.mouseSamples.count ?? 0) >= 2 ? .auto : .manual
        let segment = ZoomSegment(startTime: start, duration: dur, zoomLevel: 2.0, zoomType: type)
        zoomSegments.append(segment)
        zoomSegments.sort { $0.startTime < $1.startTime }
        selectedZoomId = segment.id
        rebuildAutoPaths()
    }

    /// Resize/move during a track-level drag (start + duration set together).
    func updateZoom(id: UUID, startTime: Double, duration newDuration: Double) {
        guard let idx = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        zoomSegments[idx].startTime = max(0, min(startTime, max(duration - ZoomSegment.minDuration, 0)))
        zoomSegments[idx].duration = max(ZoomSegment.minDuration, min(newDuration, duration - zoomSegments[idx].startTime))
        rebuildAutoPaths()
    }

    func selectZoom(id: UUID?) { selectedZoomId = id }

    func removeZoom(id: UUID) {
        zoomSegments.removeAll { $0.id == id }
        autoFocusPaths[id] = nil
        if selectedZoomId == id { selectedZoomId = nil }
    }

    func toggleZoomEnabled(id: UUID) {
        guard let idx = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        zoomSegments[idx].isEnabled.toggle()
    }

    func setTrimStart(_ t: Double) { trimStart = min(max(t, 0), trimEnd - 0.1) }
    func setTrimEnd(_ t: Double) { trimEnd = max(min(t, duration), trimStart + 0.1) }

    func rebuildAutoPaths() {
        guard let metadata else { autoFocusPaths = [:]; return }
        var paths: [UUID: [AutoFocusCameraSample]] = [:]
        for segment in zoomSegments where segment.isAutoMode {
            paths[segment.id] = AutoFocusEngine.buildPath(from: metadata, segment: segment)
        }
        autoFocusPaths = paths
    }

    var selectedSegment: ZoomSegment? {
        guard let id = selectedZoomId else { return nil }
        return zoomSegments.first { $0.id == id }
    }

    // MARK: - Export

    func export() {
        guard !isExporting else { return }
        isExporting = true
        pause()
        let base = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(base) Edited.mp4")
        let segments = zoomSegments.filter(\.isEnabled)
        let paths = autoFocusPaths
        let trimmed = trimStart > 0.01 || trimEnd < duration - 0.01
        let range: CMTimeRange? = trimmed
            ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                          duration: CMTime(seconds: max(trimEnd - trimStart, 0.05), preferredTimescale: 600))
            : nil
        let outDuration = trimEnd - trimStart
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ZoomComposer.export(url: self.url, to: outURL, segments: segments, autoFocusPaths: paths, timeRange: range)
                await MainActor.run {
                    self.isExporting = false
                    ToastWindow.show(message: "Saved: \(outURL.lastPathComponent)", duration: 3.0)
                    self.onExported?(outURL, max(outDuration, 0.01))
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    ToastWindow.show(message: "Export failed.")
                }
            }
        }
    }

    func exportGIF() {
        guard !isExporting else { return }
        pause()
        let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
        ToastWindow.show(message: "Exporting GIF…")
        Task {
            do {
                let out = try await GIFEncoder.encode(videoURL: url, to: gifURL)
                ToastWindow.show(message: "Saved GIF: \(out.lastPathComponent)", duration: 3.0)
            } catch {
                ToastWindow.show(message: "Could not export GIF.")
            }
        }
    }
}

// MARK: - Player view (AVPlayerLayer with live zoom transform)

private struct PlayerView: NSViewRepresentable {
    @ObservedObject var state: VideoEditorState

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player: state.player)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.apply(camera: state.camera(at: state.currentTime))
    }
}

final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(player: AVPlayer) { playerLayer.player = player }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.bounds = bounds
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func apply(camera: CameraState) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if camera.zoomLevel <= 1.0001 {
            playerLayer.setAffineTransform(.identity)
        } else {
            let z = camera.zoomLevel
            let w = bounds.width, h = bounds.height
            // center is top-left normalized; layer space is bottom-left.
            let tx = (0.5 - camera.center.x) * w * z
            let ty = (camera.center.y - 0.5) * h * z
            playerLayer.setAffineTransform(CGAffineTransform(translationX: tx, y: ty).scaledBy(x: z, y: z))
        }
        CATransaction.commit()
    }
}

// MARK: - Editor view

struct VideoEditorView: View {
    @ObservedObject var state: VideoEditorState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            PlayerView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            timeline
                .frame(height: 184)
                .background(Color(white: 0.10))
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(Color(white: 0.13))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { state.togglePlay() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Text(timeString(state.currentTime) + " / " + timeString(state.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { state.addZoomAtPlayhead() }) {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
            }
            Button(action: { state.exportGIF() }) {
                Label("GIF", systemImage: "photo.stack")
            }
            .disabled(state.isExporting)
            Button(action: { state.export() }) {
                if state.isExporting {
                    Text("Exporting…")
                } else {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(state.isExporting)
            .keyboardShortcut("e", modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color(white: 0.16))
    }

    private var timeline: some View {
        VStack(spacing: 10) {
            EditorTimeline(state: state)
            inspector
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var inspector: some View {
        if let seg = state.selectedSegment {
            HStack(spacing: 12) {
                Picker("", selection: Binding(
                    get: { seg.zoomType },
                    set: { newType in state.updateSelected { $0.zoomType = newType } }
                )) {
                    Text("Auto").tag(ZoomType.auto)
                    Text("Manual").tag(ZoomType.manual)
                }
                .pickerStyle(.segmented).frame(width: 140)

                Text("Zoom")
                Slider(value: Binding(
                    get: { Double(seg.zoomLevel) },
                    set: { v in state.updateSelected { $0.zoomLevel = CGFloat(v) } }
                ), in: 1.0...4.0)
                .frame(width: 160)
                Text(seg.formattedZoomLevel).font(.system(size: 11).monospacedDigit())

                Spacer()
                Button(role: .destructive, action: { state.removeSelectedZoom() }) {
                    Image(systemName: "trash")
                }
            }
            .frame(height: 30)
        } else {
            HStack {
                Text("Tap a zoom block to edit, or Add Zoom at the playhead.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
            }
            .frame(height: 30)
        }
    }

    private func timeString(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Window controller

@MainActor
final class VideoEditorWindowController: NSWindowController {
    private static var shared: VideoEditorWindowController?
    private let state: VideoEditorState

    static func show(url: URL, onExported: @escaping (URL, Double) -> Void) {
        shared?.close()
        let controller = VideoEditorWindowController(url: url, onExported: onExported)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, onExported: @escaping (URL, Double) -> Void) {
        let state = VideoEditorState(url: url)
        state.onExported = onExported
        self.state = state
        let hosting = NSHostingController(rootView: VideoEditorView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Edit Recording"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// GUI test hook: drive the editor headlessly.
    var uiTestState: VideoEditorState { state }
    static var uiTestShared: VideoEditorWindowController? { shared }
}
