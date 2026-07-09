# KRIT

Menu-bar-only (LSUIElement) macOS screenshot & screen-recording app. Swift + AppKit, SPM (no Xcode project), English everywhere (OSS). App code lives in `app/Sources/Krit/`.

## Build & verify

```bash
cd app && swift build --disable-index-store 2>&1 | tail -30   # flag is mandatory (index store fills the SSD)
cd app && KRIT_ARCHS="" ./build-app.sh                        # full .app → /Applications (host arch, fast)
```

SourceKit errors without an index store are false positives; the build is the truth. Runtime verification, driving the app, and debugging recipes: read `.claude/skills/krit-automation/SKILL.md` before testing anything at runtime.

## Where changes go

| Change | Files |
|---|---|
| New global hotkey | `Hotkeys/ShortcutNames.swift` (name + default, add to `allCapture`) → handler in `Hotkeys/HotkeyManager.swift` → recorder row in `App/PreferencesContent.swift` (ShortcutsForm) |
| New user preference | `App/Settings.swift` (UserDefaults-backed static var) + UI in `App/PreferencesContent.swift` (tab enum in `App/PreferencesWindowController.swift`) |
| Menu bar item | `App/AppDelegate.swift` menu construction (~line 236+), `@objc` action alongside |
| Capture behavior | `Capture/CaptureEngine.swift` (ScreenCaptureKit; legacy CG path only < macOS 15) |
| Recording behavior | `Capture/RecordingEngine.swift` (SCStream; window exclusion via `excludedWindowNumbers`) |
| Screenshot editor | `Annotation/` — model objects in `AnnotationObject.swift` (view-independent, draw into CGContext), editor view `AnnotationCanvas.swift`, window `AnnotationWindowController.swift` |
| Live overlays | `Zoom/PresentationZoomController.swift` (live zoom), `LiveAnnotation/` (draw-on-screen), both anchored to the screen under the cursor |
| Visual chrome / materials | `UI/ChromeFactory.swift` (radius, liquid-glass materials) — reuse tokens, never hardcode radius/colors in views |
| First-run / onboarding | `App/WelcomeWindowController.swift` (wizard with permission polling) → `App/FeatureTourController.swift` (TourKit slideshow) → `App/WhatsNewWindowController.swift` (updates only) |
| Automation / agent access | `Automation/` (CFMessagePort port + service + `krit://` router), `Utilities/UITestRunner.swift` |
| Diagnostics | `Utilities/KritTrace.swift` (os_log + opt-in file sink + panic capture) |

## Entry points

- `App/AppDelegate.swift::applicationDidFinishLaunching` — wiring order: engines → hotkeys → status item → welcome/tour/whats-new chain.
- `Hotkeys/HotkeyManager.swift::register(...)` — every global shortcut handler; capture entry points drop live overlays first (`dropOverlays()` pattern: zoom exits, live annotation steps to passive keeping ink).
- `Capture/CaptureEngine.swift::captureFullscreen/captureRectToImage` — all screenshots funnel here.
- `App/ActivationPolicy.swift` — dynamic `.accessory`/`.prohibited` dance; borderless windows must opt in via `addActivationPersistentWindow` or closing an unrelated window yanks the Dock icon from under them.

## Hard rules

- Window capture semantics are a design decision per window: chrome gets `sharingType = .none`; content meant to be seen by a screen-share audience stays capturable. Check the table in the krit-automation skill before creating any overlay window.
- Custom `NSView` buttons inside `isMovableByWindowBackground` panels must override `mouseDownCanMoveWindow → false`.
- Sync with `origin/main` before starting a feature or PR; releases go through `scripts/` + `app/build-app.sh`/`make-dmg.sh`, never by hand.
- Deprecated code moves to a `deprecated/` folder with date + reason, never straight deletion.
