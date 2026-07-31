import AppKit

// Deprecated 2026-07-30.
//
// Reason: the editor no longer frames its canvas. The stage now runs edge to
// edge with glass pills floating over it (see AnnotationWindowController's
// toolbarPillFrame / actionPillFrame), so the continuous L-shaped material that
// used to wall off the canvas on three sides has no surface left to draw.
//
// Kept because it is the only worked example in the codebase of masking a
// NSVisualEffectView with an even-odd CAShapeLayer to cut a hole in a material,
// which is worth reading before anyone tries that trick again.

// MARK: - Editor chrome backdrop (continuous frame, ES1/ES3/ES4)

/// One continuous material surface that frames the canvas on all chrome sides as a
/// single piece: top arm (header/toolbar band), left arm (sidebar, when open) and
/// bottom arm (the footer), folding around the corners with no seam. The canvas
/// occupies the notch. The material runs full-bleed to the window edges (under the
/// transparent titlebar + traffic lights), so the header reads as the SAME frame as
/// the sidebar and footer, not a separate panel. A 1px hairline traces only the
/// notch boundary (the edges where the frame meets the canvas).
@MainActor
final class EditorChromeBackdrop: NSView {
    private let material: NSVisualEffectView
    private let hairline = CAShapeLayer()
    private var leftArmWidth: CGFloat = 0
    private var bottomArmHeight: CGFloat = 0
    private var topArmHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        material = NSVisualEffectView(frame: frameRect)
        super.init(frame: frameRect)
        wantsLayer = true
        // HIG: the L-frame is STRUCTURAL window chrome (it bounds the content notch
        // and runs flush to the window edges), not a floating element, so it stays
        // a window material and does NOT become NSGlassEffectView. Glass is reserved
        // for elements that float over content; the stage in the notch is the
        // content layer and never gets glass. Window-background material so the whole
        // frame (header + sidebar + footer) reads as one continuous window chrome.
        // Sits behind the controls; the mask carves out the canvas notch so the dark
        // stage shows through.
        material.material = .windowBackground
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        hairline.fillColor = NSColor.clear.cgColor
        // Subtle: at separatorColor 0.8 this read as bright "white wires" around
        // the canvas. The notch boundary only needs a whisper of definition.
        hairline.strokeColor = KritColors.editorChromeBorder.cgColor
        hairline.lineWidth = 1
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Re-carve the frame from the current arm metrics. The notch (canvas) is the
    /// rectangle inset by the three arms; the right edge runs flush to the window.
    func update(leftArmWidth: CGFloat, bottomArmHeight: CGFloat, topArmHeight: CGFloat) {
        self.leftArmWidth = leftArmWidth
        self.bottomArmHeight = bottomArmHeight
        self.topArmHeight = topArmHeight
        relayoutMask()
    }

    override func layout() {
        super.layout()
        relayoutMask()
    }

    private func relayoutMask() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        // The notch (canvas) is bounded by the top arm above, left arm at leading,
        // bottom arm below, and runs flush to the trailing window edge.
        let notch = CGRect(
            x: leftArmWidth,
            y: bottomArmHeight,
            width: max(0, b.width - leftArmWidth),
            height: max(0, b.height - topArmHeight - bottomArmHeight)
        )

        // Mask the material: fill the whole bounds, punch out the notch (even-odd).
        let path = CGMutablePath()
        path.addRect(b)
        path.addRect(notch)
        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        material.layer?.mask = mask

        // Hairline along the three inner edges of the notch (top, left, bottom),
        // only where the frame actually borders the canvas. The trailing edge is the
        // window edge, so no hairline there.
        let border = CGMutablePath()
        // Left edge (only when the sidebar arm is present).
        if leftArmWidth > 0 {
            border.move(to: CGPoint(x: notch.minX + 0.5, y: notch.minY))
            border.addLine(to: CGPoint(x: notch.minX + 0.5, y: notch.maxY))
        }
        // Top edge (header band).
        border.move(to: CGPoint(x: notch.minX, y: notch.maxY - 0.5))
        border.addLine(to: CGPoint(x: b.width, y: notch.maxY - 0.5))
        // Bottom edge (footer band).
        border.move(to: CGPoint(x: notch.minX, y: notch.minY + 0.5))
        border.addLine(to: CGPoint(x: b.width, y: notch.minY + 0.5))
        hairline.path = border
    }
}
