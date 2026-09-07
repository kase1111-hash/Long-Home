# Changelog

All notable changes to Long-Home will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added (the game is now playable end to end)

- **Rendered, walkable terrain.** `TerrainService` owns a `TerrainGenerator`, so every
  mountain produces seam-exact meshes and `HeightMapShape3D` collision. A new
  `ProceduralMountainGenerator` builds a 640 m mountain per mountain id (FastNoiseLite seeded
  from the id, shaped by the mountain database: summit plateau, benches, slideable snow
  slopes, downclimb faces, cliff bands scaled by exposure, gullies) with a guaranteed
  sub-slide-angle corridor from summit to base camp. `CliffDistanceField` replaces the
  O(cells x cliffs) search with an O(cells) chamfer transform.
- **Sky, sun, fog and weather visuals.** `EnvironmentVisuals` (owned by `EnvironmentService`)
  adds a procedural alpine sky, a sun light driven by `TimeService`, weather-driven fog and
  snowfall particles, on both Forward+ and Compatibility renderers.
- **A climber.** The player capsule is replaced by a primitive-built climber (jacket, helmet,
  pack, limbs); the chase camera pivot is top-level and starts behind the climber.
- **A goal.** `DescentGoal` builds a visible base camp (tent, flag, beacon beam) and completes
  the run with `CLEAN_RETURN` / `INJURED_RETURN` on arrival (or `FATALITY` when falling out of
  the world). Previously a run could only end by abandonment or a fatal event.
- **Descent HUD** (`src/ui/hud/descent_hud.*`): elevation, descent progress, distance to base
  camp, movement state, time and temperature, plus control hints (`H` toggles) and the
  diegetic message channel.
- **Run tracking.** `GameStateManager` feeds player position samples and elapsed time into
  the `RunContext`, so distance, elevation progress and the post-game path are real.
- **Godot-native tests**: `tests/check_scripts.gd` (every script compiles),
  `tests/smoke_goal.gd` (menu → descent → base camp → resolution, headless),
  `tests/smoke_walk.gd` (walks the climber down the corridor to base camp at 4x speed),
  `tests/smoke_slide.gd` (starts a slide on the nearest slideable slope and lets it end),
  `tests/ui_tour.gd` (presses every screen's real buttons and screenshots them),
  `tests/screenshot_tour.gd` (renders the descent to PNGs, with weather/time overrides).

### Changed

- The debug quick start no longer runs on every debug build. It is opt-in:
  `godot --path . -- --quick-start [--mountain=<id>]`, and it selects a real mountain.
- Mouse capture is owned by `main.gd`: captured during `DESCENT`, visible in every other
  state. `player_camera.gd` no longer toggles it or handles `Esc`.
- Planning: the default summit-to-base line is analysed on entry, so **Begin Descent** is
  available without placing waypoints; risky lines show a warning instead of blocking. The
  topo map's summit/base markers use the terrain's real start and goal, and the forecast
  panel shows the mountain's typical conditions before a run.
- The player spawns on the summit plateau facing base camp; `run.start_elevation` and
  `run.target_elevation` come from the terrain.

### Balance

- The guaranteed corridor tops out at 27° (a cautious walk); steeper sliding terrain lies
  beside it. Walking speed is 2.4 m/s base and no longer collapses with stability.
- Fatigue accrues about a third as fast; a full descent ends tired rather than collapsed.

### Fixed

#### Gameplay (the climber ground to a halt within ten seconds)
- "Hesitation" counted any held movement key, drained stability to zero and, because speed
  scaled with stability, stopped the climber dead. Hesitation is now input that produces no
  movement.
- BodyConditionService simulated a private BodyState nobody read and never received the
  climber's activity, slope, weight or insulation, so the cold model treated a moving,
  clothed climber as standing still naked (frostbite in minutes). It now adopts the run's
  body state and samples the player and gear.
- RecordingService read a non-existent `body_part` field on injuries.

#### Compilation (95 of 111 scripts failed to load in Godot 4.2)
- Added explicit static types wherever a variable was inferred from a `Variant`
  (`Dictionary.get`, untyped array elements, enum `keys()[i]`, `pop_back`, `get_meta`);
  Godot 4.2 rejects those at parse time and treats the inference warning as an error
- `PackedFloat32Array` has no `min()`/`max()` in 4.2; `TextureRect.EXPAND_KEEP_ASPECT_CENTERED`
  no longer exists; `TerrainService.get_all_chunks()` / `get_bounds()` were called but never
  defined; `TopoMapGenerator.generate_map` takes `Vector3` bounds
- `Array[Dictionary]` gear variant lists were assigned untyped literals (runtime error);
  `get_meta()` with a null default errored on a missing key
- The planning screen stayed visible over the world during a descent
- Terrain mesh triangles were wound face-down; collision floated ~3000 m above the mesh;
  chunk seams had cracks; freshly built meshes were destroyed on `terrain_loaded`
- The drone camera's `look_at` spammed one error per frame when hovering above the player
- Every map display regenerated the whole topo map on `terrain_loaded` (3.4 s each, four
  displays); one cached map per terrain load with single-pass contours brings the
  descent-start hitch from ~6 s to ~2.5 s
- Space now also starts a slide from a standstill on slideable snow, not only while walking
- Sunset/sunrise no longer jumps six times brighter and flips shadows: the sun and "moon"
  branches meet at the horizon
- Fog and snowfall snap to each run's configured weather instead of easing in from the
  previous run's sky; snowfall intensity changes no longer wipe every flake
- The sun disc is hidden through the light's sky mode, so Forward+ soft shadows keep their
  penumbra
- The terrain generator followed whichever camera it saw first (the drone's, parked near the
  origin), and culled every chunk as "too far"; it now follows the live camera and never
  distance-culls the mountain. The world is revealed only once the climber and camera are
  placed, so a second run never flashes the previous base camp
- Resuming from the pause menu re-entered `DESCENT` and rebuilt the whole descent
  (respawning the player under every system that had cached it); one player node now lives
  for the whole session and is reset between runs
- The post-game panel stacked its moments list, insight and buttons on top of each other
- One-shot 3D audio players were positioned before entering the tree (an engine error on
  every footstep)

#### Service Bootstrap (game was unplayable past the main menu)
- Added a service bootstrapper in `main.gd`: 25 service classes (MountainDatabase,
  GearDatabase, SaveManager, PlanningService, audio stack, Camera Director AI,
  DroneService, replay/streamer tooling, BodyConditionService, SlideSystem,
  RopeService, RiskDetectionService, fatal event systems, tutorial systems)
  registered themselves with ServiceLocator but were never instantiated anywhere,
  so mountain selection, gear loadout, saving, audio, body simulation, sliding
  physics, risk detection and fatal events silently never came online
- EnvironmentService now owns TimeService/WeatherService creation; `main.gd` no
  longer creates duplicate instances that fought over the service registry
- Environment is now seeded from the run's start conditions via
  `EnvironmentService.initialize_run()`

#### Planning Phase (flow dead-ended before descent)
- Planning screen now builds its UI at `_ready()` - its `.tscn` is a bare root,
  so every `@onready` node reference was null and `_setup_ui()` crashed
- Terrain now loads for the selected mountain when the planning screen opens;
  previously terrain only loaded at descent start, so the topo map was empty
  and the route could never validate (Confirm button stayed disabled forever)
- Topo map display regenerates when new terrain loads
- Elevation profile draw callback is now actually connected

#### Sliding
- SlideSystem now starts/ends slide physics when the player state machine
  enters/leaves SLIDING - `begin_slide()` previously had no callers
- Removed duplicate `slide_started` emission from the player state machine
  (SlideSystem is the single source, matching the earlier `slide_ended` fix)

#### Other runtime fixes
- PhysicalMap built its UI after requesting TerrainService; when the service was
  already registered the callback fired synchronously and crashed on null UI nodes
- Pause menu status panel and map check overlay info panel looked up
  runtime-created containers by NodePath, which fails for auto-generated node
  names - both now use direct references
- Audio buses are created before the audio managers assign players to them
- DroneCamera is now registered as a service (RecordingService requested it,
  but it was never registered, silently disabling camera-track recording)
- Tutorial instructor is now added to the scene tree when spawned

## [0.1.0-alpha] - 2026-01-02

### Added

#### Core Architecture
- Event-driven architecture with EventBus (69 signals for cross-system communication)
- Service Locator pattern for dependency injection
- Game State Manager for global state machine
- Core data structures: RunContext, BodyState, GearState, StartConditions, Injury

#### Player Systems
- Player controller with CharacterBody3D-based movement
- Multi-state player movement system (standing, walking, downclimbing, traversing, sliding, falling)
- Posture system for stance tracking
- Animation controller with procedural animations
- First-person camera system
- Footstep audio system with surface-aware sounds

#### Sliding Mechanics
- High-skill sliding system with control spectrum (Controlled → Marginal → Unstable → Lost)
- Exit zone detection for slide recovery points
- Slope angle and speed calculations
- Control degradation based on terrain and fatigue

#### Rope System
- Rope deployment and rappelling mechanics
- Anchor detection and quality assessment
- Rope inventory management
- Rappel controller with physics-based descent

#### Terrain & World
- Terrain service with DEM (Digital Elevation Model) support
- Surface type detection (11 surface types including snow, ice, rock variants)
- Terrain zone classification (walkable, steep, slideable, downclimb, rappel required, cliff)
- Slope analysis and risk zone detection

#### Environment Systems
- Time service with day/night cycle
- Weather service with 9 weather states (clear through whiteout)
- Wind strength system (6 levels including gale)
- Temperature system with feels-like calculations
- Surface condition manager for dynamic terrain state

#### Body Condition
- Fatigue tracking with threshold-based warnings
- Cold exposure system with body part tracking
- Injury manager with localized damage
- Diegetic feedback (breathing, visual effects, movement penalties)

#### Camera & Drone
- Drone camera system with documentary-style witness perspective
- Camera Director AI with 5 shot intent types (Context, Tension, Commitment, Consequence, Release)
- Signal detector for interesting moment identification
- Imperfection engine for human-like camera behavior
- Emotional rhythm engine for pacing
- Drone battery management

#### Fatal Event System
- Ethical 5-phase death sequence (Moment of Error → Loss of Control → Vanishing → Aftermath → Acknowledgment)
- Ethical constraints enforcing respectful death handling
- Fatal audio controller for ambient sound management
- Fatality detector for trigger conditions

#### Audio System
- Ambient audio manager with environmental soundscapes
- Player audio manager (breathing, footsteps, gear sounds)
- UI audio manager for interface feedback
- Procedural audio generation
- Audio ducking for dramatic moments

#### User Interface
- Main menu system
- Mountain selection with multi-peak support
- Gear loadout configuration
- Route planning phase with topo map integration
- Physical map (diegetic in-game map)
- Self-check screen for body status
- Pause menu with map review
- Post-game screen with resolution display
- Topo replay visualization for run analysis
- Settings menu with streaming options
- Statistics display

#### Tutorial System
- "Knife edge" opening sequence
- Diegetic instructor system
- Organic lesson learning mechanics

#### Save & Progression
- Save manager with profile persistence
- Player profile tracking
- Route memory for learned paths
- Run history for session tracking
- Progression tracker for achievements

#### Streaming & Replay
- Recording service for run capture
- Replay player for playback
- Highlight generator for key moments
- Speedrun timer with split tracking
- OBS integration with scene suggestions and markers
- Streamer-friendly tools and configurations

#### Risk Detection
- Risk calculator for situation assessment
- Risk zone analyzer for terrain danger identification
- Fall predictor for outcome estimation
- Risk feedback with diegetic warnings

### Technical Details
- **Engine**: Godot 4.2 (Forward Plus rendering)
- **Language**: GDScript
- **Resolution**: 1920x1080 with viewport stretching
- **Physics**: 3D with 9.8 m/s² gravity
- **Anti-aliasing**: MSAA 3D enabled
- **Codebase**: 111 GDScript files, ~46,000 lines of code

### Known Limitations
- Audio uses placeholder sounds (real assets pending)
- Tutorial instructor dialogue and interactive teaching moments incomplete
- Scout drone (diegetic easy-mode recon) not yet implemented
- Single sample mountain included (more mountains planned)
- Avalanche and crevasse systems not yet implemented
- Gear damage system not yet implemented
- Accessibility features pending
- Known bugs documented in AUDIT-REPORT.md (terrain zone classification, null safety, weather window)

---

*Long-Home - A mountaineering descent simulation about consequence, not conquest.*
