# Changelog

All notable changes to KRIT, newest first.

## 0.28.0

The headline: Live Annotation. Press ⌘⇧D and draw directly on your screen — arrows, strokes, text, numbered steps — over any app, live, while you present or record. Esc steps back to your apps with the ink still on top; press ⌘⇧D again and pick up right where you left off.

### Live Annotation
- Draw over the real, live desktop: freehand, highlighter, arrow, line, rectangle, ellipse, text and auto-numbered steps, with six colors and three stroke widths on a floating toolbar
- Presentation-first by design: your screen-share audience and KRIT's own recordings see the ink; the toolbar chrome never leaks into a capture
- Esc hands mouse and keyboard straight back to your apps while every mark stays pinned on top, click-through; re-enter draw mode anytime and the drawing is intact
- The camera button (or any KRIT capture) shoots the annotated screen into your history like any screenshot
- Undo/redo, hide/show without deleting, and a close button that remembers your drawing for next time (configurable in Preferences)
- Presentation Zoom and Live Annotation coordinate: engaging one steps the other out of the way

### Feature Tour
- A six-slide, Apple-style tour of KRIT's highlights greets new installs right after the welcome wizard, and lives in the menu bar under "Feature Tour" for whenever you want a refresher

### Automation for agents and power users
- The bundled `krit` CLI can now introspect and drive the app: `ui-snapshot` dumps every window with real window-server levels plus the full view tree, `ui-click` presses any control by accessibility id, `live-annotation` drives the annotation mode, and `ui-audit` reports accessibility violations (interactive controls without labels, unreachable focus, duplicate labels)
- Every annotation toolbar control is now a first-class accessibility element (labels + press actions)
- New opt-in file trace (`defaults write com.krit.app kritTraceFile <path>`) and a crash note at `~/Library/Logs/KRIT/last-panic.txt` for field debugging

## 0.27.0

### KRIT v0.27.0

The headline: Presentation Zoom now arms without zooming. ⌘⇧8 leaves the screen untouched at 1x, ⌘⇧9 dives in, ⌘⇧0 walks back out. Hold either key and the zoom glides continuously until you let go.

### Presentation Zoom
- ⌘⇧8 arms the mode with the screen pixel-identical at 1x; a toast confirms it's on and names the zoom-in key (#25)
- Zoom in/out now ship with defaults on the same row: ⌘⇧9 in, ⌘⇧0 out. The first zoom-in jumps straight to your preferred level from Preferences (2x by default); further taps step ×1.25 up to 6x
- Zoom out steps back down and lands on exactly 1x: screen back to normal, mode still armed for the next dive
- Press and hold either zoom key to ramp the magnification continuously; release to stop right where you are. A quick tap still steps once
- The Preferences "Zoom level" slider now sets where the first zoom-in lands

## 0.26.1

### KRIT v0.26.1

Bug fix release.

### Capture
- KRIT's own windows (Preferences, editor, history) no longer vanish from captures when "hide desktop icons while capturing" is enabled. The filter excluded the whole app along with Finder; now it excludes only the desktop-icon layer, and you can screenshot KRIT's own UI like any other window (#24)

## 0.26.0

### KRIT v0.26.0

The headline: Presentation Zoom. Press ⌘⇧8 and the screen glides into a smooth, cursor-anchored magnification, ZoomIt style, for "let me zoom into this detail" moments in demos and screen shares. Press it again and it glides back out, landing seamlessly on the real screen.

### Presentation Zoom
- Live magnification anchored on the cursor: the view pans after the pointer with critically-damped smoothing, nothing jumps (#23)
- The remote audience sees it too: Meet/Zoom screen shares and KRIT's own recordings capture the magnified view
- Everything keeps working while zoomed: clicks, typing and scrolling pass straight through to the real apps, and live content stays live (it's a ScreenCaptureKit stream, not a frozen screenshot)
- The motion is yours to tune in Preferences: a Feel picker (Precise / Natural / Bouncy), a Smoothing slider from snappy to long glide, and a Zoom level slider, all applied to a running zoom in real time
- Optional Zoom in / Zoom out shortcuts step the level by 1.25x (from 1.25x to 6x) and remember where you left it
- Starting any KRIT capture or recording exits the zoom first, so shots always frame the real screen
- Reduce Motion is honored: the zoom snaps with no scale animation

## 0.25.0

### KRIT v0.25.0

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

## 0.24.1

### Fixes
- Recording controls stay readable over any content. The recording setup bar and the live recording HUD were nearly invisible when recording a light window (white controls on a white background); they now sit on a solid dark surface, so the buttons, timer, and labels are always legible.

## 0.24.0

### AI foundation
- Groundwork for AI in KRIT, detected locally with no account and no API key. On-device text recognition and translation work on every Mac, private and offline; on Apple Intelligence Macs the on-device language model is detected too.
- New Preferences ▸ General ▸ AI with a "Cloud AI features" toggle, off by default. Turn it on to use cloud features through your own Claude subscription: KRIT runs the Claude Code app you installed and never stores an API key.
- This is the foundation; the first AI features in the editor arrive in upcoming releases.

## 0.23.2

### Fixes
- Fixed a white border framing the Preferences sidebar, with its tabs washed out, on Macs running macOS earlier than 26. The sidebar now uses the native material on those systems and renders cleanly.

## 0.23.1

### Fixes
- Reach Preferences again after hiding the menu bar icon. Relaunching KRIT (Spotlight, Finder, `open -a`) now opens Preferences, so turning the icon off no longer strands you.
- Area capture no longer flashes KRIT's icon in the Dock. A new toggle in Preferences > General > Menu bar ("Show Dock icon during capture", off by default) brings it back if you want it.

## 0.23.0

- Every Preferences screen now shows a colored icon next to each setting, the way macOS System Settings does.
- Rebuilt the About tab as cards: check for updates with an automatic-update toggle, report a bug or request a feature, and a What's New shortcut.
- The Preferences sidebar now uses real Liquid Glass.
- A What's New panel appears once after each update, so you never miss a feature.
- On-screen toasts (saved, copied, recording, errors) now carry a matching colored icon.

## 0.22.0

- "Edit recording" on a recording card opens a full video editor: scrub, play and pause with a live zoom preview.
- Auto-zoom that follows the cursor, recorded while you capture, with per-zoom controls (Auto/Manual, zoom level, smoothness, follow speed, focus margin, or a fixed center).
- Timeline with a frame filmstrip, trim handles, and a zoom track you click to add zooms and drag to resize or move.
- Video backgrounds: gradients or real wallpapers with padding and rounded corners, baked into the export.
- Export writes zoom, trim and background into the file; GIF export too.
- The Space preview plays the video instead of a static thumbnail.
- The area-selection magnifier (loupe and crosshair guides) now appears only while holding Control by default, with a toggle in Preferences > Selection.
- Fixed the video card duration clipping its last digit.
- Fixed a closed editor leaving a clip decoding in the background, which made the app laggy.
- Fixed the area-selection cursor so it reliably shows the crosshair.

## 0.21.1

- Fixed a crash when opening the Shortcuts tab in Preferences; the KeyboardShortcuts resource bundle was missing from the packaged app.

## 0.21.0

- The overlay tray moves as one conveyor: drag any card down and the whole stack descends and hides together, and Restore brings them all back. Delete stays per-card.
- Descending locks to the vertical rail, so a sideways drift never pushes a card off the column.
- Pressing Space repeatedly no longer stops responding.
- The Space preview shows the shot at its native size instead of an upscaled blur.
- A capture taken while the stack is hidden restores it and continues the same session.
- Area selection now sits above always-on-top apps (terminals, teleprompters), so you can select over them.
- Expanded the editor's background gradient palette (dark and light, several animated).
- The editor opens on your saved default template, resolving the current desktop wallpaper.
- The highlighter snaps to detected text lines for clean marker strokes.

## 0.20.0

- Sharper screenshots: area and window captures grab at the display's real pixel density, so a 1x external monitor no longer comes out soft. The supersampling quality setting is gone; native is the sharpest a screen grab can be.
- Window shots capture the target window active (colored traffic lights, full-contrast chrome) instead of dimmed.
- The window picker ignores surfaces that cover a whole display (Screen Sharing or mirroring), so a window shot can't grab the entire screen.
- Restore brings back the image you saved (a window shot or an edited capture, with its background and edits) instead of the raw shot.
- Press Space over a history card for a large Quick Look preview.
- Arrow thickness no longer balloons on large or external displays, and a width you pick now sticks across captures.
- The DMG installer window keeps its background art with a clean layout.

## 0.19.0

- Much faster editing: the background composites off the main thread, so padding, wallpaper switches, and resizing no longer freeze the editor.
- Export as PDF (correctly sized page, full-resolution image) alongside PNG, JPEG, and WebP.
- Choose the export format right in the Save panel.
- Manage presets from the sidebar: pin a background preset as the default for new captures, or remove it.
- Saving no longer plays a sound.
- The area-selection overlay reliably shows above a frontmost full-screen app.

## 0.17.1

- The "Press Space to zoom" hint over a fresh capture is now a native glass capsule, shown once at landing.

## 0.17.0

- In-app updates: a Sparkle-powered updater checks releases, downloads the signed DMG and swaps the app on quit. "Check for Updates…" lives in the status bar menu, with automatic background checks.
- Color eyedropper: pick any pixel on screen (status bar > Pick Color, or a shortcut) or in the editor (toolbar tool, key I), with a magnified loupe that copies the color as sRGB hex.
- The area-selection overlay appears instantly on the shortcut; shortcuts now fire on key-down.
- Overlay card interactions stay alive after dragging a capture out as a file or closing the preview.
- The capture flash fires the moment you release the selection.
- Editor alignment buttons pin content flush against the canvas edge.
- The loupe magnifies the correct region on Retina and secondary displays, and copied colors are true sRGB.
- Five new wave wallpaper presets for screenshot backgrounds.

## 0.16.1

- Fixed a ghost rounded-rectangle border around supersampled window shots; window shots now capture edge to edge and the template draws the only shadow.

## 0.16.0

- New editor chrome: a clean main toolbar plus a contextual properties bar that shows only the active tool's options.
- Responsive editor header that tracks a much narrower window.
- Annotate / Preview mode toggle that hides editing chrome to show exactly what exports.
- Contextual crop actions (Cancel and Apply) while a crop region is staged.
- Full canvas zoom and pan: Cmd+scroll anchored zoom, pinch, Space+drag pan, Cmd+0 fit, Cmd +/- steps.
- Color picker: drag to reorder favorites, drag out or right-click to remove, hex tooltips.
- New Capture > Quality setting: Standard, High (2x) or Maximum (3x) supersampling.
- Window shots compose over the live wallpaper reliably.
- Recording window and screen choosers redesigned on native Liquid Glass.
- Fixed the overlay accepting a new gesture right after hiding a card, editor sizing for very tall or large captures, and white-bordered supersampled window grabs.

## 0.1.0

- First public build: a native macOS screenshot and markup tool, open source, no account, no upload.
- Region and full-screen capture from a global shortcut (⇧⌘4 / ⇧⌘3), with a freeze-frame so hover states and open menus stay put while you select.
- Annotation editor: arrow, rectangle, ellipse, line, text, blur, crop, with undo and redo.
- Copy to clipboard or save a full-resolution PNG.
- Menu-bar app, no Dock icon.
- First-run onboarding that walks through Screen Recording permission.
