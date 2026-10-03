# Claude.md - Long-Home

## Project Overview

Long-Home is an atmospheric, narrative-driven mountaineering descent simulation built with Godot Engine 4.2 in GDScript. The game focuses on the psychological and physical challenges of returning from a mountain summit - not the climb itself.

**Philosophy:** "The game is about consequence, not conquest. You don't win by reaching the summit. You win by returning intact, having made good decisions."

**Status:** v0.1.0-alpha | 119 GDScript files | boots to the menu and plays end to end
(summit → base camp → resolution → post-game) with procedural terrain, sky, clouds, weather
particles and a climber

## Tech Stack

- **Engine:** Godot 4.2
- **Language:** GDScript
- **Rendering:** Forward Plus
- **Resolution:** 1920x1080 (viewport stretching)
- **Physics:** 3D with 9.8 m/s² gravity

## Architecture

### Core Patterns

1. **Event Bus Pattern** - `EventBus` singleton with 69 signals for cross-system communication
2. **Service Locator Pattern** - `ServiceLocator` singleton for dependency injection
3. **State Machine Pattern** - `GameStateManager` for game lifecycle, `PlayerStateMachine` for player states
4. **Component-Based Architecture** - Player uses composable component systems

### Autoloaded Singletons

- `EventBus` - Central event dispatcher (`src/core/event_bus.gd`)
- `GameEnums` - Shared enumerations (`src/core/enums.gd`)
- `ServiceLocator` - Service registry (`src/core/service_locator.gd`)
- `GameStateManager` - Global state machine (`src/core/game_state_manager.gd`)

### Communication Patterns

```gdscript
# Cross-system events
EventBus.signal_name.emit(args)
EventBus.signal_name.connect(callback)

# Service access
var service = ServiceLocator.get_service("ServiceName")
await ServiceLocator.wait_for_service("ServiceName")

# Registration (in _ready)
ServiceLocator.register_service("ServiceName", self)
```

## Project Structure

```
src/
├── core/               # Singletons, data classes (EventBus, ServiceLocator, RunContext)
│   └── data/           # Core data structures (RunContext, BodyState, GearState, etc.)
├── entities/
│   └── player/         # Player controller, components, surface particles (10 files)
├── systems/            # Game systems
│   ├── descent_goal.gd # Base camp marker + run completion (win condition; retreats on a full route)
│   ├── summit_goal.gd  # Summit cairn + full-route summit check
│   ├── planning/       # RouteSurvey (guidebook lines), RouteMetrics (pitches, book times),
│   │                   # AlpineGrade (F..ED, I..VI), RouteScorer (logbook scoring)
│   ├── terrain/        # Procedural mountains, meshes/collision, analysis; TerrainScatter (trees,
│   │                   # boulders: placement, MultiMesh, colliders) + ScatterMeshes (low-poly builders);
│   │                   # GlacierField (glacier coverage, moraines, crevasses)
│   ├── glacier/        # CrevasseSystem: bridge collapse, falls into the slot, climbing out, probing
│   ├── sliding/        # Slide physics (5 files)
│   ├── rope/           # Rope and rappelling (7 files)
│   ├── environment/    # Weather, time, temperature, sky/clouds/ranges/fog/precipitation visuals (8 files)
│   ├── body/           # Fatigue, cold, injuries (4 files)
│   ├── drone/          # Drone camera system (5 files)
│   ├── camera_director/# AI Camera Director (5 files)
│   ├── fatal_event/    # Ethical death handling (5 files)
│   ├── risk/           # Risk detection (5 files)
│   ├── audio/          # Sound management (9 files)
│   ├── tutorial/       # Onboarding (4 files)
│   ├── save/           # Persistence (5 files)
│   ├── replay/         # Recording and playback (5 files)
│   └── streaming/      # OBS integration (1 file)
├── ui/                 # User interface (18 files, incl. hud/descent_hud.gd)
├── data/               # Gear and mountain databases (2 files)
└── scenes/             # Scene management (1 file)
tests/                  # Godot-native checks (check_scripts, smoke_goal, ui_tour,
                        # screenshot_tour, test_route_scoring, smoke_full_route, test_scatter,
                        # test_glacier) + Python validators
```

## Key Systems

### 18 Major Systems

1. **Terrain** - Chunked loading, 11 surface types, 6 terrain zones by slope angle
2. **Sliding** - Slope-plane glissade physics, braking, physical self-arrest; control spectrum (CONTROLLED → MARGINAL → UNSTABLE → LOST)
3. **Rope** - Anchor building/testing, doubled-rope rappels under brake-hand control, re-anchoring, rope pulls
4. **Environment** - Day/night, 9 weather states, temperature with wind chill
5. **Body Condition** - Fatigue, cold exposure, location-specific injuries
6. **Drone** - Third-person camera, battery system
7. **Camera Director AI** - Shot-based thinking with emotional rhythm
8. **Fatal Events** - 5-phase ethical death handling
9. **Risk Detection** - Terrain analysis and fall prediction
10. **Audio** - Procedural and ambient sound
11. **UI** - Minimalist, diegetic (in-world) design
12. **Tutorial** - Organic instructor-based learning
13. **Save/Progression** - Player profiles, run history, achievements
14. **Streaming** - Recording, replay, OBS integration
15. **Gear Database** - Equipment definitions
16. **Mountain Database** - Mountain metadata, progress, logbook, full-route unlock
17. **Planning & Scoring** - Guidebook lines per mountain, alpine grades, book times, logbook scoring, full route
18. **Glaciers & Crevasses** - Glacier tongues with icefalls and moraines, open and snow-bridged crevasses, probing, bridge collapse, climbing out

### State Machines

```
Game States:
MAIN_MENU → MOUNTAIN_SELECT → LOADOUT_CONFIG → PLANNING →
TUTORIAL → DESCENT → RESOLUTION → POST_GAME (PAUSED as overlay)

Player Movement States:
STANDING ↔ WALKING ↔ DOWNCLIMBING ↔ TRAVERSING
    ↓
SLIDING ↔ ARRESTED ↔ FALLING → INCAPACITATED (→ rescue after 5 s)
SKIING (while skis/board are on; crashes → SLIDING)
(ROPING and RESTING as parallel states)
```

### Mountain physics (who owns the motion)

All footing, sliding and ski numbers live in `TractionModel` (static, pinned by
`tests/test_physics_model.gd`). `PlayerController._physics_process` runs: input → gear
changes (F crampons, T skis) → `PostureSystem` (grip margin → stability, slips) → state machine
→ `PlayerMovement.update` (which steps `SlideSystem.physics_step` while SLIDING and
`SkiPhysics.physics_step` while SKIING) → `_apply_physics` (move_and_slide, landing impacts,
fall detection). ROPING is kinematic: `RappelController` places the climber on the face.
DOWNCLIMBING and ARRESTED cling (no gravity, vertical follows the terrain).

### Trees, boulders and run history (who owns what)

`TerrainService.load_terrain` calls `TerrainScatter.rebuild` after the meshes and before
`terrain_loaded`, so maps (`TopoMapGenerator` prints woodland/boulders) and anchors
(`AnchorDetector.scatter_anchors`) see it. Obstacles are on physics layer 3 (`OBSTACLE_LAYER`
= 4): the player's `collision_mask` is 5 (terrain + obstacles); camera rays use 1 only.
`PlayerController._check_obstacle_impacts` turns a fast collision into `hit_obstacle` (incident
`obstacle_impact`, injury by speed, ski crash / slide upset). Systems announce incidents and
decisions with `EventBus.record_incident/record_decision`; `GameStateManager` logs them into
the active run (`RunContext.log_*`, camera-shot decisions skipped), which is what the post-game
key moments and `RouteScorer` style and abseil counts read.

### Glaciers and crevasses (who owns what)

`ProceduralMountainGenerator._setup_glacier` lays a glacier beside the corridor (at least 26 m
away, extent from `MountainDatabase.glacier_extent`; 0 = none) and plans its crevasses with its
own RNG, so the rest of the mountain is unchanged. `_fill_heights` blends the face into the
smooth ice surface, adds lateral moraines and cuts the open crevasses (bridged ones only sag
0.45 m). The result's `GlacierField` (weights and moraine on the height grid, crevasses with a
bucket index) becomes `TerrainService.glacier`. `TerrainService._classify_cell` makes glacier
cells ICE below the ELA or steeper than 40°, snow above, scree on moraine, ICE in open slots.
`TerrainScatter` skips glacier cells. `CrevasseSystem` (service, physics priority 10) checks
the bridge under the climber each frame (`collapse_hazard`: strength, temperature, load); a
collapse calls `TerrainService.carve_crevasse_section`, which lowers that stretch to a debris
floor, re-analyses the 3x3 chunks, reclassifies and updates cliff distances locally, and
rebuilds the chunk meshes (~65 ms). Climbing out holds the player (`PlayerController.held_by`
skips its own physics) and moves them up the wall. Incidents `crevasse_fall` / `crevasse_slip`
cost style; decisions `probe` and `crevasse_climbed_out` reach the post-game moments.
`RouteMetrics` and `RouteSurvey` count glacier metres (slower book pace, grade bump, cost;
`ICEFALL_COST` keeps every line off glacier steeper than 30°).

### Planning and scoring (who owns what)

`RouteMetrics.measure(line, terrain, options)` is the one yardstick: it resamples a line every
2 m, classifies pitches (walk < 30°, steep 30-35°, downclimb 35-50°, rope ground), times them
with the movement model (Tobler, `TractionModel.downclimb_speed`, rope set-up/abseil timings,
85% pace, x`GameEnums.TIME_SCALE`) and grades them (`AlpineGrade`). `RouteSurvey.survey(terrain)`
builds the guidebook (cached per terrain load). `RunContext.path_modes` records how each path
sample was travelled (`GameStateManager` maps movement state + slide control to a travel mode);
`RouteScorer.score_run` measures the travelled path with those modes (out-of-control ground and
jumps earn nothing), and `Main._score_run` files it in `MountainDatabase` before `record_run`
(on-sight is judged on the knowledge the run started with). Nothing route-related is ever placed
in the 3D world; `tests/smoke_full_route.gd` asserts there is no `Label3D` on the mountain.

## Common Commands

```bash
# Run in Godot editor
godot --editor project.godot

# Run game directly
godot --path .

# Skip the menus (developer shortcut; add --full-route for the up-and-down mode)
godot --path . -- --quick-start --mountain=north_face

# Tests (run these before every commit; all need a Godot 4.2.x binary)
godot --headless --path . -s res://tests/check_scripts.gd        # every script compiles
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_goal.gd   # menu -> descent -> base camp
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_walk.gd   # walks the corridor for real (~2 min)
godot --headless --path . -s res://tests/test_physics_model.gd                # traction/slide/ski numbers
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_slide.gd      # glissade, brake, arrest
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_mechanics.gd  # downclimb, crampons, landings
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_rappel.gd -- --mountain=north_face  # rope
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_ski.gd        # skis (add -- --board)
godot --headless --audio-driver Dummy --path . -s res://tests/test_scatter.gd        # trees, boulders, impacts, anchors
godot --headless --audio-driver Dummy --path . -s res://tests/test_glacier.gd        # glaciers, crevasses, probe, collapse
godot --headless --audio-driver Dummy --path . -s res://tests/test_route_scoring.gd  # grades, guidebook, scoring
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_full_route.gd    # full route + retreat
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
  --audio-driver Dummy -s res://tests/ui_tour.gd -- --out=/tmp/tour    # every screen, with PNGs
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
  --audio-driver Dummy -s res://tests/screenshot_tour.gd -- --out=/tmp/shots --hide-ui \
  --weather=STORM --wind=GALE --settle=400 --slide   # descent renders; also --time, --temperature
python tests/test_gdscript_validation.py
python tests/test_procedural_generation.py
```

Godot 4.2 gotchas that bit this project:
- A `var x := <Variant expression>` (Dictionary.get, untyped Array element, enum `keys()[i]`,
  `pop_back`, `get_meta`, ...) is a parse error. Always annotate: `var cell: TerrainCell = ...`
- `Array[T]` fields cannot be assigned an untyped literal at runtime; use `.assign([...])`
- New `class_name` files need an import pass (`godot --headless --path . --import`) before
  other scripts can reference them from a headless run
- Test harnesses run with `-s` are compiled before the autoloads exist: reach
  `GameStateManager` etc. via `root.get_node("/root/GameStateManager")` and `load()` (see
  `tests/smoke_goal.gd`)
- On the floor, `move_and_slide()` drops the vertical part of the velocity. A slide or skis that
  keep their speed in `player.velocity` must lift it back onto the slope plane each tick
  (`TractionModel.onto_slope_plane`), or a plain projection bleeds ~20% of the speed per frame
- Collision shapes must be scaled uniformly: the terrain `HeightMapShape3D` scaled (2, 1, 2)
  flipped contact normals and stopped fast bodies dead (heights are now pre-divided instead)
- A child's `_ready()` cannot `add_child` to its parent (the parent is still adding children);
  use `call_deferred` (see the gear meshes in `player_animation_controller.gd`)
- Kinematic vertical moves on steep floors: asking for more drop than the slope gives presses
  the body into the face and the physics slides the excess downhill (follow the terrain height
  change instead, as `PlayerMovement._update_downclimbing` does)
- There is no runtime query for the rendering method in 4.2: use
  `EnvironmentVisuals.detect_rendering_method()` (project setting + whether a RenderingDevice
  exists) before touching glow, SSAO, volumetric fog, proximity fade or PSSM shadows, none of
  which the Compatibility renderer has

## Coding Conventions

### Naming

- **Classes:** `PascalCase` (e.g., `PlayerController`)
- **Functions:** `snake_case` (e.g., `update_fatigue()`)
- **Variables:** `snake_case` (e.g., `current_state`)
- **Constants:** `SCREAMING_SNAKE_CASE` (e.g., `MAX_SPEED`)
- **Signals:** `snake_case` past tense verb (e.g., `player_moved`)
- **Private members:** Prefix with `_` (e.g., `_cached_cell`)

### File Template

```gdscript
class_name ClassName
extends BaseClass

# Signals
signal something_happened

# Constants
const MAX_VALUE := 100

# Exports
@export var exported_var: int = 0

# Public variables
var public_var: String = ""

# Private variables
var _private_var: float = 0.0

# Lifecycle
func _ready() -> void:
    pass

func _process(delta: float) -> void:
    pass

# Public methods
func public_method() -> void:
    pass

# Private methods
func _private_method() -> void:
    pass
```

### Type Hints

All functions must use type hints for parameters and return values.

### Logging

```gdscript
push_error("Critical failure message")
push_warning("Non-critical warning")
print("[SystemName] Debug message")
```

## Design Principles

1. **Diegetic UI** - All feedback is in-world (breathing, frost, hand animations), not numerical HUD
2. **Indirect Control** - Sliding uses leaning for influence, never direct stopping
3. **Ethical Death** - 5-phase respectful death handling, camera pulls away
4. **Shot-Based Camera** - AI thinks in intent (CONTEXT, TENSION, COMMITMENT, CONSEQUENCE, RELEASE)

## Key Files for Common Tasks

| Task | Key Files |
|------|-----------|
| Player mechanics | `src/entities/player/player_controller.gd`, `player_movement.gd`, `player_state_machine.gd` |
| Footing, slips, friction numbers | `src/entities/player/traction_model.gd`, `posture_system.gd` |
| Skis and splitboard | `src/entities/player/ski_physics.gd` (gear in `gear_database.gd`, `gear_state.gd`) |
| Rope, anchors, rappels | `src/systems/rope/rope_service.gd`, `rappel_controller.gd`, `anchor_detector.gd` |
| Adding events | `src/core/event_bus.gd` |
| New service | `src/core/service_locator.gd` |
| Terrain queries | `src/systems/terrain/terrain_service.gd` |
| Sliding physics, self-arrest | `src/systems/sliding/slide_system.gd`, `slide_controller.gd` |
| Camera director | `src/systems/camera_director/camera_director.gd` |
| Fatal events | `src/systems/fatal_event/fatal_event_manager.gd` |
| Game states | `src/core/game_state_manager.gd` |
| Descent flow, spawn, HUD/goal lifecycle | `src/scenes/main.gd` |
| Win condition / base camp | `src/systems/descent_goal.gd`, `TerrainService.goal_position` |
| Procedural mountain shape | `src/systems/terrain/procedural_mountain_generator.gd` |
| Sky, sun, fog, post-processing, snow/rain/spindrift | `src/systems/environment/environment_visuals.gd` |
| Cloud sheet, distant ranges | `src/systems/environment/cloud_layer.gd`, `horizon_range.gd` |
| Slide spray, dust, impact bursts | `src/entities/player/surface_effects.gd` |
| Descent HUD | `src/ui/hud/descent_hud.gd` |
| Run data | `src/core/data/run_context.gd` |
| UI screens | `src/ui/` |

## Documentation

- `README.md` - Project overview and getting started
- `SPEC-SHEET.md` - Complete game specification with detailed mechanics
- `PROGRAMMING-ROADMAP.md` - Implementation guide and extension points
- `CONTRIBUTING.md` - Contributor guidelines and PR process
- `CHANGELOG.md` - Version history
- `SECURITY.md` - Security policy
- `AUDIT-REPORT.md` - Software audit findings and known bugs
- `EVALUATION-REPORT.md` - Project quality and purpose evaluation
