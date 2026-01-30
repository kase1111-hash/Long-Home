# Claude.md - Long-Home

## Project Overview

Long-Home is an atmospheric, narrative-driven mountaineering descent simulation built with Godot Engine 4.2 in GDScript. The game focuses on the psychological and physical challenges of returning from a mountain summit - not the climb itself.

**Philosophy:** "The game is about consequence, not conquest. You don't win by reaching the summit. You win by returning intact, having made good decisions."

**Status:** v0.1.0-alpha | ~111 GDScript files | ~46,254 lines of code

## Tech Stack

- **Engine:** Godot 4.2
- **Language:** GDScript
- **Rendering:** Forward Plus
- **Resolution:** 1920x1080 (viewport stretching)
- **Physics:** 3D with 9.8 m/s² gravity

## Architecture

### Core Patterns

1. **Event Bus Pattern** - `EventBus` singleton with 150+ signals for cross-system communication
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
├── core/           # Singletons, data classes (EventBus, ServiceLocator, RunContext)
├── player/         # Player controller and components (10 files)
├── systems/        # Game systems (73 files)
│   ├── terrain/    # Terrain generation and queries
│   ├── sliding/    # Slide physics (most complex system)
│   ├── rope/       # Rope and rappelling
│   ├── environment/# Weather, time, temperature
│   ├── body/       # Fatigue, cold, injuries
│   ├── drone/      # Drone camera system
│   ├── camera/     # AI Camera Director
│   ├── fatal/      # Ethical death handling
│   ├── risk/       # Risk detection
│   ├── audio/      # Sound management
│   ├── ui/         # User interface (17 files)
│   ├── tutorial/   # Onboarding
│   ├── save/       # Persistence
│   └── streaming/  # Recording and replay
├── scenes/         # .tscn scene files
└── data/           # Gear and mountain databases
tests/              # Python validation scripts
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
godot project.godot

# Run tests
godot --headless --script tests/run_tests.gd
python tests/test_gdscript_validation.py
python tests/test_procedural_generation.py
```

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
| Player mechanics | `src/player/player_controller.gd`, `player_movement.gd`, `player_state_machine.gd` |
| Adding events | `src/core/event_bus.gd` |
| New service | `src/core/service_locator.gd` |
| Terrain queries | `src/systems/terrain/terrain_service.gd` |
| Sliding physics | `src/systems/sliding/slide_system.gd` |
| Game states | `src/core/game_state_manager.gd` |
| Run data | `src/core/run_context.gd` |
| UI screens | `src/systems/ui/` |

## Documentation

- `README.md` - Project overview and getting started
- `SPEC-SHEET.md` - Complete game specification with detailed mechanics
- `PROGRAMMING-ROADMAP.md` - Implementation guide and extension points
- `CONTRIBUTING.md` - Contributor guidelines and PR process
- `CHANGELOG.md` - Version history
- `SECURITY.md` - Security policy
- `AUDIT-REPORT.md` - Software audit findings
