# KRIT automation and runtime verification

KRIT is a menu-bar-only (LSUIElement) macOS screenshot/recording app, Swift + AppKit, built with SPM. Bundle id `com.krit.app`. This skill encodes how to actually exercise it — most of it learned the hard way.

## Build

```bash
# Library/dev build — the flag is MANDATORY, the index store fills the external SSD:
cd app && swift build --disable-index-store 2>&1 | tail -30

# Full .app bundle, signed and installed into /Applications (KRIT_ARCHS="" = host arch only, much faster than the universal default):
cd app && KRIT_ARCHS="" ./build-app.sh
```

- `build-app.sh` stages in `/tmp/krit-app-build` (APFS, deliberately outside the exFAT repo volume) and ends by replacing `/Applications/KRIT.app`.
- SourceKit diagnostics without an index store are FALSE POSITIVES ("Cannot find type X in scope" on types that exist). The build is the truth; never "fix" code based on SourceKit alone.
- Verify what is actually installed/running before trusting any test result:

```bash
defaults read /Applications/KRIT.app/Contents/Info CFBundleVersion   # build stamp: YYYYMMDD.HHMM
ps -p $(pgrep -x KRIT) -o lstart=,comm=                              # which binary, since when
strings /Applications/KRIT.app/Contents/MacOS/KRIT | grep -c "<some marker string>"  # is MY code in there?
```

Other sessions rebuild `/Applications/KRIT.app` too. A test against the wrong build wastes a full user round-trip.

## Run / relaunch

```bash
pkill -x KRIT; sleep 1; open /Applications/KRIT.app; sleep 3; pgrep -lx KRIT
```

Never restart the app while the user is actively using it without telling them first. GUI test protocol: sequential, `pkill` between tests, never parallel instances.

## Driving the app

- **Automation port**: local CFMessagePort `com.krit.app.automation` (`app/Sources/Krit/Automation/AutomationPort.swift`). Wire protocol is submit+poll JSON: `{"cmd":"submit","request":{...}}` → `{"ok":true,"requestId":"<uuid>"}`, then `{"cmd":"poll","requestId":"..."}` until `done:true`. Command vocabulary lives in `AutomationJSON.parseCommand` / `AutomationService.execute` (`Automation/`), currently capture-oriented.
- **URL scheme**: `krit://` routes in `Automation/URLCommandRouter.swift` (capture/record/ocr/history, with area/window/fullscreen/scrolling variants). TRAP: LaunchServices can hold a second registration pointing at the stale `/tmp/krit-app-build/KRIT.app` staging copy, silently routing URLs to nothing. Symptom: `open "krit://..."` succeeds but the running app never reacts. Fix:

```bash
lsregister -u /tmp/krit-app-build/KRIT.app; lsregister -f /Applications/KRIT.app
# lsregister = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
```

- **UITestRunner** (`app/Sources/Krit/Utilities/UITestRunner.swift`): the in-app scenario harness used by GUI tests.
- **Synthetic input needs OS permission**: `osascript`/System Events keystrokes and CGEvent posts fail (error 1002 or silent no-op) unless the host app of this session has Accessibility permission. Test first with a single keystroke before building a plan on synthetic input. Without it, the user must reproduce by hand — design instrumentation so ONE user round-trip captures everything.

## Observing the app (what actually works here)

- **os_log is INVISIBLE for dev builds on this machine**: `log show --predicate 'subsystem == "com.krit.app"'` returns nothing for ad-hoc-signed builds even while the app demonstrably logs. Do not burn cycles on it. Use `KritTrace` (`Utilities/KritTrace.swift`) with its file sink instead:

```bash
defaults write com.krit.app kritTraceFile /tmp/krit-trace.log   # then relaunch and tail the file
```

- **Window state without any permission**: `CGWindowListCopyWindowInfo` (from any Swift script) reports every on-screen window's real server-side layer, order, and bounds — the ground truth hit-testing uses. AppKit's `window.level` can disagree with it; when debugging z-order/click routing, trust the server.
- **Hung or busy app**: `sample KRIT 3` dumps stacks with no permission needed. A healthy idle app parks the main thread in `mach_msg` inside the run loop.
- **Crash forensics**: `~/Library/Logs/KRIT/last-panic.txt` (written by `KritTrace.installPanicCapture()`).

## Window/overlay conventions (read before adding any overlay)

- Chrome that must never appear in captures (HUD, flash, toasts, the live-annotation toolbar): `sharingType = .none`.
- Content that SHOULD be captured/shared (presentation zoom frame, live-annotation ink, camera bubble): leave `sharingType` default; recording excludes only windows explicitly passed to `SCContentFilter(excludingWindows:)` in `RecordingEngine.startRecording`.
- Overlay levels in use: `.screenSaver` (zoom, annotation ink), `.screenSaver+1` (annotation toolbar), `CGShieldingWindowLevel()` (area selection), `.statusBar+N` (recording chrome). Custom `NSView` buttons inside an `isMovableByWindowBackground` panel MUST override `mouseDownCanMoveWindow` to `false` or clicks become window drags.

## Known flaky areas

- Synthetic drag in the overlay-conveyor GUI test flakes; re-run isolated 3x before believing a failure.
- Carbon global hotkeys (KeyboardShortcuts lib) fail silently if another process already registered the combo; persisted state lives in UserDefaults keys `KeyboardShortcuts_<name>`.
