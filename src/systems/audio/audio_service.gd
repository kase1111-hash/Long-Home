class_name AudioService
extends Node
## Central audio coordinator for the game
## Manages all audio systems and provides unified control
##
## Design Philosophy:
## - Audio is diegetic first - sounds have in-world sources
## - Silence is intentional and meaningful
## - Breathing and wind are the primary soundscape
## - No music during gameplay - only environmental audio

# =============================================================================
# SIGNALS
# =============================================================================

signal audio_initialized()
signal master_volume_changed(volume: float)
signal audio_ducked(reason: String)
signal audio_restored()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Master Settings")
## Master volume (0-1)
@export var master_volume: float = 1.0
## Enable audio system
@export var audio_enabled: bool = true

@export_group("Ducking")
## Volume during ducked state (for dramatic moments)
@export var ducked_volume: float = 0.3
## Ducking transition time
@export var duck_transition_time: float = 0.5

# =============================================================================
# AUDIO BUSES
# =============================================================================

const BUS_MASTER := "Master"
const BUS_AMBIENT := "Ambient"
const BUS_PLAYER := "Player"
const BUS_EFFECTS := "Effects"
const BUS_UI := "UI"

# =============================================================================
# STATE
# =============================================================================

## Child audio managers
var ambient_manager: AmbientAudioManager
var player_audio: PlayerAudioManager

## Is audio ducked
var is_ducked: bool = false

## Duck tween reference
var duck_tween: Tween

## Current game state
var current_game_state: GameEnums.GameState = GameEnums.GameState.NONE


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("AudioService", self)
	_setup_audio_buses()
	_connect_event_bus()
	print("[AudioService] Initialized")


func _setup_audio_buses() -> void:
	# Ensure audio buses exist (these should be defined in project settings)
	# For now we work with the default bus structure
	pass


func _connect_event_bus() -> void:
	# Game state
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.descent_ready.connect(_on_descent_ready)

	# Weather changes affect ambient audio
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.wind_changed.connect(_on_wind_changed)

	# Player state affects player audio
	EventBus.player_movement_changed.connect(_on_player_movement_changed)
	EventBus.player_stability_changed.connect(_on_player_stability_changed)
	EventBus.fatigue_threshold_crossed.connect(_on_fatigue_threshold_crossed)
	EventBus.micro_slip_occurred.connect(_on_micro_slip)

	# Terrain changes affect footstep sounds
	EventBus.surface_changed.connect(_on_surface_changed)
	EventBus.terrain_zone_changed.connect(_on_terrain_zone_changed)

	# Sliding has specific audio
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.slide_control_changed.connect(_on_slide_control_changed)

	# Risk affects audio tension
	EventBus.risk_level_changed.connect(_on_risk_level_changed)
	EventBus.high_risk_zone_entered.connect(_on_high_risk_zone_entered)

	# Fatal events trigger dramatic audio changes
	EventBus.fatal_event_started.connect(_on_fatal_event_started)
	EventBus.fatal_phase_changed.connect(_on_fatal_phase_changed)


## Set ambient audio manager reference
func set_ambient_manager(manager: AmbientAudioManager) -> void:
	ambient_manager = manager


## Set player audio manager reference
func set_player_audio(manager: PlayerAudioManager) -> void:
	player_audio = manager


# =============================================================================
# VOLUME CONTROL
# =============================================================================

func set_master_volume(volume: float) -> void:
	master_volume = clampf(volume, 0.0, 1.0)
	_apply_volume()
	master_volume_changed.emit(master_volume)


func _apply_volume() -> void:
	var bus_index := AudioServer.get_bus_index(BUS_MASTER)
	if bus_index >= 0:
		var db := linear_to_db(master_volume if audio_enabled else 0.0)
		AudioServer.set_bus_volume_db(bus_index, db)


## Duck all audio (for dramatic moments)
func duck_audio(reason: String = "") -> void:
	if is_ducked:
		return

	is_ducked = true
	audio_ducked.emit(reason)

	if duck_tween:
		duck_tween.kill()

	duck_tween = create_tween()
	duck_tween.tween_method(_set_ducked_volume, 1.0, ducked_volume, duck_transition_time)


## Restore audio after ducking
func restore_audio() -> void:
	if not is_ducked:
		return

	is_ducked = false
	audio_restored.emit()

	if duck_tween:
		duck_tween.kill()

	duck_tween = create_tween()
	duck_tween.tween_method(_set_ducked_volume, ducked_volume, 1.0, duck_transition_time)


func _set_ducked_volume(volume: float) -> void:
	# Apply ducking to ambient and effects, not UI
	var ambient_bus := AudioServer.get_bus_index(BUS_AMBIENT)
	var effects_bus := AudioServer.get_bus_index(BUS_EFFECTS)

	if ambient_bus >= 0:
		AudioServer.set_bus_volume_db(ambient_bus, linear_to_db(volume))
	if effects_bus >= 0:
		AudioServer.set_bus_volume_db(effects_bus, linear_to_db(volume))


# =============================================================================
# GAME STATE HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	current_game_state = new_state

	match new_state:
		GameEnums.GameState.MAIN_MENU:
			_enter_menu_audio()
		GameEnums.GameState.DESCENT:
			_enter_descent_audio()
		GameEnums.GameState.RESOLUTION:
			_enter_resolution_audio()
		GameEnums.GameState.PAUSED:
			_enter_paused_audio()


func _on_descent_ready() -> void:
	# Start all ambient audio for descent
	if ambient_manager:
		ambient_manager.start_ambient()
	if player_audio:
		player_audio.enable()


func _enter_menu_audio() -> void:
	# Menu has minimal ambient (quiet wind)
	if ambient_manager:
		ambient_manager.set_wind_intensity(0.2)
		ambient_manager.stop_all_environmental()
	if player_audio:
		player_audio.disable()


func _enter_descent_audio() -> void:
	# Full audio during descent
	if player_audio:
		player_audio.enable()


func _enter_resolution_audio() -> void:
	# Quiet, reflective audio
	duck_audio("resolution")
	if player_audio:
		player_audio.disable()


func _enter_paused_audio() -> void:
	# Mute player audio, keep ambient very quiet
	if ambient_manager:
		ambient_manager.set_wind_intensity(0.1)
	if player_audio:
		player_audio.pause_audio()


# =============================================================================
# WEATHER EVENT HANDLERS
# =============================================================================

func _on_weather_changed(old_weather: GameEnums.WeatherState, new_weather: GameEnums.WeatherState) -> void:
	if ambient_manager == null:
		return

	# Adjust ambient audio based on weather
	match new_weather:
		GameEnums.WeatherState.CLEAR:
			ambient_manager.set_weather_intensity(0.0)
		GameEnums.WeatherState.CLOUDY:
			ambient_manager.set_weather_intensity(0.2)
		GameEnums.WeatherState.DETERIORATING:
			ambient_manager.set_weather_intensity(0.5)
		GameEnums.WeatherState.STORM:
			ambient_manager.set_weather_intensity(0.8)
		GameEnums.WeatherState.WHITEOUT:
			ambient_manager.set_weather_intensity(1.0)


func _on_wind_changed(strength: GameEnums.WindStrength, _direction: Vector3) -> void:
	if ambient_manager == null:
		return

	var intensity := 0.0
	match strength:
		GameEnums.WindStrength.CALM:
			intensity = 0.1
		GameEnums.WindStrength.LIGHT:
			intensity = 0.3
		GameEnums.WindStrength.MODERATE:
			intensity = 0.5
		GameEnums.WindStrength.STRONG:
			intensity = 0.75
		GameEnums.WindStrength.SEVERE:
			intensity = 1.0

	ambient_manager.set_wind_intensity(intensity)


# =============================================================================
# PLAYER EVENT HANDLERS
# =============================================================================

func _on_player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	if player_audio == null:
		return

	player_audio.set_movement_state(new_state)


func _on_player_stability_changed(stability: float, posture: GameEnums.PostureState) -> void:
	if player_audio == null:
		return

	player_audio.set_stability(stability, posture)


func _on_fatigue_threshold_crossed(fatigue: float, threshold_name: String) -> void:
	if player_audio == null:
		return

	player_audio.set_fatigue_level(fatigue)

	# Threshold-specific audio cues
	match threshold_name:
		"breathing_change":
			player_audio.trigger_breathing_change()
		"critical":
			player_audio.trigger_critical_fatigue()


func _on_micro_slip(severity: float, _position: Vector3) -> void:
	if player_audio:
		player_audio.play_micro_slip(severity)


func _on_surface_changed(old_surface: GameEnums.SurfaceType, new_surface: GameEnums.SurfaceType) -> void:
	if player_audio:
		player_audio.set_surface_type(new_surface)


func _on_terrain_zone_changed(old_zone: GameEnums.TerrainZone, new_zone: GameEnums.TerrainZone) -> void:
	# Terrain zone affects ambient audio (exposure, echo)
	if ambient_manager:
		ambient_manager.set_terrain_zone(new_zone)


# =============================================================================
# SLIDING EVENT HANDLERS
# =============================================================================

func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	if player_audio:
		player_audio.start_slide_audio(entry_speed, slope_angle)
	if ambient_manager:
		ambient_manager.start_slide_wind()


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	if player_audio:
		player_audio.stop_slide_audio(outcome, final_speed)
	if ambient_manager:
		ambient_manager.stop_slide_wind()


func _on_slide_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel) -> void:
	if player_audio:
		player_audio.set_slide_control(new_level)


# =============================================================================
# RISK EVENT HANDLERS
# =============================================================================

func _on_risk_level_changed(risk: float, _factors: Dictionary) -> void:
	if player_audio:
		player_audio.set_risk_level(risk)
	if ambient_manager:
		ambient_manager.set_tension_level(risk)


func _on_high_risk_zone_entered(risk_type: String, severity: float) -> void:
	# Brief audio cue for entering danger zone
	if player_audio:
		player_audio.play_risk_cue(severity)


# =============================================================================
# FATAL EVENT HANDLERS
# =============================================================================

func _on_fatal_event_started(phase: GameEnums.FatalPhase) -> void:
	# Begin fatal event audio sequence
	duck_audio("fatal_event")

	if ambient_manager:
		ambient_manager.start_fatal_sequence()
	if player_audio:
		player_audio.start_fatal_sequence()


func _on_fatal_phase_changed(old_phase: GameEnums.FatalPhase, new_phase: GameEnums.FatalPhase) -> void:
	match new_phase:
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			# Wind crescendo, player audio cuts
			if ambient_manager:
				ambient_manager.set_wind_intensity(1.0)
			if player_audio:
				player_audio.cut_player_audio()

		GameEnums.FatalPhase.AFTERMATH:
			# Only wind, silence
			if ambient_manager:
				ambient_manager.enter_aftermath()
			if player_audio:
				player_audio.silence()

		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			# Fade to complete silence
			if ambient_manager:
				ambient_manager.fade_to_silence(3.0)


# =============================================================================
# UTILITY
# =============================================================================

## Play a one-shot sound effect
func play_effect(stream: AudioStream, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not audio_enabled or stream == null:
		return

	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.bus = BUS_EFFECTS
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


## Play a 3D positioned sound effect
func play_effect_3d(stream: AudioStream, position: Vector3, volume_db: float = 0.0) -> void:
	if not audio_enabled or stream == null:
		return

	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = BUS_EFFECTS
	player.global_position = position
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)


# =============================================================================
# QUERIES
# =============================================================================

func is_audio_enabled() -> bool:
	return audio_enabled


func get_master_volume() -> float:
	return master_volume


func get_summary() -> Dictionary:
	return {
		"enabled": audio_enabled,
		"master_volume": master_volume,
		"is_ducked": is_ducked,
		"game_state": GameEnums.GameState.keys()[current_game_state]
	}
