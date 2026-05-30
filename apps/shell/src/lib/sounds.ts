// KRIT UI sound layer.
// Plays the .wav pack via Web Audio: a single AudioContext, decoded buffers
// cached on first use, and one global mute flag persisted to localStorage.
// Playback is fire-and-forget and never throws into the UI.

export type SoundName =
  | "launch"
  | "capture"
  | "copy"
  | "save"
  | "record-start"
  | "record-stop"
  | "error"
  | "pin"
  | "toggle";

const MUTE_KEY = "krit.soundMuted";

let ctx: AudioContext | null = null;
const cache = new Map<SoundName, AudioBuffer>();
const inflight = new Map<SoundName, Promise<AudioBuffer | null>>();

// Mirror of the persisted flag so reads stay synchronous.
let muted = readMuted();

function readMuted(): boolean {
  try {
    return localStorage.getItem(MUTE_KEY) === "1";
  } catch {
    return false;
  }
}

function ensureCtx(): AudioContext | null {
  if (ctx) return ctx;
  const AC =
    window.AudioContext ||
    (window as unknown as { webkitAudioContext?: typeof AudioContext })
      .webkitAudioContext;
  if (!AC) return null;
  ctx = new AC();
  return ctx;
}

async function loadBuffer(
  audio: AudioContext,
  name: SoundName,
): Promise<AudioBuffer | null> {
  const hit = cache.get(name);
  if (hit) return hit;

  const pending = inflight.get(name);
  if (pending) return pending;

  const p = (async () => {
    try {
      const res = await fetch(`/sounds/${name}.wav`);
      if (!res.ok) return null;
      const buf = await audio.decodeAudioData(await res.arrayBuffer());
      cache.set(name, buf);
      return buf;
    } catch {
      return null;
    } finally {
      inflight.delete(name);
    }
  })();

  inflight.set(name, p);
  return p;
}

/** Plays a sound by name. No-op when muted or when Web Audio is unavailable. */
export async function playSound(name: SoundName): Promise<void> {
  if (muted) return;
  const audio = ensureCtx();
  if (!audio) return;
  try {
    // Browsers start the context suspended until a user gesture.
    if (audio.state === "suspended") await audio.resume();
    const buffer = await loadBuffer(audio, name);
    if (!buffer || muted) return;
    const src = audio.createBufferSource();
    src.buffer = buffer;
    src.connect(audio.destination);
    src.start();
  } catch {
    // Audio failures must never break the editor.
  }
}

/** Warms the context (call from a user gesture) so the first real cue is instant. */
export function unlockAudio(): void {
  const audio = ensureCtx();
  if (audio && audio.state === "suspended") void audio.resume();
}

/** True when the audio context is live (sound is actually audible). */
export function audioReady(): boolean {
  return ctx?.state === "running";
}

export function isMuted(): boolean {
  return muted;
}

/** Sets the global mute flag and persists it. Returns the new state. */
export function setMuted(value: boolean): boolean {
  muted = value;
  try {
    localStorage.setItem(MUTE_KEY, value ? "1" : "0");
  } catch {
    // ignore storage failures (private mode, etc.)
  }
  return muted;
}

export function toggleMuted(): boolean {
  return setMuted(!muted);
}
