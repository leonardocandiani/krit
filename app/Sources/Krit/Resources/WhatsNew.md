version: 0.25.0
## KRIT v0.25.0

The headline: taking a screenshot no longer flips a video (aerial) wallpaper from dark to light. Every still capture path now hides desktop icons through an invisible ScreenCaptureKit filter instead of drawing wallpaper-poster cover windows on screen.

### Capture
- Fullscreen, OCR, QR and scrolling captures hide desktop icons via the ScreenCaptureKit Finder-exclusion filter, nothing is painted over your desktop anymore (#21)
- The desktop freezes before area selection so the aerial wallpaper never flashes light mid-selection
- The frozen-frame fast path actually fires, so area captures come from the frame you saw (#19)

### Overlay cards
- Dragging or interacting with one card freezes every card's auto-dismiss countdown, no card vanishes mid-gesture (#20)
- One shared interaction coordinator replaces four event monitors per card (#18)
- Hover fill crossfades in instead of snapping (#17)

### Editor and annotations
- Annotate any frame of a recording in the print editor
- Multiline text annotations: Shift+Return inserts a new line
- Adjustable blur and pixelate strength for redactions, coral accent on the active text style (#15)

### Recording
- The recording HUD springs in and fades out like the other surfaces (#16)
- Recording surfaces honor Reduce Motion and no longer double their entrance animation (#13)

### Under the hood
- Design system pass, recording-to-editor connection, sharp redact rendering
- Single source of truth for the top-left to AppKit coordinate flip
