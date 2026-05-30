#!/usr/bin/env python3
"""
KRIT UI Sound Pack — procedural generator.

Synthesizes the full KRIT sound family from scratch using only the Python
standard library (wave, math, struct). No numpy, no samples, no external
audio. Run it and the .wav files appear in assets/sounds/.

    python3 packages/sounds/generate.py

Design notes
------------
Every sound shares one tonal "voice" so the pack reads as a single brand:
clean, lightly glassy/crystalline, low-mid register, never cartoonish or
8-bit. The voice is a sine fundamental plus a soft glassy partial (a touch
of the 2nd/3rd harmonic and a high shimmer at low gain) shaped by an ADSR
envelope with short fade in/out to kill clicks. Pitches come from an A
minor-pentatonic scale around A3 (220 Hz) so the tonal sounds feel related.

The shutter (capture) is the exception: it is percussive/atonal by design —
a dry transient click plus a fast descending body — but it lives in the same
register so it still belongs to the family.

The launch sound is the cinematic counterpart: a longer "sonic sunrise" that
swells from a low fundamental into a blooming A-pentatonic chord with shimmer.
It is the app waking up, so it is allowed to be bigger than the UI ticks.

Output: 44.1 kHz, 16-bit, mono. Each sound is normalized to a ~-3 dBFS peak,
no clipping.
"""

import math
import os
import struct
import wave

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Audio format — tune these for the whole pack.
SAMPLE_RATE = 48_000   # Hz
BIT_DEPTH = 24         # bits per sample (16 or 24 supported by write_wav)
NUM_CHANNELS = 2       # 2 = stereo (width + depth); 1 = mono
PEAK_DBFS = -1.0       # final true-peak ceiling after mastering

# Mastering chain (this is what makes it sound clean and professional, not the
# bit depth — 24-bit is already studio quality). Order: high-pass -> compressor
# -> gentle drive -> look-ahead limiter -> normalize.
#
# The earlier versions distorted the LOW END: the sub + chord summed and their
# bass peaks slammed the saturator and the low end was clipping. The fix is to
# control dynamics with a real compressor and clear out inaudible sub-bass with
# a high-pass, instead of leaning on saturation.
HPF_HZ = 45.0          # high-pass: remove inaudible sub-bass that only eats headroom
LOW_SHELF_HZ = 220.0   # low-shelf corner — tame the low band so it stops booming
LOW_SHELF_DB = -3.5    # low-shelf cut (negative = attenuate the bass)
COMP_THRESH_DB = -22.0 # compressor threshold (lower = catches the bass peaks more)
COMP_RATIO = 3.5       # compressor ratio (smooths peaks -> "produced" feel)
DRIVE_DB = 1.0         # very gentle harmonic warmth — no longer the loudness source
LIMIT_DBFS = -1.0      # final true-peak ceiling

# Largest positive sample value for the chosen bit depth (e.g. 2**23 - 1 at 24-bit).
MAX_AMP = 2 ** (BIT_DEPTH - 1) - 1

# Output dir: <repo>/assets/sounds  (this file lives in <repo>/packages/sounds)
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(REPO_ROOT, "assets", "sounds")

# A minor pentatonic around A3 — the KRIT scale.
A3 = 220.0
NOTES = {
    "A3": A3,
    "C4": A3 * 2 ** (3 / 12),   # ~261.6
    "D4": A3 * 2 ** (5 / 12),   # ~293.7
    "E4": A3 * 2 ** (7 / 12),   # ~329.6
    "G4": A3 * 2 ** (10 / 12),  # ~392.0
    "A4": A3 * 2 ** (12 / 12),  # 440.0
    "C5": A3 * 2 ** (15 / 12),
    "E5": A3 * 2 ** (19 / 12),
}

# ---------------------------------------------------------------------------
# Buffer helpers (a buffer is a plain list of floats, roughly in [-1, 1])
# ---------------------------------------------------------------------------


def n_samples(seconds):
    return int(round(seconds * SAMPLE_RATE))


def silence(seconds):
    return [0.0] * n_samples(seconds)


def mix(into, src, start_sec=0.0, gain=1.0):
    """Add src into the into-buffer at an offset, extending if needed."""
    start = n_samples(start_sec)
    end = start + len(src)
    if end > len(into):
        into.extend([0.0] * (end - len(into)))
    for i, s in enumerate(src):
        into[start + i] += s * gain
    return into


# ---------------------------------------------------------------------------
# Envelopes
# ---------------------------------------------------------------------------


def adsr(total_sec, attack, decay, sustain_level, release, curve=2.0):
    """
    Classic ADSR as a per-sample gain list. attack/decay/release are seconds;
    sustain_level is 0..1. `curve` shapes the decay/release (>1 = faster initial
    fall, more natural for plucked/glassy tones).
    """
    total = n_samples(total_sec)
    a = max(1, n_samples(attack))
    d = max(1, n_samples(decay))
    r = max(1, n_samples(release))
    s = max(0, total - a - d - r)
    env = []
    # attack: smooth (raised-cosine) to avoid a hard edge
    for i in range(a):
        x = i / a
        env.append(0.5 - 0.5 * math.cos(math.pi * x))
    # decay to sustain
    for i in range(d):
        x = i / d
        env.append(1.0 - (1.0 - sustain_level) * (x ** (1 / curve)))
    # sustain
    env.extend([sustain_level] * s)
    # release to 0
    for i in range(r):
        x = i / r
        env.append(sustain_level * (1.0 - x ** (1 / curve)))
    # pad/truncate to exact length
    if len(env) < total:
        env.extend([0.0] * (total - len(env)))
    return env[:total]


def perc_env(total_sec, attack_sec, curve=4.0):
    """Percussive envelope: fast attack, exponential-ish decay to zero."""
    total = n_samples(total_sec)
    a = max(1, n_samples(attack_sec))
    env = []
    for i in range(a):
        x = i / a
        env.append(0.5 - 0.5 * math.cos(math.pi * x))
    body = max(1, total - a)
    for i in range(body):
        x = i / body
        env.append(math.exp(-curve * x) * (1.0 - x))
    return env[:total]


def apply_env(buf, env):
    return [s * env[i] for i, s in enumerate(buf)]


def fade_edges(buf, fade_in_sec=0.004, fade_out_sec=0.03):
    """
    Fade in/out on the final buffer. A short fade-in kills the start click; a
    LONGER, exponential fade-out dissolves the end so nothing ever cuts off
    abruptly (hard stop), even if there is still energy at the boundary. The
    exponential shape decays like a natural release instead of a linear ramp.
    """
    fi = min(n_samples(fade_in_sec), len(buf) // 2)
    fo = min(n_samples(fade_out_sec), len(buf) // 2)
    for i in range(fi):
        buf[i] *= i / fi
    for i in range(fo):
        x = i / fo                       # 0 at the tail end .. 1 just before it
        g = x ** 2                       # exponential-ish: smooth, natural decay
        buf[-1 - i] *= g
    return buf


# ---------------------------------------------------------------------------
# Oscillators / voice
# ---------------------------------------------------------------------------


def sine(freq, seconds, phase=0.0):
    total = n_samples(seconds)
    w = 2 * math.pi * freq / SAMPLE_RATE
    return [math.sin(w * i + phase) for i in range(total)]


def triangle(freq, seconds):
    """Soft triangle via summed odd harmonics — warmer than a raw saw/square."""
    total = n_samples(seconds)
    out = [0.0] * total
    harmonics = [(1, 1.0), (3, -1 / 9), (5, 1 / 25), (7, -1 / 49)]
    for k, amp in harmonics:
        w = 2 * math.pi * (freq * k) / SAMPLE_RATE
        for i in range(total):
            out[i] += amp * math.sin(w * i)
    return out


def glassy_tone(freq, seconds, env, shimmer=0.18, body=0.32, detune=0.0015,
                sub=0.28):
    """
    The KRIT voice. Sine fundamental + a sub-octave for weight + soft body
    partial + a quiet high shimmer, very lightly detuned for a crystalline,
    non-sterile feel. Shaped by the supplied envelope.

    Partials are EXACT integer multiples of the fundamental (octave, double
    octave). Earlier the shimmer was slightly inharmonic (4.01x) and the detune
    heavier, which beat against chord notes and read as grit — pure harmonics
    keep stacked chords clean. `sub` mixes in an octave-below sine for low-end
    body without changing the perceived pitch.
    """
    fund = sine(freq, seconds)
    fund2 = sine(freq * (1 + detune), seconds)        # very subtle chorus/detune
    low = sine(freq * 0.5, seconds)                   # sub-octave for weight
    partial = sine(freq * 2.0, seconds)               # octave body (exact)
    high = sine(freq * 4.0, seconds)                  # double-octave shimmer (exact)
    out = []
    for i in range(len(fund)):
        s = (0.60 * fund[i] + 0.17 * fund2[i] + sub * low[i]
             + body * partial[i] + shimmer * high[i])
        out.append(s)
    return apply_env(out, env)


# ---------------------------------------------------------------------------
# Noise (for the shutter transient) — deterministic LCG, no random import
# ---------------------------------------------------------------------------


def noise(seconds, seed=12345):
    total = n_samples(seconds)
    out = []
    state = seed & 0xFFFFFFFF
    for _ in range(total):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        out.append((state / 0x3FFFFFFF) - 1.0)  # ~[-1, 1]
    return out


def one_pole_lowpass(buf, cutoff_hz):
    """Simple one-pole LP to tame harsh noise into a soft transient."""
    dt = 1.0 / SAMPLE_RATE
    rc = 1.0 / (2 * math.pi * cutoff_hz)
    alpha = dt / (rc + dt)
    out = []
    prev = 0.0
    for s in buf:
        prev = prev + alpha * (s - prev)
        out.append(prev)
    return out


def one_pole_highpass(buf, cutoff_hz):
    dt = 1.0 / SAMPLE_RATE
    rc = 1.0 / (2 * math.pi * cutoff_hz)
    alpha = rc / (rc + dt)
    out = []
    prev_in = 0.0
    prev_out = 0.0
    for s in buf:
        cur = alpha * (prev_out + s - prev_in)
        out.append(cur)
        prev_in = s
        prev_out = cur
    return out


def _comb(buf, delay_sec, feedback, damp=0.2):
    """Feedback comb filter with a one-pole damping in the loop (Schroeder)."""
    d = max(1, n_samples(delay_sec))
    out = [0.0] * len(buf)
    store = 0.0
    line = [0.0] * d
    idx = 0
    for i, s in enumerate(buf):
        y = line[idx]
        out[i] = y
        store = y * (1 - damp) + store * damp  # damp the high end in the tail
        line[idx] = s + store * feedback
        idx = (idx + 1) % d
    return out


def _allpass(buf, delay_sec, feedback=0.5):
    d = max(1, n_samples(delay_sec))
    out = [0.0] * len(buf)
    line = [0.0] * d
    idx = 0
    for i, s in enumerate(buf):
        bufout = line[idx]
        y = -s + bufout
        line[idx] = s + bufout * feedback
        out[i] = y
        idx = (idx + 1) % d
    return out


def _reverb_wet(src, room, damp, combs, allpasses):
    """Wet (reverb-only) signal for a given set of comb/allpass delays."""
    wet_buf = [0.0] * len(src)
    for dt in combs:
        c = _comb(src, dt, room, damp)
        for i in range(len(src)):
            wet_buf[i] += c[i] / len(combs)
    for dt in allpasses:
        wet_buf = _allpass(wet_buf, dt, 0.5)
    return wet_buf


def reverb(buf, room=0.84, damp=0.28, wet=0.32, tail_sec=1.4):
    """
    Mono Schroeder reverb (parallel combs + serial allpasses). Adds a long,
    smooth tail — the "big room" sheen behind a chime. Pure stdlib.
    """
    src = list(buf) + [0.0] * n_samples(tail_sec)  # room for the tail to ring
    combs = [0.0297, 0.0371, 0.0411, 0.0437]       # mutually prime-ish delays
    wet_buf = _reverb_wet(src, room, damp, combs, (0.005, 0.0017))
    return [src[i] * (1 - wet) + wet_buf[i] * wet for i in range(len(src))]


def stereo_reverb(buf, room=0.86, damp=0.3, wet=0.34, tail_sec=1.2):
    """
    Stereo reverb for depth and width. Builds two decorrelated wet tails (left
    and right use slightly different comb/allpass delays), so the room "opens
    up" across the stereo field instead of sitting flat in the centre. The dry
    signal stays centred; the reverb is what spreads. Returns (left, right).
    """
    src = list(buf) + [0.0] * n_samples(tail_sec)
    # left and right use distinct delay sets => the tails are uncorrelated
    combs_l = [0.0297, 0.0371, 0.0411, 0.0437]
    combs_r = [0.0319, 0.0353, 0.0431, 0.0461]
    wet_l = _reverb_wet(src, room, damp, combs_l, (0.0050, 0.0017))
    wet_r = _reverb_wet(src, room, damp, combs_r, (0.0057, 0.0021))
    left = [src[i] * (1 - wet) + wet_l[i] * wet for i in range(len(src))]
    right = [src[i] * (1 - wet) + wet_r[i] * wet for i in range(len(src))]
    return left, right


def stereoize(buf, width=0.25, haas_sec=0.0, depth=0.0,
              room=0.86, damp=0.3, tail_sec=1.0):
    """
    Turn a mono buffer into a stereo pair with width and depth.

    - width: subtle mid/side spread via a tiny inter-channel level/phase offset.
    - haas_sec: a few-ms delay on the right channel (Haas effect) widens the
      image without changing tone — great for short cues.
    - depth: amount of decorrelated stereo reverb mixed in (0 = none). This is
      what gives a real sense of space behind the bigger sounds.

    Returns (left, right) of equal length.
    """
    if depth > 0:
        rl, rr = stereo_reverb(buf, room=room, damp=damp, wet=depth,
                               tail_sec=tail_sec)
        left, right = rl, rr
    else:
        left = list(buf)
        right = list(buf)

    # Haas: nudge the right channel a touch later for width (pad both to match).
    h = n_samples(haas_sec)
    if h > 0:
        right = [0.0] * h + right
        left = left + [0.0] * h

    n = max(len(left), len(right))
    left += [0.0] * (n - len(left))
    right += [0.0] * (n - len(right))

    # Light mid/side widening: push a little of the difference outward.
    if width > 0:
        for i in range(n):
            mid = 0.5 * (left[i] + right[i])
            side = 0.5 * (left[i] - right[i])
            side *= (1 + width)
            left[i] = mid + side
            right[i] = mid - side
    return left, right


# ---------------------------------------------------------------------------
# Pitch sweep helper (for swooshes / rec start-stop)
# ---------------------------------------------------------------------------


def sweep(f_start, f_end, seconds, glassy=True):
    """Phase-continuous pitch glide. Glassy adds the octave shimmer."""
    total = n_samples(seconds)
    out = [0.0] * total
    phase = 0.0
    phase2 = 0.0
    for i in range(total):
        x = i / total
        f = f_start * (f_end / f_start) ** x  # exponential glide = musical
        phase += 2 * math.pi * f / SAMPLE_RATE
        s = math.sin(phase)
        if glassy:
            phase2 += 2 * math.pi * (f * 2.0) / SAMPLE_RATE
            s = 0.78 * s + 0.22 * math.sin(phase2)
        out[i] = s
    return out


# ---------------------------------------------------------------------------
# Normalization + WAV writing
# ---------------------------------------------------------------------------


def normalize(buf, peak_dbfs=PEAK_DBFS):
    peak = max((abs(s) for s in buf), default=0.0)
    if peak == 0.0:
        return buf
    target = 10 ** (peak_dbfs / 20.0)
    g = target / peak
    return [s * g for s in buf]


def soft_clip(buf, drive_db=DRIVE_DB):
    """
    Tanh saturator. Drives the signal harder, then shapes the peaks with a
    smooth curve so they fold instead of clipping. This both raises perceived
    loudness (higher RMS) and adds warm harmonics for body — the difference
    between a thin sine and a full, "produced" sound. tanh is normalized so the
    output still sits in [-1, 1].
    """
    drive = 10 ** (drive_db / 20.0)
    norm = math.tanh(drive)  # so a full-scale input maps back to ~1.0
    return [math.tanh(s * drive) / norm for s in buf]


def limiter(buf, ceiling_dbfs=LIMIT_DBFS, lookahead_sec=0.0015, release_sec=0.05):
    """
    Simple look-ahead peak limiter. Catches transients that exceed the ceiling
    and rides the gain down smoothly (with release) so nothing clips while
    average level stays high. Keeps the loud master clean.
    """
    ceil = 10 ** (ceiling_dbfs / 20.0)
    la = max(1, n_samples(lookahead_sec))
    rel = max(1, n_samples(release_sec))
    rel_coef = math.exp(-1.0 / rel)
    # delay the signal by the look-ahead so we can react before the peak hits
    delayed = [0.0] * la + list(buf)
    gain = 1.0
    out = [0.0] * len(delayed)
    n = len(delayed)
    for i in range(n):
        # peak within the look-ahead window ahead of the current sample
        win_end = min(n, i + la + 1)
        local_peak = 0.0
        for j in range(i, win_end):
            a = abs(delayed[j])
            if a > local_peak:
                local_peak = a
        target_gain = 1.0 if local_peak <= ceil else ceil / local_peak
        # attack instantly (clamp), release slowly
        if target_gain < gain:
            gain = target_gain
        else:
            gain = target_gain + (gain - target_gain) * rel_coef
        out[i] = delayed[i] * gain
    return out


def low_shelf(buf, corner_hz=LOW_SHELF_HZ, gain_db=LOW_SHELF_DB):
    """
    Low-shelf EQ. Splits off the low band (one-pole low-pass) and mixes it back
    at a different gain, so frequencies below the corner are attenuated (or
    boosted) while the rest passes through. Used to tame the bass so the grave
    sits under the music instead of booming over it."""
    g = 10 ** (gain_db / 20.0)
    low = one_pole_lowpass(buf, corner_hz)
    # output = (signal - low) + low*g  =>  highs untouched, lows scaled by g
    return [(buf[i] - low[i]) + low[i] * g for i in range(len(buf))]


def compress(left, right, thresh_db=COMP_THRESH_DB, ratio=COMP_RATIO,
             attack_sec=0.008, release_sec=0.12, makeup_db=None):
    """
    Stereo-linked compressor. Smooths the dynamics so loud peaks (the bass hits)
    don't dominate — this is what gives a controlled, "produced", high-quality
    feel instead of a raw signal that slams the limiter. The detector is the max
    of |L|,|R| so the stereo image stays stable (no wobble). Soft-knee.

    This is the missing piece: with the sub under control, the grave stops
    distorting at the output stage.
    """
    thresh = 10 ** (thresh_db / 20.0)
    atk = math.exp(-1.0 / max(1, n_samples(attack_sec)))
    rel = math.exp(-1.0 / max(1, n_samples(release_sec)))
    knee = 6.0  # dB soft knee
    env = 0.0   # smoothed detector level (linear)
    gl = [0.0] * len(left)
    gr = [0.0] * len(right)
    n = min(len(left), len(right))
    # auto makeup: roughly restore the level the compressor took off
    if makeup_db is None:
        makeup_db = (1 - 1 / ratio) * (-thresh_db) * 0.5
    makeup = 10 ** (makeup_db / 20.0)
    for i in range(n):
        detect = max(abs(left[i]), abs(right[i]))
        # envelope follower (peak detector with attack/release)
        coef = atk if detect > env else rel
        env = coef * env + (1 - coef) * detect
        # gain computer with soft knee, in dB
        if env <= 1e-9:
            gain = 1.0
        else:
            lvl_db = 20 * math.log10(env)
            over = lvl_db - thresh_db
            if over <= -knee / 2:
                gr_db = 0.0
            elif over >= knee / 2:
                gr_db = over * (1 / ratio - 1)
            else:  # soft knee region
                x = over + knee / 2
                gr_db = (1 / ratio - 1) * (x * x) / (2 * knee)
            gain = 10 ** (gr_db / 20.0)
        gl[i] = left[i] * gain * makeup
        gr[i] = right[i] * gain * makeup
    return gl, gr


def master_stereo(left, right, drive_db=DRIVE_DB, ceiling_dbfs=PEAK_DBFS,
                  hpf_hz=HPF_HZ):
    """
    Full stereo mastering chain — the part that makes it sound clean and
    professional (NOT the bit depth):
      1. high-pass: clear inaudible sub-bass that only wastes headroom & muddies
      2. low-shelf: tame the low band so the grave stops booming/distorting
      3. compressor: control the dynamics (tames the bass peaks that distorted)
      4. gentle drive: a touch of harmonic warmth (not the loudness source)
      5. look-ahead limiter: catch the last transients cleanly
      6. normalize both channels by one shared gain (keeps stereo balance)
    """
    # 1. high-pass both channels
    left = one_pole_highpass(left, hpf_hz)
    right = one_pole_highpass(right, hpf_hz)
    # 2. low-shelf to balance the bass
    left = low_shelf(left)
    right = low_shelf(right)
    # 3. stereo-linked compression
    left, right = compress(left, right)
    # 4. NO bus saturation. The soft-clip drive generated inter-modulation
    #    products between the chord's partials — that grit was the distortion source.
    #    Loudness comes from the compressor + limiter, cleanly. (drive_db kept
    #    in the signature for compatibility but intentionally unused here.)
    _ = drive_db
    # 5. limit
    left = limiter(left, ceiling_dbfs)
    right = limiter(right, ceiling_dbfs)
    # 6. shared normalization
    peak = max(max((abs(s) for s in left), default=0.0),
               max((abs(s) for s in right), default=0.0))
    if peak > 0:
        g = 10 ** (ceiling_dbfs / 20.0) / peak
        left = [s * g for s in left]
        right = [s * g for s in right]
    return left, right


def _encode_sample(s, sampwidth):
    v = int(round(max(-1.0, min(1.0, s)) * MAX_AMP))
    v = max(-MAX_AMP - 1, min(MAX_AMP, v))  # clamp to the signed range
    if sampwidth == 2:
        return struct.pack("<h", v)
    if sampwidth == 3:
        # struct has no int24 — write 3 little-endian bytes by hand,
        # masking to 24 bits so negatives wrap as two's complement.
        b = v & 0xFFFFFF
        return bytes((b & 0xFF, (b >> 8) & 0xFF, (b >> 16) & 0xFF))
    raise ValueError(f"unsupported BIT_DEPTH={BIT_DEPTH}")


def write_wav(path, channels, drive_db=DRIVE_DB, ceiling_dbfs=PEAK_DBFS):
    """
    Write a WAV. `channels` is either a mono buffer (list of floats) or a
    (left, right) tuple. Mono input is duplicated to both channels when the
    pack is in stereo mode. Mastering (drive + limit + normalize) runs before
    encoding for a loud, full, professional level.
    """
    if isinstance(channels, tuple):
        left, right = channels
    else:
        left = right = list(channels)

    # Fade first so the edge fade can't clip the peak sample on short sounds.
    left = fade_edges(left)
    right = fade_edges(right) if right is not left else left

    if NUM_CHANNELS == 2:
        left, right = master_stereo(left, right, drive_db, ceiling_dbfs)
        nch = 2
    else:
        # mono: master a single channel (downmix if a stereo pair was given)
        mono = [0.5 * (left[i] + right[i]) for i in range(min(len(left), len(right)))]
        left = limiter(soft_clip(mono, drive_db), ceiling_dbfs)
        left = normalize(left, ceiling_dbfs)
        nch = 1

    sampwidth = BIT_DEPTH // 8
    frames = bytearray()
    if nch == 2:
        n = max(len(left), len(right))
        left += [0.0] * (n - len(left))
        right += [0.0] * (n - len(right))
        for i in range(n):
            frames += _encode_sample(left[i], sampwidth)
            frames += _encode_sample(right[i], sampwidth)
    else:
        for s in left:
            frames += _encode_sample(s, sampwidth)

    with wave.open(path, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(sampwidth)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(frames))


# ---------------------------------------------------------------------------
# The sounds
# ---------------------------------------------------------------------------


def make_launch():
    """
    LAUNCH / OPEN — the startup theme. Long, soft and ceremonious, built as a
    little three-part phrase: two rising "questions" that hang unresolved, then
    a full "answer" — the home chord — that resolves and rings out. Swells in
    gently (no hard hit, no jump scare). ~4.8 s + reverb tail.

    100% original: voicing, timbre (KRIT's glassy voice) and reverb are all
    synthesized here — no Apple sample or its actual chord is used.

    Harmony (A major, voiced low and warm):
      Q1 — rises and rests on the fifth (E): "...?"   (unresolved)
      Q2 — rises higher and rests on the sixth (F#): "...?"  (more tension)
      A  — the A-major home chord blooms and resolves: "."   (rest)
    A deep sub pedal holds underneath the whole arc for body. Stereo depth is
    added by the per-sound profile in main().
    """
    dur = 5.4
    buf = silence(dur)

    # --- Pitches (A major, voiced low) ---
    A2 = A3 / 2                    # ~110, sub root
    E3 = NOTES["E4"] / 2          # ~164.8, the fifth
    A3n = A3                      # 220
    Cs4 = A3 * 2 ** (4 / 12)      # ~277.2, the major third — the warm colour
    E4 = NOTES["E4"]              # ~329.6
    Fs4 = A3 * 2 ** (9 / 12)      # ~370.0, the sixth — the "open question" tone
    A4 = NOTES["A4"]              # 440

    def phrase(notes, t0, note_len, gain, soft=True):
        """A small rising gesture: a few glassy notes blooming in sequence.
        Long, soft attacks and releases so notes fade in/out smoothly — no
        sudden amplitude jumps (those vertical spikes were the clipping source).
        sub=0.0: the notes carry NO sub-octave — only the single pedal below
        provides bass, so low frequencies never stack and overload."""
        for k, (freq, off, g, body, shim) in enumerate(notes):
            atk = 0.28 if soft else 0.12
            e = adsr(note_len, atk, note_len * 0.3, 0.45, note_len * 0.5, curve=1.3)
            n = glassy_tone(freq, note_len, e, shimmer=shim, body=body, sub=0.0)
            mix(buf, n, t0 + off, gain=g * gain)

    # --- Sub pedal: ONE deep voice for body. Kept low in level and rolled off
    #     below ~90 Hz so it grounds the chord without booming. This is the only
    #     source of bass in the launch — nothing else reaches down here, so the
    #     low end stays clean instead of piling up and distorting.
    sub_len = 5.0
    sub = sine(A2, sub_len)
    sub = apply_env(sub, adsr(sub_len, 0.5, 0.7, 0.6, 1.4, curve=1.3))
    sub = one_pole_highpass(sub, 95)  # trim the very bottom so it doesn't boom
    mix(buf, sub, 0.0, gain=0.16)

    # --- Q1 (0.0 s): rises A3 -> C#4 and rests on the fifth E4. Hangs open.
    #     Wider note spacing (0.4 s) so notes overlap less and don't sum spikes.
    phrase([
        (A3n, 0.00, 0.40, 0.34, 0.07),
        (Cs4, 0.40, 0.38, 0.32, 0.08),
        (E4,  0.80, 0.44, 0.32, 0.09),   # rests on the fifth = unresolved "?"
    ], t0=0.2, note_len=1.05, gain=0.8)

    # --- Q2 (1.7 s): rises higher, C#4 -> E4 and rests on the sixth F#4. More
    #     tension, "still waiting".
    phrase([
        (Cs4, 0.00, 0.38, 0.32, 0.08),
        (E4,  0.40, 0.40, 0.32, 0.09),
        (Fs4, 0.80, 0.44, 0.30, 0.10),   # rests on the sixth = bigger "?"
    ], t0=1.9, note_len=1.05, gain=0.8)

    # --- A (3.4 s): the answer. The A-major home chord resolves — root, third,
    #     fifth, octave — voiced full and warm. It BLOOMS IN with a long, soft
    #     attack (0.35 s) and staggered entries so there is no sudden hit; the
    #     hard transient here was the worst spike before.
    answer = [
        (E3,  0.00, 0.30, 0.36, 0.06),
        (A3n, 0.06, 0.38, 0.34, 0.08),
        (Cs4, 0.12, 0.36, 0.32, 0.09),   # the major third = the resolving colour
        (E4,  0.18, 0.32, 0.32, 0.09),
        (A4,  0.26, 0.22, 0.30, 0.10),   # soft top octave
    ]
    ans_len = 1.7
    for freq, start, gain, body, shimmer in answer:
        # long soft attack => the chord swells up, no hard transient
        e = adsr(ans_len, 0.35, 0.5, 0.55, 0.75, curve=1.25)
        # sub=0.0: no sub-octave on the chord voices — the pedal is the only bass
        n = glassy_tone(freq, ans_len, e, shimmer=shimmer, body=body, sub=0.0)
        mix(buf, n, 3.4 + start, gain=gain)

    # --- Round off the top so there are no harsh highs; keep it warm.
    buf = one_pole_lowpass(buf, 3400)

    # --- Extra soft fade-in over the first 150 ms so the start can never jump.
    fi = n_samples(0.15)
    for i in range(min(fi, len(buf))):
        buf[i] *= (i / fi) ** 1.3

    return buf


def make_capture():
    """
    THE SHUTTER — the signature. Dry transient click + a descending
    micro-swoosh body, now heavier and more definitive. Percussive, satisfying,
    with a longer low thock and swoosh tail for weight. ~240 ms.
    """
    dur = 0.24
    buf = silence(dur)

    # 1. Transient click: filtered noise burst, very short, gives the "snap".
    click_len = 0.022
    click = noise(click_len, seed=7)
    click = one_pole_highpass(click, 1400)
    click = one_pole_lowpass(click, 7000)
    click = apply_env(click, perc_env(click_len, 0.0007, curve=8.0))
    mix(buf, click, 0.0, gain=0.9)

    # 2. Body thock: low-mid tone for weight. Longer + lower landing makes the
    #    shutter feel heavier and more deliberate.
    body_len = 0.13
    body = sweep(340, 120, body_len, glassy=False)
    body = apply_env(body, perc_env(body_len, 0.0016, curve=4.5))
    mix(buf, body, 0.004, gain=0.9)

    # 3. Descending micro-swoosh: filtered noise gliding down for the "whip".
    #    Longer tail with a darker close for a more cinematic settle.
    sw_len = 0.2
    sw = noise(sw_len, seed=99)
    sw = one_pole_lowpass(sw, 5200)
    sw = one_pole_highpass(sw, 600)
    sw_env = perc_env(sw_len, 0.006, curve=3.4)
    sw = apply_env(sw, sw_env)
    # progressively darken the swoosh tail for the downward sense
    sw = one_pole_lowpass(sw, 2800)
    mix(buf, sw, 0.014, gain=0.52)

    return buf


def make_copy():
    """COPY — positive tick. Soft bell-like note, Apple-clean and warm rather
    than bright: dropped from E5 to E4 with a rounded top and a touch of tail.
    ~110 ms."""
    dur = 0.11
    env = perc_env(dur, 0.0024, curve=4.6)
    tone = glassy_tone(NOTES["E4"], dur, env, shimmer=0.07, body=0.30, sub=0.14)
    tone = one_pole_lowpass(tone, 4200)  # round off the edge — soft, premium
    return tone


def make_save():
    """SAVE — completion chime, a clean rising perfect fifth (A3 -> E4). Apple-
    style consonant interval, voiced low for warmth, soft bell timbre with a
    little room tail so it feels finished and premium. ~450 ms."""
    dur = 0.45
    buf = silence(dur)
    n1_len = 0.30
    n2_len = 0.40
    e1 = adsr(n1_len, 0.008, 0.11, 0.45, 0.20, curve=1.9)
    e2 = adsr(n2_len, 0.008, 0.13, 0.40, 0.26, curve=1.9)
    # sub kept low: A3 already has body; an octave-below would boom at ~110 Hz.
    n1 = glassy_tone(NOTES["A3"], n1_len, e1, shimmer=0.08, body=0.34, sub=0.10)
    n2 = glassy_tone(NOTES["E4"], n2_len, e2, shimmer=0.09, body=0.32, sub=0.12)
    mix(buf, n1, 0.0, gain=0.9)
    mix(buf, n2, 0.13, gain=0.95)
    buf = one_pole_lowpass(buf, 3800)  # warm, no harsh highs
    # short tail for a polished, settled finish
    buf = reverb(buf, room=0.7, damp=0.4, wet=0.16, tail_sec=0.25)
    return buf


def make_record_start():
    """REC START — rising tone (C4 -> G4 glide + landing). Slower glide and a
    longer landing shimmer for a more deliberate "now recording". ~420 ms
    (extra room so the landing's release decays fully instead of being cut)."""
    dur = 0.42
    buf = silence(dur)
    glide_len = 0.22
    gl = sweep(NOTES["C4"], NOTES["G4"], glide_len, glassy=True)
    gl = apply_env(gl, adsr(glide_len, 0.012, 0.08, 0.6, 0.10, curve=1.9))
    mix(buf, gl, 0.0, gain=0.85)
    # soft bell landing on the top note (the fifth) — warm, restrained shimmer
    land_len = 0.18
    land = glassy_tone(NOTES["G4"], land_len, perc_env(land_len, 0.005, 3.0),
                       shimmer=0.10, body=0.28, sub=0.14)
    mix(buf, land, 0.13, gain=0.45)
    buf = one_pole_lowpass(buf, 4000)  # Apple-soft, no edge
    return buf


def make_record_stop():
    """REC STOP — descending tone (G4 -> C4). Mirror of start, slower. ~440 ms
    (extra room so the landing's release decays fully instead of being cut)."""
    dur = 0.44
    buf = silence(dur)
    glide_len = 0.22
    gl = sweep(NOTES["G4"], NOTES["C4"], glide_len, glassy=True)
    gl = apply_env(gl, adsr(glide_len, 0.012, 0.09, 0.55, 0.11, curve=2.0))
    mix(buf, gl, 0.0, gain=0.85)
    land_len = 0.2
    land = glassy_tone(NOTES["C4"], land_len, perc_env(land_len, 0.005, 3.0),
                       shimmer=0.06, body=0.34, sub=0.12)
    mix(buf, land, 0.12, gain=0.5)
    buf = one_pole_lowpass(buf, 4000)  # Apple-soft, no edge
    return buf


def make_error():
    """
    ERROR — subtle negative cue. Low, soft, two close low notes falling a
    semitone-ish (A3 -> G#3). Not harsh, no buzz. Longer, more drawn-out tails
    so it lands gently. ~520 ms (extra room so the second note's release decays
    fully instead of being cut off).
    """
    dur = 0.52
    buf = silence(dur)
    gsharp3 = A3 * 2 ** (-1 / 12)  # ~207.65
    n1_len = 0.22
    n2_len = 0.28
    e1 = adsr(n1_len, 0.012, 0.09, 0.5, 0.16, curve=1.8)
    e2 = adsr(n2_len, 0.012, 0.11, 0.45, 0.20, curve=1.8)
    # low + soft: minimal shimmer, more body, gentle. sub kept low — these
    # notes are already in the low register, so an octave-below would boom.
    n1 = glassy_tone(A3, n1_len, e1, shimmer=0.04, body=0.42, sub=0.08)
    n2 = glassy_tone(gsharp3, n2_len, e2, shimmer=0.04, body=0.44, sub=0.08)
    mix(buf, n1, 0.0, gain=0.85)
    mix(buf, n2, 0.1, gain=0.9)
    # soften the whole thing
    buf = one_pole_lowpass(buf, 2600)
    return buf


def make_pin():
    """PIN — soft, rounded tick. Mid note, gentle attack, a touch more tail.
    ~150 ms."""
    dur = 0.15
    env = perc_env(dur, 0.006, curve=3.6)
    tone = glassy_tone(NOTES["D4"], dur, env, shimmer=0.06, body=0.36, sub=0.12)
    tone = one_pole_lowpass(tone, 3400)  # rounded, no edge
    return tone


def make_toggle():
    """TOGGLE — neutral light click. Single short mid note, slightly rounder.
    ~90 ms."""
    dur = 0.09
    env = perc_env(dur, 0.003, curve=5.5)
    tone = glassy_tone(NOTES["A4"], dur, env, shimmer=0.08, body=0.24, sub=0.16)
    tone = one_pole_lowpass(tone, 4200)
    return tone


SOUNDS = {
    "launch": make_launch,
    "capture": make_capture,
    "copy": make_copy,
    "save": make_save,
    "record-start": make_record_start,
    "record-stop": make_record_stop,
    "error": make_error,
    "pin": make_pin,
    "toggle": make_toggle,
}

# Per-sound mastering overrides (drive_db, ceiling_dbfs). Dense/polyphonic or
# transient material gets a gentler drive so the saturator stays clean — the
# launch chord and the capture click distort if pushed like a mono UI tone.
MASTER_OVERRIDES = {
    "launch":  (2.0, -2.0),   # full chord + reverb: barely drive it, give headroom
    "capture": (3.0, -1.0),   # sharp transient: light drive keeps the click clean
    "save":    (4.0, -1.5),   # two-note chime with tail: a little gentler
}

# Per-sound stereo profile: (width, haas_sec, depth, tail_sec). `depth` mixes
# in a decorrelated stereo reverb for a real sense of space; `haas`/`width`
# spread shorter cues without a tail. capture stays nearly mono — it is the
# native shutter and wants to feel focused/dry.
# NOTE: avoid Haas delay on very short cues — a few-ms offset on a sub-200 ms
# sound pushes L/R out of phase and collapses/cancels in mono. Short cues use
# width only (mid/side), longer ones use a little reverb depth for space.
STEREO_PROFILES = {
    "launch":       (0.40, 0.0,    0.34, 1.2),   # big, deep, wide room
    "save":         (0.26, 0.0,    0.16, 0.35),  # gentle space behind the chime
    "record-start": (0.24, 0.0,    0.06, 0.10),  # subtle width + tiny room
    "record-stop":  (0.24, 0.0,    0.06, 0.10),
    "error":        (0.20, 0.0,    0.10, 0.20),  # a touch of room
    "pin":          (0.18, 0.0,    0.0,  0.0),   # width only
    "copy":         (0.16, 0.0,    0.0,  0.0),
    "toggle":       (0.14, 0.0,    0.0,  0.0),
    "capture":      (0.10, 0.0,    0.0,  0.0),   # near-mono, dry, focused
}
DEFAULT_STEREO = (0.18, 0.0, 0.0, 0.0)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    mode = "stereo" if NUM_CHANNELS == 2 else "mono"
    print(f"KRIT UI Sound Pack -> {OUT_DIR}  ({BIT_DEPTH}-bit / {SAMPLE_RATE} Hz / {mode})\n")
    for name, fn in SOUNDS.items():
        buf = fn()
        path = os.path.join(OUT_DIR, f"{name}.wav")
        drive, ceiling = MASTER_OVERRIDES.get(name, (DRIVE_DB, PEAK_DBFS))
        if NUM_CHANNELS == 2:
            width, haas, depth, tail = STEREO_PROFILES.get(name, DEFAULT_STEREO)
            channels = stereoize(buf, width=width, haas_sec=haas, depth=depth,
                                 tail_sec=tail)
        else:
            channels = buf
        write_wav(path, channels, drive_db=drive, ceiling_dbfs=ceiling)
        # report duration from the actual written channel length
        n = len(channels[0]) if isinstance(channels, tuple) else len(channels)
        print(f"  {name:<14} {n / SAMPLE_RATE * 1000:6.1f} ms  -> {os.path.basename(path)}")
    print("\nDone. Convert to .caf with afconvert (see README.md).")


if __name__ == "__main__":
    main()
