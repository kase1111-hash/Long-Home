"""Looking at sounds without listening to them.

measure() gives the numbers that catch the usual faults (clipping, a DC
offset, a click at a loop seam, a file that is all hiss or all rumble), and
spectrogram_sheet() draws sounds as pictures: time left to right, frequency
on a log axis from 40 Hz at the bottom to 20 kHz at the top, with the
waveform envelope in a strip above each one.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import numpy as np

from wavio import WavData

ROW_HEIGHT = 120
WAVE_HEIGHT = 26
GAP = 6
FLOOR_DB = -84.0


@dataclass
class Measurement:
    duration: float
    peak_dbfs: float
    rms_dbfs: float
    crest_db: float
    centroid_hz: float
    low_hz: float          # 5% of the energy lies below this
    high_hz: float         # 95% of the energy lies below this
    dc: float
    start_level: float     # first sample, relative to the peak
    end_level: float       # last sample, relative to the peak
    seam: float            # loops: jump across the seam / typical step (1.0 = unremarkable)
    silence_tail: float    # one-shots: seconds at the end below -60 dB of the peak


def _dbfs(value: float) -> float:
    return 20.0 * np.log10(max(value, 1e-9))


def measure(wav: WavData) -> Measurement:
    x = wav.loop_body()
    sr = wav.sample_rate
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    level = float(np.sqrt(np.mean(x * x))) if len(x) else 0.0

    spectrum = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(len(x), 1.0 / sr)
    total = float(np.sum(spectrum)) + 1e-20
    cumulative = np.cumsum(spectrum) / total
    centroid = float(np.sum(freqs * spectrum) / total)
    low = float(freqs[min(np.searchsorted(cumulative, 0.05), len(freqs) - 1)])
    high = float(freqs[min(np.searchsorted(cumulative, 0.95), len(freqs) - 1)])

    seam = 0.0
    if wav.is_loop and len(x) > 16:
        steps = np.abs(np.diff(x))
        typical = float(np.sqrt(np.mean(steps * steps))) + 1e-12
        seam = float(abs(x[0] - x[-1])) / typical

    tail = 0.0
    if not wav.is_loop and peak > 0.0:
        loud = np.flatnonzero(np.abs(x) > peak * 10.0 ** (-60.0 / 20.0))
        if len(loud):
            tail = (len(x) - 1 - loud[-1]) / float(sr)

    return Measurement(
        duration=len(x) / float(sr),
        peak_dbfs=_dbfs(peak),
        rms_dbfs=_dbfs(level),
        crest_db=_dbfs(peak) - _dbfs(level),
        centroid_hz=centroid,
        low_hz=low,
        high_hz=high,
        dc=float(np.mean(x)) if len(x) else 0.0,
        start_level=float(abs(x[0]) / (peak + 1e-12)) if len(x) else 0.0,
        end_level=float(abs(x[-1]) / (peak + 1e-12)) if len(x) else 0.0,
        seam=seam,
        silence_tail=tail,
    )


def problems(wav: WavData, m: Measurement) -> list[str]:
    """Faults worth failing a build over."""
    found = []
    if m.peak_dbfs > -0.2:
        found.append("peaks at %.2f dBFS (clipping risk)" % m.peak_dbfs)
    # A very short low thud never averages to zero, so judge only longer files
    if abs(m.dc) > (0.004 if m.duration >= 0.3 else 0.03):
        found.append("DC offset %.4f" % m.dc)
    if wav.is_loop:
        if m.seam > 4.0:
            found.append("loop seam jumps %.1fx the typical step" % m.seam)
    else:
        if m.start_level > 0.05:
            found.append("starts at %.0f%% of its peak (click)" % (m.start_level * 100.0))
        if m.end_level > 0.02:
            found.append("ends at %.0f%% of its peak (click)" % (m.end_level * 100.0))
    if m.rms_dbfs < -60.0:
        found.append("almost silent (%.1f dBFS RMS)" % m.rms_dbfs)
    return found


# =============================================================================
# PICTURES
# =============================================================================

def _colour_map() -> np.ndarray:
    """Black through violet and orange to pale yellow (256 RGB entries)."""
    stops = np.array([
        [0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99],
        [212, 72, 66], [245, 125, 21], [250, 193, 39], [252, 255, 164],
    ], dtype=np.float64)
    positions = np.linspace(0.0, 1.0, len(stops))
    ramp = np.linspace(0.0, 1.0, 256)
    return np.stack([np.interp(ramp, positions, stops[:, c]) for c in range(3)], axis=1).astype(np.uint8)


def _spectrogram(x: np.ndarray, sr: int, width: int, height: int) -> np.ndarray:
    """Log-frequency spectrogram as a height x width array of 0..255."""
    # Short sounds are all transients: trade frequency detail for time detail
    window = 2048 if len(x) > 1.5 * sr else 512
    if len(x) < window:
        x = np.concatenate([x, np.zeros(window - len(x))])
    hop = max(1, (len(x) - window) // max(width - 1, 1))
    hop = min(hop, window // 2)
    frames = 1 + (len(x) - window) // hop
    win = np.hanning(window)
    spec = np.empty((frames, window // 2 + 1))
    for i in range(frames):
        segment = x[i * hop:i * hop + window] * win
        spec[i] = np.abs(np.fft.rfft(segment)) / (window * 0.25)
    freqs = np.fft.rfftfreq(window, 1.0 / sr)
    targets = np.geomspace(40.0, min(20000.0, sr * 0.5), height)
    columns = np.empty((frames, height))
    for i in range(frames):
        columns[i] = np.interp(targets, freqs, spec[i])
    level = 20.0 * np.log10(np.maximum(columns, 1e-9))
    scaled = np.clip((level - FLOOR_DB) / (0.0 - FLOOR_DB), 0.0, 1.0)
    # Resample along time to the requested width, low frequencies at the bottom
    source = np.linspace(0.0, frames - 1.0, width)
    lower = np.floor(source).astype(int)
    upper = np.minimum(lower + 1, frames - 1)
    blend = (source - lower)[:, None]
    image = scaled[lower] * (1.0 - blend) + scaled[upper] * blend
    return (image.T[::-1] * 255.0).astype(np.uint8)


def _envelope_strip(x: np.ndarray, width: int, height: int) -> np.ndarray:
    """Peak envelope drawn as a filled, mirrored waveform (0..255 grey)."""
    strip = np.zeros((height, width), dtype=np.uint8)
    if len(x) == 0:
        return strip
    edges = np.linspace(0, len(x), width + 1).astype(int)
    scale = float(np.max(np.abs(x))) + 1e-12
    middle = (height - 1) / 2.0
    for column in range(width):
        chunk = x[edges[column]:max(edges[column + 1], edges[column] + 1)]
        reach = float(np.max(np.abs(chunk))) / scale * middle
        top = int(round(middle - reach))
        bottom = int(round(middle + reach))
        strip[top:bottom + 1, column] = 200
    return strip


def write_png(path: Path, rgb: np.ndarray) -> None:
    """Minimal PNG writer for an H x W x 3 uint8 array."""
    height, width, _ = rgb.shape
    rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(height))

    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def spectrogram_sheet(path: Path, sounds: Sequence[WavData], seconds_across: float | None = None,
                      width: int = 1400) -> float:
    """Stack the sounds as rows sharing one time scale. Returns that scale's span.

    seconds_across is the time the full width stands for (default: the longest
    sound). A grey tick marks every 0.1 s (short sheets) or every second.
    """
    span = seconds_across or max(w.duration for w in sounds)
    palette = _colour_map()
    row = WAVE_HEIGHT + ROW_HEIGHT + GAP
    sheet = np.full((row * len(sounds), width, 3), 255, dtype=np.uint8)
    tick = 0.1 if span <= 3.0 else 1.0
    for index, wav in enumerate(sounds):
        x = wav.loop_body()
        pixels = int(np.clip(round(width * wav.duration / span), 8, width))
        top = index * row
        strip = _envelope_strip(x, pixels, WAVE_HEIGHT)
        sheet[top:top + WAVE_HEIGHT, :pixels] = strip[:, :, None]
        sheet[top:top + WAVE_HEIGHT, :pixels, 2] = np.maximum(strip, 40)
        image = _spectrogram(x, wav.sample_rate, pixels, ROW_HEIGHT)
        sheet[top + WAVE_HEIGHT:top + WAVE_HEIGHT + ROW_HEIGHT, :pixels] = palette[image]
        # Time ticks along the bottom edge of the row
        position = tick
        while position < wav.duration:
            column = int(position / span * width)
            if column < pixels:
                sheet[top + WAVE_HEIGHT + ROW_HEIGHT - 5:top + WAVE_HEIGHT + ROW_HEIGHT, column] = (255, 255, 255)
            position += tick
        # Frequency guides at 100 Hz, 1 kHz and 10 kHz
        for guide in (100.0, 1000.0, 10000.0):
            if guide < wav.sample_rate * 0.5:
                fraction = np.log(guide / 40.0) / np.log(min(20000.0, wav.sample_rate * 0.5) / 40.0)
                y = top + WAVE_HEIGHT + int((1.0 - fraction) * (ROW_HEIGHT - 1))
                sheet[y, :6] = (255, 255, 255)
    write_png(path, sheet)
    return span
