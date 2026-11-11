#!/usr/bin/env python3
"""Render the game's sound effects into assets/audio.

    python tools/sfx/generate.py                 # render everything
    python tools/sfx/generate.py wind breath     # only ids containing these words
    python tools/sfx/generate.py --list          # what exists, no rendering
    python tools/sfx/generate.py --check         # measure the files on disk
    python tools/sfx/generate.py --sheet out.png footstep_snow   # spectrograms

Needs Python 3.9+ and numpy. Every sound is synthesized from a seed derived
from its name, so a re-render gives the same files. After rendering, run
``godot --headless --path . --import`` so Godot picks up new or changed files.

See assets/audio/README.md for how the game finds these files and how to
replace one with a recording.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analysis  # noqa: E402
import dsp  # noqa: E402
import wavio  # noqa: E402
from registry import SOUNDS, SoundSpec  # noqa: E402

# Importing a module registers its sounds
import sounds_ambient  # noqa: E402,F401
import sounds_body  # noqa: E402,F401
import sounds_footsteps  # noqa: E402,F401
import sounds_gear  # noqa: E402,F401
import sounds_hazard  # noqa: E402,F401
import sounds_motion  # noqa: E402,F401
import sounds_ui  # noqa: E402,F401

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "assets" / "audio"


def finish(spec: SoundSpec, raw: np.ndarray) -> np.ndarray:
    """Common last steps: no DC, clean edges, the level the spec asks for."""
    x = dsp.remove_dc(np.asarray(raw, dtype=np.float64))
    # Nothing below 25 Hz is heard, but it eats headroom and shakes speakers
    x = dsp.filt(x, dsp.hp(25.0, 2.0), spec.sample_rate, causal=not spec.loop)
    if not spec.loop:
        x = dsp.trim_tail(x, sr=spec.sample_rate)
        x = dsp.fade(x, 0.0015, 0.012, spec.sample_rate)
    if spec.level_kind == "rms":
        x = dsp.normalize_rms(x, spec.level_dbfs)
    else:
        x = dsp.normalize_peak(x, spec.level_dbfs)
    return x


def render(spec: SoundSpec, variant: int) -> np.ndarray:
    rng = dsp.rng_for(spec.name, variant)
    return finish(spec, spec.render(dsp.At(spec.sample_rate), rng, variant))


def selected(filters: list[str]) -> list[SoundSpec]:
    specs = sorted(SOUNDS.values(), key=lambda s: (s.category, s.name))
    if not filters:
        return specs
    return [s for s in specs if any(word in s.name or word == s.category for word in filters)]


def path_for(out_dir: Path, spec: SoundSpec, variant: int) -> Path:
    return out_dir / spec.category / spec.file_name(variant)


def command_list(specs: list[SoundSpec]) -> int:
    files = 0
    for spec in specs:
        files += spec.variants
        kind = "loop" if spec.loop else "    "
        print("%-10s %-30s x%d %s  %s" % (spec.category, spec.name, spec.variants, kind, spec.description))
    print("%d sounds, %d files" % (len(specs), files))
    return 0


def command_render(specs: list[SoundSpec], out_dir: Path) -> int:
    started = time.time()
    total_bytes = 0
    failures = 0
    for spec in specs:
        for variant in range(spec.variants):
            samples = render(spec, variant)
            target = path_for(out_dir, spec, variant)
            wavio.write_wav(target, samples, spec.sample_rate, spec.loop)
            total_bytes += target.stat().st_size
            wav = wavio.read_wav(target)
            faults = analysis.problems(wav, analysis.measure(wav))
            if faults:
                failures += 1
                print("PROBLEM %s: %s" % (target.name, "; ".join(faults)))
    count = sum(s.variants for s in specs)
    print("Rendered %d files (%.1f MB) in %.1f s into %s" % (
        count, total_bytes / 1e6, time.time() - started, out_dir))
    if failures:
        print("%d file(s) have problems" % failures)
    return 1 if failures else 0


def command_check(specs: list[SoundSpec], out_dir: Path, verbose: bool) -> int:
    missing = 0
    failures = 0
    total_seconds = 0.0
    if verbose:
        print("%-34s %6s %6s %6s %5s %7s %13s" % ("file", "sec", "peak", "rms", "crest", "centre", "5%..95% Hz"))
    for spec in specs:
        for variant in range(spec.variants):
            target = path_for(out_dir, spec, variant)
            if not target.exists():
                missing += 1
                print("MISSING %s" % target.relative_to(out_dir))
                continue
            wav = wavio.read_wav(target)
            m = analysis.measure(wav)
            total_seconds += m.duration
            faults = analysis.problems(wav, m)
            if wav.is_loop != spec.loop:
                faults.append("loop points %s" % ("missing" if spec.loop else "unexpected"))
            if verbose:
                print("%-34s %6.2f %6.1f %6.1f %5.1f %7.0f %6.0f..%-6.0f %s" % (
                    target.name, m.duration, m.peak_dbfs, m.rms_dbfs, m.crest_db,
                    m.centroid_hz, m.low_hz, m.high_hz, "LOOP" if wav.is_loop else ""))
            if faults:
                failures += 1
                print("PROBLEM %s: %s" % (target.name, "; ".join(faults)))
    # Files on disk that no sound definition accounts for
    known = {path_for(out_dir, s, v) for s in SOUNDS.values() for v in range(s.variants)}
    strays = [p for p in sorted(out_dir.rglob("*.wav")) if p not in known]
    for stray in strays:
        print("STRAY %s (no generator entry)" % stray.relative_to(out_dir))
    print("%d files, %.0f s of audio; %d missing, %d with problems, %d stray" % (
        sum(s.variants for s in specs), total_seconds, missing, failures, len(strays)))
    return 1 if (missing or failures) else 0


def command_sheet(specs: list[SoundSpec], out_dir: Path, sheet: Path, span: float | None,
                  max_variants: int) -> int:
    wavs = []
    for spec in specs:
        for variant in range(min(spec.variants, max_variants)):
            target = path_for(out_dir, spec, variant)
            if target.exists():
                wavs.append((target.name, wavio.read_wav(target)))
    if not wavs:
        print("No rendered files match")
        return 1
    across = analysis.spectrogram_sheet(sheet, [w for _, w in wavs], span)
    print("%s: full width = %.2f s, rows top to bottom:" % (sheet, across))
    for index, (name, wav) in enumerate(wavs):
        print("  %2d  %-34s %.2f s" % (index + 1, name, wav.duration))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Long Home's sound effects.")
    parser.add_argument("filters", nargs="*", help="only sounds whose id contains one of these (or a category)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output directory (default: assets/audio)")
    parser.add_argument("--list", action="store_true", help="list the sounds and stop")
    parser.add_argument("--check", action="store_true", help="measure existing files instead of rendering")
    parser.add_argument("--verbose", "-v", action="store_true", help="with --check: print every measurement")
    parser.add_argument("--sheet", type=Path, help="write a spectrogram sheet of the matching files (PNG)")
    parser.add_argument("--span", type=float, help="with --sheet: seconds the full width stands for")
    parser.add_argument("--max-variants", type=int, default=99, help="with --sheet: variants drawn per sound")
    args = parser.parse_args()

    specs = selected(args.filters)
    if not specs:
        print("No sounds match %s" % args.filters)
        return 1
    if args.list:
        return command_list(specs)
    if args.check:
        return command_check(specs, args.out, args.verbose)
    if args.sheet:
        return command_sheet(specs, args.out, args.sheet, args.span, args.max_variants)
    return command_render(specs, args.out)


if __name__ == "__main__":
    sys.exit(main())
