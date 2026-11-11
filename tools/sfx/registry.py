"""The list of sounds the generator knows how to make.

A sound is a function ``(d, rng, variant) -> samples`` registered with the
``@sound`` decorator: ``d`` is the dsp module bound to the sound's sample
rate, ``rng`` a generator seeded from its name, ``variant`` counts from 0.
The name is the id the game asks for; loops end in ``_loop``. Files are
written as ``<category>/<name>_<NN>.wav``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict

import numpy as np

from dsp import SR, At

Renderer = Callable[[At, np.random.Generator, int], np.ndarray]


@dataclass
class SoundSpec:
    name: str
    category: str
    variants: int
    loop: bool
    sample_rate: int
    level_kind: str      # "peak" or "rms"
    level_dbfs: float
    render: Renderer
    description: str

    def file_name(self, variant: int) -> str:
        return "%s_%02d.wav" % (self.name, variant + 1)


SOUNDS: Dict[str, SoundSpec] = {}


def sound(name: str, category: str, variants: int = 1, peak: float | None = None,
          rms: float | None = None, rate: int = SR) -> Callable[[Renderer], Renderer]:
    """Register a sound. Give either a peak level or an RMS level in dBFS.

    One-shots default to a -3 dBFS peak; loops to -20 dBFS RMS, so the mix in
    the game is set by the volumes in the audio managers, not by the files.

    rate is the sample rate to render at. Use the lowest that keeps the
    sound's content: 11025 for rumbles, 22050 for dull sounds, 32000 for most,
    44100 for bright metal. It only changes the file size, not the design.
    """
    loop = name.endswith("_loop")
    if peak is None and rms is None:
        if loop:
            rms = -20.0
        else:
            peak = -3.0

    def register(func: Renderer) -> Renderer:
        if name in SOUNDS:
            raise ValueError("sound '%s' is registered twice" % name)
        SOUNDS[name] = SoundSpec(
            name=name,
            category=category,
            variants=variants,
            loop=loop,
            sample_rate=rate,
            level_kind="rms" if rms is not None else "peak",
            level_dbfs=rms if rms is not None else peak,
            render=func,
            description=(func.__doc__ or "").strip().split("\n")[0],
        )
        return func

    return register
