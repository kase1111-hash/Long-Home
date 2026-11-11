"""Signal-processing building blocks for the Long Home sound effects.

Everything here is plain numpy, written for offline rendering:

- Filters work on whole buffers in the frequency domain. A filter applied this
  way is circular, so a loop that is built from circular noise and circular
  modulators stays seamless without a crossfade.
- Material sounds (metal, rock, ice, wood) are sums of decaying partials struck
  by a short noise burst ("modal" synthesis).
- Textures (snow crunch, scree, crackle) are clouds of very short grains.

The sound designs themselves live in the ``sounds_*`` modules.
"""

from __future__ import annotations

import functools
import inspect
import zlib
from typing import Callable, Iterable, Sequence

import numpy as np

SR = 44100
TAU = 2.0 * np.pi

Array = np.ndarray
Response = Callable[[Array], Array]


# =============================================================================
# RANDOMNESS
# =============================================================================

def rng_for(name: str, variant: int = 0) -> np.random.Generator:
    """A generator seeded from the sound's name, so renders are repeatable."""
    seed = zlib.crc32(name.encode("utf-8")) + 7919 * variant
    return np.random.default_rng(seed)


class At:
    """This module's functions with the sample rate filled in.

        d = dsp.At(22050)
        n = d.samples(6.0)
        x = d.noise(n, rng, d.lp(900))

    Low, dull sounds (wind bodies, rumbles) are rendered at a lower rate to
    keep the files small; this keeps their code free of ``sr=`` arguments.
    """

    def __init__(self, sr: int = SR) -> None:
        self.sr = sr

    def __getattr__(self, name: str):
        try:
            func = globals()[name]
        except KeyError:
            raise AttributeError("dsp has no function '%s'" % name) from None
        if callable(func) and "sr" in inspect.signature(func).parameters:
            func = functools.partial(func, sr=self.sr)
        setattr(self, name, func)
        return func


def samples(seconds: float, sr: int = SR) -> int:
    return max(1, int(round(seconds * sr)))


def time_axis(n: int, sr: int = SR) -> Array:
    return np.arange(n, dtype=np.float64) / sr


# =============================================================================
# MAGNITUDE RESPONSES (functions of frequency, combined by multiplying)
# =============================================================================

def lp(fc: float, order: float = 2.0) -> Response:
    """Butterworth-shaped low-pass magnitude."""
    return lambda f: 1.0 / np.sqrt(1.0 + (f / fc) ** (2.0 * order))


def hp(fc: float, order: float = 2.0) -> Response:
    """Butterworth-shaped high-pass magnitude."""
    return lambda f: 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-6)) ** (2.0 * order))


def bp(lo: float, hi: float, order: float = 2.0) -> Response:
    low_cut, high_cut = hp(lo, order), lp(hi, order)
    return lambda f: low_cut(f) * high_cut(f)


def tilt(db_per_octave: float, ref: float = 1000.0) -> Response:
    """Spectral slope: -3 is pink, -6 is brown (relative to white)."""
    exponent = db_per_octave / 6.0206
    return lambda f: (np.maximum(f, 10.0) / ref) ** exponent


def peak(f0: float, q: float, gain_db: float) -> Response:
    """A resonant bump (or dip) of gain_db at f0; unity far away from it."""
    gain = 10.0 ** (gain_db / 20.0) - 1.0

    def response(f: Array) -> Array:
        ratio = np.maximum(f, 1e-6) / f0
        resonance = 1.0 / np.sqrt(1.0 + (q * (ratio - 1.0 / ratio)) ** 2)
        return 1.0 + gain * resonance

    return response


def resonator(f0: float, q: float) -> Response:
    """A band-pass resonance with unity gain at f0."""
    def response(f: Array) -> Array:
        ratio = np.maximum(f, 1e-6) / f0
        return 1.0 / np.sqrt(1.0 + (q * (ratio - 1.0 / ratio)) ** 2)

    return response


def chain(*responses: Response) -> Response:
    def response(f: Array) -> Array:
        out = np.ones_like(f)
        for r in responses:
            out = out * r(f)
        return out

    return response


def mix_responses(pairs: Sequence[tuple[float, Response]]) -> Response:
    """Weighted sum of responses (parallel filters)."""
    def response(f: Array) -> Array:
        out = np.zeros_like(f)
        for weight, r in pairs:
            out = out + weight * r(f)
        return out

    return response


# =============================================================================
# FILTERING
# =============================================================================

def _minimum_phase(magnitude_full: Array) -> Array:
    """Complex minimum-phase spectrum with the given full-length magnitude."""
    n = len(magnitude_full)
    log_mag = np.log(np.maximum(magnitude_full, 1e-7))
    cepstrum = np.fft.ifft(log_mag).real
    fold = np.zeros(n)
    fold[0] = 1.0
    fold[1:(n + 1) // 2] = 2.0
    if n % 2 == 0:
        fold[n // 2] = 1.0
    return np.exp(np.fft.fft(cepstrum * fold))


def filt(x: Array, response: Response, sr: int = SR, causal: bool = False) -> Array:
    """Apply a magnitude response to x.

    The default is zero-phase and circular: right for noise and for loops.
    causal=True uses the minimum-phase filter instead, so a transient gets no
    ringing ahead of it; the buffer is zero-padded so the tail does not wrap.
    """
    n = len(x)
    if not causal:
        spectrum = np.fft.rfft(x)
        gains = response(np.fft.rfftfreq(n, 1.0 / sr))
        return np.fft.irfft(spectrum * gains, n)

    size = 1
    while size < n * 2:
        size *= 2
    freqs = np.abs(np.fft.fftfreq(size, 1.0 / sr))
    h = _minimum_phase(response(freqs))
    padded = np.zeros(size)
    padded[:n] = x
    return np.fft.ifft(np.fft.fft(padded) * h).real[:n]


def filt_tv(x: Array, response_at: Callable[[float], Response], sr: int = SR,
            window: int = 1024) -> Array:
    """Time-varying filter: response_at(t_seconds) gives the response then.

    Short-time Fourier processing with a 75% overlap; smooth sweeps only (the
    response is sampled once per hop, about every 6 ms at the default window).
    """
    hop = window // 4
    n = len(x)
    pad = window
    padded = np.concatenate([np.zeros(pad), x, np.zeros(pad + hop)])
    win = np.hanning(window + 1)[:-1]
    out = np.zeros(len(padded))
    norm = np.zeros(len(padded))
    freqs = np.fft.rfftfreq(window, 1.0 / sr)
    for start in range(0, len(padded) - window, hop):
        centre = (start + window * 0.5 - pad) / sr
        gains = response_at(min(max(centre, 0.0), n / sr))(freqs)
        frame = np.fft.irfft(np.fft.rfft(padded[start:start + window] * win) * gains, window)
        out[start:start + window] += frame * win
        norm[start:start + window] += win * win
    out /= np.maximum(norm, 1e-9)
    return out[pad:pad + n]


def convolve(x: Array, kernel: Array, keep: int | None = None) -> Array:
    """FFT convolution, truncated to keep samples (default: len(x))."""
    keep = len(x) if keep is None else keep
    size = 1
    while size < len(x) + len(kernel) - 1:
        size *= 2
    out = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(kernel, size), size)
    if keep <= size:
        return out[:keep]
    return np.concatenate([out, np.zeros(keep - size)])


def smooth(x: Array, seconds: float, sr: int = SR) -> Array:
    """Gaussian smoothing (circular) with the given time constant."""
    if seconds <= 0.0:
        return x
    cutoff = 0.25 / seconds
    return filt(x, lambda f: np.exp(-0.5 * (f / cutoff) ** 2), sr)


# =============================================================================
# NOISE
# =============================================================================

def noise(n: int, rng: np.random.Generator, response: Response | None = None, sr: int = SR) -> Array:
    """Gaussian noise, optionally shaped; unit RMS. Circular (loops seamlessly)."""
    x = rng.standard_normal(n)
    if response is not None:
        x = filt(x, response, sr)
    return x / (np.sqrt(np.mean(x * x)) + 1e-12)


def wander(n: int, rng: np.random.Generator, rate_hz: float, sr: int = SR) -> Array:
    """A slow random control signal: zero mean, unit RMS, circular.

    rate_hz is roughly how many swings per second it makes.
    """
    x = rng.standard_normal(n)
    x = filt(x, lambda f: np.exp(-0.5 * (f / max(rate_hz, 1e-3)) ** 2), sr)
    x -= np.mean(x)
    return x / (np.sqrt(np.mean(x * x)) + 1e-12)


def wander01(n: int, rng: np.random.Generator, rate_hz: float, sr: int = SR) -> Array:
    """wander() squashed into 0..1 (about half the time above 0.5)."""
    return 0.5 + 0.5 * np.tanh(wander(n, rng, rate_hz, sr) * 0.9)


def narrowband(n: int, rng: np.random.Generator, centre_hz: float | Array, bandwidth_hz: float,
               sr: int = SR, circular: bool = False) -> Array:
    """Noise in a narrow band around a centre that may glide (an array).

    Low-passed complex noise moved up to the centre frequency: this is how a
    whistle, a howl or a creak gets a pitch without sounding like a sine wave.
    """
    z = rng.standard_normal(n) + 1j * rng.standard_normal(n)
    f = np.fft.fftfreq(n, 1.0 / sr)
    z = np.fft.ifft(np.fft.fft(z) * np.exp(-0.5 * (f / (bandwidth_hz * 0.5)) ** 2))
    centre = np.broadcast_to(np.asarray(centre_hz, dtype=np.float64), (n,))
    phase = TAU * np.cumsum(centre) / sr
    if circular:
        total = phase[-1]
        phase = phase + (np.round(total / TAU) * TAU - total) * (np.arange(1, n + 1) / n)
    out = (z * np.exp(1j * phase)).real
    return out / (np.sqrt(np.mean(out * out)) + 1e-12)


# =============================================================================
# ENVELOPES
# =============================================================================

def env_points(n: int, points: Iterable[tuple[float, float]], sr: int = SR, curve: float = 1.0) -> Array:
    """Piecewise envelope through (seconds, level) points; curve > 1 bows it."""
    pts = sorted(points)
    times = np.array([p[0] for p in pts]) * sr
    levels = np.array([p[1] for p in pts], dtype=np.float64)
    out = np.interp(np.arange(n), times, levels)
    if curve != 1.0:
        out = np.sign(out) * np.abs(out) ** curve
    return out


def env_ar(n: int, attack: float, release: float, sr: int = SR, hold: float = 0.0) -> Array:
    """Attack (raised cosine), optional hold, then exponential release.

    release is the time for the level to fall by 60 dB.
    """
    t = time_axis(n, sr)
    out = np.ones(n)
    if attack > 0.0:
        rising = t < attack
        out[rising] = 0.5 - 0.5 * np.cos(np.pi * t[rising] / attack)
    start = attack + hold
    falling = t >= start
    out[falling] = np.exp(-6.908 * (t[falling] - start) / max(release, 1e-4))
    return out


def env_decay(n: int, t60: float, sr: int = SR) -> Array:
    """Exponential decay reaching -60 dB after t60 seconds."""
    return np.exp(-6.908 * time_axis(n, sr) / max(t60, 1e-4))


def env_swell(n: int, peak_at: float, sr: int = SR, sharpness: float = 2.0) -> Array:
    """A single rise and fall with its maximum at peak_at seconds."""
    t = time_axis(n, sr)
    duration = n / sr
    rise = np.clip(t / max(peak_at, 1e-4), 0.0, 1.0)
    fall = np.clip((duration - t) / max(duration - peak_at, 1e-4), 0.0, 1.0)
    return (np.sin(0.5 * np.pi * rise) ** sharpness) * (np.sin(0.5 * np.pi * fall) ** sharpness)


def fade(x: Array, fade_in: float = 0.002, fade_out: float = 0.01, sr: int = SR) -> Array:
    """Short raised-cosine fades so a one-shot never starts or ends on a click."""
    out = x.copy()
    n = len(out)
    a = min(samples(fade_in, sr), n // 2)
    b = min(samples(fade_out, sr), n // 2)
    if a > 1:
        out[:a] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / a)
    if b > 1:
        out[-b:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(b) / b)
    return out


# =============================================================================
# TONAL AND STRUCK SOUNDS
# =============================================================================

def modal(n: int, partials: Iterable[tuple[float, float, float]], sr: int = SR,
          attack: float = 0.0004) -> Array:
    """Sum of decaying sine partials: (frequency Hz, amplitude, t60 seconds)."""
    t = time_axis(n, sr)
    out = np.zeros(n)
    for freq, amp, t60 in partials:
        if freq >= sr * 0.48:
            continue
        out += amp * np.exp(-6.908 * t / max(t60, 1e-4)) * np.sin(TAU * freq * t)
    if attack > 0.0:
        a = min(samples(attack, sr), n)
        out[:a] *= np.arange(a) / a
    return out


def struck(n: int, rng: np.random.Generator, partials: Sequence[tuple[float, float, float]],
           click: float = 0.3, click_band: tuple[float, float] = (1500.0, 9000.0),
           click_t60: float = 0.006, spread: float = 0.02, sr: int = SR) -> Array:
    """An object hit once: its partials ring, with a short noise burst on top.

    spread detunes and re-weights the partials a little, so no two hits of the
    same object are identical.
    """
    varied = [(f * (1.0 + spread * rng.standard_normal()),
               a * (1.0 + 4.0 * spread * rng.standard_normal()),
               d * (1.0 + 3.0 * spread * rng.standard_normal()))
              for f, a, d in partials]
    out = modal(n, varied, sr)
    if click > 0.0:
        burst = noise(n, rng, bp(*click_band), sr) * env_decay(n, click_t60, sr)
        out += click * burst
    return out


def thump(n: int, f_start: float, f_end: float, t60: float, sr: int = SR, drop: float = 0.03) -> Array:
    """A soft low thud: a sine whose pitch falls quickly as it decays."""
    t = time_axis(n, sr)
    freq = f_end + (f_start - f_end) * np.exp(-t / max(drop, 1e-4))
    phase = TAU * np.cumsum(freq) / sr
    out = np.sin(phase) * np.exp(-6.908 * t / max(t60, 1e-4))
    a = min(samples(0.002, sr), n)
    out[:a] *= np.arange(a) / a
    return out


def stick_slip(n: int, rng: np.random.Generator, rate_hz: float | Array, jitter: float = 0.25,
               sr: int = SR) -> Array:
    """Impulses at an irregular rate: the sticking and slipping of friction.

    Returns a sparse train (most samples zero). Convolve it with a resonant
    kernel for a creak, or smooth it for the roughness of a scrape.
    """
    rate = np.broadcast_to(np.asarray(rate_hz, dtype=np.float64), (n,))
    out = np.zeros(n)
    phase = np.cumsum(rate) / sr
    total = float(phase[-1])
    if total < 0.2:
        return out
    gaps = np.maximum(0.2, 1.0 + jitter * rng.standard_normal(int(total / 0.2) + 2))
    marks = np.cumsum(gaps)
    marks = marks[marks < total]
    at = np.minimum(np.searchsorted(phase, marks), n - 1)
    out[at] = 0.6 + 0.8 * rng.random(len(at))
    return out


# =============================================================================
# GRAINS
# =============================================================================

def grain_kernels(rng: np.random.Generator, count: int, band: tuple[float, float],
                  t60: tuple[float, float], sr: int = SR, width: float = 0.6) -> list[Array]:
    """A handful of different very short filtered noise bursts.

    Each kernel gets its own centre frequency inside band (log-spaced) and its
    own decay inside t60, which is what stops a grain cloud sounding like one
    click repeated.
    """
    kernels = []
    for _ in range(count):
        decay = rng.uniform(*t60)
        n = samples(decay * 1.3 + 0.002, sr)
        centre = np.exp(rng.uniform(np.log(band[0]), np.log(band[1])))
        lo = max(40.0, centre * (1.0 - 0.5 * width))
        hi = min(sr * 0.45, centre * (1.0 + width))
        burst = rng.standard_normal(n) * env_decay(n, decay, sr)
        burst = filt(np.concatenate([burst, np.zeros(n)]), bp(lo, hi, 1.5), sr)[:n + n // 2]
        burst *= np.minimum(1.0, np.arange(len(burst)) / max(1.0, 0.0003 * sr))
        kernels.append(burst / (np.max(np.abs(burst)) + 1e-12))
    return kernels


def grain_cloud(n: int, rng: np.random.Generator, rate: float | Array, kernels: Sequence[Array],
                amp_spread: float = 0.6, sr: int = SR, circular: bool = False) -> Array:
    """Scatter grains at rate events per second (an array makes it vary).

    Amplitudes are log-normal: a few loud cracks among many small ones.
    circular=True wraps the grains that ring past the end back to the start,
    so the cloud loops.
    """
    rate_arr = np.broadcast_to(np.asarray(rate, dtype=np.float64), (n,))
    hits = rng.random(n) < (rate_arr / sr)
    indices = np.flatnonzero(hits)
    out = np.zeros(n)
    if len(indices) == 0 or not kernels:
        return out
    which = rng.integers(0, len(kernels), size=len(indices))
    amps = np.exp(amp_spread * rng.standard_normal(len(indices)))
    for k, kernel in enumerate(kernels):
        mask = which == k
        if not np.any(mask):
            continue
        train = np.zeros(n)
        train[indices[mask]] = amps[mask] * rng.choice([-1.0, 1.0], size=int(np.sum(mask)))
        out += scatter(train, kernel, circular)
    return out


def scatter(train: Array, kernel: Array, circular: bool = False) -> Array:
    """Put a copy of kernel at every non-zero sample of train."""
    n = len(train)
    if not circular:
        return convolve(train, kernel)
    full = convolve(train, kernel, n + len(kernel))
    out = full[:n].copy()
    spill = full[n:]
    while len(spill) > 0:
        part = spill[:n]
        out[:len(part)] += part
        spill = spill[n:]
    return out


def moving_band(n: int, rng: np.random.Generator, centre_hz: float | Array, lo: float, hi: float,
                steps: int = 6, sharpness: float = 0.6, sr: int = SR) -> Array:
    """Noise whose emphasis glides between lo and hi following centre_hz.

    Fixed bands are cross-faded by how far (in octaves) each lies from the
    centre. Unlike a swept filter this is circular, so it can be used in a
    loop when centre_hz itself is circular (see wander()).
    """
    edges = np.geomspace(lo, hi, steps + 1)
    centre = np.broadcast_to(np.asarray(centre_hz, dtype=np.float64), (n,))
    # Keep the emphasis inside the bands, or the sound drops out when it strays
    centre = np.clip(centre, np.sqrt(edges[0] * edges[1]), np.sqrt(edges[-2] * edges[-1]))
    out = np.zeros(n)
    for k in range(steps):
        middle = np.sqrt(edges[k] * edges[k + 1])
        band = noise(n, rng, bp(edges[k], edges[k + 1], 3.0), sr)
        distance = np.log2(centre / middle)
        out += band * np.exp(-0.5 * (distance / sharpness) ** 2)
    return out


# =============================================================================
# SPACE
# =============================================================================

def reverb_ir(rng: np.random.Generator, t60: float, sr: int = SR, damping_hz: float = 3500.0,
              predelay: float = 0.0, density: float = 1.0) -> Array:
    """A synthetic room: decaying noise whose highs die away first."""
    n = samples(t60 * 1.15 + predelay, sr)
    t = time_axis(n, sr)
    body = rng.standard_normal(n)
    if density < 1.0:
        body *= rng.random(n) < density
    low = filt(body, lp(damping_hz * 0.35, 1.0), sr) * np.exp(-6.908 * t / t60)
    mid = filt(body, bp(damping_hz * 0.35, damping_hz, 1.0), sr) * np.exp(-6.908 * t / (t60 * 0.6))
    high = filt(body, hp(damping_hz, 1.0), sr) * np.exp(-6.908 * t / (t60 * 0.25))
    ir = low + mid + high
    ir *= np.minimum(1.0, t / 0.004)
    if predelay > 0.0:
        ir = np.concatenate([np.zeros(samples(predelay, sr)), ir])[:n]
    return ir / (np.sqrt(np.sum(ir * ir)) + 1e-12)


def reverb(x: Array, rng: np.random.Generator, t60: float, mix: float, sr: int = SR,
           damping_hz: float = 3500.0, predelay: float = 0.0, tail: float | None = None) -> Array:
    """x with a room around it. The output is longer by the tail (default t60)."""
    tail_n = samples(t60 if tail is None else tail, sr)
    dry = np.concatenate([x, np.zeros(tail_n)])
    wet = convolve(dry, reverb_ir(rng, t60, sr, damping_hz, predelay))
    return (1.0 - mix) * dry + mix * wet * 2.0


def echoes(x: Array, taps: Iterable[tuple[float, float, float]], sr: int = SR) -> Array:
    """Discrete reflections: (delay seconds, gain, low-pass Hz) per tap."""
    taps = list(taps)
    longest = max((d for d, _, _ in taps), default=0.0)
    out = np.concatenate([x, np.zeros(samples(longest, sr))])
    for delay, gain, cutoff in taps:
        shifted = np.zeros(len(out))
        offset = samples(delay, sr)
        dulled = filt(x, lp(cutoff, 1.0), sr)
        shifted[offset:offset + len(x)] = dulled[:len(out) - offset]
        out += gain * shifted
    return out


def far_away(x: Array, metres: float, sr: int = SR) -> Array:
    """Air between the source and the ear: the highs go first."""
    cutoff = float(np.clip(20000.0 / (1.0 + metres / 120.0), 250.0, 16000.0))
    return filt(x, lp(cutoff, 1.0), sr)


# =============================================================================
# LEVELS
# =============================================================================

def db(value: float) -> float:
    return 10.0 ** (value / 20.0)


def rms(x: Array) -> float:
    return float(np.sqrt(np.mean(x * x)) + 1e-12)


def normalize_peak(x: Array, dbfs: float = -1.0) -> Array:
    return x * (db(dbfs) / (np.max(np.abs(x)) + 1e-12))


def normalize_rms(x: Array, dbfs: float = -20.0, ceiling_dbfs: float = -1.0) -> Array:
    out = x * (db(dbfs) / rms(x))
    top = np.max(np.abs(out))
    if top > db(ceiling_dbfs):
        out = soft_limit(out, ceiling_dbfs)
    return out


def soft_limit(x: Array, ceiling_dbfs: float = -1.0, knee: float = 0.7) -> Array:
    """Leave everything below the knee alone and round off what is above it."""
    ceiling = db(ceiling_dbfs)
    threshold = ceiling * knee
    magnitude = np.abs(x)
    over = magnitude > threshold
    out = x.copy()
    span = ceiling - threshold
    out[over] = np.sign(x[over]) * (threshold + span * np.tanh((magnitude[over] - threshold) / span))
    return out


def saturate(x: Array, drive: float) -> Array:
    """Gentle tanh saturation; adds weight and tames peaks."""
    return np.tanh(x * drive) / np.tanh(drive)


def remove_dc(x: Array) -> Array:
    return x - np.mean(x)


def place(target: Array, sound: Array, at_seconds: float, gain: float = 1.0, sr: int = SR) -> None:
    """Mix sound into target starting at at_seconds (clipped to the buffer)."""
    start = int(round(at_seconds * sr))
    if start >= len(target) or start + len(sound) <= 0:
        return
    src_from = max(0, -start)
    start = max(0, start)
    length = min(len(sound) - src_from, len(target) - start)
    target[start:start + length] += gain * sound[src_from:src_from + length]


def trim_tail(x: Array, threshold_db: float = -66.0, sr: int = SR, keep: float = 0.01) -> Array:
    """Cut the inaudible end of a one-shot (relative to its own peak)."""
    level = np.max(np.abs(x)) * db(threshold_db)
    loud = np.flatnonzero(np.abs(x) > level)
    if len(loud) == 0:
        return x
    end = min(len(x), loud[-1] + samples(keep, sr))
    return x[:end]
