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
