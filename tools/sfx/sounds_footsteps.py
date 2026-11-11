"""Footsteps for every surface, with and without crampons, and foot slips.

A step is a heel strike, a roll of the foot and a push off: three bursts of
whatever the ground is made of. Snow is crushed in rough bursts with a few
sharp cracks on top (duller and longer the softer the snow); rock is a thud
with grit; scree is small stones knocking together; crampons add steel.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, lp, peak, tilt
from materials import (CRAMPON_RING, CRAMPON_STEEL, SOLE_ON_ICE, SOLE_ON_ROCK, bump, cracks, crush,
                       heel, hits, stones, unit)
from registry import sound


def step_shape(t: np.ndarray, rng, toe: float = 0.3) -> np.ndarray:
    """Heel, roll and toe of one walking step, with a little natural variation."""
    stretch = rng.uniform(0.9, 1.12)
    return (bump(t, 0.03, 0.028) + rng.uniform(0.5, 0.7) * bump(t, 0.13 * stretch, 0.07)
            + toe * bump(t, 0.29 * stretch, 0.045))


# =============================================================================
# SNOW
# =============================================================================

@sound("footstep_snow_firm", "footsteps", variants=5, rate=32000)
def snow_firm(d, rng, variant):
    """Firm snow: a dry crunch with a faint squeak of cold crystals."""
    n = d.samples(0.42)
    t = d.time_axis(n)
    shape = step_shape(t, rng)
    body = crush(d, n, rng, shape, (900.0, 6000.0), -2.0, 190.0, 0.004)
    detail = cracks(d, n, rng, 650.0 * shape, (1500.0, 6500.0), (0.002, 0.006))

    # Cold snow squeaks as the crystals shear under the sole
    ratio = rng.uniform(0.88, 1.15)
    rate = 170.0 * ratio * (1.0 + 0.25 * d.wander(n, rng, 9.0))
    pulses = d.stick_slip(n, rng, rate, 0.4) * bump(t, 0.14, 0.05)
    voice = d.modal(d.samples(0.02), [(880.0 * ratio, 1.0, 0.01), (1320.0 * ratio, 0.6, 0.008),
                                      (2100.0 * ratio, 0.3, 0.006)])
    squeak = unit(d.convolve(pulses, voice))

    out = body + 0.55 * detail + 0.14 * squeak + 0.42 * heel(d, n, rng, 70.0, 0.09)
    return d.filt(out, lp(9500, 1.5), causal=True)


@sound("footstep_snow_soft", "footsteps", variants=4, rate=22050)
def snow_soft(d, rng, variant):
    """Soft snow: the foot sinks; a muffled, longer crunch."""
    n = d.samples(0.52)
    t = d.time_axis(n)
    shape = bump(t, 0.05, 0.05) + 0.75 * bump(t, 0.2, 0.1) + 0.23 * bump(t, 0.38, 0.06)
    body = crush(d, n, rng, shape, (350.0, 2800.0), -4.0, 110.0, 0.008)
    detail = cracks(d, n, rng, 220.0 * shape, (500.0, 2400.0), (0.006, 0.014))
    displaced = d.noise(n, rng, chain(bp(280, 2600, 1.5), tilt(-5)))
    displaced = unit(displaced * d.env_swell(n, 0.12, sharpness=1.4))
    out = body + 0.35 * detail + 0.5 * displaced + 0.7 * heel(d, n, rng, 52.0, 0.14)
    return d.filt(out, lp(5200, 1.5), causal=True)


@sound("footstep_snow_powder", "footsteps", variants=3, rate=22050)
def snow_powder(d, rng, variant):
    """Powder: almost nothing; a soft push of displaced snow."""
    n = d.samples(0.4)
    t = d.time_axis(n)
    push = d.noise(n, rng, chain(bp(320, 3200, 1.5), tilt(-6)))
    push = unit(push * d.env_swell(n, 0.1, sharpness=1.5))
    grains = cracks(d, n, rng, 160.0 * bump(t, 0.1, 0.08), (700.0, 2500.0), (0.005, 0.012), 6)
    return push + 0.3 * grains + 0.35 * heel(d, n, rng, 48.0, 0.1)


# =============================================================================
# ICE, ROCK, SCREE
# =============================================================================

@sound("footstep_ice", "footsteps", variants=3, rate=32000)
def ice(d, rng, variant):
    """A boot sole on bare ice: a hard tap and the start of a skid."""
    n = d.samples(0.26)
    t = d.time_axis(n)
    tap = unit(d.struck(n, rng, SOLE_ON_ICE, click=0.8, click_band=(2000.0, 8000.0), spread=0.06))
    rough = unit(d.smooth(d.stick_slip(n, rng, 300.0, 0.5), 0.0012))
    skid = d.noise(n, rng, chain(bp(2200, 7500, 1.5), tilt(-2, 4000.0)))
    skid = unit(skid * d.env_ar(n, 0.008, 0.12) * (0.3 + rough))
    crackle = cracks(d, n, rng, 110.0 * np.exp(-t / 0.05), (3500.0, 8500.0), (0.001, 0.004), 5)
    return tap + 0.32 * skid + 0.25 * crackle + 0.4 * unit(d.thump(n, 150.0, 85.0, 0.045))


@sound("footstep_rock", "footsteps", variants=4, rate=32000)
def rock(d, rng, variant):
    """A boot on dry rock: a dull knock and grit under the sole."""
    n = d.samples(0.22)
    t = d.time_axis(n)
    shape = np.exp(-t / 0.03) + 0.3 * bump(t, 0.11, 0.03)
    grit = crush(d, n, rng, shape, (1500.0, 7000.0), -1.0, 260.0, 0.0025)
    detail = cracks(d, n, rng, 450.0 * shape, (1800.0, 6500.0), (0.002, 0.005))
    knock = unit(d.struck(n, rng, SOLE_ON_ROCK, click=0.3, click_band=(900.0, 5000.0), spread=0.06))
    return 0.8 * heel(d, n, rng, 92.0, 0.06) + 0.55 * grit + 0.35 * detail + 0.45 * knock


@sound("footstep_rock_wet", "footsteps", variants=2, rate=32000)
def rock_wet(d, rng, variant):
    """Wet rock: the same knock with a slap of water in it."""
    n = d.samples(0.24)
    t = d.time_axis(n)
    grit = crush(d, n, rng, np.exp(-t / 0.03), (1200.0, 5000.0), -2.0, 220.0, 0.003)
    slap = unit(d.noise(n, rng, bp(600, 3200, 1.5)) * d.env_ar(n, 0.002, 0.045))
    drop = d.modal(d.samples(0.03), [(1900.0 * rng.uniform(0.85, 1.2), 1.0, 0.02)])
    out = 0.8 * heel(d, n, rng, 88.0, 0.06) + 0.32 * grit + 0.45 * slap
    d.place(out, drop, rng.uniform(0.03, 0.09), 0.1)
    return out


@sound("footstep_scree", "footsteps", variants=4, rate=32000)
def scree(d, rng, variant):
    """Loose stones shifting and settling under the boot."""
    n = d.samples(0.5)
    t = d.time_axis(n)
    shape = np.exp(-t / 0.08) + 0.4 * bump(t, 0.2, 0.09)
    density = 420.0 * np.exp(-t / 0.06) + 160.0 * bump(t, 0.2, 0.09) + 55.0 * np.exp(-np.maximum(t - 0.3, 0.0) / 0.1)
    clatter = unit(d.grain_cloud(n, rng, density, stones(d, rng, 9, 900.0, 3800.0), 0.8))
    gravel = crush(d, n, rng, shape, (500.0, 4500.0), -2.0, 150.0, 0.005)
    return clatter + 0.6 * gravel + 0.4 * heel(d, n, rng, 70.0, 0.07)


# =============================================================================
# LOW GROUND
# =============================================================================

@sound("footstep_grass", "footsteps", variants=2, rate=32000)
def grass(d, rng, variant):
    """Alpine turf: a soft swish and a muffled thud."""
    n = d.samples(0.3)
    t = d.time_axis(n)
    swish = d.noise(n, rng, chain(bp(1500, 6000, 1.5), tilt(-3)))
    swish = unit(swish * d.env_swell(n, 0.06, sharpness=1.5) * (1.0 + 0.4 * d.wander(n, rng, 60.0)))
    blades = cracks(d, n, rng, 180.0 * bump(t, 0.07, 0.05), (2200.0, 6000.0), (0.002, 0.005), 5)
    return swish + 0.3 * blades + 0.55 * heel(d, n, rng, 60.0, 0.08)


@sound("footstep_mud", "footsteps", variants=2, rate=22050)
def mud(d, rng, variant):
    """Mud: a squelch going in and a suck coming out."""
    n = d.samples(0.42)
    t = d.time_axis(n)
    squish = crush(d, n, rng, d.env_ar(n, 0.01, 0.2), (250.0, 2800.0), -5.0, 60.0, 0.009)
    press = unit(d.narrowband(n, rng, 220.0 + 380.0 * np.exp(-t / 0.07), 280.0) * d.env_ar(n, 0.01, 0.18))
    suck_centre = 240.0 + 420.0 * np.clip((t - 0.24) / 0.1, 0.0, 1.0)
    suck = unit(d.narrowband(n, rng, suck_centre, 260.0) * bump(t, 0.3, 0.035))
    wet = cracks(d, n, rng, 45.0 + 60.0 * bump(t, 0.3, 0.04), (800.0, 2500.0), (0.004, 0.01), 5)
    return squish + 0.5 * press + 0.4 * suck + 0.25 * wet + 0.5 * heel(d, n, rng, 58.0, 0.09)


# =============================================================================
# CRAMPONS
# =============================================================================

@sound("crampon_ice", "footsteps", variants=4, rate=44100)
def crampon_ice(d, rng, variant):
    """Crampon points biting ice: a crisp steel tick and chips of ice."""
    n = d.samples(0.26)
    t = d.time_axis(n)
    steel = hits(d, n, rng, CRAMPON_STEEL, 3, 0.007)
    chips = cracks(d, n, rng, 520.0 * np.exp(-t / 0.04), (3000.0, 8500.0), (0.001, 0.004), 6)
    bite = crush(d, n, rng, np.exp(-t / 0.02), (900.0, 4500.0), -2.0, 300.0, 0.002)
    return steel + 0.5 * chips + 0.4 * bite + 0.35 * unit(d.thump(n, 160.0, 85.0, 0.05))


@sound("crampon_rock", "footsteps", variants=3, rate=44100)
def crampon_rock(d, rng, variant):
    """Crampons on rock: steel ringing and scraping for purchase."""
    n = d.samples(0.32)
    clink = hits(d, n, rng, CRAMPON_RING, 2, 0.012, click=0.7)
    rough = unit(d.smooth(d.stick_slip(n, rng, rng.uniform(180.0, 260.0), 0.45), 0.0015))
    scrape = d.noise(n, rng, chain(bp(2200, 7500, 1.5), peak(2890, 12, 9), peak(4350, 14, 8)))
    scrape = unit(scrape * d.env_ar(n, 0.005, 0.14) * (0.25 + rough))
    return clink + 0.55 * scrape + 0.4 * heel(d, n, rng, 95.0, 0.05)


@sound("crampon_snow", "footsteps", variants=3, rate=44100)
def crampon_snow(d, rng, variant):
    """Crampons in firm snow: points punching the crust, then the crunch."""
    n = d.samples(0.4)
    t = d.time_axis(n)
    shape = step_shape(t, rng, toe=0.25)
    body = crush(d, n, rng, shape, (1200.0, 7000.0), -2.0, 230.0, 0.003)
    crust = cracks(d, n, rng, 800.0 * shape, (1800.0, 6500.0), (0.0015, 0.005), 8)
    steel = hits(d, n, rng, CRAMPON_STEEL, 2, 0.006, click=0.5)
    out = body + 0.6 * crust + 0.2 * steel + 0.4 * heel(d, n, rng, 72.0, 0.08)
    return d.filt(out, lp(10000, 1.5), causal=True)


# =============================================================================
# SLIPS
# =============================================================================

@sound("slip_snow", "footsteps", variants=2, rate=32000)
def slip_snow(d, rng, variant):
    """A foot shooting out on snow: a quick dry skid."""
    n = d.samples(0.3)
    t = d.time_axis(n)
    shape = d.env_ar(n, 0.012, 0.2)
    skid = crush(d, n, rng, shape, (900.0, 5200.0), -3.0, 240.0, 0.003)
    grains = cracks(d, n, rng, 1400.0 * np.exp(-t / 0.09), (1500.0, 6000.0), (0.002, 0.006), 6)
    return skid + 0.6 * grains


@sound("slip_ice", "footsteps", variants=2, rate=32000)
def slip_ice(d, rng, variant):
    """Points skating off ice: a chattering scrape of steel."""
    n = d.samples(0.34)
    t = d.time_axis(n)
    chatter = unit(d.smooth(d.stick_slip(n, rng, 95.0 + 80.0 * t / 0.34, 0.5), 0.001))
    scrape = d.noise(n, rng, chain(bp(2000, 7000, 2), peak(3000, 10, 9), peak(4300, 12, 7)))
    scrape = unit(scrape * d.env_ar(n, 0.006, 0.24) * (0.15 + chatter))
    chips = cracks(d, n, rng, 260.0 * np.exp(-t / 0.1), (3000.0, 7500.0), (0.001, 0.004), 5)
    return scrape + 0.35 * chips


@sound("slip_rock", "footsteps", variants=2, rate=32000)
def slip_rock(d, rng, variant):
    """A sole skidding on rock, and the pebbles it sends off."""
    n = d.samples(0.36)
    t = d.time_axis(n)
    rough = unit(d.smooth(d.stick_slip(n, rng, 240.0, 0.4), 0.0012))
    skid = d.noise(n, rng, chain(bp(700, 4200, 1.5), tilt(-2)))
    skid = unit(skid * d.env_ar(n, 0.008, 0.16) * (0.3 + rough))
    pebbles = unit(d.grain_cloud(n, rng, 60.0 * bump(t, 0.16, 0.08), stones(d, rng, 6, 1400.0, 4200.0), 0.7))
    return skid + 0.5 * pebbles
