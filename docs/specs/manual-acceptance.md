# Manual acceptance protocol

Master plan F9.2. Some behaviors cannot be proven headless: drag feel with
multiple cards, the recording HUD acting on a live take, the irreversibility of a
redaction, and reduced-motion. This is the fixed script to accept them by hand.
Each item lists what changed, the steps, and the expected result. Run against the
build in `/Applications` (it is deployed by `build-app.sh`).

## How to read this

- **PASS** means the expected result happened exactly.
- If a step diverges, note the divergence; that is the regression signal.
- These cover wave 1 of the plan (design system, recording -> editor, overlay
  z-order, secure redact, reduced motion). Feel polish (F6.2-F6.5) and the overlay
  coordinator (F3.1) are not in this build yet and are listed under "Pending" so
  the script stays one source of truth.

## 1. Overlay drag z-order (F3.2)

What changed: a grabbed card is raised above its siblings the moment a drag
starts, so it no longer slides behind another card.

Steps:
1. Take 3+ screenshots in a row so the quick-access overlay stacks 3+ cards.
2. Grab the back-most card and drag it across the front cards.

Expected: the dragged card stays on top of every other card for the whole drag,
never disappearing behind one. On drop it settles back into the stack.

## 2. Recording HUD restart and discard (F4.6)

What changed: the HUD's restart (counter-clockwise) and trash buttons were
permanently disabled; they now do real work.

Steps:
1. Start an area recording. The HUD shows stop, pause, restart and trash, all
   enabled (none dimmed).
2. Click the trash button.
   Expected: recording stops, a "Recording discarded" toast appears, and NO result
   card or file is left behind (check the save folder, nothing new).
3. Start another recording, click the restart button.
   Expected: a "Restarting..." toast, the current take is dropped, and a fresh
   recording of the same area begins immediately (HUD timer back at 0:00).

## 3. Secure redact is irreversible (F7.1)

What changed: Smart Redact now lays down the irreversible Secure Blur (heavy block
mosaic) instead of a recoverable pixelate.

Steps:
1. Capture something with visible secret-looking text (a fake token / password).
2. Run Smart Redact, apply, then export the image.
3. Open the exported file and zoom in hard on the redacted band; try any
   un-pixelate / sharpen tool on it.

Expected: the band reads as solid coarse blocks with no recoverable glyph edges;
no sharpening recovers the original characters. (A plain pixelate would leak the
low-frequency outline; this must not.)

## 4. Reduced Motion (F6.1)

What changed: toasts and 14 other animated surfaces now collapse to instant when
Reduce Motion is on, through the central Motion token.

Steps:
1. System Settings -> Accessibility -> Display -> turn Reduce Motion ON.
2. Trigger a toast (copy something), open Quick Look on a history card, hover a
   history card, remove a color swatch, open a pinned window's close.

Expected: each of those appears/updates instantly, with no slide or scale, but the
end state is identical (nothing missing). Turn Reduce Motion OFF and confirm the
animations return.

## 5. Trim & Convert really converts (F4.5)

Covered headless by the `trim-convert` UI test (320x240 stereo -> 160x120 mono,
read back from the file). Manual cross-check if desired:

Steps:
1. Record a clip, open Trim & Convert, pick a smaller dimension + low quality +
   Mono, run it.
2. Inspect the output in Finder -> Get Info (or QuickLook info).

Expected: the output dimensions match what you picked and the file is smaller; the
audio is single-channel.

## Pending (not in this build, here so the script stays complete)

- **Overlay coordinator (F3.1):** when delivered, accept with 4+ cards exercising
  delete / park / conveyor / zoom gestures back to back, watching for any missed
  click, focus theft, or stuck drag.
- **Feel polish (F6.2-F6.5):** card->editor zoom morph, HUD enter/exit, hover
  crossfades. Accept by eye against the reference apps.
