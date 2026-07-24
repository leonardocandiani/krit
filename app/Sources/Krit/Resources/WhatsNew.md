version: 0.28.2
KRIT v0.28.2 is a major reliability and visual polish release for capture, recording, editing, and distribution.

### Capture workflows that stay out of your way
- Quick Access accepts a drag immediately from the full preview surface, including controls and fast first movement, without dead spots.
- All-in-One reopens with your last valid capture area already selected and ready.
- Aside window captures now select the real content window instead of its transparent shadow host, removing the dark extra frame without cropping legitimate pixels.
- Capture delivery shares one rendition across history, clipboard, autosave, and Quick Access, keeping large screenshots responsive.

### A stronger native macOS experience
- Preferences use a fast native source list, cleaner hierarchy, better keyboard and VoiceOver behavior, and live permission state.
- The Precision Monolith system ships a new KRIT icon, installer art, and eight original high-resolution wallpaper backgrounds.
- Recording uses a consistent setup, live HUD, result flow, and corrected pause and resume timeline.
- OCR, QR, Smart Redact, wallpaper decoding, and history storage move heavy work away from the main interface.

### Safer updates
- This compatibility release preserves the established ad-hoc distribution model while requiring a universal bundle, SHA-256 checksum, and Sparkle EdDSA signature before the appcast or public branch is updated.
- The installer verifies the app signature before replacing an existing installation and applies legacy Gatekeeper compatibility only to confirmed ad-hoc bundles.
- Local automation remains opt-in, test artifacts stay in temporary storage, and history file operations reject unsafe paths.
