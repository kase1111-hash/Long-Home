"""Rope, hardware and tools: the mechanical feedback of mountaineering.

Rope is friction with a ripple in it (the weave passing over an edge) and it
creaks under load. Hardware is small pieces of aluminium and steel touching.
The axe and the probe tell you what they went into.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, lp, tilt
from materials import (ALUMINIUM, AXE_STEEL, CRAMPON_RING, CRAMPON_STEEL, ICE_SHARDS, NYLON, ROCK,
                       SHOVEL_BLADE, bump, cloth, cracks, creak, crush, heel, hits, scaled, scrape,
                       stones, swish, unit)
from registry import sound


def level(x: np.ndarray) -> np.ndarray:
    return x / dsp.rms(x)


def rope_friction(d: dsp.At, n: int, rng, shape: np.ndarray, ripple_hz, depth: float = 0.5,
                  band: tuple = (1500.0, 6500.0)) -> np.ndarray:
    """Rope running over metal or rock: a hiss with the weave rippling in it."""
    ripple = d.narrowband(n, rng, ripple_hz, 18.0, circular=True)
    hiss = d.noise(n, rng, chain(bp(band[0], band[1], 1.5), tilt(-2, 3000.0)))
    return unit(hiss * shape * np.maximum(1.0 + depth * ripple, 0.1))


def tink(d: dsp.At, rng, partials, factor: float, ring: float = 1.0, click: float = 0.7) -> np.ndarray:
    """One small piece of metal touching another."""
    return unit(d.struck(d.samples(0.16 * ring + 0.02), rng, scaled(partials, factor, ring), click=click,
                         click_band=(3000.0, 12000.0), click_t60=0.003, spread=0.04))


# =============================================================================
# CARABINERS AND HARDWARE
# =============================================================================

@sound("carabiner_clip", "gear", variants=3, rate=44100)
def carabiner_clip(d, rng, variant):
    """A carabiner gate opening and snapping shut."""
    n = d.samples(0.22)
    out = np.zeros(n)
    factor = rng.uniform(0.92, 1.1)
    d.place(out, tink(d, rng, ALUMINIUM, factor, 0.6, click=0.5), 0.0, 0.55)
    d.place(out, tink(d, rng, ALUMINIUM, factor * 1.04, 1.0, click=0.9), rng.uniform(0.022, 0.034), 1.0)
    return out


@sound("carabiner_unclip", "gear", variants=2, rate=44100)
def carabiner_unclip(d, rng, variant):
    """Unclipping: the gate pressed open, the rope sliding out, the gate back."""
    n = d.samples(0.3)
    out = np.zeros(n)
    factor = rng.uniform(0.92, 1.08)
    d.place(out, tink(d, rng, ALUMINIUM, factor, 0.5, click=0.4), 0.0, 0.5)
    slide = rope_friction(d, d.samples(0.12), rng, d.env_swell(d.samples(0.12), 0.05), 150.0)
    d.place(out, slide, 0.03, 0.28)
    d.place(out, tink(d, rng, ALUMINIUM, factor * 1.03, 0.9, click=0.8), rng.uniform(0.13, 0.17), 0.9)
    return out


@sound("gear_jingle", "gear", variants=3, peak=-6.0, rate=44100)
def gear_jingle(d, rng, variant):
    """The rack on the harness: nuts, screws and carabiners knocking together."""
    n = d.samples(0.7)
    out = np.zeros(n)
    at = 0.0
    for _ in range(rng.integers(4, 7)):
        metal = ALUMINIUM if rng.random() < 0.6 else CRAMPON_STEEL
        d.place(out, tink(d, rng, metal, rng.uniform(0.75, 1.35), rng.uniform(0.6, 1.2)), at, rng.uniform(0.4, 1.0))
        at += rng.uniform(0.03, 0.13)
    return out


@sound("sling_swish", "gear", variants=2, peak=-8.0, rate=32000)
def sling_swish(d, rng, variant):
    """Webbing pulled through the hands and draped over rock."""
    n = d.samples(0.4)
    shape = d.env_swell(n, 0.13, sharpness=1.4)
    return rope_friction(d, n, rng, shape, rng.uniform(180.0, 260.0), 0.35, (900.0, 5000.0))


# =============================================================================
# ROPE
# =============================================================================

@sound("rope_uncoil", "gear", variants=2, peak=-7.0, rate=32000)
def rope_uncoil(d, rng, variant):
    """Flaking the rope out: coils sliding over each other and dropping."""
    n = d.samples(1.15)
    t = d.time_axis(n)
    shape = np.zeros(n)
    at = 0.08
    drops = []
    while at < 0.95:
        shape += rng.uniform(0.5, 1.0) * bump(t, at, rng.uniform(0.05, 0.09))
        drops.append(at + 0.08)
        at += rng.uniform(0.2, 0.3)
    out = rope_friction(d, n, rng, shape, 95.0, 0.4, (700.0, 4500.0))
    for drop in drops:
        d.place(out, heel(d, d.samples(0.15), rng, rng.uniform(70.0, 95.0), 0.06), drop, 0.3)
    return out


@sound("rope_throw", "gear", variants=2, peak=-6.0, rate=32000)
def rope_throw(d, rng, variant):
    """The ends thrown clear: a whoosh, then rope slapping down the face."""
    n = d.samples(1.4)
    out = np.zeros(n)
    d.place(out, swish(d, d.samples(0.5), rng, 380.0, 1900.0, 0.2), 0.0, 1.0)
    at = 0.45
    gain = 0.7
    cutoff = 3500.0
    for _ in range(4):
        m = d.samples(0.12)
        slap = unit(d.noise(m, rng, bp(450.0, cutoff, 1.5)) * d.env_decay(m, 0.04))
        d.place(out, slap, at, gain)
        at += rng.uniform(0.13, 0.26)
        gain *= 0.65
        cutoff *= 0.75
    return out


@sound("rope_thread", "gear", variants=2, peak=-7.0, rate=32000)
def rope_thread(d, rng, variant):
    """Pulling the rope through the anchor, arm over arm."""
    n = d.samples(0.95)
    t = d.time_axis(n)
    shape = bump(t, 0.2, 0.1) + 0.9 * bump(t, 0.62, 0.11)
    return rope_friction(d, n, rng, shape, 110.0 * (1.0 + 0.1 * d.wander(n, rng, 3.0)), 0.5)


@sound("rope_run_loop", "gear", rate=32000)
def rope_run(d, rng, variant):
    """Rope running through the belay device on rappel."""
    n = d.samples(2.4)
    ripple = 120.0 * np.exp(0.1 * d.wander(n, rng, 2.0))
    run = rope_friction(d, n, rng, np.ones(n), ripple, 0.45, (1800.0, 7500.0))
    device = d.narrowband(n, rng, 3400.0, 240.0, circular=True)
    rub = d.noise(n, rng, chain(bp(200, 620, 2), tilt(-3)))
    return level(run) + 0.14 * level(device) + 0.25 * level(rub)


@sound("rope_creak", "gear", variants=3, peak=-6.0, rate=22050)
def rope_creak(d, rng, variant):
    """Rope taking weight: nylon stretching and settling."""
    duration = (0.4, 0.55, 0.62)[variant]
    n = d.samples(duration)
    t = d.time_axis(n)
    start, end = ((60.0, 120.0), (130.0, 70.0), (85.0, 55.0))[variant]
    rate = start + (end - start) * t / duration
    return creak(d, n, rng, rate, scaled(NYLON, rng.uniform(1.5, 1.9)), d.env_swell(n, duration * 0.4), 0.3)


@sound("rope_tug", "gear", variants=2, peak=-6.0, rate=22050)
def rope_tug(d, rng, variant):
    """Testing the anchor: two hard pulls on the rope."""
    n = d.samples(0.6)
    out = np.zeros(n)
    for at in (0.0, rng.uniform(0.24, 0.3)):
        m = d.samples(0.2)
        pull = creak(d, m, rng, rng.uniform(90.0, 140.0), scaled(NYLON, 1.1), d.env_swell(m, 0.04), 0.3)
        d.place(out, pull, at, 0.8)
        d.place(out, heel(d, d.samples(0.15), rng, 90.0, 0.06), at + 0.05, 0.45)
    return out


@sound("rope_jam", "gear", variants=2, peak=-4.0, rate=22050)
def rope_jam(d, rng, variant):
    """The rope snagging: it stops dead and goes tight."""
    n = d.samples(0.5)
    t = d.time_axis(n)
    catch = unit(d.thump(n, 200.0, 90.0, 0.08))
    strain = creak(d, n, rng, 150.0 - 180.0 * t, scaled(NYLON, 1.2), d.env_ar(n, 0.01, 0.2), 0.25)
    twang = unit(d.narrowband(n, rng, 180.0, 22.0) * d.env_decay(n, 0.22))
    return catch + 0.7 * strain + 0.3 * twang


@sound("rope_flick", "gear", variants=2, peak=-7.0, rate=32000)
def rope_flick(d, rng, variant):
    """Flicking the rope to free it: a whip of slack running up the line."""
    n = d.samples(0.34)
    out = swish(d, n, rng, 600.0, 3100.0, 0.11)
    m = d.samples(0.1)
    slap = unit(d.noise(m, rng, bp(600.0, 4000.0, 1.5)) * d.env_decay(m, 0.03))
    d.place(out, slap, 0.2, 0.5)
    return out


@sound("rope_pull_loop", "gear", rate=32000)
def rope_pull(d, rng, variant):
    """Pulling the rope down after a rappel, hand over hand."""
    pulls = 4
    period = 0.66
    duration = pulls * period
    n = d.samples(duration)
    t = d.time_axis(n)
    shape = np.zeros(n)
    for k in range(pulls):
        # Distance to each pull measured round the loop, so the end meets the start
        away = np.abs(t - (k + 0.45) * period)
        away = np.minimum(away, duration - away)
        shape += rng.uniform(0.75, 1.0) * np.exp(-0.5 * (away / 0.13) ** 2)
    shape = np.maximum(shape, 0.06)
    return rope_friction(d, n, rng, shape, 100.0, 0.45, (1200.0, 6000.0))


@sound("rope_fall", "gear", variants=2, peak=-6.0, rate=32000)
def rope_fall(d, rng, variant):
    """The rope's end whipping through the anchor and the whole length coming down."""
    n = d.samples(1.4)
    out = np.zeros(n)
    m = d.samples(0.3)
    t = d.time_axis(m)
    zip_out = rope_friction(d, m, rng, d.env_swell(m, 0.2, sharpness=1.2), 120.0 + 500.0 * t / 0.3, 0.5)
    d.place(out, zip_out, 0.0, 0.7)
    d.place(out, swish(d, d.samples(0.55), rng, 300.0, 1500.0, 0.3), 0.22, 0.8)
    at = 0.7
    gain = 0.8
    for _ in range(4):
        k = d.samples(0.2)
        land = heel(d, k, rng, rng.uniform(70.0, 100.0), 0.07)
        land = land + 0.6 * unit(d.noise(k, rng, bp(500.0, 3500.0, 1.5)) * d.env_decay(k, 0.05))
        d.place(out, land, at, gain)
        at += rng.uniform(0.09, 0.2)
        gain *= 0.7
    return out


@sound("rope_knot", "gear", peak=-5.0, rate=22050)
def rope_knot(d, rng, variant):
    """The knot at the end of the rope arriving in the device."""
    n = d.samples(0.4)
    t = d.time_axis(n)
    stop = unit(d.thump(n, 170.0, 80.0, 0.09))
    strain = creak(d, n, rng, 110.0 - 120.0 * t, scaled(NYLON, 1.0), d.env_ar(n, 0.01, 0.18), 0.25)
    out = stop + 0.6 * strain
    d.place(out, tink(d, rng, ALUMINIUM, 0.85, 0.5), 0.004, 0.2)
    return out


# =============================================================================
# ANCHORS
# =============================================================================

@sound("anchor_rock", "gear", variants=2, peak=-5.0, rate=44100)
def anchor_rock(d, rng, variant):
    """A nut seated in a crack: a scrape of metal on stone and two taps home."""
    n = d.samples(1.3)
    out = np.zeros(n)
    m = d.samples(0.28)
    seat = scrape(d, m, rng, d.env_swell(m, 0.12), (1800.0, 7000.0), 160.0,
                  resonances=[(3150.0, 9.0, 8.0), (4980.0, 10.0, 6.0)], roughness=0.7)
    d.place(out, seat, 0.0, 0.55)
    for at in (0.36, 0.56):
        tap = unit(d.struck(d.samples(0.15), rng, scaled(ROCK, 1.5), click=0.6, click_band=(1500.0, 7000.0)))
        d.place(out, tap, at, 0.7)
        d.place(out, tink(d, rng, ALUMINIUM, 0.9, 0.5), at + 0.003, 0.45)
    jingle = np.zeros(d.samples(0.4))
    for k in range(3):
        d.place(jingle, tink(d, rng, ALUMINIUM, rng.uniform(0.8, 1.3), 0.8), 0.08 * k + rng.uniform(0.0, 0.03), 0.6)
    d.place(out, jingle, 0.82, 0.5)
    return out


@sound("anchor_ice", "gear", variants=2, peak=-5.0, rate=32000)
def anchor_ice(d, rng, variant):
    """An ice screw winding in: the teeth bite, then crunch and squeak, turn by turn."""
    n = d.samples(1.6)
    t = d.time_axis(n)
    out = np.zeros(n)
    bite = cracks(d, d.samples(0.12), rng, 700.0, (3000.0, 9000.0), (0.001, 0.004), 5)
    d.place(out, bite, 0.0, 0.6)
    at = 0.14
    turn = 0.3
    while at < 1.4:
        m = d.samples(turn * 0.8)
        k = d.time_axis(m)
        grind = crush(d, m, rng, d.env_swell(m, turn * 0.3), (1500.0, 7000.0), -2.0, 260.0, 0.003)
        squeak = creak(d, m, rng, 320.0 + 260.0 * k / (turn * 0.8),
                       [(1350.0, 1.0, 0.01), (2100.0, 0.5, 0.008)], d.env_swell(m, turn * 0.35), 0.35)
        d.place(out, grind + 0.35 * squeak, at, rng.uniform(0.7, 1.0))
        at += turn
        turn *= 0.94
    d.place(out, tink(d, rng, CRAMPON_STEEL, 0.8, 0.8), min(at, 1.45), 0.5)
    return out * (1.0 - 0.3 * t / 1.6)


@sound("anchor_snow", "gear", variants=2, peak=-5.0, rate=32000)
def anchor_snow(d, rng, variant):
    """Building in snow: chopping and stamping it down."""
    n = d.samples(1.5)
    out = np.zeros(n)
    at = 0.0
    for k in range(4):
        m = d.samples(0.36)
        j = d.time_axis(m)
        chop = heel(d, m, rng, rng.uniform(55.0, 75.0), 0.12)
        chop = chop + 0.8 * crush(d, m, rng, np.exp(-j / 0.05), (600.0, 5000.0), -3.0, 200.0, 0.004)
        if k % 2 == 0:
            chop = chop + 0.2 * unit(d.struck(m, rng, scaled(AXE_STEEL, 1.05, 0.4), click=0.4))
        d.place(out, chop, at, rng.uniform(0.75, 1.0))
        at += rng.uniform(0.3, 0.4)
    return out


@sound("anchor_fail", "gear", variants=2, peak=-3.0, rate=44100)
def anchor_fail(d, rng, variant):
    """The anchor ripping: a crack of metal leaving the mountain."""
    n = d.samples(0.7)
    t = d.time_axis(n)
    snap = unit(d.noise(n, rng, bp(1200.0, 11000.0, 1.5)) * d.env_decay(n, 0.012))
    ping = unit(d.struck(n, rng, scaled(CRAMPON_STEEL, 1.15, 1.6), click=0.9))
    out = snap + 0.8 * ping + 0.5 * unit(d.thump(n, 160.0, 70.0, 0.1))
    d.place(out, swish(d, d.samples(0.3), rng, 700.0, 3200.0, 0.08), 0.03, 0.5)
    debris = unit(d.grain_cloud(n, rng, 70.0 * bump(t, 0.25, 0.14), stones(d, rng, 7, 1000.0, 3800.0), 0.7))
    return out + 0.35 * debris


# =============================================================================
# AXE AND CRAMPONS
# =============================================================================

@sound("axe_plant", "gear", variants=3, peak=-6.0, rate=32000)
def axe_plant(d, rng, variant):
    """The axe shaft plunged into snow for balance."""
    n = d.samples(0.26)
    t = d.time_axis(n)
    pack = crush(d, n, rng, np.exp(-t / 0.03), (800.0, 4500.0), -3.0, 220.0, 0.003)
    out = heel(d, n, rng, rng.uniform(64.0, 78.0), 0.08) + 0.8 * pack
    d.place(out, tink(d, rng, AXE_STEEL, 1.1, 0.3), 0.002, 0.12)
    return out


@sound("axe_ice", "gear", variants=3, rate=44100)
def axe_ice(d, rng, variant):
    """The pick swung into ice: a solid thock, a ring, and chips falling."""
    n = d.samples(0.55)
    t = d.time_axis(n)
    ring = unit(d.struck(n, rng, scaled(AXE_STEEL, rng.uniform(0.94, 1.08)), click=0.8, click_band=(2000.0, 10000.0)))
    shatter = cracks(d, n, rng, 420.0 * np.exp(-t / 0.05), (3000.0, 9000.0), (0.001, 0.004), 6)
    chips = cracks(d, n, rng, 90.0 * bump(t, 0.25, 0.12), (4000.0, 10000.0), (0.001, 0.003), 5)
    return unit(d.thump(n, 210.0, 110.0, 0.06)) + 0.5 * ring + 0.55 * shatter + 0.25 * chips


@sound("axe_rock", "gear", variants=2, rate=44100)
def axe_rock(d, rng, variant):
    """Steel on rock: the pick glancing off stone."""
    n = d.samples(0.45)
    ring = unit(d.struck(n, rng, scaled(AXE_STEEL, rng.uniform(1.0, 1.15), 1.2), click=1.0, click_band=(2500.0, 11000.0)))
    knock = unit(d.struck(n, rng, scaled(ROCK, 1.3), click=0.5, click_band=(1000.0, 6000.0)))
    grate = scrape(d, n, rng, d.env_ar(n, 0.003, 0.09), (2000.0, 8000.0), 230.0,
                   resonances=[(2750.0, 10.0, 8.0)], roughness=0.6)
    return ring + 0.6 * knock + 0.3 * grate


@sound("strap_pull", "gear", variants=3, peak=-7.0, rate=32000)
def strap_pull(d, rng, variant):
    """A strap hauled tight through its buckle."""
    n = d.samples(0.5)
    m = d.samples(0.34)
    k = d.time_axis(m)
    ripple = 150.0 + 380.0 * (k / 0.34) ** 1.4
    out = np.zeros(n)
    d.place(out, rope_friction(d, m, rng, d.env_swell(m, 0.2, sharpness=1.2), ripple, 0.6, (1200.0, 6500.0)), 0.0)
    d.place(out, tink(d, rng, CRAMPON_RING, rng.uniform(1.2, 1.5), 0.4, click=0.8), 0.33, 0.6)
    return out


@sound("crampon_clank", "gear", variants=2, peak=-6.0, rate=44100)
def crampon_clank(d, rng, variant):
    """Crampons in the hand: steel frames knocking together."""
    n = d.samples(0.5)
    out = np.zeros(n)
    at = 0.0
    for _ in range(3):
        d.place(out, tink(d, rng, CRAMPON_RING, rng.uniform(0.8, 1.1), 1.1), at, rng.uniform(0.5, 1.0))
        at += rng.uniform(0.06, 0.16)
    return out


@sound("pack_zip", "gear", variants=2, peak=-8.0, rate=32000)
def pack_zip(d, rng, variant):
    """Into the pack: a zip run open and a rustle of fabric."""
    n = d.samples(0.65)
    out = np.zeros(n)
    m = d.samples(0.3)
    k = d.time_axis(m)
    teeth = d.stick_slip(m, rng, 260.0 + 420.0 * k / 0.3, 0.12) * d.env_swell(m, 0.18, sharpness=1.0)
    tooth = d.noise(d.samples(0.004), rng, bp(1800.0, 5500.0, 1.5)) * d.env_decay(d.samples(0.004), 0.003)
    zipper = d.filt(d.convolve(teeth, tooth), lp(6500.0, 2.0), causal=True)
    d.place(out, unit(zipper), 0.0, 0.8)
    d.place(out, cloth(d, d.samples(0.34), rng, 4), 0.28, 0.6)
    return out


# =============================================================================
# PROBE, SHOVEL, AIRBAG
# =============================================================================

def probe_push(d: dsp.At, rng, length: float) -> np.ndarray:
    """The shaft sliding down through snow."""
    m = d.samples(length)
    return crush(d, m, rng, d.env_swell(m, length * 0.5, sharpness=1.2), (900.0, 4500.0), -3.0, 210.0, 0.004)


@sound("probe_firm", "gear", variants=2, peak=-6.0, rate=32000)
def probe_firm(d, rng, variant):
    """Probing ahead: the shaft goes down and stops on something solid."""
    n = d.samples(0.85)
    out = np.zeros(n)
    at = 0.0
    for _ in range(2):
        d.place(out, probe_push(d, rng, 0.2), at, 0.7)
        stop = unit(d.thump(d.samples(0.12), 220.0, 120.0, 0.05))
        stop += 0.4 * unit(d.noise(d.samples(0.12), rng, bp(1500.0, 5000.0, 1.5)) * d.env_decay(d.samples(0.12), 0.012))
        d.place(out, stop, at + 0.19, 0.8)
        at += rng.uniform(0.36, 0.42)
    return out


@sound("probe_hollow", "gear", variants=2, peak=-5.0, rate=32000)
def probe_hollow(d, rng, variant):
    """Probing ahead: the crust gives and the shaft drops into nothing."""
    n = d.samples(0.8)
    t = d.time_axis(n)
    out = np.zeros(n)
    d.place(out, probe_push(d, rng, 0.2), 0.0, 0.7)
    crust = cracks(d, d.samples(0.08), rng, 900.0, (1500.0, 6000.0), (0.002, 0.005), 5)
    d.place(out, crust, 0.18, 0.9)
    void = unit(d.noise(n, rng, chain(bp(110.0, 900.0, 1.5), tilt(-6))) * bump(t, 0.32, 0.09))
    crumbs = cracks(d, n, rng, 110.0 * bump(t, 0.45, 0.13), (900.0, 4000.0), (0.003, 0.008), 5)
    out += 0.8 * void + 0.3 * crumbs
    return d.reverb(out, rng, 0.9, 0.3, damping_hz=2600.0, tail=0.6)


@sound("shovel_dig", "gear", variants=3, peak=-5.0, rate=32000)
def shovel_dig(d, rng, variant):
    """A shovelful: the blade driven in, lifted, and the snow thrown clear."""
    n = d.samples(0.85)
    t = d.time_axis(n)
    cut = crush(d, n, rng, np.exp(-t / 0.045), (700.0, 6000.0), -2.0, 240.0, 0.003)
    blade = unit(d.struck(n, rng, scaled(SHOVEL_BLADE, rng.uniform(0.9, 1.15)), click=0.4, click_band=(1500.0, 7000.0)))
    throw = unit(d.noise(n, rng, chain(bp(400.0, 4000.0, 1.5), tilt(-4))) * bump(t, 0.4, 0.08))
    landing = cracks(d, n, rng, 420.0 * bump(t, 0.6, 0.07), (800.0, 4500.0), (0.003, 0.008))
    return heel(d, n, rng, 80.0, 0.06) + 0.9 * cut + 0.22 * blade + 0.45 * throw + 0.4 * landing


@sound("snow_scrabble", "gear", variants=4, peak=-6.0, rate=22050)
def snow_scrabble(d, rng, variant):
    """Digging with the hands from inside the debris: close, muffled, desperate."""
    n = d.samples(0.34)
    shape = d.env_swell(n, rng.uniform(0.07, 0.12), sharpness=1.2)
    claw = crush(d, n, rng, shape, (350.0, 2400.0), -4.0, 150.0, 0.005)
    detail = cracks(d, n, rng, 260.0 * shape, (600.0, 2600.0), (0.004, 0.01), 5)
    return d.filt(claw + 0.4 * detail + 0.3 * heel(d, n, rng, 70.0, 0.07), lp(2800.0, 1.5), causal=True)


@sound("pit_tap", "gear", variants=3, peak=-6.0, rate=32000)
def pit_tap(d, rng, variant):
    """A column test: the flat of the hand tapping the shovel blade."""
    n = d.samples(0.16)
    blade = unit(d.struck(n, rng, scaled(SHOVEL_BLADE, rng.uniform(0.95, 1.1), 0.7), click=0.3,
                          click_band=(1200.0, 6000.0)))
    return heel(d, n, rng, 95.0 + 12.0 * variant, 0.05) + 0.5 * blade


@sound("column_fracture", "gear", peak=-4.0, rate=32000)
def column_fracture(d, rng, variant):
    """The column shearing on the weak layer and sliding off."""
    n = d.samples(0.55)
    t = d.time_axis(n)
    pop = unit(d.noise(n, rng, bp(500.0, 6000.0, 1.5)) * d.env_decay(n, 0.02))
    drop = unit(d.thump(n, 130.0, 60.0, 0.12))
    slide = crush(d, n, rng, bump(t, 0.2, 0.08), (500.0, 4000.0), -3.0, 160.0, 0.005)
    return pop + 0.8 * drop + 0.6 * slide


@sound("airbag_deploy", "gear", peak=-2.0, rate=32000)
def airbag_deploy(d, rng, variant):
    """The airbag: a bang from the cartridge and the bags filling in a rush."""
    n = d.samples(1.1)
    bang = unit(d.noise(n, rng, bp(300.0, 9000.0, 1.5)) * d.env_decay(n, 0.03))
    bang += 0.8 * unit(d.thump(n, 240.0, 80.0, 0.1))
    shape = d.env_ar(n, 0.03, 0.75)

    def response_at(now):
        e = float(np.exp(-now / 0.22))
        return chain(bp(250.0, 1800.0 + 5200.0 * e, 1.5), tilt(-3.0, 1500.0))

    rush = unit(d.filt_tv(rng.standard_normal(n), response_at) * shape)
    out = bang + 0.75 * rush
    d.place(out, cloth(d, d.samples(0.35), rng, 4, (800.0, 6000.0)), 0.45, 0.5)
    return out


@sound("ice_chips", "gear", variants=2, peak=-10.0, rate=44100)
def ice_chips(d, rng, variant):
    """Chips of ice dislodged and tinkling away down the face."""
    n = d.samples(0.6)
    out = np.zeros(n)
    for _ in range(rng.integers(5, 9)):
        chip = unit(d.struck(d.samples(0.04), rng, scaled(ICE_SHARDS, rng.uniform(0.8, 1.4)), click=0.6,
                             click_band=(3000.0, 11000.0), spread=0.08))
        d.place(out, chip, rng.uniform(0.0, 0.45) ** 1.3, rng.uniform(0.3, 1.0))
    return out
