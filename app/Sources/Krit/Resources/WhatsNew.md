version: 0.29.0
KRIT v0.29.0 brings a quieter native interface and a more dependable screenshot editor.

### A focused native interface

- Preferences now use neutral navigation, consistent inset surfaces, clearer hierarchy, and restrained transitions that keep KRIT coral reserved for active state.
- Onboarding uses the real app icon, simpler feature presentation, and a cleaner permission flow without decorative material layers.
- What's New now presents release notes as readable native cards and correctly handles first launch, missing notes, and modern section headings.

### An editor you can trust

- Preview is truly read-only: editing handles, crop overlays, Smart Redact suggestions, guides, and transient objects stay out of the exported view while zoom and pan remain available.
- Active text is committed before drag, save, copy, share, and export, so the image always matches what is visible in the editor.
- Applied crops now count as unsaved work, manual zoom is no longer overwritten after opening, and the background sidebar returns when leaving Preview.
- Smart Redact ignores stale asynchronous results after the source image changes and restores its staged review state when returning to Annotate.

### Release confidence

- New regression tests cover Preview mutations, crop state, drag export, zoom routing, release-note parsing, and update display gates.
- Continuous integration now runs the Swift test suite before producing the universal macOS bundle.

### Install

```bash
brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
brew install --cask krit
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.29.0/install.sh | bash
```

On first launch, grant Screen Recording permission in System Settings.
