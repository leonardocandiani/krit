# Changelog

All notable changes to KRIT, newest first.

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
