# Claude.md - Long-Home

## Project Overview

Long-Home is an atmospheric, narrative-driven mountaineering descent simulation built with Godot Engine 4.2 in GDScript. The game focuses on the psychological and physical challenges of returning from a mountain summit - not the climb itself.

**Philosophy:** "The game is about consequence, not conquest. You don't win by reaching the summit. You win by returning intact, having made good decisions."

**Status:** v0.1.0-alpha | 118 GDScript files | boots to the menu and plays end to end
(summit → base camp → resolution → post-game) with procedural terrain, sky and a climber

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
│   └── player/         # Player controller and components (9 files)
├── systems/            # Game systems (77 files)
│   ├── descent_goal.gd # Base camp marker + run completion (win condition)
│   ├── terrain/        # Procedural mountains, meshes/collision, analysis (10 files)
│   ├── sliding/        # Slide physics (5 files)
│   ├── rope/           # Rope and rappelling (7 files)
│   ├── environment/    # Weather, time, temperature, sky/sun/fog visuals (6 files)
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
                        # screenshot_tour) + Python regex validators
```

## Key Systems

### 16 Major Systems

1. **Terrain** - Chunked loading, 11 surface types, 6 terrain zones by slope angle
2. **Sliding** - Control spectrum (CONTROLLED → MARGINAL → UNSTABLE → LOST)
3. **Rope** - Deployment, anchors, rappelling physics
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
16. **Mountain Database** - Mountain metadata

### State Machines

```
Game States:
MAIN_MENU → MOUNTAIN_SELECT → LOADOUT_CONFIG → PLANNING →
TUTORIAL → DESCENT → RESOLUTION → POST_GAME (PAUSED as overlay)

Player Movement States:
STANDING ↔ WALKING ↔ DOWNCLIMBING ↔ TRAVERSING
    ↓
SLIDING ↔ ARRESTED ↔ FALLING → INCAPACITATED
(ROPING and RESTING as parallel states)
```

## Common Commands

```bash
# Run in Godot editor
godot --editor project.godot

# Run game directly
godot --path .

# Skip the menus (developer shortcut)
godot --path . -- --quick-start --mountain=north_face

# Tests (run these before every commit; all need a Godot 4.2.x binary)
godot --headless --path . -s res://tests/check_scripts.gd        # every script compiles
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_goal.gd   # menu -> descent -> base camp
godot --headless --audio-driver Dummy --path . -s res://tests/smoke_walk.gd   # walks the corridor for real (~2 min)
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
  --audio-driver Dummy -s res://tests/ui_tour.gd -- --out=/tmp/tour    # every screen, with PNGs
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
| Adding events | `src/core/event_bus.gd` |
| New service | `src/core/service_locator.gd` |
| Terrain queries | `src/systems/terrain/terrain_service.gd` |
| Sliding physics | `src/systems/sliding/slide_system.gd` |
| Camera director | `src/systems/camera_director/camera_director.gd` |
| Fatal events | `src/systems/fatal_event/fatal_event_manager.gd` |
| Game states | `src/core/game_state_manager.gd` |
| Descent flow, spawn, HUD/goal lifecycle | `src/scenes/main.gd` |
| Win condition / base camp | `src/systems/descent_goal.gd`, `TerrainService.goal_position` |
| Procedural mountain shape | `src/systems/terrain/procedural_mountain_generator.gd` |
| Sky, sun, fog, snowfall | `src/systems/environment/environment_visuals.gd` |
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
