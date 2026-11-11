#!/usr/bin/env python3
"""Static checks on the sound effects in assets/audio. Needs no Godot.

    python tests/test_audio_assets.py

Checks that
  - every file is named <id>_<NN>.wav (or .ogg / .mp3), numbered from 01
    without gaps, and has its Godot .import file next to it
  - every WAV is mono 16-bit PCM, does not clip, and is not silent
  - an id ending in "_loop" carries loop points and nothing else does
  - every sound id the game code asks for exists as a file
  - every sound file is asked for somewhere in the game code
  - the files match what tools/sfx/generate.py would render (skipped when
    numpy is not installed)

Exit code 0 when everything holds, 1 otherwise.
"""

from __future__ import annotations

import re
import struct
import sys
from array import array
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUDIO = ROOT / "assets" / "audio"
SOURCE = ROOT / "src"

## Generated files are WAV; a recording dropped in may be Ogg Vorbis or MP3
EXTENSIONS = ("wav", "ogg", "mp3")
FILE_NAME = re.compile(r"^([a-z0-9_]+)_(\d\d)\.(?:wav|ogg|mp3)$")

## Calls whose first argument is a sound id, and those whose second is
FIRST_ARGUMENT = re.compile(
    r"\b(?:_play|play|play_at|_play_at|_play_far|play_sound_3d|get_stream|get_variant|has_sound|_make_bed)"
    r"\(\s*\"([a-z0-9_]+)\"")
SECOND_ARGUMENT = re.compile(
    r"\b(?:_later|play_later|_add_loop|_add_layer)\(\s*[^,()]+,\s*\"([a-z0-9_]+)\"")
## "a" if x else "b" inside a call that plays a sound, or assigned to an id
TERNARY = re.compile(r"\"([a-z0-9_]+)\" if [^\n]*? else \"([a-z0-9_]+)\"")
## Tables that map something to a sound id
TABLE_ENTRY = re.compile(r"\"(?:id|sound)\": \"([a-z0-9_]+)\"")
## Functions that return the id of the sound for a surface
SOUND_FOR = re.compile(r"static func \w*sound_for\([^\n]*\n(.*?)(?=\n\n\n|\Z)", re.S)
RETURNED = re.compile(r"return \"([a-z0-9_]+)\"")
## Ids built at run time: "breath_%s_%s" % [set, phase]
FORMATTED = re.compile(r"\"([a-z0-9_%]*%s[a-z0-9_%]*)\"")
LITERAL = re.compile(r"\"([a-z0-9_]+)\"")

failures: list[str] = []
checks = 0


def expect(condition: bool, what: str) -> None:
    global checks
    checks += 1
    if condition:
        print("[test_audio_assets] ok: %s" % what)
    else:
        print("[test_audio_assets] FAILED: %s" % what)
        failures.append(what)


def read_wav(path: Path) -> dict:
    """Format, loop points and the samples of a RIFF/WAVE file."""
    raw = path.read_bytes()
    info = {"format": 0, "channels": 0, "rate": 0, "bits": 0, "loop": None, "samples": array("h")}
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        return info
    position = 12
    while position + 8 <= len(raw):
        tag, size = struct.unpack_from("<4sI", raw, position)
        body = raw[position + 8:position + 8 + size]
        if tag == b"fmt ":
            info["format"], info["channels"], info["rate"], _, _, info["bits"] = struct.unpack_from("<HHIIHH", body)
        elif tag == b"data" and info["bits"] == 16:
            samples = array("h")
            samples.frombytes(body[:len(body) - len(body) % 2])
            if sys.byteorder == "big":
                samples.byteswap()
            info["samples"] = samples
        elif tag == b"smpl" and size >= 60 and struct.unpack_from("<I", body, 28)[0] >= 1:
            _, _, start, end = struct.unpack_from("<4I", body, 36)
            info["loop"] = (start, end)
        position += 8 + size + (size & 1)
    return info


def check_files() -> dict[str, list[Path]]:
    files = sorted(p for extension in EXTENSIONS for p in AUDIO.rglob("*." + extension))
    expect(len(files) > 100, "assets/audio holds the sound set (%d files)" % len(files))

    by_id: dict[str, list[Path]] = defaultdict(list)
    badly_named = []
    for path in files:
        match = FILE_NAME.match(path.name)
        if match is None:
            badly_named.append(path.name)
            continue
        by_id[match.group(1)].append(path)
    expect(not badly_named, "every file is named <id>_<NN>.<wav|ogg|mp3> (%s)" % ", ".join(badly_named[:5]))

    gaps = []
    scattered = []
    for sound_id, paths in by_id.items():
        numbers = sorted(int(FILE_NAME.match(p.name).group(2)) for p in paths)
        if numbers != list(range(1, len(numbers) + 1)):
            gaps.append(sound_id)
        if len({p.parent for p in paths}) > 1:
            scattered.append(sound_id)
    expect(not gaps, "variants are numbered from 01 without gaps (%s)" % ", ".join(gaps[:5]))
    expect(not scattered, "the variants of a sound share a folder (%s)" % ", ".join(scattered[:5]))

    unimported = [p.name for p in files if not p.with_name(p.name + ".import").exists()]
    expect(not unimported, "every file has its .import next to it (%s)" % ", ".join(unimported[:5]))
    orphans = [p.name for p in AUDIO.rglob("*.import") if not p.with_name(p.name[:-len(".import")]).exists()]
    expect(not orphans, "no .import is left without its file (%s)" % ", ".join(orphans[:5]))

    wrong_format = []
    clipping = []
    silent = []
    loop_faults = []
    total_bytes = 0
    seconds = 0.0
    for path in files:
        total_bytes += path.stat().st_size
        if path.suffix != ".wav":
            continue
        wav = read_wav(path)
        if (wav["format"], wav["channels"], wav["bits"]) != (1, 1, 16) or wav["rate"] not in (11025, 16000, 22050, 32000, 44100, 48000):
            wrong_format.append(path.name)
            continue
        samples = wav["samples"]
        seconds += len(samples) / float(wav["rate"])
        loudest = max(max(samples), -min(samples)) if len(samples) else 0
        if loudest >= 32700:
            clipping.append(path.name)
        if loudest < 300:
            silent.append(path.name)
        is_loop = FILE_NAME.match(path.name).group(1).endswith("_loop") if FILE_NAME.match(path.name) else False
        if is_loop != (wav["loop"] is not None):
            loop_faults.append(path.name)
        elif is_loop:
            start, end = wav["loop"]
            # The loop runs from the first sample to just short of the guard copies
            if start != 0 or not (0 < end <= len(samples)) or end / float(wav["rate"]) < 1.0:
                loop_faults.append(path.name + " (points)")
            elif end < len(samples) and list(samples[end:]) != list(samples[:len(samples) - end]):
                loop_faults.append(path.name + " (guard samples)")
    expect(not wrong_format, "every WAV is mono 16-bit PCM (%s)" % ", ".join(wrong_format[:5]))
    expect(not clipping, "nothing clips (%s)" % ", ".join(clipping[:5]))
    expect(not silent, "nothing is silent (%s)" % ", ".join(silent[:5]))
    expect(not loop_faults, "loops carry loop points and one-shots do not (%s)" % ", ".join(loop_faults[:5]))
    print("[test_audio_assets] %d sounds, %d files, %.0f s, %.1f MB" % (
        len(by_id), len(files), seconds, total_bytes / 1e6))
    expect(total_bytes < 20e6, "the sound set stays under 20 MB (%.1f MB)" % (total_bytes / 1e6))
    return by_id


def check_code(by_id: dict[str, list[Path]]) -> None:
    asked: dict[str, str] = {}
    literals: set[str] = set()
    patterns: list[re.Pattern] = []
    for path in sorted(SOURCE.rglob("*.gd")):
        text = path.read_text(encoding="utf-8")
        literals.update(LITERAL.findall(text))
        for template in FORMATTED.findall(text):
            patterns.append(re.compile("^" + re.escape(template).replace("%s", "[a-z0-9]+") + "$"))
        # Only the audio code and the footsteps name sounds by id
        if "systems/audio" not in path.as_posix() and path.name != "footstep_system.gd":
            continue
        where = path.relative_to(ROOT).as_posix()
        for sound_id in FIRST_ARGUMENT.findall(text) + SECOND_ARGUMENT.findall(text) + TABLE_ENTRY.findall(text):
            asked.setdefault(sound_id, where)
        for first, second in TERNARY.findall(text):
            asked.setdefault(first, where)
            asked.setdefault(second, where)
        for body in SOUND_FOR.findall(text):
            for sound_id in RETURNED.findall(body):
                asked.setdefault(sound_id, where)

    expect(len(asked) > 80, "the game code names its sounds (%d ids found)" % len(asked))
    unknown = sorted("%s (%s)" % (i, w) for i, w in asked.items() if i not in by_id)
    expect(not unknown, "every sound the code asks for exists (%s)" % ", ".join(unknown[:8]))

    unused = sorted(i for i in by_id if i not in literals and not any(p.match(i) for p in patterns))
    expect(not unused, "every sound file is used by the game (%s)" % ", ".join(unused[:8]))


def check_generator(by_id: dict[str, list[Path]]) -> None:
    try:
        import numpy  # noqa: F401
    except ImportError:
        print("[test_audio_assets] note: numpy is not installed; not comparing with tools/sfx")
        return
    sys.path.insert(0, str(ROOT / "tools" / "sfx"))
    import generate  # noqa: F401  (importing registers every sound)
    from registry import SOUNDS

    rendered = {name: spec.variants for name, spec in SOUNDS.items()}
    on_disk = {name: len(paths) for name, paths in by_id.items()}
    missing = sorted(set(rendered) - set(on_disk))
    stray = sorted(set(on_disk) - set(rendered))
    counts = sorted(n for n in set(rendered) & set(on_disk) if rendered[n] != on_disk[n])
    expect(not missing, "every sound the generator defines is rendered (%s)" % ", ".join(missing[:5]))
    expect(not stray, "every file has a generator entry (%s)" % ", ".join(stray[:5]))
    expect(not counts, "variant counts match the generator (%s)" % ", ".join(counts[:5]))
    misplaced = sorted(n for n, spec in SOUNDS.items() if n in by_id and by_id[n][0].parent.name != spec.category)
    expect(not misplaced, "files are in the folders the generator writes to (%s)" % ", ".join(misplaced[:5]))


def main() -> int:
    if not AUDIO.is_dir():
        print("[test_audio_assets] FAIL: %s does not exist" % AUDIO)
        return 1
    by_id = check_files()
    check_code(by_id)
    check_generator(by_id)
    if failures:
        print("[test_audio_assets] FAIL: %d problem(s): %s" % (len(failures), "; ".join(failures)))
        return 1
    print("[test_audio_assets] PASS (%d checks)" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
