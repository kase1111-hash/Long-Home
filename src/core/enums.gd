extends Node
## Core game enumerations and constants
## Autoloaded as GameEnums

# =============================================================================
# GAME STATES
# =============================================================================

enum GameState {
	NONE,
	MAIN_MENU,
	MOUNTAIN_SELECT,
	LOADOUT_CONFIG,
	PLANNING,
	DESCENT,
	PAUSED,
	MAP_CHECK,
	RESOLUTION,
	POST_GAME
}

enum ResolutionType {
	CLEAN_RETURN,      # Success - no injuries, good margin
	INJURED_RETURN,    # Qualified success - made it but hurt
	FORCED_BIVY,       # Survival - had to shelter
	RESCUE,            # Near-failure - needed rescue
	FATALITY           # Failure - did not survive
}

# =============================================================================
# PLAYER STATES
# =============================================================================

enum PlayerMovementState {
	STANDING,
	WALKING,
	DOWNCLIMBING,
	TRAVERSING,
	SLIDING,
	ROPING,
	FALLING,
	ARRESTED,
	RESTING,
	INCAPACITATED
}

enum PostureState {
	STABLE,
	MARGINAL,
	UNSTABLE,
	FALLING
}

# =============================================================================
# TERRAIN & SURFACE
# =============================================================================

enum SurfaceType {
	SNOW_FIRM,
	SNOW_SOFT,
	SNOW_POWDER,
	ICE,
	ROCK_DRY,
	ROCK_WET,
	SCREE,
	MIXED
}

enum TerrainZone {
	WALKABLE,          # < 25 degrees
	STEEP,             # 25-35 degrees
	SLIDEABLE,         # 25-40 degrees (overlaps with steep)
	DOWNCLIMB,         # 35-50 degrees
	RAPPEL_REQUIRED,   # 50-70 degrees
	CLIFF              # > 70 degrees
}

# =============================================================================
# WEATHER
# =============================================================================

enum WeatherState {
	CLEAR,
	PARTLY_CLOUDY,
	CLOUDY,
	DETERIORATING,
	STORM,
	WHITEOUT,
	CLEARING
}

enum WindStrength {
	CALM,
	LIGHT,
	MODERATE,
	STRONG,
	SEVERE
}

# =============================================================================
# RISK
# =============================================================================

enum RiskLevel {
	MINIMAL,
	LOW,
	MODERATE,
	HIGH,
	EXTREME
}

# =============================================================================
# BODY & INJURY
# =============================================================================

enum BodyPart {
	HEAD,
	TORSO,
	LEFT_ARM,
	RIGHT_ARM,
	LEFT_HAND,
	RIGHT_HAND,
	LEFT_LEG,
	RIGHT_LEG,
	LEFT_FOOT,
	RIGHT_FOOT
}

enum InjuryType {
	NONE,
	SPRAIN,
	STRAIN,
	LACERATION,
	FRACTURE,
	FROSTBITE,
	HYPOTHERMIA,
	EXHAUSTION
}

enum InjurySeverity {
	MINOR,      # 0.0 - 0.3
	MODERATE,   # 0.3 - 0.6
	SEVERE,     # 0.6 - 0.9
	CRITICAL    # 0.9 - 1.0
}

# =============================================================================
# GEAR
# =============================================================================

enum GearType {
	ROPE,
	CRAMPONS,
	ICE_AXE,
	HELMET,
	HARNESS,
	CARABINERS,
	ANCHOR_KIT,
	BIVY_GEAR,
	LAYERS,
	GLOVES,
	GOGGLES
}

enum GearCondition {
	PRISTINE,
	GOOD,
	WORN,
	DAMAGED,
	BROKEN
}

# =============================================================================
# SLIDING
# =============================================================================

enum SlideControlLevel {
	CONTROLLED,    # 0.8 - 1.0: Full steering, can stop
	MARGINAL,      # 0.5 - 0.8: Limited steering, stop difficult
	UNSTABLE,      # 0.2 - 0.5: Minimal control, exit zones only
	LOST           # 0.0 - 0.2: No control, terrain decides
}

enum SlideOutcome {
	CLEAN_STOP,       # Successful controlled stop
	TUMBLE_STOP,      # Stopped but with tumble/injury risk
	TERRAIN_CATCH,    # Stopped by terrain feature
	COMPOUND_SLIDE,   # Transitioned to steeper slope
	TERMINAL_RUNOUT   # No exit, fatal trajectory
}

# =============================================================================
# ROPE & ANCHORS
# =============================================================================

enum RopeState {
	STOWED,
	DEPLOYING,
	ANCHORED,
	DESCENDING,
	RECOVERING,
	JAMMED
}

enum AnchorQuality {
	EXCELLENT,    # Bomber placement
	GOOD,         # Reliable
	MARGINAL,     # Questionable
	POOR,         # Emergency only
	UNUSABLE
}

# =============================================================================
# CAMERA & DRONE
# =============================================================================

enum DroneMode {
	SPECTATOR,     # Non-diegetic, full free-fly
	SCOUT,         # Diegetic, limited recon (easy mode)
	DISABLED       # Hard mode
}

enum ShotIntent {
	CONTEXT,       # Wide, show scale
	TENSION,       # Medium, stay close
	COMMITMENT,    # Close, forward-tracking
	CONSEQUENCE,   # Hold, let it play out
	RELEASE        # Pull back, breathe
}

enum CameraSignal {
	# Primary signals (high weight)
	SLOPE_CHANGE,
	SPEED_CHANGE,
	SLIDE_ENTRY,
	ROPE_DEPLOYMENT,
	FATIGUE_THRESHOLD,
	MICRO_SLIP,
	CLIFF_PROXIMITY,
	# Secondary signals (mood)
	WEATHER_SHIFT,
	LIGHT_CHANGE,
	ISOLATION,
	SILENCE_MOMENT
}

# =============================================================================
# FATAL EVENT PHASES
# =============================================================================

enum FatalPhase {
	NONE,
	MOMENT_OF_ERROR,
	LOSS_OF_CONTROL,
	VANISHING,
	AFTERMATH,
	ACKNOWLEDGMENT
}

# =============================================================================
# DIFFICULTY / KNOWLEDGE
# =============================================================================

enum KnowledgeLevel {
	UNKNOWN,       # Never attempted
	ATTEMPTED,     # Attempted but not completed
	FAMILIAR,      # Completed once
	EXPERIENCED,   # Multiple completions
	MASTERED       # Consistent clean returns
}

# =============================================================================
# CONSTANTS
# =============================================================================

const SLOPE_THRESHOLDS := {
	"walkable_max": 25.0,
	"slide_min": 25.0,
	"slide_max": 40.0,
	"downclimb_min": 35.0,
	"downclimb_max": 50.0,
	"rappel_min": 50.0,
	"cliff_min": 70.0
}

const TIME_SCALE := 10.0  # 1 real minute = 10 game minutes

const FATIGUE_THRESHOLDS := {
	"breathing_change": 0.3,
	"movement_slow": 0.5,
	"input_delay": 0.7,
	"critical": 0.9,
	"collapse": 1.0
}

const SURFACE_FRICTION := {
	SurfaceType.SNOW_FIRM: 0.3,
	SurfaceType.SNOW_SOFT: 0.5,
	SurfaceType.SNOW_POWDER: 0.6,
	SurfaceType.ICE: 0.1,
	SurfaceType.ROCK_DRY: 0.7,
	SurfaceType.ROCK_WET: 0.2,
	SurfaceType.SCREE: 0.6,
	SurfaceType.MIXED: 0.4
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

## Get terrain zone for a given slope angle in degrees
static func get_terrain_zone(slope_angle: float) -> TerrainZone:
	if slope_angle >= SLOPE_THRESHOLDS.cliff_min:
		return TerrainZone.CLIFF
	elif slope_angle >= SLOPE_THRESHOLDS.rappel_min:
		return TerrainZone.RAPPEL_REQUIRED
	elif slope_angle >= SLOPE_THRESHOLDS.downclimb_min:
		return TerrainZone.DOWNCLIMB
	elif slope_angle >= SLOPE_THRESHOLDS.slide_min:
		return TerrainZone.SLIDEABLE
	elif slope_angle >= SLOPE_THRESHOLDS.walkable_max:
		return TerrainZone.STEEP
	else:
		return TerrainZone.WALKABLE

## Get slide control level from 0-1 value
static func get_slide_control_level(control: float) -> SlideControlLevel:
	if control >= 0.8:
		return SlideControlLevel.CONTROLLED
	elif control >= 0.5:
		return SlideControlLevel.MARGINAL
	elif control >= 0.2:
		return SlideControlLevel.UNSTABLE
	else:
		return SlideControlLevel.LOST

## Get injury severity from 0-1 value
static func get_injury_severity(severity: float) -> InjurySeverity:
	if severity >= 0.9:
		return InjurySeverity.CRITICAL
	elif severity >= 0.6:
		return InjurySeverity.SEVERE
	elif severity >= 0.3:
		return InjurySeverity.MODERATE
	else:
		return InjurySeverity.MINOR

## Get friction coefficient for surface type
static func get_surface_friction(surface: SurfaceType) -> float:
	return SURFACE_FRICTION.get(surface, 0.5)
