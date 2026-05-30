# Contributing to KRIT

Thanks for looking. KRIT is early and the surface area is small, so a good PR
goes a long way.

## The one rule

**Original code and assets only.** KRIT reimplements features that other tools
have — that's fair game. Copying code, icons, sounds, or branding from CleanShot
X, Cap, or anything else is not. Respect the licenses of dependencies you add.

## Layout

```
apps/
  helper/      Swift agent — hotkeys, freeze, overlay, capture (the hot path)
  shell/       Tauri 2 + React — Konva editor, tray, export
packages/
  tokens/      Style Dictionary — one JSON -> CSS vars + Swift
  sounds/      procedural sound generator (Python stdlib)
assets/        brand marks, sound pack
docs/          architecture notes, screenshots
```

See [docs/architecture.md](docs/architecture.md) for why it's split this way.

## Setup

You need Xcode 15+, Rust, and [Bun](https://bun.sh).

```sh
# tokens
cd packages/tokens && bun install && bun run build && cd -

# helper (debug is fine for development)
cd apps/helper
swift build --build-path /tmp/krit-build
./scripts/make-app.sh /tmp/krit-build
cd -

# app — dev mode with hot reload
cd apps/shell && bun install && bun run tauri dev
```

The editor also runs in a plain browser (`bun run dev`) without the native
shell, which is handy for working on the Konva canvas and onboarding. Capture
and clipboard fall back to no-ops or browser APIs there.

## Before you open a PR

- `bun run build` passes in `apps/shell` (tsc has no errors).
- `cargo check` passes in `apps/shell/src-tauri`.
- `swift build` passes in `apps/helper`.
- Product-facing text is English. Code identifiers are English; comments may be
  Portuguese where the surrounding file already is.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`,
`refactor:`, `docs:`, `chore:`. Keep the subject in the imperative.
