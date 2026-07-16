# Architecture

KRIT is a single native macOS application bundle. Its capture, recording,
editing, automation and menu bar UI all run in Swift, primarily through AppKit
and ScreenCaptureKit. There is no webview, Tauri process, Rust shell or
TypeScript runtime in the shipped product.

## Runtime shape

`app/Package.swift` defines three SwiftPM targets:

- `KritKit` contains the application code and resources.
- `KritApp` is the thin executable entry point for `KRIT.app`.
- `KritCLI` builds the `krit` command line helper shipped inside the bundle.

`KritApp` is an `LSUIElement` menu bar app. `AppDelegate` wires the capture and
recording engines, global hotkeys, status item, onboarding, updater and optional
automation service during launch. The app normally stays out of the Dock, while
transient editor and preferences windows opt into the activation policy they
need.

Launch has two explicit phases. `criticalReady` applies appearance, creates the
lightweight controllers, starts enabled automation, installs the status item and
registers global hotkeys. `postFirstIdle` populates the status menu, starts
Sparkle, warms capture sounds and probes the global macOS shortcut domain. This
keeps filesystem, XPC, sound and modal-alert work outside the interval in which
KRIT becomes ready to capture. The `launch-readiness` UI scenario verifies that
the hotkeys are armed before the first idle and that the complete menu is ready
immediately afterward.

First-run onboarding is also incremental. It constructs the welcome page
immediately, materializes later pages only when the user reaches them and caches
those pages for Back navigation. Permission polling starts only after the
permission page exists and stops whenever that page is no longer visible.

```
menu bar / global hotkey / public automation
                 |
                 v
          AppDelegate and controllers
                 |
      +----------+-----------+----------+
      |                      |          |
      v                      v          v
CaptureEngine          RecordingEngine  AppKit editors and overlays
ScreenCaptureKit       ScreenCaptureKit Annotation, video, history, preview
```

## Major modules

| Area | Location | Responsibility |
| --- | --- | --- |
| Application lifecycle | `app/Sources/Krit/App` | Status item, onboarding, preferences, activation policy and Sparkle integration. |
| Capture | `app/Sources/Krit/Capture` | Screenshot and recording pipelines, selection, scrolling capture, audio, camera and export. |
| Annotation | `app/Sources/Krit/Annotation` | Image editing model, canvas, tools, redaction and export composition. |
| Video editing | `app/Sources/Krit/VideoEditor` | Timeline, zoom segments, compositor and video editor window. |
| Overlays | `app/Sources/Krit/Overlay`, `Zoom`, `LiveAnnotation` | Quick Access, pinning, preview, presentation zoom and drawing over the screen. |
| History | `app/Sources/Krit/History` | Local capture records, history browser and restore paths. |
| Automation | `app/Sources/Krit/Automation` | Opt in local command port, `krit://` routing, headless rendering and UI inspection. |
| Shared UI | `app/Sources/Krit/UI`, `Utilities` | Color, type, spacing, materials, permissions, diagnostics and test harnesses. |

The editor is deliberately view independent at its model boundary. Annotation
objects draw into a `CGContext`, so the same objects can render in the visible
canvas and in headless automation exports.

## Capture and recording flow

`CaptureEngine` owns screenshot acquisition. Fullscreen, area and window
captures funnel through ScreenCaptureKit on modern macOS, acquire the source
image before interactive overlays appear and send the final image into the
configured destination or editor flow.

`CaptureDelivery` owns the post-capture transaction. It stages the raw history
record and the presented overlay synchronously, then runs clipboard, autosave
and scripted actions through a per-capture artifact cache. Raw pixels remain the
editable history source, while thumbnails and external destinations receive the
presented image. Identical format requests share the same in-flight encode, and
codec or filesystem work stays outside the AppKit main actor. Quick Access also
receives the presented artifact, so prewarming a Finder drag reuses the same
encoded bytes instead of starting an independent full-resolution encode. Cards
restored from history and older capture paths keep a local fallback.

`ScreenCaptureCatalog` is the shared discovery boundary for still capture,
recording, Presentation Zoom and live wallpaper reads. It caches display
topology only until a screen-parameter change. Window inventories are never
retained after a call, but identical concurrent requests share the same
enumeration in flight. Each consumer still owns its filter policy, including
Finder desktop-icon handling, recording chrome, zoom self-exclusion and
wallpaper isolation. `ScreenCaptureDisplayGeometry` provides the common
AppKit-to-ScreenCaptureKit pixel-grid conversion for screenshots and streams.
Window previews use `SCScreenshotManager` on macOS 14 and later, including one
bounded retry for newly created or resized windows. Only Ventura reaches the
legacy CoreGraphics preview fallback.

`RecordingEngine` owns `SCStream` based recording, including optional system
audio, microphone, camera bubble, keystroke and click overlays. Its post-record
flow opens trim and conversion controls, then persists the completed local file
to history.

Overlay windows are ordinary AppKit windows with explicit capture semantics.
Chrome that should not appear in a screenshot uses `sharingType = .none`; content
meant for a presentation audience remains capturable. This distinction is a
per-window product decision, not a global default.

## Automation boundary

Public automation is off by default. Enabling it in Preferences starts the
local `CFMessagePort` named `com.krit.app.automation` and allows the `krit://`
router. The bundled CLI and MCP server use that public boundary, so they reuse
the running app's permissions without opening a separate screen capture route.

The UI harness is a separate, test-only build surface. `build-app.sh
--ui-test-harness` compiles the harness capability and marks the resulting
bundle; only that bundle starts observers when `KRIT_UI_TEST=1` is present in
the process environment. A normal bundle hard-disables the observers regardless
of its environment, and `make-dmg.sh` refuses to package a marked harness
bundle. Legacy distributed notifications for capture simulation share that gate.

All automation endpoints validate their input at the boundary. File writes from
the test harness stay inside `/tmp`, and public automation remains subject to
the user's explicit setting.

## State and design system

User preferences are backed by `UserDefaults` in `App/Settings.swift`. Local
history and capture metadata remain on disk. KRIT has no account or remote
capture storage.

`HistoryManager` remains a MainActor facade so menus, overlays and the history
band can read the current list synchronously. `HistoryDiskStore` owns index
loading and every ordered disk mutation on its own actor. Startup begins with a
usable empty facade, merges captures made while the index is loading, and
distinguishes that loading state from a genuinely empty history in the UI.

Preferences deliberately use a hybrid native boundary. AppKit owns the
resizable window, structural `.sidebar` material and `NSTableView` source list,
which supplies keyboard navigation, type-select and accessibility selection.
One `NSHostingView<AnyView>` renders the current grouped SwiftUI form. Changing
category or reopening the window replaces that root, so copied `@State` values
are current and the controller does not retain nine control trees. AVFoundation
device discovery is asynchronous and publishes immutable name/ID options back
to the Recording form.

`UI/ChromeFactory.swift`, `KritTheme.swift`, `KritType.swift` and
`KritSpacing.swift` define the shared visual language. Views should use those
tokens rather than introducing fixed colors, radii or animation timings.
`ChromeFactory` uses Liquid Glass on macOS 26 and later, with native material
fallbacks on earlier supported systems.

## Build, packaging and verification

The project is SwiftPM based. The normal source build is:

```bash
cd app
swift build --disable-index-store
swift test --disable-index-store
```

`build-app.sh` builds `KritApp` and `krit`, assembles `KRIT.app`, signs the
bundle for local installation and installs it into `/Applications`. It can make
a universal build or a host architecture build via `KRIT_ARCHS`.

Release notarization is not part of the current local build path. The release
scripts contain the notarization workflow, but a distributable release must be
signed and notarized with the project's Apple Developer credentials before it
can be treated as a normal Gatekeeper-ready download.

The in-app UI harness provides empirical regression scenarios when launched in
its dedicated environment. It never activates in a user launch. Production
claims should be backed by a SwiftPM build, focused tests and the relevant
runtime scenario rather than by source inspection alone.

Screenshot scenarios validate visual information, not only output dimensions
or file size. `ScreenshotVisualQuality` rejects opaque black frames returned by
WindowServer when capture permission is unavailable; the Preferences scenario
and the shared window snapshot helper then render the AppKit hierarchy
internally when possible. Preferences reports how many sections used that
fallback.

## Compatibility decision

KRIT supports macOS 13 and later. APIs introduced after Ventura must remain
behind availability checks with a functional fallback. Raising the deployment
target requires a product decision because it drops supported users, not merely
a compiler change.
