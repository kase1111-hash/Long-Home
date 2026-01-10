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

### Implemented Systems (16 Major Systems)

| System | Description |
|--------|-------------|
| **Terrain & World** | Real USGS topo data, DEM loading, slope analysis |
| **Sliding Mechanics** | High-skill, terrifying descent with control spectrum |
| **Rope System** | Strategic tool with time/safety trade-offs |
| **Time & Environment** | Day/night cycles, weather, temperature |
| **Body Condition** | Fatigue, cold exposure, injuries (diegetic feedback) |
| **Risk Detection** | Invisible but omnipresent danger feedback |
| **Drone Camera** | Documentary-style "witness" camera |
| **Camera Director AI** | AI filmmaker controlling shots with 5 intent types |
| **Fatal Event Handling** | Ethical 5-phase death sequence system |
| **Ethical Streaming** | Streamer-friendly content handling |
| **User Interface** | Minimalist, diegetic UI |
| **Tutorial System** | "Knife edge" opening, diegetic instructor |
| **End States** | Multiple failure/success types with replay |
| **Audio Design** | Environmental soundscape (wind, crampon, breathing) |
| **Streaming & Replay** | Recording, playback, and OBS integration |
| **Save & Progression** | Route memory, knowledge tracking |

---

## Getting Started

### Prerequisites

- [Godot Engine 4.2+](https://godotengine.org/download)

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
   - Click the "Play" button in the top-right corner

### Running Tests

```bash
# From project root
godot --headless --script tests/run_tests.gd
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

### Actions

| Action | Key |
|--------|-----|
| Initiate Slide | `Space` |
| Deploy Rope | `R` |
| Check Self (Body Status) | `C` |
| Open Map | `M` |
| Lean Left (during slide) | `Q` |
| Lean Right (during slide) | `E` |

---

## Project Structure

```
Long-Home/
├── src/
│   ├── core/                          # Architecture & state management
│   │   ├── event_bus.gd              # 150+ signals for cross-system communication
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
│   │   └── player/                   # Player controller (10 components)
│   │       ├── player_controller.gd  # Main CharacterBody3D
│   │       ├── player_movement.gd    # Movement physics
│   │       ├── player_input.gd       # Input handling
│   │       ├── player_animation_controller.gd
│   │       ├── player_camera.gd      # First-person perspective
│   │       ├── player_state_machine.gd
│   │       ├── posture_system.gd     # Stance & posture
│   │       ├── footstep_system.gd    # Footstep audio
│   │       └── animation_data.gd
│   │
│   ├── systems/                      # Game mechanics
│   │   ├── audio/                    # Audio management (9 files)
│   │   ├── body/                     # Physical condition (4 files)
│   │   ├── sliding/                  # Slide mechanics (5 files)
│   │   ├── rope/                     # Rope system (7 files)
│   │   ├── terrain/                  # Terrain analysis (8 files)
│   │   ├── environment/              # Weather & time (5 files)
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
│   │   ├── planning/                 # Route planning phase
│   │   ├── hud/                      # In-game diegetic UI
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
├── tests/                            # Unit tests
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
| `EventBus` | Global event communication (150+ signals) |
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

The `EventBus` contains **150+ signals** organized by category:

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
| [CHANGELOG.md](CHANGELOG.md) | Version history and release notes |
| [SPEC-SHEET.md](SPEC-SHEET.md) | Complete game specification covering all 16 major systems |
| [PROGRAMMING-ROADMAP.md](PROGRAMMING-ROADMAP.md) | Implementation guide with code structure and data models |

---

## Development Status

### Implemented (v0.1.0)

- [x] Core architecture (Event Bus, State Manager, Service Locator)
- [x] Player controller with multi-state movement
- [x] Sliding system with control spectrum
- [x] Rope and anchor system
- [x] Terrain system with DEM support
- [x] Body condition tracking (fatigue, cold, injuries)
- [x] Camera Director AI with 5 shot intents
- [x] Drone camera system
- [x] Fatal event handling (5 phases)
- [x] Tutorial system ("knife edge" opening)
- [x] Planning phase with topo maps
- [x] Audio system with diegetic feedback
- [x] Save and progression system
- [x] OBS/streaming integration
- [x] Replay and analysis tools

### Planned

- [ ] Avalanche system
- [ ] Crevasse detection and traversal
- [ ] Advanced rescue mechanics
- [ ] More complex weather generation
- [ ] Gear damage system
- [ ] Real audio assets (currently placeholders)
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

*License information to be added.*

---

*Long-Home v0.1.0-alpha - A mountaineering descent simulation*
