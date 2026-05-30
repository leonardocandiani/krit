# KRIT — shell

KRIT's annotation editor and UI. Tauri 2 + React + TypeScript + Vite, with the
markup canvas in Konva. Native capture (freeze, overlay, on-screen crop) comes
from the Swift helper in `apps/helper` over IPC; this package is the editor and
the shell.

## Run

```bash
bun install
bun run tauri dev      # native app (window + tray)
# or just the frontend in a browser (drag&drop works):
bun run dev
```

> Rust builds are heavy. Point the target outside the volume to save disk:
> `CARGO_TARGET_DIR=/tmp/krit-cargo bun run tauri build`

## What it does

- Editor window 1100x720, dark, overlay titlebar.
- Menu bar tray with the KRIT symbol and actions (snap, editor, preferences).
- Konva editor: select/move/resize, arrow, rectangle, ellipse, line, text,
  region blur (pixelate), and crop.
- Color palette (coral as the brand default) + stroke width.
- Undo/redo, copy, and save at native resolution.

## Shortcuts

| Key | Action |
|-----|--------|
| V A R E L T B C | select / arrow / rectangle / ellipse / line / text / blur / crop |
| Backspace | delete selection |
| ⌘Z / ⇧⌘Z | undo / redo |
| ⌘O / ⌘C / ⌘S | open / copy / save |

## Layout

```
src/
  App.tsx              composition + shortcuts + drag&drop
  components/
    Editor.tsx         Konva canvas (core)
    Toolbar.tsx        tools, color, stroke
    TopBar.tsx         wordmark + actions
    icons.tsx          custom SVG icons
  hooks/useHistory.ts  snapshot undo/redo
  lib/tauri.ts         Rust commands + browser fallbacks
  lib/types.ts         shape model + palette
  styles/              global.css + app.css (consumes packages/tokens)
src-tauri/
  src/lib.rs           image commands + tray
  tauri.conf.json      window, productName, identifier
```

## TODO

- IPC with the Swift helper (capture-ready -> open editor with the PNG).
- Tray capture actions firing the real helper.
- Preferences window/route.
