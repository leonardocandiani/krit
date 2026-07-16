# Contributing to KRIT

KRIT is a native macOS application written in Swift. It uses SwiftPM and AppKit,
with ScreenCaptureKit for capture and recording. The shipped app has no Tauri,
Rust, React or TypeScript layer.

## Ground rules

Submit original code and assets, and respect the licenses of every dependency.
Keep product-facing text and identifiers in English. Comments may follow the
language already used in their surrounding file.

## Layout

```
app/
  Sources/Krit/       AppKit app modules, resources and shared UI
  Sources/KritApp/    KRIT.app executable entry point
  Sources/KritCLI/    Bundled CLI and MCP entry point
  Tests/KritKitTests/ SwiftPM regression tests
  build-app.sh        Bundle assembly and local installation
docs/                 Architecture and project decisions
scripts/              Release and packaging helpers
```

See [docs/architecture.md](docs/architecture.md) before changing a cross-cutting
flow such as capture, automation, recording or activation policy.

## Setup

Use a full Xcode installation with the macOS SDK required by the current
release. The project does not need Bun, Cargo or a separate web development
server.

```bash
git clone https://github.com/leonardocandiani/krit.git
cd krit/app

# Fast source and test verification. Keep this flag: the index store is large.
swift build --disable-index-store
swift test --disable-index-store

# Assemble and install a host architecture app for runtime verification.
KRIT_ARCHS="" ./build-app.sh
```

`build-app.sh` installs `/Applications/KRIT.app`. Do not validate a runtime
change against an older installed bundle. Runtime scenarios require a separate
local harness build: `KRIT_ARCHS="" ./build-app.sh --ui-test-harness`, launched
with `KRIT_UI_TEST=1`. A normal bundle ignores that environment variable, and
`make-dmg.sh` refuses to package a bundle marked as a harness build.

## Before opening a pull request

- Run `swift build --disable-index-store` and `swift test --disable-index-store`.
- Exercise the changed flow in the installed app when it touches AppKit,
  ScreenCaptureKit, permissions, automation or packaging.
- Preserve the automation opt-in boundary. New public commands must not bypass
  `AutomationGate`.
- Give new custom controls an accessibility role, label, keyboard behavior and
  a deliberate `mouseDownCanMoveWindow` decision when placed in movable chrome.
- Use `ChromeFactory`, `KritType`, `KritSpacing` and `Motion` instead of adding
  duplicate visual constants.

## Commits

Use Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:` and `chore:`.
Keep the subject imperative and scoped to the intentional change.
