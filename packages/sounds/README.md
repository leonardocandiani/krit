# KRIT UI Sound Pack

Functional, premium UI sounds for [KRIT](../../) — the native macOS screenshot
and recording app. Every sound is **generated procedurally from code**, so the
pack is reproducible, reviewable, and 100% original. No samples are downloaded
or copied from any app or library.

## The sound family

One tonal voice runs through the whole pack: clean, lightly glassy, low-mid
register, warm rather than bright, never cartoonish or 8-bit. Tonal cues sit
around A (A3 = 220 Hz) and use clean, consonant intervals — fifths, octaves,
major thirds — for a calm, premium feel in the spirit of a polished desktop OS.
The voicing and timbre are KRIT's own; nothing is sampled or copied.

Two sounds break the mold on purpose, but stay in the same register:

- **capture** is percussive and atonal — it is a shutter, not a note.
- **launch** is the startup theme — a long, soft three-part phrase: two rising
  "questions" that hang unresolved, then an A-major "answer" that resolves and
  rings out, all over a deep sub pedal.

| Sound          | Duration | Role |
|----------------|----------|------|
| `launch`       | 6600 ms  | App opening. Startup theme: two rising "question" phrases, then an A-major "answer" chord that resolves over a deep sub, ringing out into a long stereo tail. Swells in gently. |
| `capture`      | 240 ms   | **The shutter.** Signature sound, fires on screenshot. Heavy click + descending micro-swoosh. |
| `copy`         | 110 ms   | Soft bell tick (E4) — copied to clipboard. |
| `save`         | 1130 ms  | Rising perfect fifth (A3→E4) with a room tail — file saved. |
| `record-start` | 520 ms   | Ascending glide (C4→G4) — recording started. |
| `record-stop`  | 540 ms   | Descending glide (G4→C4) — recording stopped. |
| `error`        | 720 ms   | Low, soft falling pair. Subtle, never harsh. |
| `pin`          | 150 ms   | Soft rounded tick — screenshot pinned to screen. |
| `toggle`       | 90 ms    | Neutral light click — settings on/off. |

Each file is 48 kHz, 24-bit, stereo, mastered (soft-clip drive + look-ahead
limiter) to a full, professional level with a true-peak ceiling near -1 dBFS
and short fade in/out to avoid clicks. (Sample rate, bit depth and channel
count are set by
`SAMPLE_RATE` / `BIT_DEPTH` / `NUM_CHANNELS` at the top of `generate.py`.)

### Stereo, body and loudness

Bit depth gives dynamic range, not loudness — so the pack is *mastered* rather
than left as thin sines:

- **Body / loudness:** a `tanh` soft-clip drive adds warm harmonics and lifts
  RMS, then a look-ahead limiter catches peaks before normalizing to the
  ceiling. Dense or transient sounds (the launch chord, the capture click) use
  a gentler drive so the saturator never turns them to grit.
- **Stereo depth:** sounds are widened with mid/side processing and, for the
  bigger cues, a decorrelated stereo reverb (left and right use different delay
  sets) so the room opens up across the field. Short ticks use width only — no
  Haas delay, which would cancel in mono. Every sound stays mono-compatible.

## Files

```
packages/sounds/generate.py   # the synthesizer (run this to rebuild)
packages/sounds/README.md     # this file
assets/sounds/*.wav           # generated audio (web)
assets/sounds/*.caf           # native macOS audio (Swift helper)
assets/sounds/preview.html    # open this to hear the pack
```

## Regenerating

The generator uses only the Python standard library (`wave`, `math`, `struct`)
— no numpy, no dependencies to install.

```sh
python3 packages/sounds/generate.py
```

This writes every `.wav` into `assets/sounds/`. To rebuild the native `.caf`
versions (used by the macOS capture helper), convert with `afconvert`, which
ships with macOS:

```sh
cd assets/sounds
for f in launch capture copy save record-start record-stop error pin toggle; do
  afconvert -f caff -d LEI24@48000 "$f.wav" "$f.caf"
done
```

## Previewing

Open the preview page directly — it works over `file://`:

```sh
open assets/sounds/preview.html
```

Dark KRIT-styled page with one button per sound. The `launch` button triggers a
matching on-screen sunrise animation.

## Integration

Sounds are intentionally split by platform so each layer plays from the format
that fits it.

### Native capture (Swift helper) — `capture.caf`

Play the shutter from the native side at the exact moment of capture, where
latency matters most. Use the `.caf` file.

```swift
import AVFoundation

final class KritSounds {
    static let shared = KritSounds()
    private var players: [String: AVAudioPlayer] = [:]

    func play(_ name: String) {
        guard !UserDefaults.standard.bool(forKey: "krit.soundMuted"),
              let url = Bundle.main.url(forResource: name, withExtension: "caf")
        else { return }
        // Reuse a preloaded player so the first capture isn't delayed by I/O.
        let player = players[name] ?? (try? AVAudioPlayer(contentsOf: url))
        players[name] = player
        player?.currentTime = 0
        player?.play()
    }
}

// At capture time:
KritSounds.shared.play("capture")
```

For the lowest-latency fire-and-forget option, `AudioServicesCreateSystemSoundID`
also works with `.caf`:

```swift
import AudioToolbox

var captureSound: SystemSoundID = 0
if let url = Bundle.main.url(forResource: "capture", withExtension: "caf") {
    AudioServicesCreateSystemSoundID(url as CFURL, &captureSound)
}
// At capture time:
AudioServicesPlaySystemSound(captureSound)
```

### Shell (Tauri / React) — `*.wav`

Play UI feedback sounds (`copy`, `save`, `record-start`, `record-stop`,
`error`, `pin`, `toggle`, `launch`) from the web layer on their events. Use the
`.wav` files via Web Audio for low-latency, overlap-friendly playback. Honor a
single global mute setting.

```ts
const ctx = new AudioContext();
const cache = new Map<string, AudioBuffer>();
let muted = false; // wire this to your settings store

async function load(name: string): Promise<AudioBuffer> {
  if (cache.has(name)) return cache.get(name)!;
  const res = await fetch(`/sounds/${name}.wav`);
  const buf = await ctx.decodeAudioData(await res.arrayBuffer());
  cache.set(name, buf);
  return buf;
}

export async function playSound(name: string) {
  if (muted) return;
  if (ctx.state === "suspended") await ctx.resume();
  const src = ctx.createBufferSource();
  src.buffer = await load(name);
  src.connect(ctx.destination);
  src.start();
}

// Examples:
playSound("copy");          // after writing to clipboard
playSound("save");          // after a file is written
playSound("record-start");  // when capture recording begins
playSound("error");         // on a failure / denied permission
```

A simpler `HTMLAudioElement` approach also works when overlap and latency are
not concerns:

```ts
function playSound(name: string) {
  if (muted) return;
  new Audio(`/sounds/${name}.wav`).play().catch(() => {});
}
```

### Mute

Keep one global mute setting shared by both layers. The native helper reads it
from `UserDefaults` (`krit.soundMuted` above); the shell reads it from your
settings store. When muted, skip playback entirely rather than playing at zero
volume.
