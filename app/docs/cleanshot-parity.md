# KRIT × CleanShot X — Parity Spec (source of truth for the parity loop)

Status legend: `DONE` shipped & verified · `PARTIAL` exists but incomplete · `TODO` missing.
Each item has an ID, the acceptance criteria, and the owning file(s). The parity
loop drives every item to DONE. Verification: code compiles + behavior reproduced
(headless render where possible; visual items flagged "needs live macOS 26 screen").

---

## A. Quick Access Overlay (the post-capture "preview")

Current overlay already does: configurable auto-dismiss (`Settings.overlayTimeout`,
`-1` = never), pause-on-hover, trackpad swipe-to-dismiss, draggable thumbnail with
file drag-out, corner buttons (Edit/Close/Delete/Pin), Copy/Save pills, supports
multiple windows (`openWindows: [QuickAccessWindow]`).

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| A1 | Configurable dwell / never-dismiss | DONE | Already via `Settings.overlayTimeout`; ensure a clean Preferences control exists (slider + "Never"). | Settings, PreferencesWindowController |
| A2 | Drag the card off-screen with the mouse → dismiss/delete | PARTIAL→TODO | Mouse-drag the whole card past a screen edge throws it off with slide+fade and removes that capture (distinct from the existing file drag-out and trackpad swipe). | QuickAccessOverlay |
| A3 | Hover + Spacebar → large Quick Look preview (Finder-style) | TODO | While hovering a card, pressing Space opens a QLPreviewPanel (or custom large preview) of that capture; Space/Esc closes. | QuickAccessOverlay, new QuickLookController |
| A4 | Overlay size Small / Medium / Large | TODO | A setting + context-menu toggle resizes the card (e.g. 180/240/320 wide); persists in Settings; all layout scales. | QuickAccessOverlay, Settings(scaffold) |
| A5 | Drag down to "step aside" → peek tab with up-arrow to restore | TODO | Dragging the card downward parks it at the bottom edge as a small handle showing an up-arrow; clicking/hovering it slides the card back. Auto-dismiss pauses while parked. | QuickAccessOverlay |
| A6 | Multiple captures stack without overlapping | PARTIAL→TODO | Successive captures stack in a vertical cascade (newest on top), each offset so none fully overlaps; closing one re-flows the stack. | QuickAccessOverlay |
| A7 | Share sheet from the overlay | TODO | A Share action on the card opens `NSSharingServicePicker` (AirDrop/Messages/Mail/Photos). | QuickAccessOverlay |
| A8 | Drag the floating preview out as a real file (drag-to-attach) | DONE→VERIFY/HARDEN | Card is already an `NSDraggingSource` writing a `fileURL` (QuickAccessOverlay `DraggableImageView`). HARDEN: (a) the dragged file must be the latest EDITED PNG, not the raw capture; (b) it must attach when dropped into other apps/IDEs (Claude Code in VS Code / desktop / browser, Slack, Mail) — add an `NSFilePromiseProvider` fallback for apps that request a promised file; (c) note that dropping onto a pure terminal pastes the path (terminal behavior, not our bug). | QuickAccessOverlay |

## B. Editor precision

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| B1 | Marquee multi-select (drag on empty canvas) | TODO | Dragging on empty canvas draws a selection rectangle; all intersected objects become selected. | AnnotationCanvas |
| B2 | Shift-click add/remove from selection | PARTIAL→TODO | Shift-click toggles an object in/out of the current multi-selection. | AnnotationCanvas |
| B3 | Smart guides + snapping | TODO | Dragging an object snaps its edges/centers to other objects and canvas center/edges, drawing coral alignment lines. | AnnotationCanvas |
| B4 | Shift-constrain shapes | TODO | Shift forces square/circle for rect/ellipse and 45° increments for line/arrow. | AnnotationCanvas |
| B5 | Canvas zoom + pan | TODO | Pinch/⌘+/⌘- zoom and scroll/space-drag pan; annotation coordinates stay correct; fit-to-window reset. | AnnotationCanvas |

## C. Recording

Current: video recording (AVAssetWriter + SCStream), mic audio, system audio,
cursor, FPS/quality settings, recording HUD.

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| C1 | GIF export | TODO | A recording can be exported to an optimized (palette-quantized) GIF via `CGImageDestination` `com.compuserve.gif`. | RecordingEngine, new GIFEncoder |
| C2 | Pause / resume during recording | TODO | HUD pause button gates frame append; timestamps offset by paused duration so output has no gap. | RecordingEngine, RecordingHUDWindow |
| C3 | Post-recording trim | TODO | Trim start/end via `AVMutableComposition` timeRange before save. | RecordingEngine |
| C4 | Webcam overlay | TODO | Optional circular webcam PiP composited into the recording (device picker in settings). | RecordingEngine, Settings(scaffold) |
| C5 | Click-highlight + keystroke overlay | TODO | During recording, mouse clicks show a ripple and pressed keys show a HUD; included in the captured output. | RecordingEngine, new KeystrokeClickOverlay |

## D. Capture

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| D1 | Self-timer / countdown | TODO | Optional 3-2-1 countdown window before firing the existing capture path. | CaptureEngine, new CountdownWindow, Settings(scaffold) |
| D2 | Reliable scrolling capture | PARTIAL→TODO | Replace naive row-dedup stitch with real overlap detection (cross-correlate bottom N rows of frame K vs K+1, append only new rows). | ScrollingCaptureController |
| D3 | Guaranteed native-resolution export | VERIFY/TODO | Flatten composites into a CGContext at the source pixel size (no silent downsample on 1x displays). | AnnotationCanvas, ScreenshotBackgroundComposer |

## E. Editing templates / presets

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| E1 | Save background + edit config as a named template | TODO | User saves current background options (and defaults) as a named template, persisted. | new TemplateStore, BackgroundSidebar, Settings(scaffold) |
| E2 | Apply template to every new capture (default) | TODO | A "default template" setting auto-applies on each new editor open. | TemplateStore, AnnotationWindowController, Settings(scaffold) |
| E3 | Quick-apply a saved template | TODO | One-click apply of a saved template inside the editor/sidebar. | BackgroundSidebar, AnnotationWindowController |

## F. Share / export / pin

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| F1 | Native share sheet in editor | TODO | `NSSharingServicePicker` button in the editor toolbar. | AnnotationWindowController |
| F2 | Drag-out edited image from editor & pinned window | TODO | Both the editor and the pinned window are `NSDraggingSource` carrying the edited PNG. | AnnotationWindowController, PinnedWindow |
| F3 | Copy to clipboard | DONE | Already present. | — |
| F4 | Pin to screen everywhere | DONE→VERIFY | Pin from overlay & editor; verify pinned window controls (copy/close/opacity). | PinnedWindow |

## G. Distribution (CleanShot ships; we don't yet)

| ID | Feature | Status | Acceptance | Files |
|----|---------|--------|-----------|-------|
| G1 | Notarization pipeline | TODO | `notarize-dmg.sh` fixed (stale vars) + documented signing path. | notarize-dmg.sh, build-app.sh |
| G2 | Homebrew cask | TODO | A cask formula template + release artifact naming. | new Casks/, README |
| G3 | Auto-update (Sparkle) | TODO | Sparkle wired with appcast; or a documented stub if Package deps can't add it now. | Package.swift, AppDelegate |
| G4 | CI release workflow | TODO | `.github/workflows/release.yml` building + (optionally) notarizing the DMG. | new workflow |

---

## Deferred to the 110% wave (post-parity)
- Bring-your-own-bucket cloud upload + expiring/password links (config-heavy).
- Golden-image determinism test harness for headless render (MCP contract).
- Annotation: blur shapes beyond rect, redaction presets, magnifier annotation.
- Recording: scheduled/area-follow, multi-cam.

## Verification rules for the loop
1. `swift build` must pass after every phase (hard gate).
2. Each implemented item gets an adversarial review pass before it's marked DONE.
3. Visual-only behaviors (glass, overlay motion, quick look) are marked
   `DONE (needs live-screen check)` — code + headless proof only; final visual
   sign-off requires a macOS 26+ screen.
4. The loop is complete when every A–G item is DONE or explicitly deferred above.
