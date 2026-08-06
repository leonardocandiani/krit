version: 0.31.2
KRIT 0.31.2 restores the editor's drag-out control and makes its purpose clear at a glance.

## Editor

- Keeps the full Drag out control visible when the editor first opens.
- Replaces the ambiguous grip-only treatment with an explicit cursor icon and label.
- Matches the drag control's hover, pressed, contrast, and sizing behavior to the surrounding action pill.

## Reliability

- Removes the circular width measurement that could hide the drag source permanently.
- Adds regression coverage for the initial editor layout and platform drag icon.

## Install

```bash
brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit
brew install --cask krit
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.31.2/install.sh | bash
```

On first launch, grant Screen Recording permission in System Settings.
