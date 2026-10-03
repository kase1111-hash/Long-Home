# Long-Home

An atmospheric indie game and narrative-driven mountaineering descent simulation built with Godot Engine 4.2.

> *"The game is about consequence, not conquest. You don't win by reaching the summit. You win by returning intact, having made good decisions before and after the summit."*

## Table of Contents

- [Overview](#overview)
- [Core Philosophy](#core-philosophy)
- [Features](#features)
- [Getting Started](#getting-started)
- [Controls](#controls)
- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Game Systems](#game-systems)
- [Documentation](#documentation)
- [Development Status](#development-status)
- [Related Repositories](#related-repositories)

---

## Overview

**Long-Home** is an atmospheric indie Godot game that delivers a narrative-driven mountaineering descent simulation focusing on the psychological tension of returning from a summit. This indie survival game explores what traditional mountain games ignore - what happens after the climb, when fatigue sets in, weather turns, and every decision carries weight.

As a first-person mountain survival experience, Long-Home combines realistic terrain simulation with consequence-driven gameplay. The game emphasizes environmental storytelling and diegetic feedback systems, creating an immersive alpine descent where players must read the mountain rather than a dashboard.

**Engine:** Godot 4.2
**Language:** GDScript
**Version:** 0.1.0-alpha

---

## Core Philosophy

### Design Pillars

1. **Consequence over Conquest** - Focus on the descent, not the ascent
2. **Judgment Under Fatigue** - Decision-making deteriorates with exhaustion
3. **Organic Teaching** - No UI popups; players learn through environment and consequences
4. **Diegetic First** - In-world perspective (maps are physical, info is earned)
5. **Ethical Streaming** - Respectful handling of failure/death moments
6. **Silence as Tool** - Audio and quiet moments create tension
7. **Realistic Risk** - Based on actual mountaineering accident reports

### Key Mantras

- *"The player should feel like they are reading the mountain, not a dashboard"*
- *"The drone never steals focus from the mountain"*
- *"The camera does not look away—but it does not exploit"*
- *"Witness without harm"*

---

## Features

### 18 Major Systems

| System | Status | Description |
|--------|--------|-------------|
| **Terrain & World** | Complete | Procedural 640 m mountains per peak (DEM loading optional), rendered meshes + collision, slope analysis, 11 surface types, 6 terrain zones; low-poly forests, krummholz, snags, boulders and talus placed from the terrain, with colliders; glaciers with icefalls, moraines and open or snow-bridged crevasses |
| **Footing & Movement** | Complete | One traction model for boots, crampons, axe and hands: Tobler walking pace, grip-margin slips, slow face-in downclimbing, timed crampon changes, landing impacts |
| **Glaciers & Crevasses** | Complete | Probing ahead with the axe, snow bridges that give way under load and warmth, falls into the slot carved into the terrain, front-pointing out or waiting for a rescue |
| **Sliding Mechanics** | Complete | Slope-plane glissade physics with braking, crampon catches and rock impacts; physical self-arrest; snow spray or dust trails the climber |
| **Rope System** | Complete | Anchor building and testing, doubled-rope rappels under brake-hand control, re-anchoring, rope pulls that can snag |
| **Skiing & Snowboarding** | Complete | Touring skis or a splitboard: carving, skidding, hockey stops, crashes into slides, rock damage |
| **Planning & Route Scoring** | Complete | A guidebook per mountain (lines graded F-ED with pitch topos and book times), navigation gear, a day plan with turnaround time, logbook scoring of the line actually climbed, and an unlockable full route (up and down) |
| **Time & Environment** | Complete | Day/night cycles with a sun-lit procedural sky, wind-driven cloud sheet and distant ranges, 9 weather states with fog, snow, rain and spindrift, temperature; glow/SSAO/cascaded shadows on Forward+ |
| **Body Condition** | Complete | Fatigue, cold exposure, injuries (diegetic feedback) |
| **Risk Detection** | Complete | Terrain analysis, fall prediction, diegetic risk cues |
| **Drone Camera** | Partial | Spectator drone implemented; scout drone not yet implemented |
| **Camera Director AI** | Complete | AI filmmaker with 5 shot intent types |
| **Fatal Event Handling** | Complete | Ethical 5-phase death sequence system |
| **User Interface** | Complete | Minimalist UI across all game phases plus a small descent HUD and control hints |
| **Tutorial System** | Structural | Framework exists; instructor dialogue and interactions incomplete |
| **Audio Design** | Structural | System architecture in place; uses placeholder audio assets |
| **Streaming & Replay** | Complete | Recording, playback, OBS integration, highlights |
| **Save & Progression** | Complete | Route memory, run history, player profiles |

---

## Getting Started

### Prerequisites

- [Godot Engine 4.2.x](https://godotengine.org/download) (developed and tested with 4.2.2; the
  project uses the Forward+ renderer but also runs with the Compatibility/OpenGL 3 renderer)
- No external assets are required: terrain, sky, clouds, distant ranges, particles, the climber and base camp are all procedural

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/kase1111-hash/Long-Home.git
   cd Long-Home
   ```

2. Open the project in Godot:
   ```bash
   godot --editor project.godot
   ```

3. Run the game:
   - Press `F5` in the Godot editor, or
   - Click the "Play" button in the top-right corner, or
   - From a terminal: `godot --path .`

4. Play: **New Descent** → pick a mountain → choose your kit → look at the topo map
   (double-click to add waypoints, or just **Begin Descent** on the direct line) → walk,
   slide and rope your way from the summit plateau down to the lit base camp beacon.
   Reaching base camp ends the run and opens the resolution and post-game analysis.

### Developer quick start

Skip the menus and drop straight onto a mountain:

```bash
godot --path . -- --quick-start                 # The Knife Edge
godot --path . -- --quick-start --mountain=north_face
```

Mountain ids: `knife_edge`, `north_face`, `the_couloir`, `storm_peak`, `long_way_down`.
Add `--full-route` to start a full route (up from base camp, then down) without beating the
game first.

### Running Tests

The Godot-native checks need the `godot` binary on your `PATH` (a 4.2.x release build):

```bash
# Every script must compile (Godot 4.2 treats several inference warnings as errors)
godot --headless --path . -s res://tests/check_scripts.gd

# Boot headless, walk into a descent, reach base camp, land on the resolution screen
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_goal.gd

# Actually walk the climber down the corridor to base camp at 4x speed (~3 min wall clock)
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_walk.gd -- --mountain=knife_edge

# The mountain physics model: footing, downclimbing, walking pace, glissade, arrest, skis
godot --headless --path . -s res://tests/test_physics_model.gd

# Crampons off, glissade a firm slope, brake with S, self-arrest with Space
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_slide.gd

# Downclimb a steep snow face, take crampons off and on (F), land 1/3/6 m drops
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_mechanics.gd

# Build an anchor at a cliff band (R), strip it, build again, rappel down, pull the rope
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_rappel.gd -- --mountain=north_face

# Step into skis (T), run the fall line, skid to a stop, step out (add --board for the splitboard)
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_ski.gd

# Trees and boulders: placement rules, clear zones, colliders, mesh overrides, anchors, map
# symbols, and in a live descent: blocked by a boulder at walking pace, hurt by a tree at speed
godot --headless --audio-driver Dummy --path . -s res://tests/test_scatter.gd

# Glaciers and crevasses: generation on every mountain, ice and snow zones, open slots and
# walkable bridges, maps and grades, and in a live descent: probe, a bridge collapse, climbing
# out with axe and crampons, and a rescue without them
godot --headless --audio-driver Dummy --path . -s res://tests/test_glacier.gd

# Alpine grades, guidebook lines on every mountain, book times, route scoring and the logbook
godot --headless --audio-driver Dummy --path . -s res://tests/test_route_scoring.gd

# Full route: plan both legs from the guidebook, base camp -> summit -> base camp, then a retreat
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_full_route.gd

# Walk every screen with the real buttons and save a screenshot of each (needs a display;
# xvfb-run works on a headless Linux box)
mkdir -p /tmp/tour && xvfb-run -a -s "-screen 0 1280x720x24" \
  godot --path . --rendering-driver opengl3 --audio-driver Dummy \
  -s res://tests/ui_tour.gd -- --out=/tmp/tour

# Render the descent itself to PNGs (supports --weather=STORM, --time=18.5, --hide-ui,
# --slide, and --gear for skiing, a downclimb, a glissade and a rappel)
mkdir -p /tmp/shots && xvfb-run -a -s "-screen 0 1280x720x24" \
  godot --path . --rendering-driver opengl3 --audio-driver Dummy \
  -s res://tests/screenshot_tour.gd -- --out=/tmp/shots --quick-start
```

Python-only checks (regex based, no Godot needed):

```bash
python tests/test_gdscript_validation.py
python tests/test_procedural_generation.py
```

---

## Controls

### Movement

| Action | Key |
|--------|-----|
| Move Forward | `W` |
| Move Back | `S` |
| Move Left | `A` |
| Move Right | `D` |
| Look | Mouse (captured during the descent) |

Movement is camera-relative everywhere: walking, downclimbing (push toward the slope you want to
descend), on the rope (push down the face to let rope run) and on skis (`A`/`D` turn the skis).

### Actions

| Action | Key |
|--------|-----|
| Glissade (sit down on a 20-42° snow or scree slope) / self-arrest while sliding | `Space` |
| Brake a glissade (heels and axe spike) | hold `S` |
| Lean a glissade | `A` / `D` or `Q` / `E` |
| Rope: build an anchor and rappel, then unclip on a ledge or build the next anchor; strip the anchor while building | `R` |
| Let the rope run fast while rappelling | hold `Space` |
| Strap crampons on / take them off (timed) | `F` |
| Step into skis or a splitboard / step out (timed, on snow, ≤ 38°) | `T` |
| Probe the snow ahead with the axe shaft or a ski pole (on a glacier) | `G` |
| On skis: turn, skid to slow or stop, tuck or pole | `A`/`D`, `S`, `W` |
| Check Self (Body Status) | `C` |
| Open Map (needs the topo map in your pack) | `M` |
| Pause / resume | `Esc` |
| Toggle control hints | `H` |

The HUD is deliberately small: elevation, how far you have descended, distance to base camp,
what you are doing, what is on your feet, the time and the temperature. Without an altimeter
the elevation is an estimate to the nearest 50 m. On the way up a full route, "Descended" and
"Base camp" read "Climbed" and "Summit". While you glissade, ski or work the rope, the hint line
swaps to the controls of that activity. Everything else is read from the mountain.

### How the mountain behaves

Every way down runs on one footing model (`src/entities/player/traction_model.gd`): the grip of
what is on your feet against `tan(slope)` plus a little for every step's braking.

- **Walking** follows Tobler's hiking function: steep descents are slower than the flat, side
  slopes slow you, soft snow and powder make you posthole, crampons scrape over rock. Boots hold
  firm snow to about 35°, but on ice they skate past about 7°. Crampons bite on ice and hard
  snow, but they ball up in warm slush.
- **Slips** happen on thin grip margins. Most are a stagger. On snow, ice, scree or broken rock
  steeper than a body can rest on, a slip becomes a slide; off a face, it becomes a fall. A
  plunged axe shaft, or the other holds while downclimbing, catches many of them.
- **Downclimbing** starts above 35°. The climber turns side-on, then faces in, and moves one
  placement at a time: about 0.3-0.5 m/s on snow with crampons and axe, slower on steep rock and
  ice. Hand holds (glove dexterity, cold fingers) and the axe add grip. Rock steeper than about
  52° needs the rope.
- **Rappelling** is a timed job before it is a descent. Find an anchor (a horn, a boulder, a
  crack for a nut, screws or a V-thread in ice, a buried picket or a cut bollard in snow), build
  it, weight-test it (it can fail the test) and thread a doubled rope (half its length reaches
  down). That takes 30-45 s, longer tired, cold-handed or in wind. You go down at about 1 m/s,
  faster with Space (more anchor load, snags and wear), and brake when you let go. You come off
  on easier ground, and the rope can snag when you pull it down.
- **Glissading** integrates gravity, friction, drag and your lean on the slope plane. Soft snow
  is controllable, hard snow runs away, and nothing brakes on ice. Glissading with crampons on
  can catch a point and flip you. **Self-arrest** is a roll onto the axe and then real arrest
  friction: it stops you in a few metres on firm snow, fails on ice, and can tear the axe out
  of your hands at speed.
- **Skiing and snowboarding** carve and skid. The edges carry your momentum round until the turn
  asks more than the snow and your legs can hold. Past that the skis skid, and the skid scrubs
  speed. A hockey stop works on snow but not on ice. Straight-lining a 35° slope tops out at
  about 40 m/s, so you control speed by turning. Crashes come from speed, hard skids, ice and
  tired legs. A crash on a steep slope becomes a slide, and skis grind to a halt on rock.
- **Falls** are judged on landing from the impact speed, cushioned by the surface. A hop is
  nothing, about 3 m is a hard landing, about 6 m breaks something, and a disabling injury ends
  the run with a rescue.

### Trees and boulders

Each mountain is dressed after it loads (`src/systems/terrain/terrain_scatter.gd`):

- **Trees and boulders.** Low-poly conifers grow in clumps below a treeline set by the
  mountain's climate, thinning into wind-flattened krummholz and dead snags near the top of
  their range. Boulders lie on scree and rock and pile up as talus under the cliff bands, and
  small rocks litter broken ground.
- **Clear ground.** The normal route, the summit and base camp are kept clear.
- **Obstacles.** You walk round trunks and boulders. Sliding, skiing or falling into one at
  speed hurts, and the faster you are, the worse it is.
- **Anchors and maps.** A sound tree or a big boulder makes the best rappel anchor, and the
  topo maps print woodland and boulders.

**Swapping in better meshes.** The meshes are built in code (`scatter_meshes.gd`). To replace
one, put a Mesh resource (`.tres`, `.res`, `.mesh`) or a model (`.glb`, `.gltf`, `.tscn`) in
`res://assets/scatter/`:

- **Names:** `conifer_0`, `conifer_1`, `conifer_2`, `shrub_0`, `shrub_1`, `snag_0`, `snag_1`,
  `boulder_0` … `boulder_3`, `rock_0` … `rock_2`. A bare `conifer`, `boulder` and so on replaces
  every variant of that kind.
- **Fitting:** each mesh is fitted from its bounding box, base down, to the object's size, so it
  can be authored at any scale. Model the origin at the base of the trunk, or the middle of the
  rock's footprint.
- **Materials:** the mesh's own materials are kept.

### Glaciers and crevasses

Most peaks carry a glacier in the flank beside the normal route (`glacier_field.gd`, built by
the procedural generator; *The Knife Edge* has none). The ice flows down the fall line between
lateral moraines and steepens into icefalls where the rock steps are. Below the equilibrium line
it is bare ice; above it, snow lies on top.

- **Crevasses** open where the ice stretches: rows across the icefalls, chevrons along the
  edges, and the bergschrund at the head. Open slots are cut into the terrain, several metres
  deep. Others are hidden under snow bridges, which show only a faint sag.
- **Probing** (`G`, with an axe or ski poles). The shaft goes into the snow ahead and tells you
  whether it is hollow, and it leaves a dark probe hole. Nothing on the mountain is labelled; a
  probe and the sag are all you get.
- **Bridges give way.** A thin bridge goes in about a second under a walker, and a thick one
  nearly always holds. Afternoon warmth weakens them; skis and a glissade spread the load. When
  a bridge goes, that stretch of the crevasse is carved open to the debris below (4-8.5 m) and
  you fall in for real.
- **Getting out.** With an axe in hand and crampons on, push against a wall to front-point out
  at about 0.2 m/s. It is tiring, and a tired climber can skate back down. Without them there
  is no way up the ice, and after a long wait the run ends in a rescue.
- **On paper.** The topo map shades the glacier and draws the open crevasses (not the hidden
  ones). The guidebook adds half a grade or more for a crevassed glacier, slows its book time
  and notes "crosses the glacier (probe ahead)". The normal route keeps off the ice, and every
  guidebook line goes round the icefalls.

### Planning, the guidebook and the logbook

Planning happens at the hut, on paper. Nothing about a route is ever drawn, labelled or marked
on the mountain itself.

- **The guidebook** (Planning screen, *Guidebook* tab) lists each mountain's lines: the *Normal
  Route* (the easiest way off), a *Face Direct* down the fall line (the cliff bands abseiled), a
  snow *Couloir* or *Snowfield* (the ski and glissade line) and a *Rib* or *Spur* off to one
  side. The printed guide has the first two; the others come from the hut book once you have been
  on the mountain. Each line has a grade (IFAS F … ED, plus a commitment grade I-VI from its
  length), a book time, the abseils and rope it needs, and a pitch-by-pitch topo with altitudes.
  The lines are inked on the paper map; *Follow this line* copies one onto your plan.
- **Book times** come from the game's own movement model (Tobler pace, downclimbing speed, rope
  set-up and abseil times), so they are what a competent party actually takes. The *Plan* tab
  times your own line for your own pack, and sets out the day: start, back by, sunset, daylight
  to spare. A full route adds a turnaround time.
- **Navigation gear** (new *Navigation* category): a *guidebook* puts the route card beside your
  map on the mountain; without a *topo map* there is nothing to pull out; a *compass* steadies
  your position in cloud; an *altimeter* gives your height to the metre, which is how you find
  yourself on a topo given in metres.
- **The logbook.** Every run is scored on the line you actually climbed, measured with the
  guidebook's yardstick: `line points (grade, height) × outcome × style × pace × plan × on-sight`.
  Falls and tumbling slides earn no difficulty, and only abseils actually made count. Pace is
  against the book time of the same line, so a hard line is not punished for being slow. Each
  mountain keeps its best score and the last 25 entries; the resolution screen shows the line,
  style and score, and the post-game screen the breakdown.

### The full route

Come down **The Long Way Down** alive and every mountain opens a *full route* (toggle it on the
mountain select screen): an alpine start at base camp, the climb to the summit, and the way home.
Plan both legs; lines with an abseil pitch cannot be climbed on foot. The summit is a cairn with
prayer flags and no marker; standing on top turns you round. Walk back into camp without the
summit and the run ends as a retreat: home safe, a fraction of the points.

---

## Project Structure

```
Long-Home/
├── src/
│   ├── core/                          # Architecture & state management
│   │   ├── event_bus.gd              # 69 signals for cross-system communication
│   │   ├── enums.gd                  # Game enumerations & constants
│   │   ├── service_locator.gd        # Dependency injection system
│   │   ├── game_state_manager.gd     # Global state machine
│   │   └── data/                     # Core data structures
│   │       ├── run_context.gd        # Complete run state
│   │       ├── body_state.gd         # Physical condition tracking
│   │       ├── gear_state.gd         # Equipment state
│   │       ├── start_conditions.gd   # Difficulty parameters
│   │       └── injury.gd             # Injury data class
│   │
│   ├── entities/
│   │   └── player/                   # Player controller (9 components)
│   │       ├── player_controller.gd  # Main CharacterBody3D
│   │       ├── player_movement.gd    # Movement physics
│   │       ├── player_input.gd       # Input handling
│   │       ├── player_animation_controller.gd
│   │       ├── player_camera.gd      # Third-person chase camera
│   │       └── player.tscn           # Procedural climber model
│   │       ├── player_state_machine.gd
│   │       ├── posture_system.gd     # Stance & posture
│   │       ├── footstep_system.gd    # Footstep audio
│   │       └── animation_data.gd
│   │
│   ├── systems/                      # Game mechanics
│   │   ├── planning/                 # Guidebook survey, alpine grades, book times, route scoring
│   │   ├── summit_goal.gd            # Summit cairn + full-route summit check
│   │   ├── audio/                    # Audio management (9 files)
│   │   ├── body/                     # Physical condition (4 files)
│   │   ├── sliding/                  # Slide mechanics (5 files)
│   │   ├── rope/                     # Rope system (7 files)
│   │   ├── terrain/                  # Procedural mountains, meshes, collision, analysis,
│   │   │                             # trees and boulders (terrain_scatter, scatter_meshes),
│   │   │                             # glacier and crevasse data (glacier_field)
│   │   ├── glacier/                  # Crevasse falls, bridge collapse, climbing out, probing
│   │   ├── environment/              # Weather, time, sky/clouds/ranges/fog/precipitation visuals (8 files)
│   │   ├── descent_goal.gd           # Base camp marker + run completion
│   │   ├── risk/                     # Risk detection (5 files)
│   │   ├── drone/                    # Drone camera (5 files)
│   │   ├── camera_director/          # AI film director (5 files)
│   │   ├── fatal_event/              # Death sequence (5 files)
│   │   ├── replay/                   # Recording & playback (5 files)
│   │   ├── tutorial/                 # First-time experience (4 files)
│   │   ├── save/                     # Persistence (5 files)
│   │   └── streaming/                # OBS integration (1 file)
│   │
│   ├── ui/                           # User interface
│   │   ├── main_menu.gd
│   │   ├── selection/                # Gear & mountain selection
│   │   ├── planning/                 # Route planning: topo map, guidebook tab, route cards
│   │   ├── hud/                      # Descent HUD, physical map, self-check
│   │   ├── pause/                    # Pause menu
│   │   ├── analysis/                 # Post-game analysis
│   │   ├── stats/                    # Statistics display
│   │   ├── settings/                 # Game settings
│   │   ├── post_game_screen.gd
│   │   └── resolution_screen.gd
│   │
│   ├── data/                         # Game databases
│   │   ├── gear_database.gd
│   │   └── mountain_database.gd
│   │
│   └── scenes/
│       └── main.gd                   # Main scene controller
│
├── data/                             # Game data files
│   └── mountains/
│       └── sample_mountain/
│           └── manifest.json
│
├── tests/                            # Godot-native checks (check_scripts, smoke_goal, ui_tour,
│                                     # screenshot_tour, test_route_scoring, smoke_full_route,
│                                     # test_scatter, test_glacier)
│                                     # and Python regex validators
├── SPEC-SHEET.md                     # Complete game specification
├── PROGRAMMING-ROADMAP.md            # Implementation guide
├── project.godot                     # Godot configuration
└── icon.svg                          # Project icon
```

---

## Architecture

### Core Systems

The game uses a **Service Locator** pattern with an **Event Bus** for cross-system communication.

#### Autoloaded Singletons

| Service | Purpose |
|---------|---------|
| `EventBus` | Global event communication (69 signals) |
| `GameEnums` | Shared enumerations and constants |
| `ServiceLocator` | Dependency injection registry |
| `GameStateManager` | Global state machine |

#### Game States

```
MAIN_MENU → MOUNTAIN_SELECT → LOADOUT_CONFIG → PLANNING → TUTORIAL → DESCENT → RESOLUTION → POST_GAME
                                                              ↓
                                                          PAUSED
```

#### Player Movement States

```
STANDING ↔ WALKING ↔ DOWNCLIMBING ↔ TRAVERSING
    ↓
SLIDING ↔ ARRESTED
    ↓
FALLING → INCAPACITATED

ROPING (parallel state during rope operations)
RESTING (temporary recovery state)
```

### Event-Driven Architecture

The `EventBus` contains **69 signals** organized by category:

- **Game State** (5 signals): `game_state_changed`, `run_started`, `run_ended`, etc.
- **Player** (6 signals): `player_movement_changed`, `micro_slip_occurred`, etc.
- **Sliding** (4 signals): `slide_started`, `slide_state_updated`, etc.
- **Rope** (7 signals): `rope_deployment_started`, `rappel_started`, etc.
- **Body Condition** (4 signals): `fatigue_threshold_crossed`, `injury_occurred`, etc.
- **Camera/Drone** (4 signals): `shot_intent_changed`, `drone_mode_changed`, etc.
- **Fatal Events** (3 signals): `fatal_event_started`, `fatal_phase_changed`, etc.
- **Audio** (5 signals): `audio_ready`, `wind_audio_changed`, etc.

---

## Game Systems

### Sliding System

The most complex mechanic - sliding is never fully safe.

**Control Spectrum:**
- **Controlled** (0.8-1.0): Player can steer and initiate stop
- **Marginal** (0.5-0.8): Limited steering, stopping difficult
- **Unstable** (0.2-0.5): Minimal control, exit zones only option
- **Lost** (0.0-0.2): No control, outcome determined by terrain

**Key Parameters:**
- Minimum slide slope: 25°
- Maximum slide slope: 45°
- Terminal velocity: 25 m/s
- Lean influence: 0.3 (indirect control)

### Camera Director AI

A three-layer AI that thinks in shots, not coordinates.

**Layers:**
1. **Situation Awareness** - Detects interesting moments via 15+ signals
2. **Directorial Intent** - Selects shot type (5 types)
3. **Camera Behavior** - Executes movement with human-like imperfection

**Shot Types:**
- **CONTEXT** - Wide, show scale
- **TENSION** - Medium, close, stay near
- **COMMITMENT** - Lower altitude, forward-tracking
- **CONSEQUENCE** - Hold longer, let it play out
- **RELEASE** - Pull back, breathe

### Fatal Event System

Ethically handles player death in 5 phases:

1. **Moment of Error** (1.5s) - Camera hesitates, framing error
2. **Loss of Control** (4s) - Wide shot, drone pulls away (not in)
3. **Vanishing** (3s) - Subject disappears behind terrain
4. **Aftermath** (6s) - Silence, wind only, emptiness
5. **Acknowledgment** (5s) - Drone ascends, terrain enormity revealed

**Ethical Constraints:**
- Drone NEVER zooms in on impact
- Drone NEVER confirms death
- Death inferred by absence of recovery

### Body Condition System

All feedback is diegetic - no numerical displays.

| Variable | Diegetic Expression |
|----------|---------------------|
| Fatigue | Breathing audio, camera sway, delayed inputs |
| Cold Exposure | Frost on screen, shivering animations |
| Hydration | Hand animation clumsiness |
| Injuries | Localized movement penalties |

**Self-Check Action:** Player can stop to check condition, revealing descriptive messages like:
- *"Legs burning. Pace unsustainable."*
- *"Fingers going numb. Need to keep moving."*

---

## Documentation

| Document | Purpose |
|----------|---------|
| [SPEC-SHEET.md](SPEC-SHEET.md) | Complete game specification covering all 16 major systems |
| [PROGRAMMING-ROADMAP.md](PROGRAMMING-ROADMAP.md) | Implementation guide with code structure and data models |
| [CHANGELOG.md](CHANGELOG.md) | Version history and release notes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor guidelines, coding standards, and PR process |
| [AUDIT-REPORT.md](AUDIT-REPORT.md) | Software audit findings and known bugs |
| [EVALUATION-REPORT.md](EVALUATION-REPORT.md) | Project quality and purpose evaluation |
| [SECURITY.md](SECURITY.md) | Security policy and vulnerability reporting |
| [claude.md](claude.md) | Quick developer reference for the codebase |

---

## Development Status

### Complete (v0.1.0)

- [x] Core architecture (Event Bus, State Manager, Service Locator)
- [x] Player controller with multi-state movement
- [x] Sliding system with control spectrum
- [x] Rope and anchor system
- [x] Terrain system with DEM support
- [x] Body condition tracking (fatigue, cold, injuries)
- [x] Camera Director AI with 5 shot intents
- [x] Drone camera system (spectator mode)
- [x] Fatal event handling (5 phases)
- [x] Planning phase with topo maps, a graded guidebook and a day plan
- [x] Route scoring and a per-mountain logbook
- [x] Full route (base camp to summit and back), unlocked after The Long Way Down
- [x] Save and progression system
- [x] OBS/streaming integration
- [x] Replay and analysis tools
- [x] Risk detection system

### Partial / Structural

- [ ] Tutorial system (framework exists; instructor dialogue incomplete)
- [ ] Audio system (architecture in place; uses placeholder assets)
- [ ] Scout drone (diegetic easy-mode drone not yet implemented)

### Planned

- [ ] Avalanche system
- [ ] Crevasse detection and traversal
- [ ] Advanced rescue mechanics
- [ ] More complex weather generation
- [ ] Gear damage system
- [ ] Real audio assets to replace placeholders
- [ ] Real USGS mountain data integration
- [ ] Accessibility features

---

## Comparable Inspirations

| Game | What Inspired |
|------|---------------|
| Journey | Emotional pacing, contemplative moments |
| Death Stranding | Terrain respect, environment as antagonist |
| The Long Dark | Survival mechanics, consequence-driven |
| Real mountaineering reports | Authentic accident scenarios |

**Unique differentiator:** None of these focus on descent psychology specifically.

---

## Related Repositories

Long-Home is part of a larger ecosystem of projects exploring natural language interfaces, AI agents, and indie game development.

### Game Development

| Repository | Description |
|------------|-------------|
| [Shredsquatch](https://github.com/kase1111-hash/Shredsquatch) | 3D first-person snowboarding infinite runner (SkiFree homage) |
| [Midnight-pulse](https://github.com/kase1111-hash/Midnight-pulse) | Procedurally generated night drive with synthwave aesthetics |

### NatLangChain Ecosystem

| Repository | Description |
|------------|-------------|
| [NatLangChain](https://github.com/kase1111-hash/NatLangChain) | Prose-first, intent-native blockchain protocol for natural language |
| [IntentLog](https://github.com/kase1111-hash/IntentLog) | Git for human reasoning - tracks "why" changes happen via prose commits |
| [RRA-Module](https://github.com/kase1111-hash/RRA-Module) | Revenant Repo Agent - converts abandoned repos into autonomous licensing agents |
| [mediator-node](https://github.com/kase1111-hash/mediator-node) | LLM mediation layer for matching, negotiation, and closure proposals |
| [ILR-module](https://github.com/kase1111-hash/ILR-module) | IP & Licensing Reconciliation for dispute resolution |
| [Finite-Intent-Executor](https://github.com/kase1111-hash/Finite-Intent-Executor) | Posthumous execution of predefined intent (Solidity smart contract) |

### Agent-OS Ecosystem

| Repository | Description |
|------------|-------------|
| [Agent-OS](https://github.com/kase1111-hash/Agent-OS) | Natural-language native operating system for AI agents |
| [synth-mind](https://github.com/kase1111-hash/synth-mind) | NLOS-based agent with six psychological modules for emergent continuity |
| [boundary-daemon-](https://github.com/kase1111-hash/boundary-daemon-) | Trust enforcement layer defining cognition boundaries for Agent OS |
| [memory-vault](https://github.com/kase1111-hash/memory-vault) | Secure, offline-capable, owner-sovereign storage for cognitive artifacts |
| [value-ledger](https://github.com/kase1111-hash/value-ledger) | Economic accounting layer for cognitive work (ideas, effort, novelty) |
| [learning-contracts](https://github.com/kase1111-hash/learning-contracts) | Safety protocols for AI learning and data management |

### Security Infrastructure

| Repository | Description |
|------------|-------------|
| [Boundary-SIEM](https://github.com/kase1111-hash/Boundary-SIEM) | Security Information and Event Management for AI systems |

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

*Long-Home v0.1.0-alpha - A mountaineering descent simulation*
