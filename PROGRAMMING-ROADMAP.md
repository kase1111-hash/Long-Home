# Long-Home: Programming Roadmap

This document provides implementation guidance for each game system, showing what has been built and how to extend it.

**Implementation Status:** All 16 major systems are implemented with 111 GDScript files.

---

## Table of Contents

1. [Core Architecture](#1-core-architecture) ✅
2. [Terrain System](#2-terrain-system) ✅
3. [Player Controller](#3-player-controller) ✅
4. [Sliding System](#4-sliding-system) ✅
5. [Rope & Anchor System](#5-rope--anchor-system) ✅
6. [Time & Weather System](#6-time--weather-system) ✅
7. [Body Condition System](#7-body-condition-system) ✅
8. [Risk Detection System](#8-risk-detection-system) ✅
9. [Drone Camera System](#9-drone-camera-system) ✅
10. [Camera Director AI](#10-camera-director-ai) ✅
11. [Fatal Event System](#11-fatal-event-system) ✅
12. [UI System](#12-ui-system) ✅
13. [Audio System](#13-audio-system) ✅
14. [Streaming & Replay System](#14-streaming--replay-system) ✅
15. [Tutorial & Onboarding](#15-tutorial--onboarding) ✅
16. [Save & Progression System](#16-save--progression-system) ✅

---

## File Structure Overview

```
src/
├── core/                              # 9 files
│   ├── event_bus.gd                  # 150+ signals
│   ├── enums.gd                      # GameEnums
│   ├── service_locator.gd            # DI container
│   ├── game_state_manager.gd         # State machine
│   └── data/                         # Data classes
│       ├── run_context.gd
│       ├── body_state.gd
│       ├── gear_state.gd
│       ├── start_conditions.gd
│       └── injury.gd
├── entities/player/                   # 10 files
├── systems/
│   ├── audio/                         # 9 files
│   ├── body/                          # 4 files
│   ├── sliding/                       # 5 files
│   ├── rope/                          # 7 files
│   ├── terrain/                       # 8 files
│   ├── environment/                   # 5 files
│   ├── risk/                          # 5 files
│   ├── drone/                         # 5 files
│   ├── camera_director/               # 5 files
│   ├── fatal_event/                   # 5 files
│   ├── replay/                        # 5 files
│   ├── tutorial/                      # 4 files
│   ├── save/                          # 5 files
│   └── streaming/                     # 1 file
├── ui/                                # 16 files
├── data/                              # 2 files
└── scenes/                            # 1 file
```

---

## 1. Core Architecture

**Status:** ✅ Implemented

**Files:**
- `src/core/event_bus.gd` - 150+ signals organized by category
- `src/core/enums.gd` - All game enumerations
- `src/core/service_locator.gd` - Dependency injection
- `src/core/game_state_manager.gd` - Global state machine

### 1.1 Game State Machine

```
States:
├── PreGame
│   ├── MainMenu
│   ├── MountainSelect
│   └── LoadoutConfig
├── Planning
│   ├── TopoView
│   └── RouteMarking
├── Descent
│   ├── Active (real-time gameplay)
│   ├── Paused
│   └── MapCheck
├── Resolution
│   ├── Success
│   ├── Injury
│   ├── Rescue
│   └── Fatality
└── PostGame
    ├── Replay
    └── Stats
```

**Implementation Steps:**
1. Create `GameStateManager` singleton
2. Implement state transition validation rules
3. Build event bus for cross-system communication
4. Create `RunContext` data object (carries all run-specific state)

### 1.2 Core Data Structures

```
RunContext:
├── StartConditions
│   ├── timeOfDay: float (0-24)
│   ├── weatherWindow: WeatherState
│   ├── gearLoadout: GearSet
│   ├── physicalCondition: BodyState
│   └── routeKnowledge: KnowledgeLevel
├── CurrentState
│   ├── position: Vector3
│   ├── velocity: Vector3
│   ├── bodyState: BodyState
│   ├── gearState: GearState
│   └── timeElapsed: float
└── History
    ├── pathTaken: List<Vector3>
    ├── decisions: List<DecisionEvent>
    └── incidents: List<IncidentEvent>
```

**Implementation Steps:**
1. Define all enum types (WeatherState, GearType, InjuryType, etc.)
2. Create immutable data classes for conditions
3. Implement serialization for save/replay
4. Build history recording system for post-run analysis

### 1.3 Dependency Injection Setup

**Systems to Register:**
- TerrainProvider
- WeatherService
- TimeService
- PlayerController
- CameraDirector
- AudioManager
- UIManager
- ReplayRecorder

---

## 2. Terrain System

**Status:** ✅ Implemented

**Files:**
- `src/systems/terrain/terrain_service.gd` - Main coordinator
- `src/systems/terrain/terrain_generator.gd` - Generation/loading
- `src/systems/terrain/terrain_chunk.gd` - Terrain cells
- `src/systems/terrain/terrain_cell.gd` - Cell data
- `src/systems/terrain/dem_loader.gd` - DEM file loading
- `src/systems/terrain/slope_analyzer.gd` - Slope calculations
- `src/systems/terrain/surface_classifier.gd` - Surface type detection
- `src/systems/terrain/topo_map_generator.gd` - Topo map rendering

### 2.1 Terrain Data Pipeline

```
Pipeline:
USGS DEM Data → Parser → HeightmapGenerator → TerrainMesh → PhysicsCollider
                              ↓
                    SlopeAnalyzer → TerrainMetadata
                              ↓
                    SurfaceClassifier → SurfaceMap
```

**Implementation Steps:**

#### Phase 1: Data Import
1. Create DEM file parser (GeoTIFF, USGS ASCII)
2. Build coordinate system converter (lat/long to world units)
3. Implement heightmap generator with configurable resolution
4. Create terrain chunk system for large mountains

#### Phase 2: Terrain Analysis
1. Implement `SlopeAnalyzer`:
   - Calculate slope angle per vertex/cell
   - Calculate aspect (compass direction of slope face)
   - Identify contour compression zones (cliffs)
   - Detect drainage channels

2. Create `TerrainMetadata` structure:
   ```
   TerrainCell:
   ├── slopeAngle: float (degrees)
   ├── aspect: float (0-360)
   ├── curvature: float
   ├── drainage: float
   ├── elevation: float
   └── distanceToCliff: float
   ```

#### Phase 3: Surface Classification
1. Implement `SurfaceClassifier`:
   ```
   SurfaceType:
   ├── Snow (firmness: 0-1)
   ├── Ice
   ├── Rock (wet/dry)
   ├── Scree
   └── Mixed
   ```

2. Surface determination rules:
   - Elevation → snow line threshold
   - Aspect + time → sun exposure → melt/freeze
   - Slope angle + drainage → water accumulation
   - Temperature history → ice formation

#### Phase 4: Runtime Queries
1. Create `TerrainQuery` API:
   ```
   GetSlopeAt(position) → float
   GetSurfaceAt(position) → SurfaceType
   GetAspectAt(position) → float
   IsCliffNear(position, radius) → bool
   FindExitZones(position, direction) → List<ExitZone>
   GetContourLines(bounds) → List<ContourLine>
   ```

### 2.2 Topo Map Generation

**Implementation Steps:**
1. Generate contour lines from heightmap at intervals
2. Create vector representation for smooth rendering
3. Implement LOD system for map zoom levels
4. Add landmark detection and labeling
5. Build route overlay system for planning phase

### 2.3 Procedural Detail

**Implementation Steps:**
1. Add procedural rock placement based on cliff zones
2. Generate snow accumulation in depressions
3. Create creek/drainage visual effects
4. Implement dynamic snow displacement (footprints, slides)

---

## 3. Player Controller

**Status:** ✅ Implemented

**Files:**
- `src/entities/player/player_controller.gd` - Main CharacterBody3D
- `src/entities/player/player_movement.gd` - Movement physics
- `src/entities/player/player_input.gd` - Input handling
- `src/entities/player/player_animation_controller.gd` - Animation state
- `src/entities/player/player_camera.gd` - First-person perspective
- `src/entities/player/player_state_machine.gd` - State management
- `src/entities/player/posture_system.gd` - Stance & stability
- `src/entities/player/footstep_system.gd` - Footstep audio
- `src/entities/player/animation_data.gd` - Animation resources

### 3.1 Movement State Machine

```
States:
├── Standing
├── Walking
├── Downclimbing
├── Traversing
├── Sliding (→ See Sliding System)
├── Roping (→ See Rope System)
├── Falling
├── Arrested
├── Resting
└── Incapacitated
```

**Implementation Steps:**

#### Phase 1: Basic Movement
1. Create `PlayerMovementController`:
   - Slope-aware movement speed calculation
   - Stamina-based speed modifiers
   - Terrain surface friction integration

2. Implement movement rules:
   ```
   baseSpeed = 1.0
   slopeModifier = cos(slopeAngle) for walking
   fatigueModifier = 1.0 - (fatigue * 0.5)
   surfaceModifier = GetFrictionFor(surface)
   finalSpeed = baseSpeed * slopeModifier * fatigueModifier * surfaceModifier
   ```

#### Phase 2: Posture System
1. Create `PostureController`:
   - Track center of mass
   - Calculate stability based on slope + speed
   - Trigger micro-slips when stability drops

2. Stability calculation:
   ```
   stability = baseStability
   stability -= slopeAngle * slopePenalty
   stability -= speed * speedPenalty
   stability -= fatigue * fatiguePenalty
   stability += crampons ? cramponBonus : 0

   if (stability < threshold) TriggerMicroSlip()
   ```

#### Phase 3: Downclimbing
1. Implement facing-slope detection
2. Create hand/foot placement system
3. Add hold quality assessment (visual only, no UI markers)
4. Implement fall trigger on bad holds

#### Phase 4: Input Handling
1. Create input buffer system
2. Implement "hesitation penalty" - delayed inputs increase risk
3. Add commitment detection for slide initiation

### 3.2 Animation Integration

**Implementation Steps:**
1. Create animation state machine matching movement states
2. Implement IK for hand/foot placement
3. Add procedural stumble/recovery animations
4. Create fatigue-based animation modifications (slower, sloppier)

---

## 4. Sliding System

**Status:** ✅ Implemented

**Files:**
- `src/systems/sliding/slide_system.gd` - Core physics
- `src/systems/sliding/slide_controller.gd` - Input handling
- `src/systems/sliding/slide_state_manager.gd` - Control spectrum
- `src/systems/sliding/slide_feedback.gd` - Audio/visual feedback
- `src/systems/sliding/exit_zone_detector.gd` - Safe exit detection

### 4.1 Slide Physics

**Implementation Steps:**

#### Phase 1: Slide Detection & Initiation
1. Create `SlideDetector`:
   ```
   canSlide = slopeAngle >= minSlideAngle
           && slopeAngle <= maxSlideAngle
           && surface.allowsSliding
           && playerState.canInitiateSlide
   ```

2. Implement commitment window:
   - Player presses slide input
   - Brief "point of no return" animation
   - Transition to sliding state

#### Phase 2: Slide Physics Engine
1. Create `SlidePhysicsController`:
   ```
   acceleration = gravity * sin(slopeAngle) * surfaceFriction
   drag = baseDrag * (1 + speed * speedDragCoefficient)

   velocity += acceleration * deltaTime
   velocity -= drag * deltaTime
   position += velocity * deltaTime
   ```

2. Surface friction values:
   ```
   SurfaceFriction:
   ├── FirmSnow: 0.3
   ├── SoftSnow: 0.5
   ├── Ice: 0.1
   ├── WetRock: 0.2
   └── Scree: 0.6
   ```

#### Phase 3: Control Influence
1. Implement player influence (not direct control):
   ```
   leanInput = GetPlayerLeanInput()  // -1 to 1

   // Lean affects trajectory, not speed
   lateralForce = leanInput * leanStrength * (1 - speed/maxSpeed)
   velocity += lateralForce * deltaTime

   // Edge engagement affects friction
   edgeInput = GetEdgeEngagement()
   effectiveFriction = baseFriction + (edgeInput * edgeBonus)
   ```

2. Speed-based control degradation:
   ```
   controlEffectiveness = 1.0 - (speed / terminalSpeed) * 0.8
   ```

#### Phase 4: Transition Zones
1. Detect slope angle changes during slide
2. Implement "compound slide" trigger:
   ```
   if (newSlopeAngle > currentSlope + transitionThreshold)
       TriggerCompoundSlide()  // Increases danger significantly
   ```

3. Create exit zone detection:
   ```
   isExitZone = slopeAngle < exitAngleThreshold
             || surfaceChange (snow pocket, rocks)
             || curvature allows natural stop
   ```

### 4.2 Slide State Spectrum

```
SlideControlLevel:
├── Controlled (0.8-1.0)
│   └── Player can steer, initiate stop
├── Marginal (0.5-0.8)
│   └── Limited steering, stop difficult
├── Unstable (0.2-0.5)
│   └── Minimal control, exit zones only option
└── Lost (0.0-0.2)
    └── No control, outcome determined by terrain
```

**Implementation Steps:**
1. Calculate control level continuously
2. Feed control level to animation/audio systems
3. Determine outcome probabilities based on control + terrain

### 4.3 Slide Outcome Resolution

**Implementation Steps:**
1. Create `SlideOutcomeResolver`:
   ```
   outcomes:
   ├── CleanStop → return to standing
   ├── TumbleStop → injury check, fatigue spike
   ├── TerrainCatch → gear damage chance
   ├── CompoundSlide → continue with lower control
   └── TerminalRunout → fatality sequence
   ```

2. Probability calculation:
   ```
   P(outcome) = f(controlLevel, speed, terrain, exitZoneQuality)
   ```

---

## 5. Rope & Anchor System

**Status:** ✅ Implemented

**Files:**
- `src/systems/rope/rope_service.gd` - Main coordinator
- `src/systems/rope/rope.gd` - Rope instance
- `src/systems/rope/rope_inventory.gd` - Rope management
- `src/systems/rope/rope_deployment_system.gd` - Deployment logic
- `src/systems/rope/rappel_controller.gd` - Rappel mechanics
- `src/systems/rope/anchor_detector.gd` - Anchor detection
- `src/systems/rope/anchor_point.gd` - Anchor data

### 5.1 Rope Mechanics

**Implementation Steps:**

#### Phase 1: Rope Inventory
1. Create `RopeInventory`:
   ```
   Rope:
   ├── length: float (meters)
   ├── condition: float (0-1)
   ├── weight: float
   └── deployed: bool
   ```

#### Phase 2: Anchor System
1. Create `AnchorDetector`:
   - Scan terrain for valid anchor points
   - Quality assessment based on rock type, angle, cracks
   - No UI indicators - visual/audio hints only

2. Anchor quality factors:
   ```
   anchorQuality = baseQuality
   anchorQuality *= rockTypeModifier
   anchorQuality *= angleModifier (overhangs worse)
   anchorQuality *= weatherModifier (ice degrades)
   ```

#### Phase 3: Deployment Sequence
1. Implement deployment state machine:
   ```
   States:
   ├── Selecting (looking for anchor)
   ├── Placing (animation + time cost)
   ├── Testing (brief pause)
   └── Ready
   ```

2. Time cost calculation:
   ```
   deployTime = baseTime
   deployTime += fatigueModifier
   deployTime += weatherModifier (wind, cold)
   deployTime += anchorDifficulty
   ```

#### Phase 4: Rappel Physics
1. Create `RappelController`:
   - Controlled descent along rope
   - Speed regulation (faster = more risk)
   - Rope jam probability based on terrain

2. Risk factors during rappel:
   ```
   jamProbability = baseJamChance
   jamProbability += ropeConditionPenalty
   jamProbability += terrainRoughness
   jamProbability += speedPenalty
   ```

### 5.2 Strategic Integration

**Implementation Steps:**
1. Calculate time cost vs risk reduction tradeoff
2. Track daylight impact of rope decisions
3. Implement "mandatory rope" terrain detection
4. Create rope recovery mechanics (takes time, may fail)

---

## 6. Time & Weather System

**Status:** ✅ Implemented

**Files:**
- `src/systems/environment/environment_service.gd` - Coordinator
- `src/systems/environment/time_service.gd` - Day/night cycle
- `src/systems/environment/weather_service.gd` - Storm/conditions
- `src/systems/environment/temperature_system.gd` - Temperature
- `src/systems/environment/surface_condition_manager.gd` - Surface changes

### 6.1 Time Simulation

**Implementation Steps:**

#### Phase 1: Time Scaling
1. Create `TimeService`:
   ```
   gameTimeScale = 10  // 1 real minute = 10 game minutes
   currentTime = startTime + (realTimeElapsed * gameTimeScale)
   ```

2. Time-dependent calculations:
   ```
   sunAngle = CalculateSunPosition(currentTime, latitude)
   shadowLength = CalculateShadows(sunAngle, terrain)
   temperature = CalculateTemperature(currentTime, elevation, weather)
   ```

#### Phase 2: Light System
1. Implement dynamic lighting based on sun position
2. Create shadow casting for terrain features
3. Add "golden hour" and "blue hour" color grading
4. Implement visibility degradation at dusk/night

### 6.2 Weather System

**Implementation Steps:**

#### Phase 1: Weather State Machine
```
WeatherStates:
├── Clear
├── Cloudy
├── Deteriorating
├── Storm
├── Whiteout
└── Clearing
```

#### Phase 2: Weather Transitions
1. Create `WeatherService`:
   ```
   transitionProbability = f(currentState, timeOfDay, elevation)
   if (random() < transitionProbability * deltaTime)
       TransitionTo(nextState)
   ```

2. Weather effects on systems:
   ```
   Weather Impact Matrix:
   ├── Visibility → camera, navigation
   ├── Wind → drone, stability, cold
   ├── Precipitation → surface conditions
   └── Temperature → body condition, ice formation
   ```

#### Phase 3: Forecasting
1. Generate weather "windows" at run start
2. Player can observe cloud patterns
3. No explicit forecast UI - environmental reading only

### 6.3 Surface Condition Updates

**Implementation Steps:**
1. Track sun exposure per terrain cell
2. Update snow firmness based on temperature history
3. Create ice formation on shaded wet rock
4. Implement freeze-thaw cycle effects

---

## 7. Body Condition System

**Status:** ✅ Implemented

**Files:**
- `src/systems/body/body_condition_service.gd` - Coordinator
- `src/systems/body/fatigue_manager.gd` - Fatigue tracking
- `src/systems/body/cold_exposure_manager.gd` - Cold system
- `src/systems/body/injury_manager.gd` - Injury management

**Data Classes:**
- `src/core/data/body_state.gd` - Physical condition state
- `src/core/data/injury.gd` - Injury data

### 7.1 Physical State Tracking

```
BodyState:
├── fatigue: float (0-1)
├── coldExposure: float (0-1)
├── hydration: float (0-1)
├── injuries: List<Injury>
└── mentalState: float (0-1)
```

**Implementation Steps:**

#### Phase 1: Fatigue System
1. Create `FatigueManager`:
   ```
   fatigueRate = baseRate
   fatigueRate *= speedModifier (faster = more fatigue)
   fatigueRate *= slopeModifier
   fatigueRate *= loadModifier (heavier pack = more)
   fatigueRate *= conditionModifier (cold/injured = more)

   fatigue += fatigueRate * deltaTime
   ```

2. Fatigue effects:
   ```
   Fatigue Thresholds:
   ├── 0.3: Breathing changes
   ├── 0.5: Movement slows, stability decreases
   ├── 0.7: Input delay, camera sway
   ├── 0.9: Critical - high fall risk
   └── 1.0: Collapse
   ```

#### Phase 2: Cold Exposure
1. Create `ColdExposureManager`:
   ```
   heatLoss = baseHeatLoss
   heatLoss *= temperatureDelta
   heatLoss *= windModifier
   heatLoss *= wetModifier
   heatLoss -= clothingInsulation

   coldExposure += heatLoss * deltaTime
   ```

2. Cold effects by body part:
   ```
   Extremity Priority:
   ├── Hands → dexterity loss, rope handling
   ├── Feet → stability, crampon effectiveness
   └── Core → systemic performance loss
   ```

#### Phase 3: Injury System
1. Create `InjuryManager`:
   ```
   Injury:
   ├── type: InjuryType
   ├── severity: float (0-1)
   ├── location: BodyPart
   └── effects: List<Effect>

   InjuryTypes:
   ├── Sprain (ankle, wrist)
   ├── Strain (muscle)
   ├── Laceration
   ├── Fracture
   └── Frostbite
   ```

2. Injury generation from events:
   ```
   OnSlideImpact(force):
       if (force > injuryThreshold)
           severity = (force - threshold) / maxForce
           location = DetermineImpactLocation()
           injury = GenerateInjury(severity, location)
   ```

### 7.2 Body State UI Integration

**Implementation Steps:**
1. Map fatigue → breathing audio + camera sway
2. Map cold → screen frost + animation shiver
3. Map injuries → localized movement penalties
4. Create "self-check" action for explicit state review

---

## 8. Risk Detection System

**Status:** ✅ Implemented

**Files:**
- `src/systems/risk/risk_detection_service.gd` - Main coordinator
- `src/systems/risk/risk_calculator.gd` - Stateless calculations
- `src/systems/risk/risk_zone_analyzer.gd` - Zone analysis
- `src/systems/risk/fall_predictor.gd` - Fall probability
- `src/systems/risk/risk_feedback.gd` - Subtle cues

### 8.1 Risk Calculation Engine

**Implementation Steps:**

#### Phase 1: Multi-Factor Risk Model
1. Create `RiskCalculator`:
   ```
   instantRisk = 0
   instantRisk += slopeRisk(terrain)
   instantRisk += speedRisk(velocity)
   instantRisk += fatigueRisk(bodyState)
   instantRisk += surfaceRisk(surface)
   instantRisk += weatherRisk(weather)
   instantRisk += gearRisk(equipment)

   // Multiplicative danger zones
   if (nearCliff) instantRisk *= cliffMultiplier
   if (noExitZone) instantRisk *= noExitMultiplier
   ```

#### Phase 2: Risk Zones
1. Precompute terrain risk zones
2. Create real-time risk field around player
3. Identify "point of no return" thresholds

#### Phase 3: Fall Probability
1. Create `FallPredictor`:
   ```
   fallProbability = baseChance
   fallProbability += stabilityDeficit * stabilityWeight
   fallProbability += speedExcess * speedWeight
   fallProbability += randomVariance * varianceWeight

   // Roll for fall events
   if (random() < fallProbability * deltaTime)
       TriggerFallEvent()
   ```

### 8.2 Risk Communication (Diegetic)

**Implementation Steps:**
1. Map risk level → audio cues:
   ```
   riskLevel > 0.3: Breathing intensifies
   riskLevel > 0.5: Heartbeat audible
   riskLevel > 0.7: Wind/environment dampened
   ```

2. Map risk level → visual cues:
   ```
   riskLevel > 0.4: Micro-slips occur
   riskLevel > 0.6: Camera instability
   riskLevel > 0.8: Peripheral blur
   ```

3. Map risk level → haptic feedback (if applicable)

---

## 9. Drone Camera System

**Status:** ✅ Implemented

**Files:**
- `src/systems/drone/drone_service.gd` - Coordinator
- `src/systems/drone/drone_entity.gd` - 3D drone object
- `src/systems/drone/drone_controller.gd` - Movement/positioning
- `src/systems/drone/drone_camera.gd` - Camera setup
- `src/systems/drone/drone_battery.gd` - Power system

### 9.1 Drone Entity

**Implementation Steps:**

#### Phase 1: Drone Physics
1. Create `DroneController`:
   ```
   DroneState:
   ├── position: Vector3
   ├── velocity: Vector3
   ├── rotation: Quaternion
   ├── battery: float (0-1)
   └── signalStrength: float (0-1)
   ```

2. Movement physics:
   ```
   // Momentum-based movement
   acceleration = inputDirection * thrustPower
   acceleration += windForce * windInfluence
   acceleration -= velocity * drag

   velocity += acceleration * deltaTime
   position += velocity * deltaTime

   // No instant stops
   minStopTime = 0.5 seconds
   ```

#### Phase 2: Environmental Constraints
1. Battery drain calculation:
   ```
   drainRate = baseDrain
   drainRate += altitude * altitudePenalty
   drainRate += windSpeed * windPenalty
   drainRate += temperature < 0 ? coldPenalty : 0

   battery -= drainRate * deltaTime
   ```

2. Signal degradation:
   ```
   signalStrength = 1.0
   signalStrength -= distance / maxRange
   signalStrength -= terrainOcclusion
   signalStrength -= weatherInterference
   ```

#### Phase 3: Camera Properties
1. Create `DroneCamera`:
   ```
   CameraSettings:
   ├── fov: float (wide lens, ~90-110)
   ├── distortion: float (slight fisheye)
   ├── shake: float (wind + movement based)
   └── exposure: float (auto, struggles in snow)
   ```

### 9.2 Spectator vs Scout Mode

**Implementation Steps:**

#### Spectator Mode
1. Full free-fly control
2. No gameplay effect
3. Always available in replay/stream mode
4. Separate from player view

#### Scout Mode (Easy Mode)
1. Player must stop to deploy
2. Limited range and battery
3. Time continues passing
4. Weather/cold exposure continues
5. Fatigue recovery reduced while scouting

---

## 10. Camera Director AI

**Status:** ✅ Implemented

**Files:**
- `src/systems/camera_director/camera_director.gd` - Main AI
- `src/systems/camera_director/signal_detector.gd` - Moment detection
- `src/systems/camera_director/intent_selector.gd` - Shot type selection
- `src/systems/camera_director/emotional_rhythm_engine.gd` - Pacing
- `src/systems/camera_director/imperfection_engine.gd` - Human-like flaws

### 10.1 Signal Detection Layer

**Implementation Steps:**

#### Phase 1: Signal Sources
1. Create `SignalDetector`:
   ```
   PrimarySignals (high weight):
   ├── SlopeChange: Δslope > threshold
   ├── SpeedChange: Δspeed > threshold
   ├── SlideEntry: stateChange to Sliding
   ├── RopeDeployment: stateChange to Roping
   ├── FatigueThreshold: fatigue crosses level
   ├── MicroSlip: stability event
   └── CliffProximity: distance < threshold

   SecondarySignals (mood weight):
   ├── WeatherShift: weather state change
   ├── LightChange: significant sun angle change
   ├── Isolation: no landmarks in view
   └── SilenceMoment: wind drop
   ```

#### Phase 2: Signal Aggregation
1. Create weighted signal combination
2. Implement signal decay over time
3. Build anticipation buffer (pre-event detection)

### 10.2 Intent Selection Layer

**Implementation Steps:**

#### Phase 1: Shot Intent Types
1. Create `ShotIntent` enum and parameters:
   ```
   ContextShot:
   ├── distance: far
   ├── movement: static/slow drift
   ├── altitude: high
   ├── duration: long
   └── triggers: [NewTerrain, MajorExposure, PreSlide]

   TensionShot:
   ├── distance: medium
   ├── movement: slight handheld
   ├── altitude: level
   ├── duration: medium
   └── triggers: [Downclimbing, Traversing, MarginalSlope]

   CommitmentShot:
   ├── distance: close
   ├── movement: forward-tracking
   ├── altitude: low
   ├── duration: short
   └── triggers: [SlideStart, RopeDescend, SpeedIncrease]

   ConsequenceShot:
   ├── distance: medium-far
   ├── movement: minimal/hold
   ├── altitude: static
   ├── duration: extended
   └── triggers: [Fall, UncontrolledSlide, Injury]

   ReleaseShot:
   ├── distance: pulling back
   ├── movement: rising
   ├── altitude: increasing
   ├── duration: moderate
   └── triggers: [SafeExit, ReachCabin, DangerEnd]
   ```

#### Phase 2: Intent Selection Logic
1. Create `IntentSelector`:
   ```
   currentSignalStrength = AggregateSignals()

   if (signalStrength > intentThreshold)
       newIntent = SelectIntentFor(dominantSignal)
       if (newIntent != currentIntent)
           BeginIntentTransition(newIntent)
   ```

### 10.3 Camera Behavior Layer

**Implementation Steps:**

#### Phase 1: Position Planning
1. Create `ShotPlanner`:
   ```
   targetPosition = CalculateIdealPosition(intent, playerPos, terrain)
   targetPosition = ApplyRuleOfThirds(targetPosition)
   targetPosition = AvoidTerrainCollision(targetPosition)
   targetPosition = AddWindOffset(targetPosition)
   ```

#### Phase 2: Movement Execution
1. Create `CameraMovementController`:
   ```
   // Smooth acceleration only
   currentVelocity = Vector3.Lerp(currentVelocity, targetVelocity, acceleration)

   // Add human-like imperfection
   currentVelocity += PerlinNoise() * imperfectionAmount

   // Delayed obstacle avoidance (human reaction time)
   if (ObstacleDetected())
       QueueAvoidanceManeuver(reactionDelay)
   ```

#### Phase 3: Framing Rules
1. Implement rule of thirds offset
2. Add intentional partial occlusion
3. Create asymmetric framing
4. Never perfectly centered player

### 10.4 Emotional Rhythm Engine

**Implementation Steps:**
1. Track "intensity" over time
2. Force calm shot after intense sequence
3. Seek tension after extended calm
4. Prevent rapid shot changes (minimum duration)
5. Create pacing curve for full descent

### 10.5 Mistake Simulation

**Implementation Steps:**
1. Occasionally frame too wide (miss detail)
2. Lose subject in whiteout conditions
3. Arrive late to sudden events
4. Commit to wrong angle, require recovery
5. Probability increases in hard conditions

---

## 11. Fatal Event System

**Status:** ✅ Implemented

**Files:**
- `src/systems/fatal_event/fatal_event_manager.gd` - Main coordinator
- `src/systems/fatal_event/fatality_detector.gd` - Death detection
- `src/systems/fatal_event/fatal_phase_handler.gd` - 5 phases of death
- `src/systems/fatal_event/fatal_audio_controller.gd` - Audio transitions
- `src/systems/fatal_event/ethical_constraints.gd` - Streaming safety

### 11.1 Death Detection

**Implementation Steps:**

#### Phase 1: Terminal State Recognition
1. Create `FatalityDetector`:
   ```
   isFatal = false

   // Immediate fatality conditions
   if (impactForce > instantDeathThreshold) isFatal = true
   if (fallDistance > survivalLimit) isFatal = true

   // Accumulated fatality
   if (slideSpeed > terminalSpeed && noExitZone) isFatal = true
   if (coldExposure >= 1.0) isFatal = true
   if (injuries.TotalSeverity() > survivalThreshold) isFatal = true
   ```

#### Phase 2: Point of No Return
1. Detect irreversible state before death
2. Trigger camera behavior changes
3. Begin audio transitions

### 11.2 Phase-Based Response

**Implementation Steps:**

1. Create `FatalEventHandler`:
   ```
   Phases:
   ├── MomentOfError
   │   ├── hesitateCamera(0.3s)
   │   ├── addFramingError()
   │   └── dominateTerrain()
   ├── LossOfControl
   │   ├── pullBackCamera()
   │   ├── disableZoom()
   │   └── driftUpward()
   ├── Vanishing
   │   ├── slowDrone()
   │   ├── loseSubject()
   │   └── transitionAudio()
   ├── Aftermath
   │   ├── holdPosition(5s)
   │   ├── silenceAudio()
   │   └── waitForSettling()
   └── Acknowledgment
       ├── slowAscend()
       ├── revealScale()
       └── fadeToBlack()
   ```

### 11.3 Prohibited Behavior Enforcement

**Implementation Steps:**
1. Create `EthicsEnforcer`:
   ```
   NEVER:
   ├── ZoomOnImpact()
   ├── FollowIntoVoid()
   ├── FrameBodyClearly()
   ├── CircleBody()
   └── HoverOverhead()
   ```

2. Hard-code restrictions in camera AI
3. Override any shot selection that violates rules

---

## 12. UI System

**Status:** ✅ Implemented

**Files:**
- `src/ui/main_menu.gd` - Start screen
- `src/ui/selection/mountain_select_screen.gd` - Mountain selection
- `src/ui/selection/loadout_config_screen.gd` - Gear configuration
- `src/ui/planning/planning_screen.gd` - Route planning
- `src/ui/planning/topo_map_display.gd` - Topo rendering
- `src/ui/planning/elevation_profile_display.gd` - Elevation view
- `src/ui/planning/route_planner.gd` - Route tools
- `src/ui/planning/planning_service.gd` - Planning coordinator
- `src/ui/hud/physical_map.gd` - In-game map
- `src/ui/hud/self_check_screen.gd` - Body status
- `src/ui/pause/pause_menu.gd` - Pause menu
- `src/ui/pause/map_check_overlay.gd` - Pause map
- `src/ui/analysis/topo_replay_visualization.gd` - Post-run replay
- `src/ui/stats/stats_display.gd` - Statistics
- `src/ui/settings/streaming_settings.gd` - Stream options
- `src/ui/post_game_screen.gd` - Results
- `src/ui/resolution_screen.gd` - Outcome display

### 12.1 Diegetic UI Framework

**Implementation Steps:**

#### Phase 1: Body-Based Feedback
1. Create `DiegeticUIManager`:
   ```
   BodyFeedback:
   ├── BreathingAudio → fatigue + exertion
   ├── CameraSway → fatigue + instability
   ├── HandAnimations → cold + fatigue
   ├── InputDelay → exhaustion
   └── ScreenFrost → cold exposure
   ```

#### Phase 2: Environmental Feedback
1. Map risk → sound changes
2. Map surface → footstep audio
3. Map stability → micro-slip visuals
4. Map speed → peripheral blur

### 12.2 Map System

**Implementation Steps:**

#### Phase 1: Physical Map
1. Create `MapController`:
   - Player animation to unfold map
   - Map shake in wind/fatigue
   - Partial occlusion in bad conditions

#### Phase 2: Topo Rendering
1. Render contour lines from terrain data
2. No "you are here" marker by default
3. Player estimates position via landmarks
4. Optional assists (difficulty-dependent)

### 12.3 Self-Check System

**Implementation Steps:**
1. Create "check yourself" action
2. Brief vignette with status
3. No numbers - descriptive text only:
   ```
   "Legs burning. Pace unsustainable."
   "Fingers going numb. Need to keep moving."
   ```

### 12.4 Minimal Abstract UI

**Implementation Steps:**
1. Create icon system for critical warnings only
2. Brief appearance, quick fade
3. Triggers: mandatory rope, severe cold imminent
4. Never persistent on screen

---

## 13. Audio System

**Status:** ✅ Implemented

**Files:**
- `src/systems/audio/audio_service.gd` - Central coordinator
- `src/systems/audio/ambient_audio_manager.gd` - Wind, environment
- `src/systems/audio/player_audio_manager.gd` - Breathing, footsteps
- `src/systems/audio/gear_audio_manager.gd` - Rope, crampon sounds
- `src/systems/audio/ui_audio_manager.gd` - Menu sounds
- `src/systems/audio/procedural_audio.gd` - Generated sounds
- `src/systems/audio/audio_initializer.gd` - Setup
- `src/systems/audio/audio_config.gd` - Configuration
- `src/systems/audio/placeholder_audio_loader.gd` - Placeholder assets

### 13.1 Environmental Audio

**Implementation Steps:**

#### Phase 1: Ambient Layers
1. Create `AmbientAudioManager`:
   ```
   Layers:
   ├── Wind (constant, varies with conditions)
   ├── Snow (movement, settling)
   ├── Ice (creaking, cracking)
   └── Silence (intentional absence)
   ```

#### Phase 2: Dynamic Wind
1. Wind volume based on exposure
2. Wind direction affects stereo field
3. Wind masks other sounds at high levels
4. Sudden wind drops create tension

### 13.2 Player Audio

**Implementation Steps:**
1. Create `PlayerAudioManager`:
   ```
   Breathing:
   ├── Rate → exertion level
   ├── Depth → fatigue level
   └── Quality → cold/injury

   Movement:
   ├── Footsteps → surface type
   ├── Crampon scrape → ice/rock
   ├── Clothing rustle → speed
   └── Gear clinks → movement intensity
   ```

### 13.3 Drone Audio

**Implementation Steps:**
1. Drone motor volume based on shot intent:
   - Loud during tension shots
   - Near silent during wide shots
2. Wind masks drone at altitude
3. Signal degradation audio (static, drops)

### 13.4 Fatal Event Audio

**Implementation Steps:**
1. Create `FatalAudioController`:
   ```
   DuringLoss:
   ├── Wind crescendo
   ├── Motor fade
   └── Player audio cut (abrupt, not fade)

   AfterVanish:
   ├── Wind only
   ├── Occasional ice
   └── No music/sting
   ```

---

## 14. Streaming & Replay System

**Status:** ✅ Implemented

**Files:**
- `src/systems/replay/recording_service.gd` - Records run data
- `src/systems/replay/replay_player.gd` - Plays back runs
- `src/systems/replay/highlight_generator.gd` - Extracts best moments
- `src/systems/replay/speedrun_timer.gd` - Optional timing
- `src/systems/replay/streamer_tools.gd` - Streamer features
- `src/systems/streaming/obs_integration.gd` - OBS/streamer tools

### 14.1 Replay Recording

**Implementation Steps:**

#### Phase 1: Event Recording
1. Create `ReplayRecorder`:
   ```
   RecordedData:
   ├── PlayerState (position, velocity, state) @ 30fps
   ├── CameraState @ 30fps
   ├── Events (slides, falls, rope, decisions)
   ├── AudioState (for reconstruction)
   └── WeatherState (snapshots)
   ```

#### Phase 2: Compression
1. Delta compression for continuous data
2. Keyframes every N seconds
3. Event-based recording for discrete changes

### 14.2 Replay Playback

**Implementation Steps:**
1. Create `ReplayPlayer`:
   - Topo view with path overlay
   - Key moment highlighting
   - Speed controls (normal only for fatal)
   - Camera angle selection (non-fatal only)

### 14.3 Streaming Mode

**Implementation Steps:**

#### Phase 1: Separate Feeds
1. Player view (gameplay camera)
2. Spectator view (drone camera)
3. Overlay system for streamer UI

#### Phase 2: Streamer Controls
1. Shot intent bias slider
2. Human error amount slider
3. Shot lock toggle
4. Warning overlay toggle

### 14.4 Ethical Streaming Features

**Implementation Steps:**
1. Create `StreamEthicsManager`:
   ```
   Features:
   ├── PredictiveFade (stream only)
   ├── FatalAudioReplacement
   ├── DelayedFatalReplay
   ├── WarningBanner
   └── ClipExclusion (fatal moments)
   ```

---

## 15. Tutorial & Onboarding

**Status:** ✅ Implemented

**Files:**
- `src/systems/tutorial/tutorial_manager.gd` - Main coordinator
- `src/systems/tutorial/knife_edge_scene.gd` - Opening tutorial
- `src/systems/tutorial/instructor.gd` - NPC guide
- `src/systems/tutorial/tutorial_triggers.gd` - Event triggers

### 15.1 Opening Sequence

**Implementation Steps:**

#### Phase 1: Knife Edge Spawn
1. Narrow ridge environment
2. Immediate exposure
3. No UI elements
4. Wind audio before visual

#### Phase 2: Instructor System
1. Create `InstructorController`:
   - Diegetic voice lines
   - Reactive to player actions
   - Models good behavior
   - Never explains controls directly

#### Phase 3: Organic Lessons
1. Backing up = immediate slip
2. Careless movement = micro-slips
3. Instructor demonstrates sliding
4. Rope use shown as time cost

### 15.2 Hard Mode Variant

**Implementation Steps:**
1. Instructor accident scripted event
2. Player left alone
3. Cabin discovery (no markers)
4. Rescue sled mechanics
5. Return journey with injured NPC

---

## 16. Save & Progression System

**Status:** ✅ Implemented

**Files:**
- `src/systems/save/save_manager.gd` - Save coordination
- `src/systems/save/player_profile.gd` - Player data
- `src/systems/save/progression_tracker.gd` - Skills & achievements
- `src/systems/save/route_memory.gd` - Route familiarity
- `src/systems/save/run_history.gd` - Previous descents

### 16.1 Run Data

**Implementation Steps:**
1. Create `RunResult`:
   ```
   RunResult:
   ├── mountain: MountainID
   ├── startConditions: StartConditions
   ├── outcome: OutcomeType
   ├── path: CompressedPath
   ├── decisions: List<Decision>
   ├── duration: float
   └── injuries: List<Injury>
   ```

### 16.2 Knowledge Persistence

**Implementation Steps:**
1. Create `PlayerKnowledge`:
   ```
   Knowledge:
   ├── mountainsFamiliar: List<MountainID>
   ├── routesKnown: Map<MountainID, List<Route>>
   ├── hazardsLearned: List<HazardID>
   └── techniquesExperienced: List<TechniqueID>
   ```

2. Knowledge effects:
   - Faster planning on known mountains
   - Danger pattern recognition
   - Route preview unlocks (subtle)

### 16.3 Post-Run Analysis

**Implementation Steps:**
1. Create `RunAnalyzer`:
   - Path overlay on topo
   - Decision point markers
   - Compound effect visualization
   - Minimal text insights

---

## Implementation Status Summary

All 16 major systems have been implemented. Below is the completion status:

| Phase | Systems | Status |
|-------|---------|--------|
| **Phase 1: Core Foundation** | Terrain, Player, Camera, Time | ✅ Complete |
| **Phase 2: Core Mechanics** | Sliding, Rope, Body Condition, Risk | ✅ Complete |
| **Phase 3: Camera & Polish** | Drone, Camera Director AI, Audio, UI | ✅ Complete |
| **Phase 4: Experience** | Fatal Event, Tutorial, Replay, Streaming | ✅ Complete |
| **Phase 5: Content** | Mountains, Weather, Progression, Save | ✅ Complete |

### Future Development Areas

The following areas are planned for future development:

| Feature | Priority | Notes |
|---------|----------|-------|
| Avalanche System | Medium | Terrain-triggered avalanches |
| Crevasse System | Medium | Hidden crevasse detection |
| Advanced Rescue | Low | Multi-person rescue scenarios |
| Complex Weather | Medium | More dynamic storm generation |
| Gear Damage | Low | Cumulative equipment degradation |
| Real Audio Assets | High | Replace placeholder audio |
| Real USGS Data | High | Actual mountain DEM files |
| Accessibility | Medium | Expanded accessibility options |

### File Statistics

| Category | File Count |
|----------|------------|
| Core Architecture | 9 |
| Player Entity | 10 |
| Audio Systems | 9 |
| Terrain Systems | 8 |
| Rope Systems | 7 |
| Camera Director | 5 |
| Drone Systems | 5 |
| Fatal Event | 5 |
| Replay Systems | 5 |
| Risk Systems | 5 |
| Save Systems | 5 |
| Environment | 5 |
| Sliding Systems | 5 |
| Body Systems | 4 |
| Tutorial Systems | 4 |
| UI Systems | 16 |
| Data Systems | 2 |
| Streaming | 1 |
| Scenes | 1 |
| **Total** | **111** |

---

*Programming Roadmap v1.1 - Companion to SPEC-SHEET.md*
