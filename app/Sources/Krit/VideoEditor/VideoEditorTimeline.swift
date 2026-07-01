import AppKit
import SwiftUI

// Timeline ported faithfully from Snapzy's VideoTimelineView + ZoomTimelineTrack:
// a frame-thumbnail strip with dimmed trim regions and a yellow trim border, a red
// playhead across both lanes, and a zoom track whose blocks you add by clicking
// empty space, move by dragging the middle, and resize by dragging the edges.

struct EditorTimeline: View {
    @ObservedObject var state: VideoEditorState

    private let frameStripHeight: CGFloat = 64
    private let zoomTrackHeight: CGFloat = 36
    private let spacing: CGFloat = 6
    private var totalHeight: CGFloat { frameStripHeight + spacing + zoomTrackHeight }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: spacing) {
                    ZStack(alignment: .leading) {
                        FilmStrip(thumbnails: state.frameThumbnails, isLoading: state.isExtractingFrames)
                        TrimHandles(state: state, width: w)
                    }
                    .frame(height: frameStripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        state.seek(to: Double(max(0, min(v.location.x / w, 1))) * state.duration)
                    })

                    ZoomTrack(state: state, width: w)
                        .frame(height: zoomTrackHeight)
                }

                // Red playhead across both lanes.
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: totalHeight)
                    .offset(x: (state.duration > 0 ? CGFloat(state.currentTime / state.duration) : 0) * w - 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: totalHeight)
    }
}

// MARK: - Frame strip

private struct FilmStrip: View {
    let thumbnails: [NSImage]
    let isLoading: Bool

    var body: some View {
        GeometryReader { geo in
            if isLoading || thumbnails.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ProgressView().scaleEffect(0.7)
                    Text("Extracting frames…").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.25))
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<thumbnails.count, id: \.self) { i in
                        Image(nsImage: thumbnails[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width / CGFloat(thumbnails.count))
                            .clipped()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Trim handles

private struct TrimHandles: View {
    @ObservedObject var state: VideoEditorState
    let width: CGFloat

    private let handleWidth: CGFloat = 14

    private func x(_ t: Double) -> CGFloat { state.duration > 0 ? CGFloat(t / state.duration) * width : 0 }

    var body: some View {
        let startX = x(state.trimStart)
        let endX = x(state.trimEnd)
        ZStack(alignment: .leading) {
            // Dimmed outside the trim range.
            Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, startX))
            Rectangle().fill(Color.black.opacity(0.5))
                .frame(width: max(0, width - endX)).offset(x: endX)

            // Yellow border around the kept range.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(0, endX - startX))
                .offset(x: startX)
                .allowsHitTesting(false)

            handle(at: startX) { dx in state.setTrimStart(state.trimStart + dx) }
            handle(at: endX - handleWidth) { dx in state.setTrimEnd(state.trimEnd + dx) }
        }
    }

    private func handle(at offset: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: 60)
            .overlay(
                RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.5))
                    .frame(width: 2, height: 22)
            )
            .offset(x: max(0, min(offset, width - handleWidth)))
            .gesture(DragGesture().onChanged { v in
                let dt = Double(v.translation.width / max(width, 1)) * state.duration
                onDrag(dt)
            })
    }
}

// MARK: - Zoom track

private struct ZoomTrack: View {
    @ObservedObject var state: VideoEditorState
    let width: CGFloat

    private let handleWidth: CGFloat = 8
    private let minVisualBlockWidth: CGFloat = 64

    @State private var dragMode: DragMode = .none
    @State private var dragSegmentId: UUID?
    @State private var dragInitialStart: TimeInterval = 0
    @State private var dragInitialEnd: TimeInterval = 0
    @State private var didBegin = false
    @State private var isHovering = false
    @State private var hoverX: CGFloat = 0

    private enum DragMode { case none, position, startEdge, endEdge }

    private var videoDuration: TimeInterval { state.duration }
    private var pixelsPerSecond: CGFloat { videoDuration > 0 ? width / CGFloat(videoDuration) : 1 }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.2))

            HStack(spacing: 3) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 9))
                Text("Zooms").font(.system(size: 9, weight: .medium))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.leading, 6)
            .allowsHitTesting(false)

            ForEach(state.zoomSegments) { seg in
                let l = layout(for: seg)
                ZoomBlockVisual(
                    segment: seg,
                    isSelected: state.selectedZoomId == seg.id,
                    isDragging: dragSegmentId == seg.id,
                    blockX: l.startX,
                    blockWidth: l.width
                )
            }

            if shouldShowPlaceholder {
                ZoomPlaceholder(width: placeholderWidth, x: placeholderX)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(trackGesture)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): isHovering = true; hoverX = p.x
            case .ended: isHovering = false
            }
        }
        .contextMenu { contextMenu }
    }

    // MARK: Gesture (tap to add/select, drag edges to resize, middle to move)

    private var trackGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !didBegin { begin(at: v.startLocation); didBegin = true }
                if dragMode != .none, abs(v.translation.width) >= 2 {
                    apply(translation: v.translation)
                }
            }
            .onEnded { v in
                if abs(v.translation.width) < 3 { handleTap(at: v.startLocation) }
                dragMode = .none; dragSegmentId = nil; didBegin = false
            }
    }

    private func begin(at location: CGPoint) {
        guard let (seg, l) = segment(atX: location.x) else { dragMode = .none; dragSegmentId = nil; return }
        dragSegmentId = seg.id
        dragInitialStart = seg.startTime
        dragInitialEnd = seg.endTime
        state.selectZoom(id: seg.id)
        if location.x <= l.startX + handleWidth { dragMode = .startEdge }
        else if location.x >= l.endX - handleWidth { dragMode = .endEdge }
        else { dragMode = .position }
    }

    private func apply(translation: CGSize) {
        guard let id = dragSegmentId else { return }
        let delta = TimeInterval(translation.width / pixelsPerSecond)
        let initialDuration = dragInitialEnd - dragInitialStart
        switch dragMode {
        case .none: return
        case .position:
            state.updateZoom(id: id, startTime: dragInitialStart + delta, duration: initialDuration)
        case .startEdge:
            let newStart = max(0, min(dragInitialStart + delta, dragInitialEnd - ZoomSegment.minDuration))
            state.updateZoom(id: id, startTime: newStart, duration: dragInitialEnd - newStart)
        case .endEdge:
            let newEnd = max(dragInitialStart + ZoomSegment.minDuration, min(dragInitialEnd + delta, videoDuration))
            state.updateZoom(id: id, startTime: dragInitialStart, duration: newEnd - dragInitialStart)
        }
    }

    private func handleTap(at location: CGPoint) {
        if let (seg, _) = segment(atX: location.x) {
            state.selectZoom(id: seg.id)
        } else {
            state.addZoom(at: (Double(location.x / max(width, 1))) * videoDuration)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button {
            state.addZoom(at: isHovering ? Double(hoverX / max(width, 1)) * videoDuration : state.currentTime)
        } label: { Label("Add Zoom Here", systemImage: "plus.magnifyingglass") }
        if let id = state.selectedZoomId {
            Divider()
            Button(role: .destructive) { state.removeZoom(id: id) } label: { Label("Delete Zoom", systemImage: "trash") }
        }
        if !state.zoomSegments.isEmpty {
            Divider()
            Button(role: .destructive) { state.zoomSegments.removeAll(); state.selectedZoomId = nil } label: {
                Label("Remove All Zooms", systemImage: "trash.fill")
            }
        }
    }

    // MARK: Layout

    private struct Layout { let startX: CGFloat; let endX: CGFloat; let width: CGFloat }

    private func layout(for seg: ZoomSegment) -> Layout {
        guard videoDuration > 0, width > 0 else { return Layout(startX: 0, endX: minVisualBlockWidth, width: minVisualBlockWidth) }
        let logicalStart = CGFloat(seg.startTime / videoDuration) * width
        let logicalWidth = CGFloat(seg.duration / videoDuration) * width
        let visualWidth = min(width, max(minVisualBlockWidth, logicalWidth))
        let startX = max(0, min(logicalStart, max(0, width - visualWidth)))
        return Layout(startX: startX, endX: startX + visualWidth, width: visualWidth)
    }

    private func segment(atX x: CGFloat) -> (ZoomSegment, Layout)? {
        let hits = state.zoomSegments.compactMap { seg -> (ZoomSegment, Layout)? in
            let l = layout(for: seg)
            return (x >= l.startX && x <= l.endX) ? (seg, l) : nil
        }
        if let selId = state.selectedZoomId, let sel = hits.first(where: { $0.0.id == selId }) { return sel }
        return hits.first
    }

    private var isOverSegment: Bool { segment(atX: hoverX) != nil }
    private var shouldShowPlaceholder: Bool { isHovering && !isOverSegment && dragMode == .none }
    private var placeholderWidth: CGFloat {
        guard videoDuration > 0 else { return minVisualBlockWidth }
        return min(width, max(minVisualBlockWidth, CGFloat(ZoomSegment.defaultDuration / videoDuration) * width))
    }
    private var placeholderX: CGFloat { max(0, min(hoverX - placeholderWidth / 2, width - placeholderWidth)) }
}

// MARK: - Zoom block (visual)

private struct ZoomBlockVisual: View {
    let segment: ZoomSegment
    let isSelected: Bool
    let isDragging: Bool
    let blockX: CGFloat
    let blockWidth: CGFloat

    private let handleWidth: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.kritAccent : .clear, lineWidth: 2))
                .shadow(color: isSelected ? Color.kritAccent.opacity(0.4) : .clear, radius: 4, y: 2)

            HStack(spacing: 4) {
                Image(systemName: segment.isAutoMode ? "cursorarrow.click" : "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                if blockWidth >= 48 {
                    Text(segment.formattedZoomLevel).font(.system(size: 10, weight: .semibold))
                }
                Spacer(minLength: 0)
                if blockWidth >= 96 {
                    Text(segment.zoomType.displayName)
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.white.opacity(0.2)).cornerRadius(3)
                }
            }
            .padding(.horizontal, handleWidth + 4)
            .foregroundColor(.white)

            handleGrip().offset(x: 0)
            handleGrip().offset(x: blockWidth - handleWidth)
        }
        .frame(width: blockWidth, height: 28)
        .offset(x: blockX)
        .opacity(segment.isEnabled ? 1.0 : 0.5)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .allowsHitTesting(false)
    }

    private func handleGrip() -> some View {
        ZStack {
            Rectangle().fill(isSelected ? Color.white.opacity(0.2) : .clear)
            RoundedRectangle(cornerRadius: 1)
                .fill(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.4))
                .frame(width: 3, height: 14)
        }
        .frame(width: handleWidth, height: 28)
    }

    private var fill: Color {
        if !segment.isEnabled { return Color.gray.opacity(0.5) }
        return isDragging ? Color.kritAccent.opacity(0.85) : Color.kritAccent
    }
}

// MARK: - Placeholder

private struct ZoomPlaceholder: View {
    let width: CGFloat
    let x: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.kritAccent.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.kritAccent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .overlay(
                HStack(spacing: 4) {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 10, weight: .medium))
                    Text("Click to add").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(Color.kritAccent.opacity(0.85))
            )
            .frame(width: width, height: 28)
            .offset(x: x)
            .allowsHitTesting(false)
    }
}
