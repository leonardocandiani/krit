# Changelog

All notable changes to KRIT, newest first.

## Unreleased

## 0.31.1

### Fixed

- Preferences sidebar glyphs now share the native traffic-light centerline.
- Selected and hovered sidebar rows keep a professional left margin without shrinking the click target.
- The sidebar keeps native source-list keyboard navigation and VoiceOver semantics.


## 0.31.0

KRIT 0.31.0 rebuilds the screenshot editor and puts every screen on one visual system.

### The editor

The command band and the bottom bar are now floating glass capsules over a stage that runs the full height of the window, and the background sidebar is a floating panel rather than a column welded to the edge. The panel stops clear of the traffic lights, so the close and zoom buttons are never buried under its content.

Glass is real glass: a top highlight, an inner rim, a contact shadow and a lift shadow, instead of a flat translucent fill. How translucent it gets is now yours to set, in Settings under Editor, Appearance.

### One ruler for the whole app

KRIT was carrying two competing radius scales. Screens built at different times ended up with corners 4pt apart, which is enough for the eye to catch even when it cannot name what is wrong. Every surface now derives from the same spacing and radius tokens.

The recording bars, the preview card and the Quick Look preview also drop their single heavy shadow for the shared one. The old shadow was dark enough to read as a filter painted under a rectangle; over pale content it looked like a smudge.

### Fixes

A preview card could open the whole editor when you did nothing but move the cursor across it. Hovering a card activates KRIT so Space and the shortcut keys work without a click, and a Cmd+E already in flight toward another app was landing on the card. Keystrokes that arrive in the first fraction of a second after the card takes focus are now ignored.

Dragging a slider in Settings dragged the entire window instead of the slider.

A selected tool in the toolbar turned solid white, hiding the icon of the tool you had just picked.


## 0.30.0

### Editor

- Rebuilt the editor around one focused command bar with direct tools, grouped secondary actions, and contextual properties.
- Kept selection handles and hit targets consistent at every zoom level.
- Made drag-out respond from the first attempt without flattening the preview before the drag threshold.
- Added Copy & Close, accurate saved-state tracking, and clearer unsaved-work protection.

### Product surfaces

- Refined Preferences with clearer hierarchy, quieter navigation, and a focused Preview section.
- Replaced first-run onboarding with four task-focused pages covering capture, permissions, shortcuts, and automation.
- Added a branded Updates window that hands verified downloads and installation to Sparkle.
- Rebuilt What's New as a readable release digest with proper headings, bullets, and code blocks.

### Backgrounds and presets

- Simplified background preset deletion to one explicit action with confirmation.
- Prevented edited or ambiguous preset states from deleting the wrong item.
- Improved background thumbnail accessibility and sidebar motion.


## 0.29.0

KRIT v0.29.0 brings a quieter native interface and a more dependable screenshot editor.

### A focused native interface

- Preferences now use neutral navigation, consistent inset surfaces, clearer hierarchy, and restrained transitions that keep KRIT coral reserved for active state.
- Onboarding uses the real app icon, simpler feature presentation, and a cleaner permission flow without decorative material layers.
- What's New now presents release notes as readable native cards and correctly handles first launch, missing notes, and modern section headings.

### An editor you can trust

- Preview is truly read-only: editing handles, crop overlays, Smart Redact suggestions, guides, and transient objects stay out of the exported view while zoom and pan remain available.
- Active text is committed before drag, save, copy, share, and export, so the image always matches what is visible in the editor.
- Applied crops now count as unsaved work, manual zoom is no longer overwritten after opening, and the background sidebar returns when leaving Preview.
- Smart Redact ignores stale asynchronous results after the source image changes and restores its staged review state when returning to Annotate.

### Release confidence

- New regression tests cover Preview mutations, crop state, drag export, zoom routing, release-note parsing, and update display gates.
- Continuous integration now runs the Swift test suite before producing the universal macOS bundle.

### Install

```bash
brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
brew install --cask krit
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.29.0/install.sh | bash
```

On first launch, grant Screen Recording permission in System Settings.


## 0.28.2

KRIT v0.28.2 is a major reliability and visual polish release for capture, recording, editing, and distribution.

### Capture workflows that stay out of your way
- Quick Access accepts a drag immediately from the full preview surface, including controls and fast first movement, without dead spots.
- All-in-One reopens with your last valid capture area already selected and ready.
- Aside window captures now select the real content window instead of its transparent shadow host, removing the dark extra frame without cropping legitimate pixels.
- Capture delivery shares one rendition across history, clipboard, autosave, and Quick Access, keeping large screenshots responsive.

### A stronger native macOS experience
- Preferences use a fast native source list, cleaner hierarchy, better keyboard and VoiceOver behavior, and live permission state.
- The Precision Monolith system ships a new KRIT icon, installer art, and eight original high-resolution wallpaper backgrounds.
- Recording uses a consistent setup, live HUD, result flow, and corrected pause and resume timeline.
- OCR, QR, Smart Redact, wallpaper decoding, and history storage move heavy work away from the main interface.

### Safer updates
- This compatibility release preserves the established ad-hoc distribution model while requiring a universal bundle, SHA-256 checksum, and Sparkle EdDSA signature before the appcast or public branch is updated.
- The installer verifies the app signature before replacing an existing installation and applies legacy Gatekeeper compatibility only to confirmed ad-hoc bundles.
- Local automation remains opt-in, test artifacts stay in temporary storage, and history file operations reject unsafe paths.


### Security
- Legacy distributed capture notifications now exist only inside the explicit UI test environment. A normal KRIT launch no longer registers that unauthenticated local capture surface.
- UI-test capture artifacts are confined to `/tmp`, including screenshots, sidecars and area-selection snapshots.

### Reliability
- Launch now has an explicit capture-ready boundary: the status item and global hotkeys are armed before the first run-loop idle, while Sparkle validation, sound resource warming and native-shortcut conflict probing run afterward. The status menu is also populated after that boundary instead of constructing every item and SF Symbol on the critical path.
- The native screenshot-shortcut conflict dialog now honors its one-time contract instead of reappearing on every launch when the user chooses to open System Settings.
- First-run onboarding now builds each page on demand instead of constructing four complete AppKit view trees before the welcome window appears.
- The synthetic media sources used by UI regression scenarios now share a bounded 15-second writer deadline, cancel partial output on failure, and report the failing stage instead of waiting forever.
- Smart Redact and text-aware highlighter detection run their synchronous Vision work away from the AppKit main thread, so large screenshots keep the editor responsive while recognition runs.
- OCR and QR recognition use that same background Vision executor, keeping capture-selection interactions responsive on large images.
- Video editor wallpaper thumbnails and full export backgrounds now decode off the main thread, avoiding cold UI stalls from multi-megabyte image files.
- Cached wallpaper thumbnails now complete asynchronously too, avoiding reentrant SwiftUI state publication during view rendering.
- Wallpaper thumbnail cache entries now include their requested pixel size, so a small swatch never degrades the larger editor preview.
- Video playback ticks and editor-sidebar animation completions now retain their MainActor isolation under Swift 6 concurrency checks.
- Save-panel, history, keystroke, camera, scrolling-stitch and mono-audio callbacks now preserve their execution ownership under Swift 6 concurrency checks.
- Post-capture delivery now stages the overlay and raw history record before any encode, then shares one per-capture rendition cache across history, clipboard, autosave and scripted actions. Image encoding and silent file writes no longer block AppKit, and a failed destination does not cancel the remaining actions.
- Quick Access drag preparation now consumes that same per-capture rendition cache, eliminating the second full-size encode that the card previously started after every normal capture.
- Screenshot, recording, Presentation Zoom and live-wallpaper capture now share one ScreenCaptureKit catalog. Display topology is cached until macOS reports a screen change, window inventories stay fresh, and concurrent discovery is single-flight.
- Window chooser previews on macOS 14 and later now retry ScreenCaptureKit instead of falling through to the obsolete CoreGraphics window API. Ventura keeps the legacy fallback it still requires.
- Screenshot and recording regions now use one tested pixel-grid conversion based on the real `NSScreen` backing scale, fixing 1x external-display buffers and mixed AppKit/CoreGraphics monitor coordinates.
- History index loading, validation, image persistence and deletes now run through a serial disk actor instead of the AppKit main actor. Captures made during startup merge safely with disk history, and delete operations cannot race a slow encode into recreating orphaned files.
- Recording Preferences now discover microphones and cameras away from the SwiftUI render path, then refresh when hardware connects or disconnects.
- UI screenshot gates reject opaque black WindowServer frames and fall back to AppKit rendering, so a permission failure cannot pass visual verification based on PNG file size alone.
- Microphone discovery uses AVFoundation's modern `.external` device type on macOS 14 and later while preserving Ventura's legacy device types.

### Design
- Preferences now use a native AppKit source list and a single fresh SwiftUI form host. The window is resizable, section changes are instant, light and dark appearance share the same hierarchy, and reopening reloads current settings instead of retaining nine stale UI trees.
- Every Preferences section has a compact title and purpose header. Capture adds an honest permission-aware readiness state and a visual, keyboard-accessible background chooser.
- Colored icon tiles were replaced with quieter hierarchical SF Symbols. KRIT coral is reserved for navigation state and active choices.

### Accessibility
- Preferences navigation is a native source list with arrow-key navigation, type-select, stable selected-row semantics and a VoiceOver label.
- Onboarding keeps actionable labels and explanatory notes at secondary-label contrast instead of making them look disabled.

### Compatibility
- Preferences keep scroll-end breathing room on macOS 13, use structural sidebar material on every supported system and keep the forced glass fallback consistent for clustered surfaces.
- The installed bundle keeps a macOS 13 minimum deployment target, modern ScreenCaptureKit and AVFoundation paths stay version-gated, and the ad-hoc signed app passes deep code-signature verification.

### Documentation
- Architecture and contribution guides now describe the native Swift runtime, real build commands and automation boundary.

## 0.28.1

### KRIT v0.28.1

Security and polish release.

### Automation is now off by default
- The local command port and the `krit://` URL scheme no longer start on their own. A default install exposes no scriptable capture surface at all, so no other app on your Mac can screenshot the screen or read the accessibility tree through KRIT without you asking.
- Turn it on deliberately in Preferences ▸ General ▸ Automation when you want the bundled `krit` CLI, Shortcuts, or an agent to drive KRIT.

### Fixes
- Pressing a capture shortcut and then Esc no longer leaves the next shortcut feeling laggy: cancelling area selection now hands focus straight back to the app you were in
- Presentation zoom: a zoom-in pressed the instant you arm the mode is honored, gliding into the zoom instead of being dropped at 1x
- Hardening: hidden toolbar controls can't be driven through automation, and the automation job table is bounded

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
