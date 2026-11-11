"""Sliding, self-arrest, skis and the rush of air at speed.

The loops here are textures with no events in them: the game sets their
volume and pitch from the climber's speed, and plays bumps, bites and stops
as separate one-shots, so a long slide never audibly repeats.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, hp, lp, tilt
from materials import (AXE_STEEL, CRAMPON_RING, PLASTIC, bump, cloth, cracks, crush, heel, hits, scaled,
                       scrape, stones, unit)
from registry import sound


def level(x: np.ndarray) -> np.ndarray:
    """Scale to unit RMS, for mixing steady textures."""
    return x / dsp.rms(x)


# =============================================================================
# SLIDING
# =============================================================================

@sound("slide_snow_loop", "motion", rate=32000)
def slide_snow(d, rng, variant):
    """A body sliding on firm snow: a rushing scrape with weight under it."""
    n = d.samples(3.0)
    hiss = d.noise(n, rng, chain(bp(350, 5500, 1.5), tilt(-3)))
    hiss *= np.maximum(1.0 + 0.25 * d.wander(n, rng, 6.0) + 0.15 * d.wander(n, rng, 22.0), 0.3)
    grains = cracks(d, n, rng, 1500.0, (1500.0, 6000.0), (0.002, 0.005), 8, circular=True)
    rumble = d.noise(n, rng, chain(bp(55, 220, 2), tilt(-4))) * (1.0 + 0.3 * d.wander(n, rng, 3.0))
    return level(hiss) + 0.45 * level(grains) + 0.5 * level(rumble)


@sound("slide_ice_loop", "motion", rate=32000)
def slide_ice(d, rng, variant):
    """Sliding on ice: harder, scratchier, nothing to slow you."""
    n = d.samples(3.0)
    rate = 85.0 * np.exp(0.25 * d.wander(n, rng, 1.5))
    skate = scrape(d, n, rng, np.ones(n), (1500.0, 7000.0), rate, roughness=0.65, slope=-3.0)
    ticks = cracks(d, n, rng, 300.0, (3500.0, 8000.0), (0.001, 0.003), 6, circular=True)
    low = d.noise(n, rng, chain(bp(70, 300, 2), tilt(-4)))
    return level(skate) + 0.35 * level(ticks) + 0.22 * level(low)


@sound("slide_scree_loop", "motion", rate=32000)
def slide_scree(d, rng, variant):
    """Sliding with the scree: a river of small stones."""
    n = d.samples(3.0)
    clatter = d.grain_cloud(n, rng, 230.0, stones(d, rng, 12, 800.0, 3600.0), 0.8, circular=True)
    gravel = d.noise(n, rng, chain(bp(300, 3200, 1.5), tilt(-3)))
    gravel *= 0.4 + unit(d.smooth(d.stick_slip(n, rng, 130.0, 0.6), 0.004))
    rumble = d.noise(n, rng, chain(bp(50, 240, 2), tilt(-4)))
    return level(clatter) + 0.8 * level(gravel) + 0.5 * level(rumble)


@sound("axe_drag_loop", "motion", rate=32000)
def axe_drag(d, rng, variant):
    """The pick of the axe dragging through snow and ice under full weight."""
    n = d.samples(2.4)
    rate = 68.0 * np.exp(0.3 * d.wander(n, rng, 1.8))
    drag = scrape(d, n, rng, np.ones(n), (1200.0, 6000.0), rate,
                  resonances=[(2600.0, 10.0, 8.0), (3900.0, 12.0, 6.0)], roughness=0.8)
    grind = d.noise(n, rng, chain(bp(150, 520, 2), tilt(-3)))
    grind *= 0.4 + unit(d.smooth(d.stick_slip(n, rng, 55.0, 0.6), 0.004))
    return level(drag) + 0.4 * level(grind)


@sound("axe_bite", "motion", variants=2, rate=44100)
def axe_bite(d, rng, variant):
    """The pick driven in: the moment a self-arrest takes."""
    n = d.samples(0.4)
    t = d.time_axis(n)
    pack = crush(d, n, rng, np.exp(-t / 0.03), (800.0, 5000.0), -2.0, 240.0, 0.003)
    ping = unit(d.struck(n, rng, scaled(AXE_STEEL, rng.uniform(0.95, 1.1), 0.5), click=0.7,
                         click_band=(2000.0, 9000.0)))
    return unit(d.thump(n, 190.0, 85.0, 0.07)) + 0.7 * pack + 0.35 * ping


@sound("arrest_stop", "motion", variants=2, peak=-5.0, rate=32000)
def arrest_stop(d, rng, variant):
    """The last of the slide: the scrape slowing, the snow packing, stillness."""
    n = d.samples(0.75)
    t = d.time_axis(n)
    slowing = 80.0 * np.exp(-t / 0.22) + 14.0
    drag = scrape(d, n, rng, np.exp(-t / 0.18), (900.0, 5200.0), slowing, roughness=0.8)
    settle = crush(d, n, rng, bump(t, 0.3, 0.1), (500.0, 3500.0), -3.0, 90.0, 0.006)
    out = drag + 0.5 * settle
    d.place(out, cloth(d, d.samples(0.3), rng, 3), 0.36, 0.3)
    return out


@sound("axe_ripped", "motion", peak=-3.0, rate=44100)
def axe_ripped(d, rng, variant):
    """The axe torn out of the hands: a wrench of steel and it is gone."""
    n = d.samples(0.8)
    t = d.time_axis(n)
    wrench = scrape(d, n, rng, d.env_ar(n, 0.004, 0.12), (1500.0, 7000.0), 140.0,
                    resonances=[(2750.0, 10.0, 9.0), (4300.0, 12.0, 7.0)], roughness=0.7)
    out = wrench + 0.9 * unit(d.struck(n, rng, AXE_STEEL, click=0.8, click_band=(2000.0, 10000.0)))
    clank = unit(d.struck(d.samples(0.3), rng, scaled(AXE_STEEL, 1.18, 0.8), click=0.6, click_band=(2000.0, 9000.0)))
    d.place(out, clank, 0.22, 0.55)
    d.place(out, clank, 0.41, 0.25)
    skitter = cracks(d, n, rng, 300.0 * bump(t, 0.3, 0.12), (1200.0, 5000.0), (0.002, 0.006))
    return out + 0.25 * skitter


@sound("slide_bump", "motion", variants=3, peak=-5.0, rate=32000)
def slide_bump(d, rng, variant):
    """Going over a lump in the slope while sliding."""
    n = d.samples(0.32)
    t = d.time_axis(n)
    pack = crush(d, n, rng, np.exp(-t / 0.04), (500.0, 4200.0), -3.0, 180.0, 0.004)
    out = heel(d, n, rng, rng.uniform(58.0, 82.0), 0.1) + 0.6 * pack
    d.place(out, cloth(d, d.samples(0.2), rng, 2), 0.02, 0.25)
    return out


@sound("slide_start", "motion", variants=2, peak=-6.0, rate=32000)
def slide_start(d, rng, variant):
    """Sitting down and letting go: cloth, then the snow starts to move."""
    n = d.samples(0.6)
    t = d.time_axis(n)
    release = crush(d, n, rng, d.env_swell(n, 0.22, sharpness=1.4), (500.0, 5000.0), -3.0, 200.0, 0.004)
    out = release.copy()
    d.place(out, cloth(d, d.samples(0.28), rng, 3), 0.0, 0.6)
    return out + 0.3 * heel(d, n, rng, 60.0, 0.09) * bump(t, 0.03, 0.05)


# =============================================================================
# SKIS AND SPLITBOARD
# =============================================================================

@sound("ski_glide_loop", "motion", rate=32000)
def ski_glide(d, rng, variant):
    """Skis running straight on snow: a smooth, steady hiss."""
    n = d.samples(3.0)
    hiss = d.noise(n, rng, chain(bp(1500, 9000, 1.5), tilt(-3, 4000.0)))
    hiss *= np.maximum(1.0 + 0.12 * d.wander(n, rng, 4.0) + 0.08 * d.wander(n, rng, 17.0), 0.4)
    rumble = d.noise(n, rng, chain(bp(60, 250, 2), tilt(-4)))
    return level(hiss) + 0.28 * level(rumble)


@sound("ski_carve_loop", "motion", rate=32000)
def ski_carve(d, rng, variant):
    """Edges set and skidding: the scrape of a turn or a sideslip."""
    n = d.samples(2.6)
    rate = 34.0 * np.exp(0.3 * d.wander(n, rng, 1.6))
    edge = scrape(d, n, rng, np.ones(n), (700.0, 6500.0), rate, roughness=0.65)
    spray = cracks(d, n, rng, 500.0, (2500.0, 7500.0), (0.001, 0.004), 6, circular=True)
    return level(edge) + 0.3 * level(spray)


@sound("ski_rock_loop", "motion", rate=32000)
def ski_rock(d, rng, variant):
    """Ski bases grinding over rock: the sound of money."""
    n = d.samples(2.2)
    rate = 52.0 * np.exp(0.35 * d.wander(n, rng, 2.0))
    grind = scrape(d, n, rng, np.ones(n), (500.0, 5000.0), rate, resonances=[(1200.0, 4.0, 6.0)], roughness=0.85)
    knocks = d.grain_cloud(n, rng, 24.0, stones(d, rng, 8, 700.0, 2600.0), 0.7, circular=True)
    return level(grind) + 0.5 * level(knocks)


@sound("ski_stop", "motion", variants=2, peak=-4.0, rate=32000)
def ski_stop(d, rng, variant):
    """A hard stop across the slope: a wall of snow thrown up."""
    n = d.samples(0.8)
    t = d.time_axis(n)
    envelope = d.env_ar(n, 0.02, 0.55 + 0.1 * variant)

    def response_at(now):
        e = float(np.exp(-now / 0.25))
        return chain(hp(650.0, 1.5), lp(2600.0 + 5600.0 * e, 1.5), tilt(-2.0, 3000.0))

    wall = unit(d.filt_tv(rng.standard_normal(n), response_at) * envelope)
    wall *= np.maximum(1.0 + 0.3 * d.wander(n, rng, 30.0), 0.2)
    falling = cracks(d, n, rng, 600.0 * bump(t, 0.3, 0.15), (2000.0, 7000.0), (0.002, 0.005))
    return wall + 0.3 * falling


@sound("binding_click", "motion", variants=3, rate=32000)
def binding_click(d, rng, variant):
    """Stepping into a binding: the boot seats, the heel piece snaps shut."""
    n = d.samples(0.34)
    out = np.zeros(n)
    seat = unit(d.noise(d.samples(0.04), rng, bp(1500.0, 6000.0, 1.5)) * d.env_decay(d.samples(0.04), 0.02))
    d.place(out, seat, 0.0, 0.3)
    clack = unit(d.struck(d.samples(0.2), rng, scaled(PLASTIC, rng.uniform(0.9, 1.2)), click=0.8,
                          click_band=(2500.0, 7000.0)))
    d.place(out, clack, 0.07, 1.0)
    spring = unit(d.struck(d.samples(0.15), rng, scaled(CRAMPON_RING, 1.4, 0.4), click=0.3))
    d.place(out, spring, 0.072, 0.22)
    d.place(out, heel(d, d.samples(0.12), rng, 110.0, 0.04), 0.07, 0.4)
    return out


@sound("binding_release", "motion", variants=2, rate=32000)
def binding_release(d, rng, variant):
    """Stepping out: the lever goes down and the binding lets go."""
    n = d.samples(0.36)
    out = np.zeros(n)
    for at, gain in ((0.0, 0.8), (rng.uniform(0.07, 0.1), 1.0)):
        clack = unit(d.struck(d.samples(0.2), rng, scaled(PLASTIC, rng.uniform(0.7, 0.82), 1.2), click=0.6,
                              click_band=(1800.0, 6000.0)))
        d.place(out, clack, at, gain)
    return out


@sound("board_ratchet", "motion", variants=2, rate=44100)
def board_ratchet(d, rng, variant):
    """Splitboard straps: the ratchet clicked tight."""
    n = d.samples(0.55)
    out = np.zeros(n)
    at = 0.0
    gap = 0.07
    teeth = [(1500.0, 1.0, 0.012), (3100.0, 0.6, 0.008), (5200.0, 0.3, 0.006)]
    for _ in range(rng.integers(7, 10)):
        click = unit(d.struck(d.samples(0.03), rng, teeth, click=0.9, click_band=(2500.0, 9000.0), spread=0.04))
        d.place(out, click, at, rng.uniform(0.7, 1.0))
        at += gap * rng.uniform(0.9, 1.1)
        gap = max(0.04, gap * 0.92)
    return out


@sound("ski_drop", "motion", rate=32000)
def ski_drop(d, rng, variant):
    """Skis slapped down flat on the snow, one after the other."""
    n = d.samples(0.5)
    out = np.zeros(n)
    for at, gain in ((0.0, 1.0), (0.13, 0.8)):
        m = d.samples(0.2)
        slap = unit(d.noise(m, rng, bp(300.0, 4000.0, 1.5)) * d.env_decay(m, 0.05))
        slap += 0.6 * unit(d.thump(m, 160.0, 90.0, 0.06))
        slap += 0.3 * unit(d.struck(m, rng, scaled(PLASTIC, 0.7), click=0.3, click_band=(1500.0, 5000.0)))
        d.place(out, slap, at, gain)
    return out


@sound("ski_crash", "motion", variants=2, peak=-4.0, rate=32000)
def ski_crash(d, rng, variant):
    """A fall on skis: snow, a body, and skis clattering after it."""
    duration = 1.3
    n = d.samples(duration)
    t = d.time_axis(n)
    out = 0.6 * crush(d, n, rng, d.env_ar(n, 0.02, 0.4), (700.0, 7000.0), -2.0, 220.0, 0.004)
    at = 0.04
    strength = 1.0
    for _ in range(3):
        m = d.samples(0.4)
        hit = heel(d, m, rng, rng.uniform(48.0, 68.0), 0.16)
        hit = hit + 0.6 * crush(d, m, rng, np.exp(-d.time_axis(m) / 0.05), (500.0, 4000.0), -3.0, 170.0, 0.005)
        d.place(out, hit, at, strength)
        at += rng.uniform(0.25, 0.4)
        strength *= 0.8
    for _ in range(4):
        clack = unit(d.struck(d.samples(0.25), rng, scaled(PLASTIC, rng.uniform(0.55, 0.75), 2.0), click=0.6,
                              click_band=(1500.0, 6000.0)))
        d.place(out, clack, rng.uniform(0.08, duration - 0.4), rng.uniform(0.3, 0.6))
    return out


@sound("ski_land", "motion", variants=2, peak=-4.0, rate=32000)
def ski_land(d, rng, variant):
    """Skis meeting the snow again after air."""
    n = d.samples(0.42)
    t = d.time_axis(n)
    slap = unit(d.noise(n, rng, bp(300.0, 3500.0, 1.5)) * d.env_decay(n, 0.06))
    pack = crush(d, n, rng, np.exp(-t / 0.06), (600.0, 6000.0), -2.0, 220.0, 0.004)
    return heel(d, n, rng, rng.uniform(50.0, 60.0), 0.16) + 0.7 * slap + 0.6 * pack


# =============================================================================
# AIR
# =============================================================================

@sound("air_rush_loop", "motion", rate=22050)
def air_rush(d, rng, variant):
    """Air tearing past the ears at speed: sliding, skiing, falling."""
    n = d.samples(3.2)
    rush = d.noise(n, rng, chain(bp(150, 3200, 1.5), tilt(-4)))
    rush *= np.maximum(1.0 + 0.45 * d.wander(n, rng, 12.0) + 0.2 * d.wander(n, rng, 35.0), 0.15)
    flutter = d.noise(n, rng, chain(bp(40, 160, 2), tilt(-3))) * np.abs(d.wander(n, rng, 18.0))
    return level(rush) + 0.5 * level(flutter)
