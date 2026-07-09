version: 0.28.1
## KRIT v0.28.1

Security and polish release.

### Automation is now off by default
- The local command port and the `krit://` URL scheme no longer start on their own. A default install exposes no scriptable capture surface at all, so no other app on your Mac can screenshot the screen or read the accessibility tree through KRIT without you asking.
- Turn it on deliberately in Preferences ▸ General ▸ Automation when you want the bundled `krit` CLI, Shortcuts, or an agent to drive KRIT.

### Fixes
- Pressing a capture shortcut and then Esc no longer leaves the next shortcut feeling laggy: cancelling area selection now hands focus straight back to the app you were in
- Presentation zoom: a zoom-in pressed the instant you arm the mode is honored, gliding into the zoom instead of being dropped at 1x
- Hardening: hidden toolbar controls can't be driven through automation, and the automation job table is bounded
