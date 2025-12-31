class_name AmbientAudioManager
extends Node
## Manages environmental and ambient audio
## Wind is the primary soundscape - always present, always meaningful
##
## Design Philosophy:
## - Wind is layered: base layer, gust layer, altitude layer
## - Silence is intentional - brief wind drops create tension
## - Weather affects all ambient sounds
## - The mountain speaks through sound

# =============================================================================
# SIGNALS
# =============================================================================

signal wind_intensity_changed(intensity: float)
signal silence_moment_started()
signal silence_moment_ended()
signal ambient_started()
signal ambient_stopped()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Wind Layers")
## Base wind stream (constant, low frequency)
@export var wind_base_stream: AudioStream
## Gust wind stream (intermittent, mid frequency)
@export var wind_gust_stream: AudioStream
## High altitude wind stream (high frequency, thin)
@export var wind_altitude_stream: AudioStream
## Howling wind for exposed areas
@export var wind_howl_stream: AudioStream

@export_group("Environmental")
## Snow/ice cracking ambient
@export var ice_ambient_stream: AudioStream
## Distant avalanche rumble
@export var avalanche_distant_stream: AudioStream
## Snow settling sound
@export var snow_settle_stream: AudioStream

@export_group("Volume Curves")
## Wind base volume range (min, max dB)
@export var wind_base_volume_range: Vector2 = Vector2(-24.0, -6.0)
## Wind gust volume range
@export var wind_gust_volume_range: Vector2 = Vector2(-30.0, -12.0)
## Wind altitude volume range
@export var wind_altitude_volume_range: Vector2 = Vector2(-36.0, -18.0)

@export_group("Timing")
## Minimum time between gusts (seconds)
@export var gust_interval_min: float = 3.0
## Maximum time between gusts
@export var gust_interval_max: float = 12.0
## Silence moment probability per update
@export var silence_moment_chance: float = 0.001
## Silence moment duration range
@export var silence_duration_range: Vector2 = Vector2(1.5, 4.0)

# =============================================================================
# AUDIO PLAYERS
# =============================================================================

var wind_base_player: AudioStreamPlayer
var wind_gust_player: AudioStreamPlayer
var wind_altitude_player: AudioStreamPlayer
var wind_howl_player: AudioStreamPlayer
var ice_ambient_player: AudioStreamPlayer

# =============================================================================
# STATE
# =============================================================================

## Current wind intensity (0-1)
var wind_intensity: float = 0.3

## Current weather intensity (0-1)
var weather_intensity: float = 0.0

## Current tension level (0-1) from risk
var tension_level: float = 0.0

## Current terrain zone
var current_terrain_zone: GameEnums.TerrainZone = GameEnums.TerrainZone.WALKABLE

## Is in silence moment
var in_silence_moment: bool = false

## Time until next gust
var next_gust_time: float = 5.0

## Is sliding (affects wind audio)
var is_sliding: bool = false

## Is in fatal sequence
var in_fatal_sequence: bool = false

## Is ambient active
var is_active: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_create_audio_players()
	ServiceLocator.register_service("AmbientAudioManager", self)

	# Register with audio service
	ServiceLocator.get_service_async("AudioService", func(service):
		if service:
			service.set_ambient_manager(self)
	)

	print("[AmbientAudioManager] Initialized")


func _create_audio_players() -> void:
	# Base wind - always playing when active
	wind_base_player = AudioStreamPlayer.new()
	wind_base_player.bus = "Ambient"
	wind_base_player.volume_db = -20.0
	add_child(wind_base_player)

	# Gust wind - intermittent
	wind_gust_player = AudioStreamPlayer.new()
	wind_gust_player.bus = "Ambient"
	wind_gust_player.volume_db = -30.0
	add_child(wind_gust_player)

	# Altitude wind - high exposure areas
	wind_altitude_player = AudioStreamPlayer.new()
	wind_altitude_player.bus = "Ambient"
	wind_altitude_player.volume_db = -36.0
	add_child(wind_altitude_player)

	# Howling wind - severe conditions
	wind_howl_player = AudioStreamPlayer.new()
	wind_howl_player.bus = "Ambient"
	wind_howl_player.volume_db = -40.0
	add_child(wind_howl_player)

	# Ice ambient
	ice_ambient_player = AudioStreamPlayer.new()
	ice_ambient_player.bus = "Ambient"
	ice_ambient_player.volume_db = -30.0
	add_child(ice_ambient_player)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active:
		return

	_update_wind_volumes(delta)
	_update_gusts(delta)
	_check_silence_moment(delta)


func _update_wind_volumes(delta: float) -> void:
	if in_silence_moment:
		# Fade to silence
		_fade_player(wind_base_player, -60.0, delta * 2.0)
		_fade_player(wind_gust_player, -60.0, delta * 2.0)
		_fade_player(wind_altitude_player, -60.0, delta * 2.0)
		return

	# Calculate target volumes based on intensity
	var base_target := lerpf(wind_base_volume_range.x, wind_base_volume_range.y, wind_intensity)
	var gust_target := lerpf(wind_gust_volume_range.x, wind_gust_volume_range.y, wind_intensity)
	var altitude_target := lerpf(wind_altitude_volume_range.x, wind_altitude_volume_range.y, wind_intensity)

	# Terrain zone affects altitude wind
	if _is_exposed_terrain():
		altitude_target += 6.0  # Louder on exposed terrain

	# Sliding increases wind audio
	if is_sliding:
		base_target += 6.0
		gust_target += 3.0

	# Weather intensity adds to wind
	base_target += weather_intensity * 6.0
	gust_target += weather_intensity * 3.0

	# Howl in severe conditions
	var howl_target := -60.0
	if wind_intensity > 0.7 or weather_intensity > 0.7:
		howl_target = -18.0 + (wind_intensity - 0.7) * 20.0

	# Apply volumes with smoothing
	_fade_player(wind_base_player, base_target, delta)
	_fade_player(wind_gust_player, gust_target, delta)
	_fade_player(wind_altitude_player, altitude_target, delta)
	_fade_player(wind_howl_player, howl_target, delta * 0.5)


func _fade_player(player: AudioStreamPlayer, target_db: float, delta: float) -> void:
	var speed := 5.0
	player.volume_db = lerpf(player.volume_db, target_db, speed * delta)


func _update_gusts(delta: float) -> void:
	next_gust_time -= delta

	if next_gust_time <= 0:
		_trigger_gust()
		# Schedule next gust
		var interval_mod := 1.0 - wind_intensity * 0.5  # More frequent at high intensity
		next_gust_time = randf_range(gust_interval_min, gust_interval_max) * interval_mod


func _trigger_gust() -> void:
	if wind_gust_player.stream and not wind_gust_player.playing:
		# Randomize pitch slightly for variety
		wind_gust_player.pitch_scale = randf_range(0.9, 1.1)
		wind_gust_player.play()


func _check_silence_moment(delta: float) -> void:
	if in_silence_moment:
		return

	# Silence moments are rare and meaningful
	# More likely when tension is moderate (not too high, not too low)
	var silence_chance := silence_moment_chance
	if tension_level > 0.3 and tension_level < 0.7:
		silence_chance *= 2.0

	# Less likely during severe weather
	if weather_intensity > 0.5:
		silence_chance *= 0.2

	if randf() < silence_chance * delta:
		_start_silence_moment()


func _start_silence_moment() -> void:
	in_silence_moment = true
	silence_moment_started.emit()

	# Brief moment of quiet - wind drops
	var duration := randf_range(silence_duration_range.x, silence_duration_range.y)

	# Camera system can use this signal for a "silence" shot
	EventBus.emit_camera_signal(GameEnums.CameraSignal.SILENCE_MOMENT, 0.5)

	# End silence after duration
	get_tree().create_timer(duration).timeout.connect(_end_silence_moment)


func _end_silence_moment() -> void:
	in_silence_moment = false
	silence_moment_ended.emit()


func _is_exposed_terrain() -> bool:
	return current_terrain_zone in [
		GameEnums.TerrainZone.CLIFF,
		GameEnums.TerrainZone.RAPPEL_REQUIRED,
		GameEnums.TerrainZone.DOWNCLIMB
	]


# =============================================================================
# PUBLIC CONTROL
# =============================================================================

## Start ambient audio
func start_ambient() -> void:
	is_active = true

	# Start base wind
	if wind_base_stream:
		wind_base_player.stream = wind_base_stream
		wind_base_player.play()

	# Prepare gust player
	if wind_gust_stream:
		wind_gust_player.stream = wind_gust_stream

	# Prepare altitude wind
	if wind_altitude_stream:
		wind_altitude_player.stream = wind_altitude_stream
		wind_altitude_player.play()

	# Prepare howl
	if wind_howl_stream:
		wind_howl_player.stream = wind_howl_stream
		wind_howl_player.play()

	ambient_started.emit()


## Stop all ambient audio
func stop_ambient() -> void:
	is_active = false
	wind_base_player.stop()
	wind_gust_player.stop()
	wind_altitude_player.stop()
	wind_howl_player.stop()
	ice_ambient_player.stop()
	ambient_stopped.emit()


## Stop environmental sounds (not wind)
func stop_all_environmental() -> void:
	ice_ambient_player.stop()


## Set wind intensity (0-1)
func set_wind_intensity(intensity: float) -> void:
	wind_intensity = clampf(intensity, 0.0, 1.0)
	wind_intensity_changed.emit(wind_intensity)


## Set weather intensity (0-1)
func set_weather_intensity(intensity: float) -> void:
	weather_intensity = clampf(intensity, 0.0, 1.0)


## Set tension level from risk system (0-1)
func set_tension_level(tension: float) -> void:
	tension_level = clampf(tension, 0.0, 1.0)


## Set current terrain zone
func set_terrain_zone(zone: GameEnums.TerrainZone) -> void:
	current_terrain_zone = zone


## Start slide-specific wind audio
func start_slide_wind() -> void:
	is_sliding = true
	# Pitch up base wind slightly for speed feel
	wind_base_player.pitch_scale = 1.1


## Stop slide wind audio
func stop_slide_wind() -> void:
	is_sliding = false
	wind_base_player.pitch_scale = 1.0


# =============================================================================
# FATAL EVENT AUDIO
# =============================================================================

## Start fatal event audio sequence
func start_fatal_sequence() -> void:
	in_fatal_sequence = true
	# Wind begins to crescendo
	set_wind_intensity(0.8)


## Enter aftermath phase - only wind, settling
func enter_aftermath() -> void:
	# Wind still present but calming
	set_wind_intensity(0.5)

	# Play snow settling sound if available
	if snow_settle_stream:
		var player := AudioStreamPlayer.new()
		player.stream = snow_settle_stream
		player.volume_db = -12.0
		player.bus = "Ambient"
		add_child(player)
		player.play()
		player.finished.connect(player.queue_free)


## Fade all ambient to silence
func fade_to_silence(duration: float) -> void:
	var tween := create_tween()
	tween.tween_method(func(vol): wind_base_player.volume_db = vol, wind_base_player.volume_db, -60.0, duration)
	tween.parallel().tween_method(func(vol): wind_gust_player.volume_db = vol, wind_gust_player.volume_db, -60.0, duration)
	tween.parallel().tween_method(func(vol): wind_altitude_player.volume_db = vol, wind_altitude_player.volume_db, -60.0, duration)
	tween.parallel().tween_method(func(vol): wind_howl_player.volume_db = vol, wind_howl_player.volume_db, -60.0, duration)


# =============================================================================
# SPECIAL SOUNDS
# =============================================================================

## Play ice cracking ambient
func play_ice_crack() -> void:
	if ice_ambient_stream and not ice_ambient_player.playing:
		ice_ambient_player.stream = ice_ambient_stream
		ice_ambient_player.volume_db = randf_range(-24.0, -18.0)
		ice_ambient_player.pitch_scale = randf_range(0.8, 1.2)
		ice_ambient_player.play()


## Play distant avalanche rumble
func play_distant_avalanche() -> void:
	if avalanche_distant_stream:
		var player := AudioStreamPlayer.new()
		player.stream = avalanche_distant_stream
		player.volume_db = -18.0
		player.bus = "Ambient"
		add_child(player)
		player.play()
		player.finished.connect(player.queue_free)


# =============================================================================
# QUERIES
# =============================================================================

func get_wind_intensity() -> float:
	return wind_intensity


func is_in_silence_moment() -> bool:
	return in_silence_moment


func get_summary() -> Dictionary:
	return {
		"wind_intensity": wind_intensity,
		"weather_intensity": weather_intensity,
		"tension_level": tension_level,
		"is_sliding": is_sliding,
		"in_silence": in_silence_moment,
		"terrain_zone": GameEnums.TerrainZone.keys()[current_terrain_zone]
	}
