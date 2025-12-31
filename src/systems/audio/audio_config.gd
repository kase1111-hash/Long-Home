class_name AudioConfig
extends Resource
## Audio configuration resource for the game
## Defines all sound resources and audio settings
##
## Usage:
## Create an instance of this resource and assign audio streams
## Then reference it from AudioService or individual managers

# =============================================================================
# WIND SOUNDS
# =============================================================================

@export_group("Wind")
## Base wind layer (looping, constant)
@export var wind_base: AudioStream
## Wind gusts (looping or one-shot)
@export var wind_gust: AudioStream
## High altitude thin wind
@export var wind_altitude: AudioStream
## Severe wind howl
@export var wind_howl: AudioStream
## Wind through rocks/crevices
@export var wind_whistle: AudioStream

# =============================================================================
# ENVIRONMENTAL SOUNDS
# =============================================================================

@export_group("Environment")
## Ice cracking/settling
@export var ice_crack: AudioStream
## Snow settling after disturbance
@export var snow_settle: AudioStream
## Distant avalanche rumble
@export var avalanche_distant: AudioStream
## Rock fall distant
@export var rockfall_distant: AudioStream
## Silence (empty audio for intentional quiet)
@export var silence: AudioStream

# =============================================================================
# BREATHING SOUNDS
# =============================================================================

@export_group("Breathing")
## Calm/resting breathing (looping)
@export var breathing_calm: AudioStream
## Exerted breathing (looping)
@export var breathing_exerted: AudioStream
## Heavy/labored breathing (looping)
@export var breathing_heavy: AudioStream
## Critical/gasping breathing (looping)
@export var breathing_critical: AudioStream

# =============================================================================
# FOOTSTEP SOUNDS
# =============================================================================

@export_group("Footsteps")
## Firm snow crunch
@export var footstep_snow_firm: AudioStream
## Soft snow compression
@export var footstep_snow_soft: AudioStream
## Ice step (sharp, crystalline)
@export var footstep_ice: AudioStream
## Rock step
@export var footstep_rock: AudioStream
## Scree/loose rock
@export var footstep_scree: AudioStream

# =============================================================================
# GEAR SOUNDS
# =============================================================================

@export_group("Gear")
## Crampon scrape on hard surface
@export var crampon_scrape: AudioStream
## Rope handling/coiling
@export var rope_handling: AudioStream
## Rope tension creak
@export var rope_tension: AudioStream
## Rope jam/catch
@export var rope_jam: AudioStream
## Ice axe placement
@export var ice_axe_place: AudioStream
## Ice axe self-arrest
@export var ice_axe_arrest: AudioStream
## Gear/pack rustle
@export var gear_rustle: AudioStream
## Carabiner click
@export var carabiner_click: AudioStream
## Zipper sound
@export var zipper: AudioStream

# =============================================================================
# SLIDE SOUNDS
# =============================================================================

@export_group("Sliding")
## Snow sliding (looping)
@export var slide_snow: AudioStream
## Ice sliding (looping)
@export var slide_ice: AudioStream
## Scree sliding
@export var slide_scree: AudioStream
## Tumble/roll
@export var tumble: AudioStream
## Impact/stop
@export var impact: AudioStream

# =============================================================================
# PLAYER REACTIONS
# =============================================================================

@export_group("Reactions")
## Sharp intake/gasp
@export var gasp: AudioStream
## Pain grunt (mild)
@export var pain_mild: AudioStream
## Pain grunt (severe)
@export var pain_severe: AudioStream
## Relief exhale
@export var relief_exhale: AudioStream
## Effort grunt
@export var effort_grunt: AudioStream
## Shiver sound
@export var shiver: AudioStream

# =============================================================================
# UI SOUNDS
# =============================================================================

@export_group("UI")
## Map unfold
@export var map_unfold: AudioStream
## Map fold
@export var map_fold: AudioStream
## Watch check
@export var watch_check: AudioStream
## Menu select
@export var menu_select: AudioStream
## Menu confirm
@export var menu_confirm: AudioStream

# =============================================================================
# HELPER METHODS
# =============================================================================

## Get a random footstep sound for a surface type
func get_footstep_for_surface(surface: GameEnums.SurfaceType) -> AudioStream:
	match surface:
		GameEnums.SurfaceType.SNOW_FIRM:
			return footstep_snow_firm
		GameEnums.SurfaceType.SNOW_SOFT, GameEnums.SurfaceType.SNOW_POWDER:
			return footstep_snow_soft
		GameEnums.SurfaceType.ICE:
			return footstep_ice
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET:
			return footstep_rock
		GameEnums.SurfaceType.SCREE:
			return footstep_scree
		_:
			return footstep_snow_firm


## Get slide sound for a surface type
func get_slide_for_surface(surface: GameEnums.SurfaceType) -> AudioStream:
	match surface:
		GameEnums.SurfaceType.ICE:
			return slide_ice
		GameEnums.SurfaceType.SCREE:
			return slide_scree
		_:
			return slide_snow


## Get breathing stream for intensity level
func get_breathing_for_intensity(intensity: float) -> AudioStream:
	if intensity < 0.3:
		return breathing_calm
	elif intensity < 0.6:
		return breathing_exerted
	elif intensity < 0.85:
		return breathing_heavy
	else:
		return breathing_critical
