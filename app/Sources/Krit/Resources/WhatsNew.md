version: 0.26.0
## KRIT v0.26.0

The headline: Presentation Zoom. Press ⌘⇧8 and the screen glides into a smooth, cursor-anchored magnification, ZoomIt style, for "let me zoom into this detail" moments in demos and screen shares. Press it again and it glides back out, landing seamlessly on the real screen.

### Presentation Zoom
- Live magnification anchored on the cursor: the view pans after the pointer with critically-damped smoothing, nothing jumps (#23)
- The remote audience sees it too: Meet/Zoom screen shares and KRIT's own recordings capture the magnified view
- Everything keeps working while zoomed: clicks, typing and scrolling pass straight through to the real apps, and live content stays live (it's a ScreenCaptureKit stream, not a frozen screenshot)
- The motion is yours to tune in Preferences: a Feel picker (Precise / Natural / Bouncy), a Smoothing slider from snappy to long glide, and a Zoom level slider, all applied to a running zoom in real time
- Optional Zoom in / Zoom out shortcuts step the level by 1.25x (from 1.25x to 6x) and remember where you left it
- Starting any KRIT capture or recording exits the zoom first, so shots always frame the real screen
- Reduce Motion is honored: the zoom snaps with no scale animation
