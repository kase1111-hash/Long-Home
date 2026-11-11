"""What things are made of, and what they do when stressed.

Shared by the sound modules: the partials of steel, aluminium, ice, rock and
wood, and the small models built on them (a crunch, a scrape, a creak, a
swish of cloth). Every function here takes a ``dsp.At`` first, so it works at
whatever sample rate the sound is rendered at.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, lp, peak, tilt

## Partials as (frequency Hz, level, t60 seconds)
CRAMPON_STEEL = [(2350.0, 1.0, 0.05), (3620.0, 0.8, 0.04), (5210.0, 0.6, 0.03),
                 (7400.0, 0.4, 0.02), (9800.0, 0.2, 0.012)]
CRAMPON_RING = [(1850.0, 1.0, 0.11), (2890.0, 0.8, 0.09), (4350.0, 0.55, 0.06), (6600.0, 0.3, 0.04)]
AXE_STEEL = [(1620.0, 1.0, 0.16), (2750.0, 0.8, 0.12), (4300.0, 0.5, 0.08), (6100.0, 0.3, 0.05)]
ALUMINIUM = [(3150.0, 1.0, 0.07), (4980.0, 0.8, 0.055), (7250.0, 0.55, 0.04), (9900.0, 0.3, 0.025)]
SHOVEL_BLADE = [(1080.0, 1.0, 0.06), (2260.0, 0.6, 0.045), (3900.0, 0.35, 0.03)]
PLASTIC = [(380.0, 1.0, 0.04), (910.0, 0.7, 0.03), (2100.0, 0.5, 0.02), (3900.0, 0.3, 0.012)]
WOOD = [(138.0, 1.0, 0.14), (285.0, 0.7, 0.1), (468.0, 0.45, 0.07), (760.0, 0.25, 0.05), (1210.0, 0.12, 0.03)]
ROCK = [(520.0, 1.0, 0.035), (890.0, 0.7, 0.028), (1420.0, 0.5, 0.02), (2300.0, 0.3, 0.014)]
SOLE_ON_ROCK = [(450.0, 1.0, 0.02), (980.0, 0.5, 0.014), (1650.0, 0.3, 0.01)]
SOLE_ON_ICE = [(640.0, 1.0, 0.02), (1500.0, 0.6, 0.014), (3100.0, 0.35, 0.009)]
ICE_BODY = [(112.0, 1.0, 0.13), (207.0, 0.7, 0.1), (372.0, 0.5, 0.075), (640.0, 0.36, 0.05),
            (1010.0, 0.22, 0.035), (1490.0, 0.12, 0.025)]
ICE_SHARDS = [(2900.0, 1.0, 0.02), (4300.0, 0.8, 0.016), (6100.0, 0.6, 0.012), (8700.0, 0.35, 0.008)]
NYLON = [(240.0, 1.0, 0.02), (410.0, 0.7, 0.018), (690.0, 0.4, 0.012), (1150.0, 0.2, 0.008)]


def unit(x: np.ndarray) -> np.ndarray:
    """Scale to a peak of 1, so layers can be mixed by plain numbers."""
    return x / (np.max(np.abs(x)) + 1e-12)


def bump(t: np.ndarray, at: float, width: float) -> np.ndarray:
    """A smooth bump in time centred at ``at`` seconds."""
    return np.exp(-0.5 * ((t - at) / width) ** 2)


def scaled(partials, factor: float, ring: float = 1.0):
    """The same object, bigger or smaller (lower or higher), ringing longer or shorter."""
    return [(f * factor, a, t60 * ring) for f, a, t60 in partials]


def heel(d: dsp.At, n: int, rng, pitch: float, t60: float) -> np.ndarray:
    """Weight arriving on the ground: a low thud with a little air in it."""
    thud = d.thump(n, pitch * 2.3, pitch, t60)
    puff = d.noise(n, rng, lp(pitch * 3.5, 1.5)) * d.env_decay(n, t60 * 0.6)
    return unit(thud + 0.45 * puff)


def crush(d: dsp.At, n: int, rng, shape: np.ndarray, band: tuple, slope: float,
          burst_rate: float, burst_width: float) -> np.ndarray:
    """Material giving way under load: noise that arrives in irregular bursts.

    This is the body of a crunch. On its own it is a rough hiss; the sharp
    detail comes from cracks() on top.
    """
    carrier = d.noise(n, rng, chain(bp(band[0], band[1], 1.5), tilt(slope, 2000.0)))
    bursts = d.smooth(d.stick_slip(n, rng, burst_rate, 0.6), burst_width)
    return unit(carrier * shape * (0.28 + unit(bursts)))


def cracks(d: dsp.At, n: int, rng, rate, band: tuple, t60: tuple, count: int = 7,
           circular: bool = False) -> np.ndarray:
    """Individual fractures: sparse, sharp, a few much louder than the rest."""
    kernels = d.grain_kernels(rng, count, band, t60)
    return unit(d.grain_cloud(n, rng, rate, kernels, 0.8, circular=circular))


def stones(d: dsp.At, rng, count: int, low: float, high: float) -> list:
    """Small stones knocking: each a dry clack with its own pitch, quickly dead."""
    kernels = []
    for _ in range(count):
        base = np.exp(rng.uniform(np.log(low), np.log(high)))
        ring = rng.uniform(0.005, 0.014)
        partials = [(base, 1.0, ring), (base * rng.uniform(1.55, 1.85), 0.6, ring * 0.8),
                    (base * rng.uniform(2.4, 2.9), 0.35, ring * 0.6)]
        kernels.append(unit(d.struck(d.samples(ring * 1.5 + 0.004), rng, partials, click=1.1,
                                     click_band=(base * 0.8, min(base * 4.0, d.sr * 0.42)), click_t60=0.003)))
    return kernels


def hits(d: dsp.At, n: int, rng, partials, count: int, spacing: float, click: float = 0.9,
         click_band: tuple = (3000.0, 11000.0), length: float = 0.14) -> np.ndarray:
    """The same object struck a few times in quick, uneven succession."""
    out = np.zeros(n)
    at = 0.0
    top = min(click_band[1], d.sr * 0.42)
    for _ in range(count):
        hit = d.struck(d.samples(length), rng, partials, click=click, click_band=(click_band[0], top),
                       click_t60=0.004, spread=0.05)
        d.place(out, hit, at, rng.uniform(0.55, 1.0))
        at += rng.uniform(0.5, 1.5) * spacing
    return unit(out)


def scrape(d: dsp.At, n: int, rng, shape: np.ndarray, band: tuple, rate, resonances=(),
           roughness: float = 0.75, slope: float = -2.0) -> np.ndarray:
    """Something hard dragged over something rough.

    rate is how often it catches and lets go (Hz): low rates chatter, high
    rates hiss. resonances are (Hz, Q, dB) of the thing being dragged.
    """
    catch = unit(d.smooth(d.stick_slip(n, rng, rate, 0.5), 0.0012))
    response = chain(bp(band[0], band[1], 1.5), tilt(slope, 3000.0), *[peak(f, q, g) for f, q, g in resonances])
    return unit(d.noise(n, rng, response) * shape * ((1.0 - roughness) + roughness * catch))


def creak(d: dsp.At, n: int, rng, rate, partials, shape: np.ndarray, jitter: float = 0.3) -> np.ndarray:
    """Something under strain letting go in tiny jerks: rope, ice, wood."""
    pulses = d.stick_slip(n, rng, rate, jitter) * shape
    longest = max(t60 for _, _, t60 in partials)
    kernel = d.modal(d.samples(longest * 1.2 + 0.004), partials)
    return unit(d.convolve(pulses, kernel))


def cloth(d: dsp.At, n: int, rng, swells: int = 3, band: tuple = (1500.0, 8000.0)) -> np.ndarray:
    """Shell fabric moving: a few short swishes with a crinkle in them."""
    t = d.time_axis(n)
    duration = n / d.sr
    shape = np.zeros(n)
    for _ in range(swells):
        shape += rng.uniform(0.5, 1.0) * bump(t, rng.uniform(0.12, 0.8) * duration, rng.uniform(0.02, 0.05))
    top = min(band[1], d.sr * 0.42)
    swish = d.noise(n, rng, chain(bp(band[0], top, 1.5), tilt(-3))) * shape
    swish *= np.maximum(1.0 + 0.4 * d.wander(n, rng, 90.0), 0.1)
    ticks = cracks(d, n, rng, 250.0 * shape, (2500.0, min(8000.0, top)), (0.001, 0.003), 5)
    return unit(unit(swish) + 0.2 * ticks)


def swish(d: dsp.At, n: int, rng, low: float, high: float, peak_at: float, band_q: float = 1.2) -> np.ndarray:
    """Something moving fast through air: a whoosh whose pitch rises and falls."""
    shape = d.env_swell(n, peak_at, sharpness=1.5)
    times = d.time_axis(n)

    def response_at(t):
        e = float(np.interp(t, times, shape))
        centre = low + (high - low) * e
        return chain(bp(centre / (1.0 + 1.0 / band_q), centre * (1.0 + 1.0 / band_q), 1.5), tilt(-3, centre))

    return unit(d.filt_tv(rng.standard_normal(n), response_at) * shape)
