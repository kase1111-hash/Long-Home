class_name FootstepSystem
extends Node
## Handles footstep audio and effects based on terrain and movement
##
## Connects animation footsteps to audio system

# =============================================================================
# SIGNALS
# =============================================================================

signal footstep_played(surface: GameEnums.SurfaceType, foot: StringName)

# =============================================================================
# CONFIGURATION
# =============================================================================

## Volume range for footsteps
const BASE_VOLUME := -19.0
const VOLUME_VARIATION := 2.5

## Pitch range for variation
const BASE_PITCH := 1.0
const PITCH_VARIATION := 0.07

## How loud crampon steel is over the boot's own step on rock and scree (dB)
const CRAMPON_OVERLAY := -5.0

## Every other step of a downclimb the axe goes in first
const AXE_PLANT_VOLUME := -20.0

## Footstep sound by surface type: a SoundLibrary id (each has several
## variants), how loud that ground is underfoot and how it shifts the pitch
const SURFACE_SOUNDS := {
	GameEnums.SurfaceType.ROCK: {"sound": "footstep_rock", "volume_mod": 0.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.ROCK_DRY: {"sound": "footstep_rock", "volume_mod": 0.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.ROCK_WET: {"sound": "footstep_rock_wet", "volume_mod": 1.0, "pitch_mod": -0.05},
	GameEnums.SurfaceType.SNOW_PACKED: {"sound": "footstep_snow_firm", "volume_mod": -1.0, "pitch_mod": 0.08},
	GameEnums.SurfaceType.SNOW_FIRM: {"sound": "footstep_snow_firm", "volume_mod": 0.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.SNOW_SOFT: {"sound": "footstep_snow_soft", "volume_mod": -1.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.SNOW_POWDER: {"sound": "footstep_snow_powder", "volume_mod": -4.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.ICE: {"sound": "footstep_ice", "volume_mod": 1.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.SCREE: {"sound": "footstep_scree", "volume_mod": 2.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.GRASS: {"sound": "footstep_grass", "volume_mod": -4.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.MUD: {"sound": "footstep_mud", "volume_mod": 0.0, "pitch_mod": 0.0},
	GameEnums.SurfaceType.MIXED: {"sound": "footstep_scree", "volume_mod": 0.0, "pitch_mod": 0.05},
}

# =============================================================================
# REFERENCES
# =============================================================================

## Player controller
var player: PlayerController

## Animation controller
var anim_controller: PlayerAnimationController

## Audio service
var audio_service: Node

# =============================================================================
# STATE
# =============================================================================

## Last surface type for tracking changes
var last_surface: GameEnums.SurfaceType = GameEnums.SurfaceType.ROCK_DRY

## Footstep counter (every other downclimbing step plants the axe)
var footstep_count: int = 0

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	player = get_parent() as PlayerController
	if player == null:
		push_error("[FootstepSystem] Must be child of PlayerController")
		return

	# Find animation controller
	anim_controller = player.get_node_or_null("AnimationController") as PlayerAnimationController
	if anim_controller:
		anim_controller.footstep_triggered.connect(_on_footstep_triggered)

	# Get audio service
	ServiceLocator.get_service_async("AudioService", func(service):
		audio_service = service
	)

	print("[FootstepSystem] Initialized")


# =============================================================================
# FOOTSTEP HANDLING
# =============================================================================

func _on_footstep_triggered(foot: StringName, surface: GameEnums.SurfaceType) -> void:
	_play_footstep_sound(surface, foot)
	footstep_played.emit(surface, foot)
	footstep_count += 1


func _play_footstep_sound(surface: GameEnums.SurfaceType, foot: StringName) -> void:
	var sound_data: Dictionary = SURFACE_SOUNDS.get(surface, SURFACE_SOUNDS[GameEnums.SurfaceType.ROCK_DRY])
	var sound_name: String = sound_data.get("sound", "footstep_rock")

	# Calculate volume
	var volume: float = BASE_VOLUME + float(sound_data.get("volume_mod", 0.0))
	volume += AudioService.roll_range(-VOLUME_VARIATION, VOLUME_VARIATION)

	# Adjust for movement speed
	var speed_factor := player.velocity.length() / 5.0
	volume += speed_factor * 3.0  # Louder when moving faster

	# Adjust for fatigue (heavier footsteps)
	var run := GameStateManager.get_current_run()
	if run and run.body_state:
		volume += run.body_state.fatigue * 2.0

	# Calculate pitch
	var pitch: float = BASE_PITCH + float(sound_data.get("pitch_mod", 0.0))
	pitch += AudioService.roll_range(-PITCH_VARIATION, PITCH_VARIATION)

	# Slight difference between left/right foot
	if foot == &"right":
		pitch *= 0.98

	if audio_service == null or not audio_service.has_method("play_footstep"):
		# Fallback: emit event through EventBus
		EventBus.emit_signal("footstep_occurred", surface, player.global_position, volume)
		return

	# Crampons change what a step is: steel biting ice and firm snow instead
	# of a sole, and steel scraping over the boot's own step on rock
	var overlay := ""
	if player.footwear == GameEnums.Footwear.CRAMPONS:
		var steel := crampon_sound_for(surface)
		if steel == "crampon_rock":
			overlay = steel
		elif steel != "":
			sound_name = steel

	audio_service.play_footstep(sound_name, volume, pitch, player.global_position)
	if overlay != "":
		audio_service.play_footstep(overlay, volume + CRAMPON_OVERLAY, pitch, player.global_position)

	# Facing in on steep ground, the axe goes in before every other step
	if player.current_state == GameEnums.PlayerMovementState.DOWNCLIMBING and player.has_ice_axe() \
			and footstep_count % 2 == 0 and audio_service.has_method("play"):
		audio_service.play(axe_sound_for(surface), AXE_PLANT_VOLUME + AudioService.roll_range(-2.0, 2.0), pitch)


## What crampons sound like on a surface: "" when they make no difference
## (deep snow swallows them, and on turf and mud they are just boots)
static func crampon_sound_for(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "crampon_ice"
		GameEnums.SurfaceType.SNOW_FIRM, GameEnums.SurfaceType.SNOW_PACKED:
			return "crampon_snow"
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, \
		GameEnums.SurfaceType.SCREE, GameEnums.SurfaceType.MIXED:
			return "crampon_rock"
	return ""


## What the axe sounds like going into a surface
static func axe_sound_for(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "axe_ice"
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, \
		GameEnums.SurfaceType.SCREE, GameEnums.SurfaceType.MIXED:
			return "axe_rock"
	return "axe_plant"


# =============================================================================
# SURFACE CHANGE EFFECTS
# =============================================================================

func _process(_delta: float) -> void:
	if player == null or player.current_cell == null:
		return

	var current_surface := player.current_cell.surface_type

	# Detect surface change
	if current_surface != last_surface:
		_on_surface_changed(last_surface, current_surface)
		last_surface = current_surface


func _on_surface_changed(old_surface: GameEnums.SurfaceType, new_surface: GameEnums.SurfaceType) -> void:
	# Could play transition sound (e.g., stepping from rock onto snow)
	print("[FootstepSystem] Surface changed: %s -> %s" % [
		GameEnums.SurfaceType.keys()[old_surface],
		GameEnums.SurfaceType.keys()[new_surface]
	])
