"""Menus and the things the climber handles: map, guidebook, watch.

The interface sounds are small and made of real materials (a pebble tapped,
paper unfolded), in keeping with a game that has no music and no stingers.
They are quiet on purpose.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, lp, tilt
from materials import PLASTIC, bump, cloth, cracks, scaled, unit
from registry import sound


PEBBLE = [(980.0, 1.0, 0.045), (1520.0, 0.5, 0.03), (2350.0, 0.25, 0.02)]


def tap(d: dsp.At, rng, factor: float, ring: float, click: float, length: float) -> np.ndarray:
    """A small stone tapped on another: the grain of every menu sound."""
    return unit(d.struck(d.samples(length), rng, scaled(PEBBLE, factor, ring), click=click,
                         click_band=(1500.0, 5000.0), click_t60=0.004, spread=0.03))


# =============================================================================
# MENUS
# =============================================================================

@sound("ui_hover", "ui", variants=2, peak=-14.0, rate=44100)
def ui_hover(d, rng, variant):
    """Moving onto a button: the lightest tick."""
    return d.filt(tap(d, rng, 1.8 + 0.12 * variant, 0.45, 0.25, 0.05), lp(6000.0, 1.5), causal=True)


@sound("ui_select", "ui", variants=2, peak=-9.0, rate=44100)
def ui_select(d, rng, variant):
    """Pressing a button."""
    return tap(d, rng, 1.0 + 0.06 * variant, 1.0, 0.3, 0.1)


@sound("ui_confirm", "ui", peak=-8.0, rate=44100)
def ui_confirm(d, rng, variant):
    """Committing to something: two taps, the second higher."""
    n = d.samples(0.2)
    out = np.zeros(n)
    d.place(out, tap(d, rng, 0.72, 1.1, 0.3, 0.12), 0.0, 0.85)
    d.place(out, tap(d, rng, 1.08, 1.2, 0.3, 0.14), 0.058, 1.0)
    return out


@sound("ui_back", "ui", peak=-11.0, rate=44100)
def ui_back(d, rng, variant):
    """Stepping back out: lower and softer."""
    return d.filt(tap(d, rng, 0.64, 1.1, 0.2, 0.11), lp(3500.0, 1.5), causal=True)


@sound("ui_error", "ui", peak=-9.0, rate=44100)
def ui_error(d, rng, variant):
    """That cannot be done: two dull knocks."""
    n = d.samples(0.26)
    out = np.zeros(n)
    for at, gain in ((0.0, 1.0), (0.095, 0.8)):
        m = d.samples(0.12)
        knock = unit(d.thump(m, 185.0, 110.0, 0.055)) + 0.35 * tap(d, rng, 0.42, 0.7, 0.15, 0.12)
        d.place(out, knock, at, gain)
    return out


@sound("ui_toggle", "ui", variants=2, peak=-11.0, rate=44100)
def ui_toggle(d, rng, variant):
    """Switching an item in or out of the pack: a small firm click."""
    n = d.samples(0.07)
    click = unit(d.struck(n, rng, scaled(PLASTIC, 2.2 + 0.25 * variant, 0.4), click=0.8,
                          click_band=(2500.0, 8000.0), click_t60=0.003))
    return click


# =============================================================================
# PAPER
# =============================================================================

def paper(d: dsp.At, n: int, rng, shape: np.ndarray, weight: float = 0.5) -> np.ndarray:
    """Stiff paper handled: crackle from the creases, a low flap from the sheet."""
    crackle = cracks(d, n, rng, 1700.0 * shape, (1800.0, 9000.0), (0.001, 0.003), 8)
    hiss = d.noise(n, rng, chain(bp(1500.0, 9000.0, 1.5), tilt(-3)))
    hiss = unit(hiss * shape * np.maximum(1.0 + 0.5 * d.wander(n, rng, 70.0), 0.1))
    flap = unit(d.noise(n, rng, chain(bp(180.0, 1500.0, 1.5), tilt(-4))) * shape ** 1.5)
    return crackle + 0.6 * hiss + weight * flap


@sound("map_unfold", "ui", variants=2, peak=-6.0, rate=32000)
def map_unfold(d, rng, variant):
    """The map pulled out and opened: three folds coming apart."""
    n = d.samples(0.72)
    t = d.time_axis(n)
    shape = bump(t, 0.1, 0.05) + 0.8 * bump(t, 0.3, 0.06) + bump(t, 0.52, 0.07)
    return paper(d, n, rng, shape)


@sound("map_fold", "ui", variants=2, peak=-7.0, rate=32000)
def map_fold(d, rng, variant):
    """The map folded away and pressed flat."""
    n = d.samples(0.6)
    t = d.time_axis(n)
    shape = bump(t, 0.09, 0.06) + 0.9 * bump(t, 0.3, 0.06)
    out = paper(d, n, rng, shape, 0.4)
    pat = unit(d.thump(d.samples(0.12), 170.0, 95.0, 0.05))
    d.place(out, pat, 0.44, 0.45)
    return out


@sound("map_rustle", "ui", variants=2, peak=-10.0, rate=32000)
def map_rustle(d, rng, variant):
    """The wind catching the open map."""
    n = d.samples(0.34)
    t = d.time_axis(n)
    shape = bump(t, rng.uniform(0.08, 0.14), 0.05) + 0.6 * bump(t, rng.uniform(0.2, 0.26), 0.04)
    return paper(d, n, rng, shape, 0.7)


@sound("page_turn", "ui", peak=-9.0, rate=32000)
def page_turn(d, rng, variant):
    """A page of the guidebook turned."""
    n = d.samples(0.38)
    t = d.time_axis(n)
    sweep = d.noise(n, rng, chain(bp(1200.0, 7500.0, 1.5), tilt(-3)))
    sweep = unit(sweep * d.env_swell(n, 0.16, sharpness=1.6))
    edge = cracks(d, n, rng, 500.0 * bump(t, 0.24, 0.05), (2500.0, 9000.0), (0.001, 0.003), 5)
    return sweep + 0.4 * edge


@sound("watch_check", "ui", peak=-12.0, rate=32000)
def watch_check(d, rng, variant):
    """A sleeve pushed back to look at the watch."""
    n = d.samples(0.3)
    out = cloth(d, n, rng, 2)
    tick = unit(d.struck(d.samples(0.03), rng, scaled(PLASTIC, 4.0, 0.3), click=0.5, click_band=(3000.0, 9000.0)))
    d.place(out, tick, 0.22, 0.3)
    return out


@sound("compass_open", "ui", peak=-11.0, rate=44100)
def compass_open(d, rng, variant):
    """The compass lid flipped open."""
    n = d.samples(0.14)
    out = np.zeros(n)
    d.place(out, unit(d.struck(d.samples(0.08), rng, scaled(PLASTIC, 2.6, 0.5), click=0.7,
                               click_band=(2500.0, 8000.0))), 0.0, 0.6)
    d.place(out, unit(d.struck(d.samples(0.09), rng, scaled(PLASTIC, 1.9, 0.6), click=0.6,
                               click_band=(2000.0, 7000.0))), 0.05, 1.0)
    return out
