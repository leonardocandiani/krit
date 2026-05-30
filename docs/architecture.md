# Architecture

KRIT is two processes that share one design language. The split follows a single
rule: **pixels stay native, everything else is TypeScript.**

## Why hybrid

A screenshot tool has a hot path and a cold path.

The hot path — global hotkey, freezing the screen, drawing a selection overlay
at 120 Hz, cropping at full Retina resolution — has to be native. It touches
AppKit windows, ScreenCaptureKit, and the TCC permission model. Anything with a
runtime in the middle adds latency you can feel and fights the platform.

The cold path — the annotation editor, the tray, settings, export — is a normal
app. It's most of the code, it changes the most, and it's far cheaper to build
and maintain in React than in AppKit.

So KRIT is a Swift agent for the hot path and a Tauri app for the cold path,
talking over a thin boundary.

## The two processes

### `apps/helper` — Swift agent

A faceless agent (`LSUIElement`, no Dock icon) with an active run loop, which it
needs for global hotkeys and overlay windows.

- **HotkeyManager** — registers ⇧⌘4 / ⇧⌘3 via Carbon.
- **CaptureEngine** — ScreenCaptureKit. Snapshots every display *before* the
  overlay appears (the "freeze frame"), so a hover state or open menu is
  preserved while the user selects. Crops the frame and writes a PNG.
- **OverlayController** — one borderless `NSPanel` per `NSScreen` at shield
  window level, with the selection rectangle and dimensions. Coordinate
  conversion respects each display's `backingScaleFactor`.

It runs two ways:

- **resident** (default) — registers hotkeys and stays alive.
- **one-shot** (`capture-region` / `capture-screen`) — overlay, capture once,
  print the PNG path to stdout, exit. This is what the shell drives.

Plus `check-permission` / `request-permission`, which wrap
`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` for onboarding.

### `apps/shell` — Tauri 2 + React

- **Editor** — Konva canvas: arrow, rectangle, ellipse, line, text, blur, crop,
  with undo/redo. Exports full-resolution PNG via `devicePixelRatio`.
- **Tray** — the menu-bar menu (Rust). Triggers captures, opens the editor.
- **Rust commands** — `capture(mode)` spawns the helper one-shot off the main
  thread; `open_image` / `save_image` / `copy_image_to_clipboard` handle I/O;
  permission commands delegate to the helper.

## The boundary

The IPC is deliberately thin and low-frequency.

```
tray / hotkey
   │  capture(mode)
   ▼
helper one-shot ──► overlay ──► crop ──► /tmp/krit-*.png
   │  stdout: path
   ▼
Rust emits krit://capture-complete { path }
   │
   ▼
React loadFromPath(path) ──► open_image ──► editor
```

**Frames never cross the IPC.** The helper encodes the PNG and hands over a file
path; the webview reads it as a data URL through a Rust command. Passing raw
pixels over the webview bridge would be the slow, wrong thing.

Events: `krit://capture-complete` (path), `krit://capture-cancelled` (Esc — silent),
`krit://capture-error`.

## Design tokens

`packages/tokens` holds one JSON source — the nexu/Raycast palette plus KRIT's
own colors. Style Dictionary compiles it to CSS variables for the web side and
(planned) Swift for the native side, so both halves render the same void black,
the same coral accent, the same radii. One source, no drift.

## Packaging

`tauri build` bundles the helper's `KRIT Helper.app` into the main app's
`Contents/Resources`. At runtime the Rust side resolves the helper from there in
production, or from `apps/helper/dist` in development.

Builds are currently **unsigned** — notarization needs a paid Apple Developer
account. Until then, distribution is a `.dmg` plus a `xattr -dr
com.apple.quarantine` step. Signing is on the v1.0 roadmap.

## Constraints worth knowing

- **macOS 13+** for the ScreenCaptureKit APIs KRIT relies on.
- **Screen Recording (TCC)** is mandatory and user-granted; macOS often needs an
  app relaunch after the first grant, which the onboarding accounts for.
- **Apple Silicon** for the current release binary; an Intel/universal build is
  a build-config change, not a code change.
