version: 0.31.3
KRIT 0.31.3 makes drag-and-drop dependable from both Quick Access and the editor, and fixes transparent framing in Aside window captures.

## Drag and drop

- Starts screenshot drags reliably from natural horizontal or diagonal pulls across the Quick Access card, including its controls and edges.
- Prevents a previous snap-back animation from interfering with an immediate retry.
- Delivers one stable file in the selected format and keeps the card available until the destination finishes writing it.
- Makes Drag out in the editor start without waiting for a full-resolution render.
- Preserves the exact edit state captured when the drag begins, while keeping later edits open in the editor.

## Window capture

- Removes the extra transparent rounded frame embedded in Aside Browser window captures without altering captures from other apps.

## Interface

- Aligns Settings sidebar icons consistently with the macOS window controls.

## Reliability

- Adds regression coverage for file-promise lifetime, drag hit targets, accepted-drop delivery, editor state, and transparent window framing.

## Install

```bash
brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
brew install --cask krit
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.31.3/install.sh | bash
```

On first launch, grant Screen Recording permission in System Settings.
