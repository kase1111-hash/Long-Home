"""The climber's own sounds: breath, heart, and the body meeting the ground.

Breath is air made rough by the throat and shaped by the mouth, so each
breath here is noise through a few moving resonances. The game plays inhales
and exhales one at a time and sets the pace itself, which is why there is a
calm, a hard and a gasping set rather than breathing loops.

Nothing here is a voice. Pain is a hiss through the teeth and a shaky breath;
there are no cries (see the fatal-event rules in the spec).
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, lp, mix_responses, peak, resonator, tilt
from materials import (CRAMPON_RING, ROCK, SOLE_ON_ICE, WOOD, bump, cloth, cracks, crush, heel, hits,
                       scaled, scrape, unit)
from registry import sound


# =============================================================================
# BREATH
# =============================================================================

def breath(d: dsp.At, rng, duration: float, start, end, band: tuple, slope: float, peak_at: float,
           q: float = 3.5, rough: float = 0.18, air: float = 0.12, sharpness: float = 1.3) -> np.ndarray:
    """One inhale or exhale.

    start and end are the mouth's resonances as (Hz, weight) at the beginning
    and the end of the breath; peak_at is where in the breath (0..1) it is
    loudest (late for an inhale, early for an exhale).
    """
    n = d.samples(duration)
    flat = lambda f: np.ones_like(f)  # noqa: E731

    def response_at(t):
        u = min(max(t / duration, 0.0), 1.0)
        parts = [(w, resonator(fa + (fb - fa) * u, q)) for (fa, w), (fb, _) in zip(start, end)]
        return chain(bp(band[0], band[1], 1.5), tilt(slope, 1000.0), mix_responses(parts + [(air, flat)]))

    out = d.filt_tv(rng.standard_normal(n), response_at)
    out *= d.env_swell(n, peak_at * duration, sharpness=sharpness)
    return out * np.maximum(1.0 + rough * d.wander(n, rng, 45.0), 0.2)


def varied(rng, formants, amount: float = 0.06):
    """The same mouth, a slightly different shape: no two breaths alike."""
    scale = rng.uniform(1.0 - amount, 1.0 + amount)
    return [(f * scale, w * rng.uniform(0.85, 1.15)) for f, w in formants]


@sound("breath_calm_in", "breath", variants=3, peak=-9.0, rate=22050)
def breath_calm_in(d, rng, variant):
    """A quiet breath in through the nose."""
    a = varied(rng, [(420.0, 1.0), (1150.0, 0.6), (2300.0, 0.35)])
    b = [(f * 1.1, w) for f, w in a]
    return breath(d, rng, rng.uniform(1.15, 1.35), a, b, (260.0, 5200.0), -5.0, 0.55, rough=0.12, air=0.2)


@sound("breath_calm_out", "breath", variants=3, peak=-9.0, rate=22050)
def breath_calm_out(d, rng, variant):
    """A quiet breath out."""
    a = varied(rng, [(400.0, 1.0), (1050.0, 0.55), (2100.0, 0.3)])
    b = [(f * 0.88, w) for f, w in a]
    return breath(d, rng, rng.uniform(1.35, 1.65), a, b, (200.0, 4600.0), -5.5, 0.2, rough=0.12, air=0.2)


@sound("breath_hard_in", "breath", variants=3, peak=-5.0, rate=22050)
def breath_hard_in(d, rng, variant):
    """Working hard: a full breath in through the mouth."""
    a = varied(rng, [(620.0, 1.0), (1500.0, 0.7), (2700.0, 0.5), (3900.0, 0.25)])
    b = [(f * 1.14, w) for f, w in a]
    return breath(d, rng, rng.uniform(0.66, 0.8), a, b, (300.0, 7500.0), -3.0, 0.6, rough=0.2)


@sound("breath_hard_out", "breath", variants=3, peak=-5.0, rate=22050)
def breath_hard_out(d, rng, variant):
    """Working hard: a blown breath out."""
    a = varied(rng, [(540.0, 1.0), (1280.0, 0.7), (2450.0, 0.4)])
    b = [(f * 0.82, w) for f, w in a]
    return breath(d, rng, rng.uniform(0.78, 0.95), a, b, (200.0, 5800.0), -5.0, 0.18, rough=0.22)


@sound("breath_gasp_in", "breath", variants=3, rate=22050)
def breath_gasp_in(d, rng, variant):
    """A sharp snatched breath: fear, or a body at its limit."""
    a = varied(rng, [(780.0, 1.0), (1850.0, 0.8), (3100.0, 0.6), (4300.0, 0.3)])
    b = [(f * 1.12, w) for f, w in a]
    return breath(d, rng, rng.uniform(0.34, 0.45), a, b, (400.0, 9000.0), -2.0, 0.45,
                  rough=0.25, sharpness=1.0)


@sound("breath_gasp_out", "breath", variants=3, rate=22050)
def breath_gasp_out(d, rng, variant):
    """The forced breath out that follows a gasp."""
    a = varied(rng, [(680.0, 1.0), (1400.0, 0.8), (2600.0, 0.5)])
    b = [(f * 0.75, w) for f, w in a]
    return breath(d, rng, rng.uniform(0.42, 0.54), a, b, (250.0, 7000.0), -4.0, 0.12,
                  rough=0.28, sharpness=1.0)


# =============================================================================
# REACTIONS
# =============================================================================

@sound("reaction_relief", "breath", variants=2, peak=-6.0, rate=22050)
def reaction_relief(d, rng, variant):
    """It held. A long breath let go."""
    a = varied(rng, [(560.0, 1.0), (1250.0, 0.7), (2400.0, 0.4)])
    b = [(f * 0.7, w) for f, w in a]
    out = breath(d, rng, rng.uniform(1.05, 1.25), a, b, (180.0, 5000.0), -5.0, 0.12, rough=0.15)
    # The end of a long sigh wavers
    t = d.time_axis(len(out))
    waver = 1.0 + 0.25 * np.sin(dsp.TAU * 7.5 * t) * np.clip((t - 0.5) / 0.4, 0.0, 1.0)
    return out * waver


def teeth_hiss(d: dsp.At, rng, duration: float) -> np.ndarray:
    """Air sucked in through clenched teeth."""
    n = d.samples(duration)
    response = chain(bp(2200.0, 9000.0, 1.5), peak(4200.0 * rng.uniform(0.9, 1.1), 3.0, 8.0),
                     peak(6500.0 * rng.uniform(0.9, 1.1), 4.0, 5.0))
    hiss = d.noise(n, rng, response) * d.env_swell(n, duration * 0.55, sharpness=1.2)
    return unit(hiss * np.maximum(1.0 + 0.2 * d.wander(n, rng, 60.0), 0.2))


@sound("reaction_pain", "breath", variants=3, peak=-5.0, rate=22050)
def reaction_pain(d, rng, variant):
    """Something hurts: a hiss through the teeth, a breath that shakes."""
    n = d.samples(0.85)
    out = np.zeros(n)
    low = varied(rng, [(520.0, 1.0), (1100.0, 0.7), (2300.0, 0.3)])
    if variant == 0:
        d.place(out, teeth_hiss(d, rng, 0.34), 0.0)
    elif variant == 1:
        # The air knocked out, then the hiss
        burst = breath(d, rng, 0.17, low, [(f * 0.8, w) for f, w in low], (200.0, 4500.0), -5.0, 0.15,
                       rough=0.3, sharpness=1.0)
        d.place(out, unit(burst), 0.0, 0.9)
        d.place(out, teeth_hiss(d, rng, 0.3), 0.22)
    else:
        d.place(out, teeth_hiss(d, rng, 0.3), 0.0)
        shaky = breath(d, rng, 0.5, low, [(f * 0.8, w) for f, w in low], (200.0, 4500.0), -5.0, 0.2)
        t = d.time_axis(len(shaky))
        shaky *= 0.35 + 0.65 * np.abs(np.sin(np.pi * 11.0 * t)) ** 1.5
        d.place(out, unit(shaky), 0.33, 0.7)
    return out


@sound("reaction_effort", "breath", variants=3, peak=-5.0, rate=22050)
def reaction_effort(d, rng, variant):
    """A hard pull or a heave: breath driven out by the effort."""
    duration = rng.uniform(0.24, 0.3)
    a = varied(rng, [(520.0, 1.0), (1050.0, 0.8), (2300.0, 0.4)])
    b = [(f * 0.84, w) for f, w in a]
    air = unit(breath(d, rng, duration, a, b, (180.0, 5000.0), -4.0, 0.1, rough=0.3, sharpness=1.0))
    # The throat closing on it: a short low buzz under the breath, not a voice
    n = len(air)
    t = d.time_axis(n)
    pitch = rng.uniform(105.0, 125.0) * (1.0 - 0.18 * t / duration)
    pulses = d.stick_slip(n, rng, pitch, 0.07) * d.env_ar(n, 0.012, duration * 0.6)
    throat = d.modal(d.samples(0.02), [(f, w, 0.011) for f, w in a])
    return air + 0.33 * unit(d.convolve(pulses, throat))


@sound("reaction_shiver", "breath", variants=2, peak=-9.0, rate=22050)
def reaction_shiver(d, rng, variant):
    """Cold: a breath out that judders."""
    a = varied(rng, [(430.0, 1.0), (1100.0, 0.6), (2200.0, 0.3)])
    out = breath(d, rng, rng.uniform(0.8, 1.0), a, [(f * 0.9, w) for f, w in a], (220.0, 4000.0), -6.0, 0.25)
    t = d.time_axis(len(out))
    rate = rng.uniform(9.0, 11.5) * (1.0 + 0.08 * d.wander(len(out), rng, 2.0))
    judder = np.abs(np.sin(np.pi * np.cumsum(rate) / d.sr)) ** 1.5
    return out * (0.2 + 0.8 * judder)


@sound("heartbeat", "breath", variants=2, peak=-4.0, rate=11025)
def heartbeat(d, rng, variant):
    """One beat of the heart, as heard from inside: two soft thuds."""
    n = d.samples(0.52)
    force = 1.0 + 0.5 * variant
    first = d.thump(n, 150.0, 58.0, 0.14)
    second = d.thump(n, 175.0, 72.0, 0.1)
    out = first.copy()
    d.place(out, second, 0.27 - 0.03 * variant, 0.68)
    # Driven hard enough to grow overtones, with a knock in the low mids:
    # a pure 60 Hz thud vanishes on small speakers
    out = dsp.saturate(out * 2.4 * force, 1.6)
    knock = d.noise(n, rng, chain(bp(120.0, 520.0, 1.5), tilt(-4, 250.0))) * d.env_decay(n, 0.06)
    out += 0.3 * knock
    d.place(out, knock, 0.27 - 0.03 * variant, 0.2)
    return out


# =============================================================================
# THE BODY MEETING THE GROUND
# =============================================================================

@sound("impact_snow", "body", variants=3, rate=32000)
def impact_snow(d, rng, variant):
    """A body landing in snow: a deep soft thud and the crunch around it."""
    n = d.samples(0.55)
    t = d.time_axis(n)
    shape = np.exp(-t / 0.06) + 0.3 * bump(t, 0.15, 0.06)
    pack = crush(d, n, rng, shape, (500.0, 4000.0), -3.0, 160.0, 0.005)
    detail = cracks(d, n, rng, 320.0 * shape, (900.0, 4500.0), (0.003, 0.008))
    jacket = np.zeros(n)
    d.place(jacket, cloth(d, d.samples(0.3), rng, 3), 0.04)
    return heel(d, n, rng, rng.uniform(44.0, 56.0), 0.2) + 0.7 * pack + 0.3 * detail + 0.28 * jacket


@sound("impact_rock", "body", variants=3, rate=32000)
def impact_rock(d, rng, variant):
    """A body hitting rock: hard, short, with the rattle of what it carries."""
    n = d.samples(0.5)
    t = d.time_axis(n)
    knock = unit(d.struck(n, rng, scaled(ROCK, 0.62), click=0.5, click_band=(500.0, 4500.0), spread=0.08))
    grit = scrape(d, n, rng, d.env_ar(n, 0.004, 0.26), (900.0, 5500.0), 210.0, roughness=0.6)
    out = heel(d, n, rng, rng.uniform(70.0, 82.0), 0.12) + 0.6 * knock + 0.36 * grit
    d.place(out, cloth(d, d.samples(0.3), rng, 3), 0.03, 0.25)
    rattle = hits(d, d.samples(0.22), rng, scaled(CRAMPON_RING, rng.uniform(0.8, 1.2), 0.7), 2, 0.035, click=0.5)
    d.place(out, rattle, rng.uniform(0.02, 0.07), 0.3)
    return out


@sound("impact_ice", "body", variants=2, rate=32000)
def impact_ice(d, rng, variant):
    """A body slapping onto hard ice and skittering."""
    n = d.samples(0.45)
    t = d.time_axis(n)
    smack = unit(d.struck(n, rng, scaled(SOLE_ON_ICE, 0.8), click=0.9, click_band=(1500.0, 8000.0), spread=0.07))
    skitter = scrape(d, n, rng, d.env_ar(n, 0.01, 0.22), (2000.0, 7000.0), 150.0, roughness=0.7)
    chips = cracks(d, n, rng, 240.0 * np.exp(-t / 0.08), (3000.0, 8500.0), (0.001, 0.004), 5)
    return heel(d, n, rng, 78.0, 0.07) + 0.75 * smack + 0.34 * skitter + 0.25 * chips


@sound("impact_tree", "body", variants=2, rate=32000)
def impact_tree(d, rng, variant):
    """Hitting a tree: a woody thunk, a crack, and the snow coming off the branches."""
    n = d.samples(0.95)
    t = d.time_axis(n)
    trunk = unit(d.struck(n, rng, scaled(WOOD, rng.uniform(0.9, 1.15)), click=0.4,
                          click_band=(500.0, 3500.0), spread=0.06))
    bark = cracks(d, n, rng, 500.0 * np.exp(-t / 0.035), (800.0, 3800.0), (0.003, 0.008))
    branches = d.noise(n, rng, chain(bp(1800.0, 7000.0, 1.5), tilt(-3))) * d.env_swell(n, 0.12, sharpness=1.5)
    branches *= np.maximum(1.0 + 0.5 * d.wander(n, rng, 40.0), 0.1)
    dump = d.noise(n, rng, chain(bp(140.0, 1300.0, 1.5), tilt(-5))) * bump(t, 0.33, 0.1)
    trickle = cracks(d, n, rng, 220.0 * bump(t, 0.45, 0.16), (900.0, 5000.0), (0.003, 0.008))
    return (trunk + 0.5 * heel(d, n, rng, 62.0, 0.12) + 0.45 * bark + 0.3 * unit(branches)
            + 0.5 * unit(dump) + 0.22 * trickle)


@sound("tumble", "body", variants=2, peak=-4.0, rate=32000)
def tumble(d, rng, variant):
    """Going over and over down a slope: thuds, cloth, something metal."""
    duration = 1.5 + 0.2 * variant
    n = d.samples(duration)
    out = np.zeros(n)
    at = 0.0
    strength = 1.0
    while at < duration - 0.45:
        m = d.samples(0.42)
        t = d.time_axis(m)
        shape = np.exp(-t / 0.05)
        hit = heel(d, m, rng, rng.uniform(46.0, 70.0), rng.uniform(0.12, 0.2))
        hit = hit + 0.6 * crush(d, m, rng, shape, (500.0, 4000.0), -3.0, 170.0, 0.005)
        d.place(out, hit, at, strength)
        d.place(out, cloth(d, d.samples(0.26), rng, 3), at + rng.uniform(0.05, 0.14), 0.3 * strength)
        at += rng.uniform(0.22, 0.4)
        strength *= rng.uniform(0.7, 0.95)
    rattle = hits(d, d.samples(0.2), rng, scaled(CRAMPON_RING, 1.1, 0.7), 2, 0.04, click=0.5)
    d.place(out, rattle, rng.uniform(0.2, 0.7), 0.22)
    return out


@sound("cloth_rustle", "body", variants=4, peak=-9.0, rate=32000)
def cloth_rustle(d, rng, variant):
    """Shell jacket and pack straps moving."""
    return cloth(d, d.samples(rng.uniform(0.2, 0.34)), rng, 2 + variant % 3)


@sound("pack_drop", "body", peak=-5.0, rate=32000)
def pack_drop(d, rng, variant):
    """The pack coming off and hitting the snow: the day is over."""
    n = d.samples(0.8)
    t = d.time_axis(n)
    out = heel(d, n, rng, 50.0, 0.2) + 0.5 * crush(d, n, rng, np.exp(-t / 0.07), (400.0, 3000.0), -4.0, 120.0, 0.006)
    d.place(out, cloth(d, d.samples(0.4), rng, 4), 0.03, 0.4)
    buckles = hits(d, d.samples(0.2), rng, scaled(CRAMPON_RING, 1.3, 0.6), 2, 0.06, click=0.5)
    d.place(out, buckles, 0.09, 0.25)
    return out
