"""Reading and writing the game's WAV files (16-bit PCM, mono).

Loops carry their loop points in a ``smpl`` chunk, which Godot's importer
reads ("Detect From WAV"), so a looping sound needs no import settings.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

## Copies of the first samples written after the end of a loop. Godot
## interpolates each output sample with the one after it and does not wrap
## that neighbour, so without these the last sample of every pass would be
## blended with silence instead of with the start of the loop.
LOOP_GUARD_SAMPLES = 8


@dataclass
class WavData:
    samples: np.ndarray        # float64 in -1..1, mono
    sample_rate: int
    channels: int
    bits: int
    loop_start: int = -1       # -1 when the file has no loop
    loop_end: int = -1         # exclusive, the way Godot reads it

    @property
    def is_loop(self) -> bool:
        return self.loop_start >= 0

    @property
    def duration(self) -> float:
        return len(self.samples) / float(self.sample_rate)

    def loop_body(self) -> np.ndarray:
        """The samples one pass of the loop plays."""
        if not self.is_loop:
            return self.samples
        return self.samples[self.loop_start:self.loop_end]


def to_pcm16(x: np.ndarray, seed: int) -> np.ndarray:
    """Float samples to 16-bit with triangular dither (repeatable)."""
    rng = np.random.default_rng(seed)
    dither = (rng.random(len(x)) - rng.random(len(x))) / 32768.0
    scaled = np.round((np.clip(x, -1.0, 1.0) + dither) * 32767.0)
    return np.clip(scaled, -32768, 32767).astype("<i2")


def write_wav(path: Path, x: np.ndarray, sample_rate: int, loop: bool = False) -> None:
    """Write x as a mono 16-bit WAV. A loop plays x end to end, seamlessly."""
    data = np.asarray(x, dtype=np.float64)
    loop_length = len(data)
    samples = to_pcm16(data, zlib.crc32(path.name.encode("utf-8")))
    if loop:
        # Copied after dithering, so the guard is the loop's start bit for bit
        samples = np.concatenate([samples, samples[:LOOP_GUARD_SAMPLES]])
    pcm = samples.tobytes()

    fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
    chunks = [fmt, struct.pack("<4sI", b"data", len(pcm)) + pcm]
    if len(pcm) % 2 == 1:
        chunks[-1] += b"\x00"
    if loop:
        # One forward loop over the whole body. Godot treats the end as
        # exclusive, so it is the body length (the guard samples follow it).
        period_ns = int(round(1e9 / sample_rate))
        chunks.append(struct.pack("<4sI9I6I", b"smpl", 60,
                                  0, 0, period_ns, 60, 0, 0, 0, 1, 0,
                                  0, 0, 0, loop_length, 0, 0))
    body = b"WAVE" + b"".join(chunks)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<4sI", b"RIFF", len(body)) + body)


def read_wav(path: Path) -> WavData:
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("%s is not a RIFF/WAVE file" % path)
    position = 12
    channels = bits = sample_rate = 0
    audio_format = 1
    pcm = b""
    loop_start = loop_end = -1
    while position + 8 <= len(raw):
        tag, size = struct.unpack_from("<4sI", raw, position)
        body = raw[position + 8:position + 8 + size]
        if tag == b"fmt ":
            audio_format, channels, sample_rate, _, _, bits = struct.unpack_from("<HHIIHH", body)
        elif tag == b"data":
            pcm = body
        elif tag == b"smpl" and size >= 60:
            loops = struct.unpack_from("<I", body, 28)[0]
            if loops >= 1:
                _, loop_type, loop_start, loop_end = struct.unpack_from("<4I", body, 36)
                if loop_type != 0:
                    loop_start = loop_end = -1
        position += 8 + size + (size & 1)
    if audio_format != 1 or bits != 16:
        raise ValueError("%s: only 16-bit PCM is supported (format %d, %d bits)" % (path, audio_format, bits))
    values = np.frombuffer(pcm, dtype="<i2").astype(np.float64) / 32768.0
    if channels > 1:
        values = values.reshape(-1, channels).mean(axis=1)
    return WavData(values, sample_rate, channels, bits, loop_start, loop_end)
