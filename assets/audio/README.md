# Sound effects

Every sound the game plays is a file in this folder. There is no music.

The files here were **synthesized, not recorded**: `tools/sfx/generate.py`
builds each one from noise, resonances and small physical models (a crunch is
snow giving way in bursts, a carabiner is two pieces of aluminium ringing).
They were tuned by measurement and by looking at spectrograms, not by ear, so
treat them as a complete, coherent first pass. Any of them can be replaced by a
recording without touching code.

## How the game finds a sound

A sound's **id** is its file name without the number:

```
assets/audio/footsteps/footstep_snow_firm_03.wav   ->   id "footstep_snow_firm"
```

- Files that share an id are **variants**. One is picked at random each time,
  never the same one twice running.
- An id ending in `_loop` loops.
- The folder is only for tidiness. `SoundLibrary` scans every folder under
  `assets/audio`.

Code asks for a sound by id:

```gdscript
var audio := ServiceLocator.get_service("AudioService") as AudioService
audio.play("carabiner_clip")                       # heard the same wherever the camera is
audio.play_at("ice_crack", position, -6.0)         # placed in the world
```

## Replacing or adding a sound

- **Replace:** put your file in its place under the same name (`.wav`, `.ogg`
  or `.mp3`; delete the old file if the extension differs), then run
  `godot --headless --path . --import`.
- **Add a variant:** add a file with the next number
  (`footstep_snow_firm_06.wav`). Nothing else changes.
- **Add a new sound:** add `<id>_01.wav` and ask for the id in code.
  `python tests/test_audio_assets.py` fails if a file is never asked for, or an
  id is asked for that has no file.

A looping WAV made by the generator carries its loop points. One dropped in by
hand is looped end to end, so trim it to a clean loop first.

Levels: one-shots are rendered with a peak near -3 dBFS and loops at -20 dBFS
RMS. The mix is set in the audio managers (`src/systems/audio/`), not in the
files, so a replacement at about those levels drops straight in.

If a file re-rendered by the generator has been replaced by a recording, the
recording wins until the generator is run again: rendering overwrites every
file it knows. Remove the sound's `@sound` entry from `tools/sfx/` to keep a
recording for good.

## Regenerating

Needs Python 3.9+ and numpy.

```bash
python tools/sfx/generate.py                  # render everything (about 7 s)
python tools/sfx/generate.py wind breath      # only ids containing these words
python tools/sfx/generate.py --list           # every sound and what it is
python tools/sfx/generate.py --check -v       # measure the files on disk
python tools/sfx/generate.py --sheet out.png footstep_snow --max-variants 1
godot --headless --path . --import            # let Godot pick up the changes
```

Rendering is repeatable: each sound is seeded from its name, so the same code
gives the same files. `--sheet` draws spectrograms (time left to right, 40 Hz
to 20 kHz bottom to top on a log scale, the waveform's envelope above each):
the way to see what a change did without listening to 257 files.

Dull sounds are rendered at a lower sample rate than bright ones (11 kHz for
rumbles up to 44.1 kHz for metal) to keep the folder small.

## What is here

| Folder | Sounds |
|--------|--------|
| `ambient/` | The wind in layers (`wind_low_loop`, two `wind_mid_loop`, `wind_high_loop`, `wind_howl_loop`, `wind_whistle_loop`), `wind_gust`, `spindrift_loop`, `rain_loop`, `sleet_loop`, glacier ice (`ice_creak`, `ice_crack`), `snow_settle`, `rockfall_distant`, `avalanche_distant`, `flag_flap_loop` |
| `breath/` | Breaths one at a time in three sets (`breath_calm_in/out`, `breath_hard_in/out`, `breath_gasp_in/out`), `heartbeat`, and reactions: `reaction_relief`, `reaction_pain`, `reaction_effort`, `reaction_shiver` |
| `footsteps/` | A step on every surface (`footstep_snow_firm`, `_snow_soft`, `_snow_powder`, `_ice`, `_rock`, `_rock_wet`, `_scree`, `_grass`, `_mud`), crampons (`crampon_ice`, `crampon_rock`, `crampon_snow`) and slips (`slip_snow`, `slip_ice`, `slip_rock`) |
| `body/` | The body meeting things: `impact_snow`, `impact_rock`, `impact_ice`, `impact_tree`, `tumble`, `cloth_rustle`, `pack_drop` |
| `motion/` | Sliding (`slide_snow_loop`, `slide_ice_loop`, `slide_scree_loop`, `slide_start`, `slide_bump`), self-arrest (`axe_drag_loop`, `axe_bite`, `arrest_stop`, `axe_ripped`), skis and board (`ski_glide_loop`, `ski_carve_loop`, `ski_rock_loop`, `ski_stop`, `ski_land`, `ski_crash`, `ski_drop`, `binding_click`, `binding_release`, `board_ratchet`), `air_rush_loop` |
| `gear/` | Rope (`rope_uncoil`, `rope_thread`, `rope_throw`, `rope_run_loop`, `rope_creak`, `rope_tug`, `rope_jam`, `rope_flick`, `rope_pull_loop`, `rope_fall`, `rope_knot`), anchors (`anchor_rock`, `anchor_ice`, `anchor_snow`, `anchor_fail`), hardware (`carabiner_clip`, `carabiner_unclip`, `gear_jingle`, `sling_swish`, `strap_pull`, `crampon_clank`, `pack_zip`), axe (`axe_plant`, `axe_ice`, `axe_rock`, `ice_chips`), avalanche kit (`probe_firm`, `probe_hollow`, `shovel_dig`, `pit_tap`, `column_fracture`, `snow_scrabble`, `airbag_deploy`) |
| `hazard/` | Avalanches (`whumpf`, `snow_crack`, `slab_release`, `avalanche_roar_loop`, `avalanche_inside_loop`, `debris_settle`, `serac_fall`) and crevasses (`bridge_collapse`, `crevasse_ambience_loop`, `ice_groan`) |
| `ui/` | Menus (`ui_hover`, `ui_select`, `ui_confirm`, `ui_back`, `ui_toggle`, `ui_error`) and things in the hand (`map_unfold`, `map_fold`, `map_rustle`, `page_turn`, `watch_check`, `compass_open`) |

`python tools/sfx/generate.py --list` prints every sound with a one-line
description.

## Rules the sounds follow

From the audio design in `SPEC-SHEET.md`:

- **Diegetic.** Every sound has a source in the world. There are no warning
  tones: losing control of a slide is heard as the climber's heart and breath.
- **No voice.** Pain is a hiss through the teeth and a shaking breath, never a
  cry.
- **Fatal events are silent.** No impact, no cry: the climber's sounds are
  cut and only the wind is left (`FatalAudioController`).
