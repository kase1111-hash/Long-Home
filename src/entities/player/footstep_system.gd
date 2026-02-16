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
const BASE_VOLUME := -12.0
const VOLUME_VARIATION := 3.0

## Pitch range for variation
const BASE_PITCH := 1.0
const PITCH_VARIATION := 0.1

## Footstep sounds by surface type
const SURFACE_SOUNDS := {
	GameEnums.SurfaceType.ROCK_DRY: {
		"sounds": ["footstep_rock_1", "footstep_rock_2", "footstep_rock_3"],
		"volume_mod": 0.0,
		"pitch_mod": 0.0,
	},
	GameEnums.SurfaceType.ROCK_WET: {
		"sounds": ["footstep_rock_wet_1", "footstep_rock_wet_2"],
		"volume_mod": 2.0,
		"pitch_mod": -0.1,
	},
	GameEnums.SurfaceType.SNOW_PACKED: {
		"sounds": ["footstep_snow_1", "footstep_snow_2", "footstep_snow_3"],
		"volume_mod": -3.0,
		"pitch_mod": 0.1,
	},
	GameEnums.SurfaceType.SNOW_FIRM: {
		"sounds": ["footstep_snow_1", "footstep_snow_2", "footstep_snow_3"],
		"volume_mod": -2.0,
		"pitch_mod": 0.05,
	},
	GameEnums.SurfaceType.SNOW_SOFT: {
		"sounds": ["footstep_snow_deep_1", "footstep_snow_deep_2"],
		"volume_mod": -4.0,
		"pitch_mod": 0.12,
	},
	GameEnums.SurfaceType.SNOW_POWDER: {
		"sounds": ["footstep_snow_deep_1", "footstep_snow_deep_2"],
		"volume_mod": -5.0,
		"pitch_mod": 0.15,
	},
	GameEnums.SurfaceType.ICE: {
		"sounds": ["footstep_ice_1", "footstep_ice_2"],
		"volume_mod": 3.0,
		"pitch_mod": 0.2,
		"crampon_sounds": ["crampon_1", "crampon_2"],  # If wearing crampons
	},
	GameEnums.SurfaceType.SCREE: {
		"sounds": ["footstep_gravel_1", "footstep_gravel_2", "footstep_gravel_3"],
		"volume_mod": 5.0,
		"pitch_mod": -0.05,
	},
	GameEnums.SurfaceType.GRASS: {
		"sounds": ["footstep_grass_1", "footstep_grass_2"],
		"volume_mod": -6.0,
		"pitch_mod": 0.0,
	},
	GameEnums.SurfaceType.MUD: {
		"sounds": ["footstep_mud_1", "footstep_mud_2"],
		"volume_mod": 0.0,
		"pitch_mod": -0.15,
	},
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

## Footstep counter for alternating sounds
var footstep_count: int = 0

## Has crampons equipped
var has_crampons: bool = false

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

	# Get sound list
	var sounds: Array = sound_data.get("sounds", ["footstep_default"])

	# Check for crampon sounds on ice
	if surface == GameEnums.SurfaceType.ICE and has_crampons:
		var crampon_sounds = sound_data.get("crampon_sounds", [])
		if not crampon_sounds.is_empty():
			sounds = crampon_sounds

	# Select sound (alternate or random)
	var sound_name: String = sounds[footstep_count % sounds.size()]

	# Calculate volume
	var volume := BASE_VOLUME + sound_data.get("volume_mod", 0.0)
	volume += randf_range(-VOLUME_VARIATION, VOLUME_VARIATION)

	# Adjust for movement speed
	var speed_factor := player.velocity.length() / 5.0
	volume += speed_factor * 3.0  # Louder when moving faster

	# Adjust for fatigue (heavier footsteps)
	var run := GameStateManager.get_current_run()
	if run and run.body_state:
		volume += run.body_state.fatigue * 2.0

	# Calculate pitch
	var pitch := BASE_PITCH + sound_data.get("pitch_mod", 0.0)
	pitch += randf_range(-PITCH_VARIATION, PITCH_VARIATION)

	# Slight difference between left/right foot
	if foot == &"right":
		pitch *= 0.98

	# Play sound through audio service
	if audio_service and audio_service.has_method("play_footstep"):
		audio_service.play_footstep(sound_name, volume, pitch, player.global_position)
	else:
		# Fallback: emit event through EventBus
		EventBus.emit_signal("footstep_occurred", surface, player.global_position, volume)


# =============================================================================
# GEAR INTEGRATION
# =============================================================================

func update_gear_state() -> void:
	var run := GameStateManager.get_current_run()
	if run == null:
		return

	# Check if crampons are equipped
	var gear_state = run.gear_state
	if gear_state and gear_state.has_method("has_item"):
		has_crampons = gear_state.has_item(GameEnums.GearType.CRAMPONS)


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
