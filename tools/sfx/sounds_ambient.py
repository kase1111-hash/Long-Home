"""Wind, weather and the mountain's own noises.

The wind is built from layers the game mixes by wind speed: a low body, two
mid "rush" loops (played left and right), a thin high hiss, howls and whistles
for strong wind, and gusts as one-shots. The loops are stationary on purpose:
the slow rise and fall comes from the game moving the layer volumes, so the
wind never repeats the way a long recorded loop does.

Dull sounds are rendered at a lower sample rate than bright ones; nothing
here has content the lower rate would lose.
"""

from __future__ import annotations

import numpy as np

import dsp
from dsp import bp, chain, hp, lp, peak, resonator, tilt
from materials import ICE_BODY, ICE_SHARDS, ROCK
from registry import sound


# =============================================================================
# WIND LAYERS
# =============================================================================

@sound("wind_low_loop", "ambient", rate=11025)
def wind_low(d, rng, variant):
    """The body of the wind: a soft rumble, always there."""
    n = d.samples(6.0)
    bed = d.noise(n, rng, chain(hp(42, 2), tilt(-7), lp(850, 1.5)))
    bed *= 1.0 + 0.16 * d.wander(n, rng, 0.9)
    low = d.noise(n, rng, chain(bp(85, 210, 2), tilt(-4)))
    low *= dsp.db(2.5 * d.wander(n, rng, 0.8))
    mid = d.noise(n, rng, chain(bp(230, 560, 2), tilt(-4)))
    mid *= dsp.db(2.5 * d.wander(n, rng, 1.0))
    return bed + 0.5 * low + 0.36 * mid


@sound("wind_mid_loop", "ambient", variants=2, rate=11025)
def wind_mid(d, rng, variant):
    """The rush of moving air; two takes, one for each ear."""
    n = d.samples(5.6 + 1.3 * variant)
    bed = d.noise(n, rng, chain(hp(170, 2), tilt(-5), lp(3200, 1.5)))
    centre = 760.0 * np.exp(0.3 * d.wander(n, rng, 0.9))
    whoosh = d.moving_band(n, rng, centre, 260.0, 2900.0, steps=6, sharpness=0.8)
    whoosh = d.filt(whoosh, tilt(-4))
    out = 0.6 * bed + 0.75 * whoosh / dsp.rms(whoosh)
    return out * (1.0 + 0.14 * d.wander(n, rng, 1.1))


@sound("wind_high_loop", "ambient", rate=22050)
def wind_high(d, rng, variant):
    """Thin, high air over snow and past the ears; louder on exposed ground."""
    n = d.samples(5.0)
    centre = 3600.0 * np.exp(0.26 * d.wander(n, rng, 0.9))
    hiss = d.moving_band(n, rng, centre, 1600.0, 8600.0, steps=5, sharpness=0.85)
    hiss = d.filt(hiss, tilt(-4, 4000.0))
    flutter = 1.0 + 0.2 * d.wander(n, rng, 3.0) + 0.09 * d.wander(n, rng, 11.0)
    return hiss * np.maximum(flutter, 0.35)


@sound("wind_howl_loop", "ambient", variants=2, rate=11025)
def wind_howl(d, rng, variant):
    """Wind moaning round the mountain: pitched, rising and falling."""
    n = d.samples(8.0 + 1.6 * variant)
    voices = [(205.0, 0.20, 1.0), (318.0, 0.17, 0.85), (497.0, 0.15, 0.6)]
    if variant == 1:
        voices = [(176.0, 0.22, 1.0), (262.0, 0.18, 0.9), (410.0, 0.16, 0.7), (640.0, 0.12, 0.35)]
    out = np.zeros(n)
    strength = np.zeros(n)
    for base, depth, level in voices:
        glide = d.wander(n, rng, 0.17)
        # Gusts shake the pitch a little on top of the slow glide
        freq = base * np.exp(depth * glide + 0.012 * d.wander(n, rng, 4.0))
        # A howl swells and dies; it is louder while its pitch is high
        swell = d.wander01(n, rng, 0.2) ** 2.2
        swell *= 0.55 + 0.45 * np.clip(0.5 + 0.5 * glide, 0.0, 1.0)
        # Wide enough to be air moaning, not a tone: about a sixth of an octave
        voice = d.narrowband(n, rng, freq, base * 0.12, circular=True)
        overtone = d.narrowband(n, rng, freq * 2.0, base * 0.2, circular=True)
        out += level * swell * (voice + 0.2 * overtone)
        strength += level * swell
    air = d.noise(n, rng, chain(bp(140, 950, 2), tilt(-6)))
    out += 0.42 * air * (0.5 + 0.5 * strength / (np.max(strength) + 1e-9))
    return out


@sound("wind_whistle_loop", "ambient", rate=11025)
def wind_whistle(d, rng, variant):
    """A breathy whistle where strong wind crosses rock edges."""
    n = d.samples(6.4)
    out = np.zeros(n)
    air = d.noise(n, rng, chain(bp(600, 5200, 2), tilt(-5)))
    for base, level in ((930.0, 1.0), (1460.0, 0.7), (2210.0, 0.35)):
        freq = base * np.exp(0.09 * d.wander(n, rng, 0.5) + 0.014 * d.wander(n, rng, 5.0))
        swell = d.wander01(n, rng, 0.45) ** 3.5
        tone = d.narrowband(n, rng, freq, base * 0.045, circular=True)
        breath = d.filt(air, resonator(base, 5.0))
        out += level * swell * (tone + 0.8 * breath / dsp.rms(breath))
    return out + 0.2 * air


@sound("wind_gust", "ambient", variants=4, peak=-4.0, rate=16000)
def wind_gust(d, rng, variant):
    """A gust arriving and passing: it brightens as it peaks."""
    duration = (2.7, 3.3, 3.9, 2.9)[variant]
    n = d.samples(duration)
    shape = d.env_swell(n, duration * rng.uniform(0.3, 0.44), sharpness=1.6)
    times = d.time_axis(n)

    def response_at(t):
        e = float(np.interp(t, times, shape))
        return chain(hp(55, 2), tilt(-6.5 + 2.6 * e), lp(520.0 + 3900.0 * e ** 1.5, 1.2),
                     peak(330.0 + 720.0 * e, 1.3, 5.0 * e))

    body = d.filt_tv(rng.standard_normal(n), response_at)
    body *= shape ** 1.25
    body *= 1.0 + 0.2 * d.wander(n, rng, 5.0) * shape
    if variant >= 2:
        whistle = d.narrowband(n, rng, 880.0 + 520.0 * shape, 70.0)
        body += 0.22 * dsp.rms(body) * whistle * shape ** 4
    return body


@sound("spindrift_loop", "ambient", rate=32000)
def spindrift(d, rng, variant):
    """Snow grains blown across the surface: a dry hiss that sizzles."""
    n = d.samples(3.4)
    hiss = d.noise(n, rng, chain(bp(1900, 7600, 2), tilt(-3, 4000.0)))
    drift = 0.6 + 0.4 * d.wander01(n, rng, 1.6)
    sizzle = np.maximum(1.0 + 0.28 * d.wander(n, rng, 28.0), 0.2)
    kernels = d.grain_kernels(rng, 6, (2800.0, 7500.0), (0.001, 0.003), width=0.45)
    crystals = d.grain_cloud(n, rng, 900.0 * drift, kernels, 0.7, circular=True)
    return hiss * drift * sizzle + 0.5 * crystals * dsp.rms(hiss) / (dsp.rms(crystals) + 1e-9)


# =============================================================================
# PRECIPITATION
# =============================================================================

@sound("rain_loop", "ambient", rate=32000)
def rain(d, rng, variant):
    """Rain on a shell jacket and hood."""
    n = d.samples(3.2)
    drops = d.grain_kernels(rng, 8, (1200.0, 5200.0), (0.003, 0.009), width=0.45)
    pats = d.grain_kernels(rng, 4, (280.0, 900.0), (0.012, 0.03))
    cloud = d.grain_cloud(n, rng, 380.0, drops, 0.8, circular=True)
    heavy = d.grain_cloud(n, rng, 13.0, pats, 0.5, circular=True)
    bed = d.noise(n, rng, chain(bp(600, 5000, 1.5), tilt(-4)))
    return cloud / dsp.rms(cloud) + 0.55 * heavy / (dsp.rms(heavy) + 1e-9) + 0.3 * bed


@sound("sleet_loop", "ambient", rate=32000)
def sleet(d, rng, variant):
    """Ice pellets ticking on the shell: sparser and sharper than rain."""
    n = d.samples(3.0)
    pellets = d.grain_kernels(rng, 8, (2400.0, 7800.0), (0.0015, 0.004), width=0.4)
    cloud = d.grain_cloud(n, rng, 230.0, pellets, 0.9, circular=True)
    bed = d.noise(n, rng, chain(bp(1400, 6500, 1.5), tilt(-4)))
    return cloud / dsp.rms(cloud) + 0.18 * bed


# =============================================================================
# ICE, SNOW AND ROCK IN THE DISTANCE
# =============================================================================

@sound("ice_creak", "ambient", variants=3, peak=-5.0, rate=22050)
def ice_creak(d, rng, variant):
    """A glacier shifting: a deep groan with a tick or two of cracking ice."""
    duration = (1.5, 2.1, 1.8)[variant]
    n = d.samples(duration)
    t = d.time_axis(n)
    start, end = ((38.0, 23.0), (21.0, 33.0), (46.0, 28.0))[variant]
    rate = start + (end - start) * (t / duration) ** 1.3
    pulses = d.stick_slip(n, rng, rate, 0.32)
    pulses *= d.env_swell(n, duration * 0.35, sharpness=1.2)
    kernel = d.modal(d.samples(0.16), [(f * rng.uniform(0.94, 1.06), a, t60) for f, a, t60 in ICE_BODY])
    groan = d.convolve(pulses, kernel)
    out = groan / (np.max(np.abs(groan)) + 1e-9)
    for _ in range(1 + variant % 2):
        tick = d.struck(d.samples(0.05), rng, ICE_SHARDS, click=0.8, click_band=(2500.0, 10000.0))
        d.place(out, tick, rng.uniform(0.15, duration * 0.7), 0.3)
    return d.reverb(out, rng, 1.0, 0.22, damping_hz=1900.0, tail=0.8)


@sound("ice_crack", "ambient", variants=3, peak=-3.0, rate=32000)
def ice_crack(d, rng, variant):
    """Ice breaking with a sharp report that echoes off the walls."""
    n = d.samples(0.5)
    snap = d.noise(n, rng, bp(1300, 12000, 1.5)) * d.env_decay(n, 0.012 + 0.004 * variant)
    boom = d.thump(n, 150.0 - 15.0 * variant, 58.0, 0.28)
    t = d.time_axis(n)
    kernels = d.grain_kernels(rng, 6, (2800.0, 9000.0), (0.002, 0.006))
    crackle = d.grain_cloud(n, rng, 650.0 * np.exp(-t / 0.05), kernels, 0.8)
    out = snap + 0.75 * boom + 0.5 * crackle
    out = d.echoes(out, [(0.085, 0.32, 3200.0), (0.2, 0.2, 1900.0), (0.37, 0.1, 1100.0)])
    return d.reverb(out, rng, 0.7, 0.12, damping_hz=2400.0, tail=0.45)


@sound("snow_settle", "ambient", variants=2, peak=-8.0, rate=32000)
def snow_settle(d, rng, variant):
    """Disturbed snow coming to rest: trickling grains and a soft sigh."""
    duration = 2.0 + 0.3 * variant
    n = d.samples(duration)
    t = d.time_axis(n)
    kernels = d.grain_kernels(rng, 6, (900.0, 5200.0), (0.003, 0.01))
    trickle = d.grain_cloud(n, rng, 10.0 + 150.0 * np.exp(-t / 0.55), kernels, 0.8)
    sigh = d.noise(n, rng, chain(bp(250, 2600, 1.5), tilt(-5))) * d.env_ar(n, 0.06, 1.3)
    return trickle / (np.max(np.abs(trickle)) + 1e-9) + 0.22 * sigh / np.max(np.abs(sigh))


@sound("rockfall_distant", "ambient", variants=2, peak=-9.0, rate=11025)
def rockfall_distant(d, rng, variant):
    """A stone coming down a face a long way off."""
    duration = 3.0 + 0.8 * variant
    n = d.samples(duration)
    out = np.zeros(n)
    kernels = d.grain_kernels(rng, 6, (700.0, 3000.0), (0.006, 0.018))
    at = 0.05
    strength = 1.0
    while at < duration - 0.6:
        hit = d.struck(d.samples(0.12), rng, ROCK, click=0.5, click_band=(600.0, 4000.0), spread=0.08)
        d.place(out, hit, at, strength)
        m = d.samples(0.35)
        clatter = d.grain_cloud(m, rng, 70.0 * np.exp(-d.time_axis(m) / 0.1), kernels, 0.7)
        d.place(out, clatter, at + 0.01, 0.35 * strength)
        at += rng.uniform(0.22, 0.62)
        strength *= rng.uniform(0.72, 0.98)
    out = d.far_away(out, 700.0)
    return d.reverb(out, rng, 1.5, 0.42, damping_hz=1500.0, predelay=0.03, tail=1.0)


@sound("avalanche_distant", "ambient", variants=2, peak=-6.0, rate=11025)
def avalanche_distant(d, rng, variant):
    """An avalanche running somewhere else on the mountain: a long low roar."""
    duration = 6.5 + 1.5 * variant
    n = d.samples(duration)
    rise = 1.2 + 0.6 * variant
    shape = d.env_points(n, [(0.0, 0.0), (rise, 1.0), (rise + 1.5, 0.85), (duration, 0.0)], curve=1.5)
    rumble = d.noise(n, rng, chain(hp(42, 2), tilt(-6), lp(480, 1.5)))
    rumble *= shape * (1.0 + 0.3 * d.wander(n, rng, 1.2))
    roar = d.noise(n, rng, chain(bp(170, 900, 2), tilt(-5))) * shape ** 1.7
    roar *= 1.0 + 0.35 * d.wander(n, rng, 2.5)
    out = rumble + 0.55 * roar
    if variant == 0:
        boom = d.thump(d.samples(0.7), 120.0, 55.0, 0.55)
        d.place(out, boom, 0.08, 0.5 * np.max(np.abs(out)))
    return d.reverb(out, rng, 2.2, 0.33, damping_hz=900.0, tail=1.0)


# =============================================================================
# PLACES
# =============================================================================

@sound("flag_flap_loop", "ambient", rate=22050)
def flag_flap(d, rng, variant):
    """Prayer flags snapping on their line at the summit cairn."""
    n = d.samples(4.4)
    rate = 6.2 * np.exp(0.3 * d.wander(n, rng, 0.5))
    snaps = d.stick_slip(n, rng, rate, 0.4)
    snaps *= 0.45 + 0.55 * d.wander01(n, rng, 0.8)
    out = np.zeros(n)
    hits = np.flatnonzero(snaps)
    choice = rng.integers(0, 3, size=len(hits))
    for k in range(3):
        m = d.samples(0.11)
        cloth = d.noise(m, rng, chain(bp(420.0 + 160.0 * k, 5200.0, 1.5), tilt(-4)))
        cloth *= d.env_ar(m, 0.002, 0.05 + 0.02 * k)
        whup = d.thump(m, 250.0 - 30.0 * k, 110.0, 0.07)
        kernel = cloth / np.max(np.abs(cloth)) + 0.55 * whup
        train = np.zeros(n)
        train[hits[choice == k]] = snaps[hits[choice == k]]
        out += d.scatter(train, kernel, circular=True)
    rustle = d.noise(n, rng, chain(bp(900, 6000, 1.5), tilt(-4)))
    return out + 0.07 * rustle * np.max(np.abs(out))
