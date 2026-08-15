version: 0.31.4
KRIT 0.31.4 makes editor drag-out compatible with destinations that require a real file and stabilizes recording on high-resolution displays.

## Editor drag and drop

- Delivers one concrete file URL from Drag out so Finder, browsers, upload fields, and other apps can accept the edited image directly.
- Prepares the full-resolution export while the editor is idle, keeping normal drag gestures responsive.
- Falls back to an immediate export when a drag starts before background preparation finishes.
- Invalidates prepared files as soon as the document changes, preventing an immediate post-edit drag from exporting an older revision.
- Keeps the exported file alive through accepted-drop delivery and closes the editor only when the delivered revision is still current.

## Screen recording

- Prevents H.264 writer setup failures on large Retina and high-resolution displays.
- Keeps recording dimensions within the 4096-pixel hardware encoder boundary while preserving the captured display's aspect ratio.
- Removes a still-image-only quality property from H.264 compression settings.

## Reliability

- Adds regression coverage for concrete editor file URLs, prepared-export invalidation, large-display scaling, and H.264 settings.
- Adds full-screen recording and physical editor drag scenarios to the local runtime harness.

## Install

```bash
brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
brew install --cask krit
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.31.4/install.sh | bash
```

On first launch, grant Screen Recording permission in System Settings.
