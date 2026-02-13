# Changelog

All notable changes to Long-Home will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
