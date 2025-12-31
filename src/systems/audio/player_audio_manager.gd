class_name PlayerAudioManager
extends Node
## Manages all player-originated sounds
## Breathing is the primary player audio - communicates fatigue and stress
##
## Design Philosophy:
## - Breathing tells the player's story
## - Footsteps vary by surface and speed
## - Gear sounds are subtle but informative
## - High risk mutes environment, amplifies player audio

# =============================================================================
# SIGNALS
# =============================================================================

signal breathing_intensity_changed(intensity: float)
signal footstep_played(surface: GameEnums.SurfaceType)
signal gear_sound_played(gear_type: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Breathing")
## Calm breathing stream
@export var breathing_calm_stream: AudioStream
## Exerted breathing stream
@export var breathing_exerted_stream: AudioStream
## Heavy/gasping breathing stream
@export var breathing_heavy_stream: AudioStream
## Critical/desperate breathing
@export var breathing_critical_stream: AudioStream

@export_group("Footsteps")
## Footstep on firm snow
@export var footstep_snow_firm: AudioStream
## Footstep on soft snow
@export var footstep_snow_soft: AudioStream
## Footstep on ice
@export var footstep_ice: AudioStream
## Footstep on rock
@export var footstep_rock: AudioStream
## Footstep on scree
@export var footstep_scree: AudioStream

@export_group("Gear")
## Crampon scrape sound
@export var crampon_scrape_stream: AudioStream
## Rope handling sound
@export var rope_handling_stream: AudioStream
## Gear rustle (pack movement)
@export var gear_rustle_stream: AudioStream
## Ice axe placement
@export var ice_axe_stream: AudioStream

@export_group("Slide Sounds")
## Snow sliding sound
@export var slide_snow_stream: AudioStream
## Ice sliding sound
@export var slide_ice_stream: AudioStream
## Tumble/fall sound
@export var tumble_stream: AudioStream

@export_group("Reactions")
## Sharp intake (micro-slip reaction)
@export var gasp_stream: AudioStream
## Pain grunt
@export var pain_grunt_stream: AudioStream
## Relief exhale
@export var relief_exhale_stream: AudioStream

@export_group("Volume Settings")
## Base breathing volume
@export var breathing_base_volume: float = -12.0
## Footstep volume
@export var footstep_volume: float = -18.0
## Gear sound volume
@export var gear_volume: float = -24.0

@export_group("Timing")
## Footstep interval when walking (seconds)
@export var footstep_walk_interval: float = 0.6
## Footstep interval when running
@export var footstep_run_interval: float = 0.35

# =============================================================================
# AUDIO PLAYERS
# =============================================================================

var breathing_player: AudioStreamPlayer
var footstep_player: AudioStreamPlayer
var gear_player: AudioStreamPlayer
var slide_player: AudioStreamPlayer
var reaction_player: AudioStreamPlayer

# =============================================================================
# STATE
# =============================================================================

## Is player audio enabled
var is_enabled: bool = false

## Is audio paused
var is_paused: bool = false

## Current movement state
var movement_state: GameEnums.PlayerMovementState = GameEnums.PlayerMovementState.STANDING

## Current surface type
var current_surface: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM

## Current fatigue level (0-1)
var fatigue_level: float = 0.0

## Current risk level (0-1)
var risk_level: float = 0.0

## Current stability (0-1)
var stability: float = 1.0

## Current posture
var current_posture: GameEnums.PostureState = GameEnums.PostureState.STABLE

## Breathing intensity (0-1)
var breathing_intensity: float = 0.0

## Time until next footstep
var next_footstep_time: float = 0.0

## Is sliding
var is_sliding: bool = false

## Current slide control level
var slide_control: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED

## In fatal sequence
var in_fatal_sequence: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_create_audio_players()
	ServiceLocator.register_service("PlayerAudioManager", self)

	# Register with audio service
	ServiceLocator.get_service_async("AudioService", func(service):
		if service:
			service.set_player_audio(self)
	)

	print("[PlayerAudioManager] Initialized")


func _create_audio_players() -> void:
	# Breathing - always looping when enabled
	breathing_player = AudioStreamPlayer.new()
	breathing_player.bus = "Player"
	breathing_player.volume_db = breathing_base_volume
	add_child(breathing_player)

	# Footsteps - one-shot
	footstep_player = AudioStreamPlayer.new()
	footstep_player.bus = "Player"
	footstep_player.volume_db = footstep_volume
	add_child(footstep_player)

	# Gear sounds - one-shot
	gear_player = AudioStreamPlayer.new()
	gear_player.bus = "Player"
	gear_player.volume_db = gear_volume
	add_child(gear_player)

	# Slide sounds - loops during slide
	slide_player = AudioStreamPlayer.new()
	slide_player.bus = "Player"
	slide_player.volume_db = -18.0
	add_child(slide_player)

	# Reaction sounds - one-shot
	reaction_player = AudioStreamPlayer.new()
	reaction_player.bus = "Player"
	reaction_player.volume_db = -6.0
	add_child(reaction_player)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_enabled or is_paused:
		return

	_update_breathing(delta)
	_update_footsteps(delta)
	_update_slide_audio(delta)


func _update_breathing(delta: float) -> void:
	# Calculate target breathing intensity
	var target_intensity := 0.0

	# Base on fatigue
	target_intensity = fatigue_level

	# Risk increases breathing
	if risk_level > 0.5:
		target_intensity = maxf(target_intensity, risk_level * 0.8)

	# Instability increases breathing
	if stability < 0.5:
		target_intensity = maxf(target_intensity, (1.0 - stability) * 0.6)

	# Sliding increases breathing
	if is_sliding:
		var slide_intensity := 0.5
		if slide_control == GameEnums.SlideControlLevel.MARGINAL:
			slide_intensity = 0.7
		elif slide_control == GameEnums.SlideControlLevel.UNSTABLE:
			slide_intensity = 0.85
		elif slide_control == GameEnums.SlideControlLevel.LOST:
			slide_intensity = 1.0
		target_intensity = maxf(target_intensity, slide_intensity)

	# Smooth transition
	breathing_intensity = lerpf(breathing_intensity, target_intensity, 2.0 * delta)

	# Update breathing audio
	_apply_breathing_audio()


func _apply_breathing_audio() -> void:
	# Select appropriate breathing stream based on intensity
	var target_stream: AudioStream = null
	var target_volume := breathing_base_volume

	if breathing_intensity < 0.3:
		target_stream = breathing_calm_stream
		target_volume = breathing_base_volume - 6.0
	elif breathing_intensity < 0.6:
		target_stream = breathing_exerted_stream
		target_volume = breathing_base_volume
	elif breathing_intensity < 0.85:
		target_stream = breathing_heavy_stream
		target_volume = breathing_base_volume + 3.0
	else:
		target_stream = breathing_critical_stream
		target_volume = breathing_base_volume + 6.0

	# Risk amplifies breathing volume
	if risk_level > 0.6:
		target_volume += (risk_level - 0.6) * 10.0

	# Switch stream if needed
	if target_stream and breathing_player.stream != target_stream:
		breathing_player.stream = target_stream
		if not breathing_player.playing and is_enabled:
			breathing_player.play()

	# Smooth volume change
	breathing_player.volume_db = lerpf(breathing_player.volume_db, target_volume, 0.1)

	breathing_intensity_changed.emit(breathing_intensity)


func _update_footsteps(delta: float) -> void:
	# Only play footsteps when moving on ground
	if not _should_play_footsteps():
		return

	next_footstep_time -= delta

	if next_footstep_time <= 0:
		_play_footstep()
		# Schedule next footstep based on movement speed
		next_footstep_time = _get_footstep_interval()


func _should_play_footsteps() -> bool:
	return movement_state in [
		GameEnums.PlayerMovementState.WALKING,
		GameEnums.PlayerMovementState.DOWNCLIMBING,
		GameEnums.PlayerMovementState.TRAVERSING
	]


func _get_footstep_interval() -> float:
	match movement_state:
		GameEnums.PlayerMovementState.WALKING:
			return footstep_walk_interval
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			return footstep_walk_interval * 1.5  # Slower, more deliberate
		GameEnums.PlayerMovementState.TRAVERSING:
			return footstep_walk_interval * 1.2
		_:
			return footstep_walk_interval


func _play_footstep() -> void:
	var stream := _get_footstep_stream()
	if stream == null:
		return

	footstep_player.stream = stream
	# Randomize pitch for variety
	footstep_player.pitch_scale = randf_range(0.9, 1.1)
	# Volume varies slightly
	footstep_player.volume_db = footstep_volume + randf_range(-3.0, 1.0)

	# Crampons add extra scrape on ice/rock
	if current_surface in [GameEnums.SurfaceType.ICE, GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY]:
		_play_crampon_scrape()

	footstep_player.play()
	footstep_played.emit(current_surface)


func _get_footstep_stream() -> AudioStream:
	match current_surface:
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


func _play_crampon_scrape() -> void:
	if crampon_scrape_stream and randf() > 0.3:  # Not every step
		gear_player.stream = crampon_scrape_stream
		gear_player.volume_db = gear_volume + randf_range(-6.0, 0.0)
		gear_player.pitch_scale = randf_range(0.85, 1.15)
		gear_player.play()
		gear_sound_played.emit("crampon")


func _update_slide_audio(delta: float) -> void:
	if not is_sliding:
		return

	# Slide audio pitch increases with loss of control
	var pitch := 1.0
	match slide_control:
		GameEnums.SlideControlLevel.CONTROLLED:
			pitch = 1.0
		GameEnums.SlideControlLevel.MARGINAL:
			pitch = 1.1
		GameEnums.SlideControlLevel.UNSTABLE:
			pitch = 1.2
		GameEnums.SlideControlLevel.LOST:
			pitch = 1.3

	slide_player.pitch_scale = lerpf(slide_player.pitch_scale, pitch, 2.0 * delta)

	# Volume increases with loss of control
	var vol := -18.0
	match slide_control:
		GameEnums.SlideControlLevel.CONTROLLED:
			vol = -18.0
		GameEnums.SlideControlLevel.MARGINAL:
			vol = -12.0
		GameEnums.SlideControlLevel.UNSTABLE:
			vol = -6.0
		GameEnums.SlideControlLevel.LOST:
			vol = -3.0

	slide_player.volume_db = lerpf(slide_player.volume_db, vol, 2.0 * delta)


# =============================================================================
# PUBLIC CONTROL
# =============================================================================

## Enable player audio
func enable() -> void:
	is_enabled = true
	is_paused = false

	# Start breathing
	if breathing_calm_stream:
		breathing_player.stream = breathing_calm_stream
		breathing_player.play()


## Disable player audio
func disable() -> void:
	is_enabled = false
	breathing_player.stop()
	footstep_player.stop()
	slide_player.stop()


## Pause audio (keeps state)
func pause_audio() -> void:
	is_paused = true
	breathing_player.stream_paused = true
	slide_player.stream_paused = true


## Resume audio
func resume_audio() -> void:
	is_paused = false
	breathing_player.stream_paused = false
	slide_player.stream_paused = false


## Set movement state
func set_movement_state(state: GameEnums.PlayerMovementState) -> void:
	var old_state := movement_state
	movement_state = state

	# Play gear rustle on state change
	if old_state != state and gear_rustle_stream:
		gear_player.stream = gear_rustle_stream
		gear_player.volume_db = gear_volume
		gear_player.play()


## Set surface type
func set_surface_type(surface: GameEnums.SurfaceType) -> void:
	current_surface = surface


## Set fatigue level (0-1)
func set_fatigue_level(fatigue: float) -> void:
	fatigue_level = clampf(fatigue, 0.0, 1.0)


## Set risk level (0-1)
func set_risk_level(risk: float) -> void:
	risk_level = clampf(risk, 0.0, 1.0)


## Set stability and posture
func set_stability(new_stability: float, posture: GameEnums.PostureState) -> void:
	stability = clampf(new_stability, 0.0, 1.0)
	current_posture = posture


## Trigger breathing change audio cue
func trigger_breathing_change() -> void:
	# Brief gasp as breathing pattern changes
	if gasp_stream:
		reaction_player.stream = gasp_stream
		reaction_player.volume_db = -12.0
		reaction_player.play()


## Trigger critical fatigue audio
func trigger_critical_fatigue() -> void:
	# Desperate breathing is handled by breathing system
	# Additional wheeze or cough could go here
	pass


## Play micro-slip reaction
func play_micro_slip(severity: float) -> void:
	if gasp_stream:
		reaction_player.stream = gasp_stream
		reaction_player.volume_db = -12.0 + severity * 6.0
		reaction_player.pitch_scale = 1.0 + randf_range(-0.1, 0.1)
		reaction_player.play()


## Play risk cue (entering danger zone)
func play_risk_cue(severity: float) -> void:
	# Sharp intake of breath
	if gasp_stream:
		reaction_player.stream = gasp_stream
		reaction_player.volume_db = -18.0 + severity * 12.0
		reaction_player.play()


# =============================================================================
# SLIDE AUDIO
# =============================================================================

## Start slide audio
func start_slide_audio(entry_speed: float, slope_angle: float) -> void:
	is_sliding = true

	# Select slide stream based on surface
	var stream := slide_snow_stream
	if current_surface == GameEnums.SurfaceType.ICE:
		stream = slide_ice_stream

	if stream:
		slide_player.stream = stream
		slide_player.volume_db = -18.0
		slide_player.pitch_scale = 1.0 + (entry_speed / 10.0) * 0.2
		slide_player.play()


## Stop slide audio
func stop_slide_audio(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	is_sliding = false
	slide_player.stop()

	# Play outcome sound
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			# Relief exhale
			if relief_exhale_stream:
				reaction_player.stream = relief_exhale_stream
				reaction_player.volume_db = -12.0
				reaction_player.play()

		GameEnums.SlideOutcome.TUMBLE_STOP:
			# Tumble sound + pain grunt
			if tumble_stream:
				slide_player.stream = tumble_stream
				slide_player.volume_db = -6.0
				slide_player.play()
			if pain_grunt_stream:
				get_tree().create_timer(0.3).timeout.connect(func():
					reaction_player.stream = pain_grunt_stream
					reaction_player.volume_db = -6.0
					reaction_player.play()
				)

		GameEnums.SlideOutcome.TERRAIN_CATCH:
			# Abrupt stop sound
			if tumble_stream:
				slide_player.stream = tumble_stream
				slide_player.volume_db = -12.0 + final_speed * 0.5
				slide_player.play()


## Set slide control level
func set_slide_control(control: GameEnums.SlideControlLevel) -> void:
	slide_control = control


# =============================================================================
# FATAL EVENT AUDIO
# =============================================================================

## Start fatal event audio sequence
func start_fatal_sequence() -> void:
	in_fatal_sequence = true
	# Breathing becomes desperate
	breathing_intensity = 1.0


## Cut player audio abruptly (loss of control phase)
func cut_player_audio() -> void:
	# Abrupt cut, not fade
	breathing_player.stop()
	footstep_player.stop()
	reaction_player.stop()


## Complete silence
func silence() -> void:
	breathing_player.stop()
	footstep_player.stop()
	slide_player.stop()
	gear_player.stop()
	reaction_player.stop()
	is_enabled = false


# =============================================================================
# ROPE AUDIO
# =============================================================================

## Play rope handling sound
func play_rope_handling() -> void:
	if rope_handling_stream:
		gear_player.stream = rope_handling_stream
		gear_player.volume_db = gear_volume
		gear_player.pitch_scale = randf_range(0.95, 1.05)
		gear_player.play()
		gear_sound_played.emit("rope")


## Play ice axe placement
func play_ice_axe() -> void:
	if ice_axe_stream:
		gear_player.stream = ice_axe_stream
		gear_player.volume_db = gear_volume + 3.0
		gear_player.pitch_scale = randf_range(0.9, 1.1)
		gear_player.play()
		gear_sound_played.emit("ice_axe")


# =============================================================================
# QUERIES
# =============================================================================

func get_breathing_intensity() -> float:
	return breathing_intensity


func is_audio_enabled() -> bool:
	return is_enabled


func get_summary() -> Dictionary:
	return {
		"enabled": is_enabled,
		"breathing_intensity": breathing_intensity,
		"fatigue_level": fatigue_level,
		"risk_level": risk_level,
		"is_sliding": is_sliding,
		"surface": GameEnums.SurfaceType.keys()[current_surface],
		"movement": GameEnums.PlayerMovementState.keys()[movement_state]
	}
