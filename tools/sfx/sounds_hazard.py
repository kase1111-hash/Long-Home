"""Avalanches, collapsing snow bridges, falling ice.

These are the sounds that should stop a player where they stand. The
warnings (a whumpf, shooting cracks) are short and close. An avalanche itself
is a release crack and then a roar that the game moves with the debris. A
burial is heard from inside: the game muffles the world and these loops are
already dark.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, hp, lp, tilt
from materials import ICE_BODY, ICE_SHARDS, bump, cracks, crush, heel, scaled, unit
from registry import sound


def level(x: np.ndarray) -> np.ndarray:
    return x / dsp.rms(x)


# =============================================================================
# WARNINGS
# =============================================================================

@sound("whumpf", "hazard", variants=2, rate=22050)
def whumpf(d, rng, variant):
    """The snowpack collapsing underfoot: a deep, soft, travelling thud."""
    n = d.samples(1.0)
    t = d.time_axis(n)
    drop = unit(d.thump(n, 110.0 - 10.0 * variant, 46.0, 0.42))
    air = d.noise(n, rng, chain(bp(90.0, 900.0, 1.5), tilt(-6)))
    air = unit(air * d.env_swell(n, 0.08, sharpness=1.3))
    spread = cracks(d, n, rng, 220.0 * np.exp(-t / 0.16), (600.0, 3000.0), (0.004, 0.01))
    out = dsp.saturate(drop * 1.8, 1.5) + 0.75 * air + 0.22 * spread
    return d.reverb(out, rng, 0.8, 0.14, damping_hz=1200.0, tail=0.4)


@sound("snow_crack", "hazard", variants=2, rate=32000)
def snow_crack(d, rng, variant):
    """Cracks shooting out through the slab from where you stand."""
    n = d.samples(0.75)
    t = d.time_axis(n)
    snap = unit(d.noise(n, rng, bp(1200.0, 9000.0, 1.5)) * d.env_decay(n, 0.008))
    # The tear runs away from you: bright and close at first, duller as it goes
    running = cracks(d, n, rng, 1500.0 * np.exp(-t / 0.13), (1200.0, 7000.0), (0.002, 0.006), 8)
    shape = np.exp(-t / 0.16)

    def response_at(now):
        return lp(900.0 + 8000.0 * float(np.exp(-now / 0.14)), 1.5)

    running = unit(d.filt_tv(running * shape, response_at))
    boom = unit(d.thump(n, 115.0, 50.0, 0.2))
    return snap + 0.8 * running + 0.6 * boom


@sound("slab_release", "hazard", variants=2, peak=-2.0, rate=22050)
def slab_release(d, rng, variant):
    """The slope letting go: a crack like a rifle and the ground starting to move."""
    n = d.samples(1.7)
    t = d.time_axis(n)
    crack = unit(d.noise(n, rng, bp(500.0, 9000.0, 1.5)) * d.env_decay(n, 0.02))
    crack = d.echoes(crack, [(0.11, 0.35, 2600.0), (0.27, 0.2, 1500.0)])[:n]
    boom = unit(d.thump(n, 95.0, 40.0, 0.5))
    moving = d.noise(n, rng, chain(hp(40.0, 2), tilt(-6), lp(1400.0, 1.5)))
    moving = unit(moving * d.env_points(n, [(0.0, 0.0), (0.35, 0.5), (1.1, 1.0), (1.7, 0.7)]))
    blocks = cracks(d, n, rng, 260.0 * bump(t, 0.25, 0.2), (300.0, 2500.0), (0.006, 0.02))
    return crack + 0.9 * dsp.saturate(boom * 1.6, 1.4) + 0.6 * moving + 0.3 * blocks


# =============================================================================
# THE AVALANCHE
# =============================================================================

def block_kernels(d: dsp.At, rng, count: int) -> list:
    """Slabs and blocks of snow colliding: low thuds of different sizes."""
    kernels = []
    for _ in range(count):
        m = d.samples(rng.uniform(0.09, 0.2))
        pitch = rng.uniform(42.0, 95.0)
        kernels.append(unit(heel(d, m, rng, pitch, rng.uniform(0.07, 0.16))))
    return kernels


@sound("avalanche_roar_loop", "hazard", rms=-17.0, rate=22050)
def avalanche_roar(d, rng, variant):
    """An avalanche in motion, close: a roar with blocks grinding in it and powder hissing over."""
    n = d.samples(5.0)
    rumble = d.noise(n, rng, chain(hp(34.0, 2), tilt(-7), lp(2200.0, 1.5)))
    rumble *= np.maximum(1.0 + 0.3 * d.wander(n, rng, 1.6), 0.3)
    roar = d.noise(n, rng, chain(bp(200.0, 1400.0, 1.5), tilt(-4)))
    roar *= np.maximum(1.0 + 0.4 * d.wander(n, rng, 2.4) + 0.2 * d.wander(n, rng, 9.0), 0.2)
    powder = d.noise(n, rng, chain(bp(1800.0, 6000.0, 1.5), tilt(-3)))
    powder *= np.maximum(1.0 + 0.3 * d.wander(n, rng, 5.0), 0.3)
    blocks = d.grain_cloud(n, rng, 14.0, block_kernels(d, rng, 8), 0.6, circular=True)
    return level(rumble) + 0.7 * level(roar) + 0.2 * level(powder) + 0.75 * level(blocks)


@sound("avalanche_inside_loop", "hazard", rms=-17.0, rate=22050)
def avalanche_inside(d, rng, variant):
    """Carried in the flow: everything close, dark and violent."""
    n = d.samples(4.0)
    churn = d.noise(n, rng, chain(hp(36.0, 2), tilt(-6), lp(700.0, 1.5)))
    churn *= np.maximum(1.0 + 0.5 * d.wander(n, rng, 3.0), 0.15)
    grind = d.noise(n, rng, chain(bp(300.0, 1500.0, 1.5), tilt(-4)))
    grind *= 0.3 + unit(d.smooth(d.stick_slip(n, rng, 22.0, 0.6), 0.02))
    knocks = d.grain_cloud(n, rng, 6.0, block_kernels(d, rng, 6), 0.5, circular=True)
    return level(churn) + 0.5 * level(grind) + 0.9 * level(knocks)


@sound("debris_settle", "hazard", variants=2, peak=-8.0, rate=22050)
def debris_settle(d, rng, variant):
    """The debris stopping and setting: creaks, pops, the last grains running."""
    n = d.samples(1.9)
    t = d.time_axis(n)
    pops = cracks(d, n, rng, 3.0 + 26.0 * np.exp(-t / 0.5), (300.0, 1500.0), (0.02, 0.06), 6)
    trickle = cracks(d, n, rng, 12.0 + 160.0 * np.exp(-t / 0.45), (900.0, 5000.0), (0.003, 0.008))
    sigh = unit(d.noise(n, rng, chain(bp(200.0, 2200.0, 1.5), tilt(-5))) * d.env_ar(n, 0.05, 1.2))
    return pops + 0.5 * trickle + 0.25 * sigh


# =============================================================================
# ICE
# =============================================================================

@sound("serac_fall", "hazard", variants=2, peak=-2.0, rate=22050)
def serac_fall(d, rng, variant):
    """A serac coming off the icefall: a gunshot crack, then tons of ice."""
    duration = 3.8 + 0.5 * variant
    n = d.samples(duration)
    t = d.time_axis(n)
    out = np.zeros(n)
    shot = unit(d.noise(d.samples(0.3), rng, bp(700.0, 9500.0, 1.5)) * d.env_decay(d.samples(0.3), 0.018))
    shot = d.echoes(shot, [(0.26, 0.4, 2600.0), (0.57, 0.24, 1500.0), (0.96, 0.12, 900.0)])
    d.place(out, shot, 0.0, 1.0)
    # Blocks breaking away: slow at first, then all at once
    at = 0.35
    gap = 0.34
    while at < duration - 1.6:
        m = d.samples(0.5)
        block = heel(d, m, rng, rng.uniform(38.0, 70.0), rng.uniform(0.18, 0.3))
        shatter = cracks(d, m, rng, 500.0 * np.exp(-d.time_axis(m) / 0.07), (1800.0, 8000.0), (0.002, 0.006))
        d.place(out, dsp.saturate(block * 1.5, 1.4) + 0.4 * shatter, at, rng.uniform(0.55, 0.95))
        at += gap * rng.uniform(0.7, 1.3)
        gap = max(0.09, gap * 0.82)
    rumble = d.noise(n, rng, chain(hp(36.0, 2), tilt(-6), lp(1100.0, 1.5)))
    rumble = unit(rumble * d.env_points(n, [(0.0, 0.0), (0.5, 0.25), (1.6, 1.0), (duration, 0.0)], curve=1.4))
    tinkle = cracks(d, n, rng, 120.0 * bump(t, 2.0, 0.8), (3000.0, 9000.0), (0.001, 0.004), 6)
    out += 0.7 * rumble + 0.15 * tinkle
    return d.reverb(out, rng, 1.6, 0.22, damping_hz=1800.0, tail=0.9)


@sound("bridge_collapse", "hazard", variants=2, peak=-3.0, rate=22050)
def bridge_collapse(d, rng, variant):
    """A snow bridge going: the floor drops and the pieces fall a long way."""
    n = d.samples(1.6)
    t = d.time_axis(n)
    out = np.zeros(n)
    give = unit(d.thump(n, 120.0, 48.0, 0.3))
    air = unit(d.noise(n, rng, chain(bp(100.0, 1100.0, 1.5), tilt(-5))) * d.env_swell(n, 0.07, sharpness=1.3))
    crust = cracks(d, n, rng, 900.0 * np.exp(-t / 0.06), (900.0, 5500.0), (0.003, 0.008))
    out += dsp.saturate(give * 1.6, 1.4) + 0.7 * air + 0.5 * crust
    # Blocks hitting the walls on the way down, each one deeper and duller
    at = 0.25
    gain = 0.6
    cutoff = 3800.0
    for _ in range(5):
        m = d.samples(0.3)
        hit = heel(d, m, rng, rng.uniform(60.0, 100.0), 0.1)
        hit = hit + 0.6 * crush(d, m, rng, np.exp(-d.time_axis(m) / 0.04), (400.0, cutoff), -3.0, 160.0, 0.005)
        d.place(out, d.filt(hit, lp(cutoff, 1.5)), at, gain)
        at += rng.uniform(0.14, 0.28)
        gain *= 0.72
        cutoff *= 0.72
    tinkle = cracks(d, n, rng, 70.0 * bump(t, 0.7, 0.3), (3500.0, 9000.0), (0.001, 0.004), 5)
    out += 0.12 * tinkle
    return d.reverb(out, rng, 1.7, 0.3, damping_hz=2400.0, predelay=0.02, tail=1.1)


@sound("crevasse_ambience_loop", "hazard", rms=-26.0, rate=22050)
def crevasse_ambience(d, rng, variant):
    """Inside a crevasse: water dripping somewhere, the ice ticking, wind far above."""
    n = d.samples(7.0)
    # Drips: a short rising chirp each, ringing in the slot
    drip_train = np.zeros(n)
    count = 7
    for at in np.sort(rng.uniform(0.2, 6.6, size=count)):
        drip_train[d.samples(at)] = rng.uniform(0.4, 1.0)
    drips = np.zeros(n)
    hits_at = np.flatnonzero(drip_train)
    choice = rng.integers(0, 3, size=len(hits_at))
    for k in range(3):
        m = d.samples(0.05)
        j = d.time_axis(m)
        base = rng.uniform(1300.0, 2100.0)
        chirp = np.sin(dsp.TAU * np.cumsum(base * (1.0 + 0.35 * j / 0.05)) / d.sr) * d.env_decay(m, 0.035)
        chirp[:20] *= np.arange(20) / 20.0
        train = np.zeros(n)
        train[hits_at[choice == k]] = drip_train[hits_at[choice == k]]
        drips += d.scatter(train, chirp, circular=True)
    room = d.reverb_ir(rng, 1.5, damping_hz=3000.0, predelay=0.012)
    wet = d.scatter(drips, room, circular=True)
    drips = drips + 2.4 * wet

    hollow = (d.narrowband(n, rng, 68.0, 10.0, circular=True)
              + 0.7 * d.narrowband(n, rng, 113.0, 14.0, circular=True)
              + 0.4 * d.narrowband(n, rng, 171.0, 20.0, circular=True))
    hollow *= 0.6 + 0.4 * d.wander01(n, rng, 0.3)
    above = d.noise(n, rng, chain(bp(110.0, 520.0, 2), tilt(-6)))
    above *= 0.6 + 0.4 * d.wander01(n, rng, 0.4)
    ticks = cracks(d, n, rng, 1.6, (2500.0, 8000.0), (0.004, 0.012), 5, circular=True)
    ticks = ticks + 1.5 * d.scatter(ticks, room, circular=True)
    return level(hollow) + 0.8 * level(above) + 1.1 * drips / (dsp.rms(drips) + 1e-9) + 0.35 * unit(ticks)


@sound("ice_groan", "hazard", variants=2, peak=-6.0, rate=16000)
def ice_groan(d, rng, variant):
    """The glacier moving around you, heard from inside it."""
    duration = 2.0 + 0.5 * variant
    n = d.samples(duration)
    t = d.time_axis(n)
    rate = (26.0, 34.0)[variant] * np.exp(-0.5 * t / duration)
    pulses = d.stick_slip(n, rng, rate, 0.3) * d.env_swell(n, duration * 0.4, sharpness=1.2)
    body = scaled(ICE_BODY, rng.uniform(0.75, 0.95), 1.4)
    kernel = d.modal(d.samples(0.25), body)
    groan = unit(d.convolve(pulses, kernel))
    tick = unit(d.struck(d.samples(0.05), rng, ICE_SHARDS, click=0.8, click_band=(2500.0, 9500.0)))
    d.place(groan, tick, rng.uniform(0.3, duration * 0.6), 0.25)
    return d.reverb(groan, rng, 1.8, 0.35, damping_hz=2000.0, tail=1.1)
