class_name AmbientAudioManager
extends Node
## Manages environmental and ambient audio
## Wind is the primary soundscape - always present, always meaningful
##
## Design Philosophy:
## - Wind is layered: a low body, a rush on each side, a thin high hiss, and
##   howls and whistles that only a strong wind brings
## - Silence is intentional - brief wind drops create tension
## - Weather affects all ambient sounds
## - The mountain speaks through sound
##
## The wind loops are steady textures. Everything that makes wind sound alive
## happens here: each layer's level follows the wind strength on its own
## curve (a gale is brighter, not just louder), drifts a little on its own,
## and swells together when a gust comes through.

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

@export_group("Timing")
## Seconds between gusts in calm air, and in a storm
@export var gust_interval_calm: float = 14.0
@export var gust_interval_storm: float = 4.0
## Silence moment probability per update
@export var silence_moment_chance: float = 0.001
## Silence moment duration range
@export var silence_duration_range: Vector2 = Vector2(1.5, 4.0)

## Level of each layer in the mix (dB, with the layer fully up)
const TRIM_LOW := -6.0
const TRIM_MID := -8.0
const TRIM_HIGH := -13.0
const TRIM_HOWL := -11.0
const TRIM_WHISTLE := -16.0
const TRIM_SPINDRIFT := -14.0
const TRIM_RAIN := -10.0
const TRIM_SLEET := -12.0
const TRIM_FLAGS := -13.0

## Seconds for the heard wind to follow a change in the real one
const WIND_FOLLOW_TIME := 2.5

## Wind (0-1) from which loose snow starts to blow, and where it is in full
## flight: the same 13 and 26 m/s the spindrift particles use, over a 28 m/s gale
const SPINDRIFT_FROM := 0.46
const SPINDRIFT_FULL := 0.93

## How far the flags at the summit and the camp carry (m)
const FLAG_REACH := 7.0

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

## Is sliding (affects wind audio)
var is_sliding: bool = false

## Is in fatal sequence
var in_fatal_sequence: bool = false

## Is ambient active
var is_active: bool = false

## Overall level of the ambience (0-1): quiet behind the menus, full on the mountain
var presence: float = 1.0

## A slowly wandering level for one layer, so the layers never move in step
class Wander:
	var value_db: float = 0.0
	var target_db: float = 0.0
	var timer: float = 0.0
	var depth_db: float = 2.5

	func step(delta: float) -> float:
		timer -= delta
		if timer <= 0.0:
			timer = AudioService.roll_range(2.0, 6.0)
			target_db = AudioService.roll_range(-depth_db, depth_db)
		value_db = lerpf(value_db, target_db, 1.0 - exp(-delta / 1.5))
		return db_to_linear(value_db)

var _library: SoundLibrary

## Layer name -> AudioFader, its Wander, and [sound id, variant]
var _layers: Dictionary = {}
var _wander: Dictionary = {}
var _layer_sound: Dictionary = {}

var _summit_flags: AudioFader
var _camp_flags: AudioFader

## Wind as heard: eased toward wind_intensity
var _wind_now: float = 0.3
var _exposure: float = 0.4
var _quiet: float = 1.0
var _presence_now: float = 1.0

## The gust passing through: 0 between gusts
var _gust: float = 0.0
var _gust_target: float = 0.0
var _gust_hold: float = 0.0
var _next_gust: float = 6.0

## Wind level forced by the fatal sequence (negative: not forced)
var _fatal_wind: float = -1.0

## What is falling: rain and sleet are heard, snow is not
var _rain_level: float = 0.0
var _sleet_level: float = 0.0
var _on_snow: float = 1.0
var _poll_timer: float = 0.0

var _next_ice: float = 30.0
var _next_rockfall: float = 180.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_library = ServiceLocator.get_service("SoundLibrary") as SoundLibrary
	_create_layers()
	assign_streams()
	ServiceLocator.register_service("AmbientAudioManager", self)
	EventBus.wind_audio_changed.connect(_on_fatal_wind_changed)
	EventBus.fatal_event_completed.connect(end_fatal_sequence)
	EventBus.descent_ready.connect(_on_descent_ready)

	# Register with audio service
	ServiceLocator.get_service_async("AudioService", func(service):
		if service:
			service.set_ambient_manager(self)
	)

	print("[AmbientAudioManager] Initialized")


func _create_layers() -> void:
	_add_layer("low", "wind_low_loop", 0, AudioService.BUS_AMBIENT, TRIM_LOW)
	_add_layer("mid_left", "wind_mid_loop", 0, AudioService.BUS_AMBIENT_LEFT, TRIM_MID)
	_add_layer("mid_right", "wind_mid_loop", 1, AudioService.BUS_AMBIENT_RIGHT, TRIM_MID)
	_add_layer("high", "wind_high_loop", 0, AudioService.BUS_AMBIENT, TRIM_HIGH)
	_add_layer("howl_left", "wind_howl_loop", 0, AudioService.BUS_AMBIENT_LEFT, TRIM_HOWL)
	_add_layer("howl_right", "wind_howl_loop", 1, AudioService.BUS_AMBIENT_RIGHT, TRIM_HOWL)
	_add_layer("whistle", "wind_whistle_loop", 0, AudioService.BUS_AMBIENT, TRIM_WHISTLE)
	_add_layer("spindrift", "spindrift_loop", 0, AudioService.BUS_AMBIENT, TRIM_SPINDRIFT)
	_add_layer("rain", "rain_loop", 0, AudioService.BUS_AMBIENT, TRIM_RAIN)
	_add_layer("sleet", "sleet_loop", 0, AudioService.BUS_AMBIENT, TRIM_SLEET)

	_summit_flags = _add_flags()
	_camp_flags = _add_flags()


func _add_layer(key: String, sound_id: String, variant: int, bus: String, trim_db: float) -> void:
	var player := AudioStreamPlayer.new()
	player.name = "Layer_" + key
	player.bus = bus
	add_child(player)
	_layers[key] = AudioFader.new(player, trim_db, 1.2, 2.0)
	_wander[key] = Wander.new()
	_layer_sound[key] = [sound_id, variant]


func _add_flags() -> AudioFader:
	var player := AudioStreamPlayer3D.new()
	player.bus = AudioService.BUS_AMBIENT
	player.unit_size = FLAG_REACH
	player.max_distance = 90.0
	add_child(player)
	return AudioFader.new(player, TRIM_FLAGS, 0.8, 1.5)


## Give every layer its sound from the library (again after a reload)
func assign_streams() -> void:
	if _library == null:
		return
	for key in _layers.keys():
		var fader: AudioFader = _layers[key]
		var sound: Array = _layer_sound[key]
		var id: String = sound[0]
		var variant: int = sound[1]
		if _library.has_sound(id):
			fader.player.set("stream", _library.get_variant(id, variant))
	if _library.has_sound("flag_flap_loop"):
		_summit_flags.player.set("stream", _library.get_stream("flag_flap_loop"))
		_camp_flags.player.set("stream", _library.get_stream("flag_flap_loop"))


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active:
		return

	_update_gusts(delta)
	_update_wind(delta)
	_update_surroundings(delta)
	_update_layers(delta)
	_update_distant_sounds(delta)
	_check_silence_moment(delta)


func _update_wind(delta: float) -> void:
	var target := wind_intensity
	if _fatal_wind >= 0.0:
		target = _fatal_wind
	elif is_sliding:
		# Moving fast, the air is louder whatever the weather
		target = minf(1.0, target + 0.12)
	_wind_now = lerpf(_wind_now, target, 1.0 - exp(-delta / WIND_FOLLOW_TIME))

	var exposed := 1.0 if _is_exposed_terrain() else 0.4
	_exposure = lerpf(_exposure, exposed, 1.0 - exp(-delta / 2.0))
	_quiet = lerpf(_quiet, 0.12 if in_silence_moment else 1.0, 1.0 - exp(-delta / 0.6))
	_presence_now = lerpf(_presence_now, presence, 1.0 - exp(-delta / 1.2))


## The wind as it is this instant: the steady wind lifted by the passing gust
func _wind_with_gust() -> float:
	return clampf(_wind_now * (1.0 + 0.45 * _gust) + 0.06 * _gust, 0.0, 1.15)


func _update_layers(delta: float) -> void:
	var w := _wind_with_gust()
	var storm := weather_intensity
	var scale := _presence_now * _quiet

	# A stronger wind is brighter: the higher layers come up later and faster
	var low := 0.06 + 0.94 * pow(w, 0.9)
	var mid := 0.05 + 0.95 * pow(w, 1.25)
	var high := (0.03 + 0.6 * pow(w, 1.5)) * lerpf(0.55, 1.0, _exposure)
	var howl := smoothstep(0.5, 0.95, maxf(w, 0.4 * w + 0.6 * storm)) * 0.75
	var whistle := smoothstep(0.68, 1.0, w) * _exposure * 0.55
	var spindrift := smoothstep(SPINDRIFT_FROM, SPINDRIFT_FULL, w) * _on_snow * 0.6

	_set_layer("low", low * scale, 0.94 + 0.12 * w, delta)
	_set_layer("mid_left", mid * scale, 0.92 + 0.16 * w, delta)
	_set_layer("mid_right", mid * scale, 0.9 + 0.17 * w, delta)
	_set_layer("high", high * scale, 0.9 + 0.2 * w, delta)
	_set_layer("howl_left", howl * scale, 0.9 + 0.18 * w, delta)
	_set_layer("howl_right", howl * scale, 0.86 + 0.2 * w, delta)
	_set_layer("whistle", whistle * scale, 0.9 + 0.2 * w, delta)
	_set_layer("spindrift", spindrift * scale, 0.9 + 0.2 * w, delta)
	_set_layer("rain", _rain_level * _presence_now, 1.0, delta)
	_set_layer("sleet", _sleet_level * _presence_now, 1.0, delta)

	# Flags flap harder in more wind
	var flap := (0.25 + 0.75 * minf(w, 1.0)) * _presence_now
	_summit_flags.level = flap
	_summit_flags.pitch = 0.85 + 0.35 * w
	_summit_flags.update(delta)
	_camp_flags.level = flap * 0.8
	_camp_flags.pitch = 0.7 + 0.25 * w
	_camp_flags.update(delta)


func _set_layer(key: String, level: float, pitch: float, delta: float) -> void:
	var fader: AudioFader = _layers[key]
	var wander: Wander = _wander[key]
	fader.level = level * wander.step(delta) if level > 0.0 else 0.0
	fader.pitch = pitch
	fader.update(delta)


func _update_gusts(delta: float) -> void:
	# The gust itself: up quickly, held a moment, away slowly
	if _gust_hold > 0.0:
		_gust_hold -= delta
		if _gust_hold <= 0.0:
			_gust_target = 0.0
	var time := 0.6 if _gust_target > _gust else 2.2
	_gust = lerpf(_gust, _gust_target, 1.0 - exp(-delta / time))

	_next_gust -= delta
	if _next_gust <= 0.0 and not in_silence_moment:
		trigger_gust(AudioService.roll_range(0.45, 1.0))


## Send a gust through now (strength 0-1)
func trigger_gust(strength: float = 0.8) -> void:
	_gust_target = clampf(strength, 0.0, 1.0)
	_gust_hold = AudioService.roll_range(0.8, 1.6)
	# More frequent in more wind
	var interval := lerpf(gust_interval_calm, gust_interval_storm, clampf(_wind_now, 0.0, 1.0))
	_next_gust = interval * AudioService.roll_range(0.6, 1.5)

	var service := ServiceLocator.get_service("AudioService") as AudioService
	if service == null or not is_active:
		return
	var buses := [AudioService.BUS_AMBIENT_LEFT, AudioService.BUS_AMBIENT_RIGHT, AudioService.BUS_AMBIENT]
	var bus: String = buses[AudioService.roll_index(buses.size())]
	var volume := lerpf(-26.0, -9.0, clampf(_wind_now, 0.0, 1.0)) + 6.0 * (strength - 0.7)
	volume += linear_to_db(maxf(_presence_now * _quiet, 0.01))
	service.play("wind_gust", volume, AudioService.roll_range(0.88, 1.12), bus)


## What the climber is standing in: is there loose snow to blow, is it raining
func _update_surroundings(delta: float) -> void:
	_poll_timer -= delta
	if _poll_timer > 0.0:
		return
	_poll_timer = 0.5

	var rain := 0.0
	var sleet := 0.0
	var environment := ServiceLocator.get_service("EnvironmentService") as EnvironmentService
	if environment != null and environment.visuals != null and GameStateManager.current_state == GameEnums.GameState.DESCENT:
		var amount := 0.45 + 0.55 * weather_intensity
		match environment.visuals.get_precipitation_form():
			EnvironmentVisuals.PrecipitationForm.RAIN:
				rain = amount
			EnvironmentVisuals.PrecipitationForm.SLEET:
				sleet = amount
				rain = amount * 0.35
	_rain_level = rain
	_sleet_level = sleet

	var snow := 1.0
	var player := _get_player()
	if player != null and player.current_cell != null:
		snow = 1.0 if TractionModel.is_snow(player.current_cell.surface_type) else 0.25
	_on_snow = snow


## Now and then the mountain itself: ice shifting in a glacier, a stone falling
func _update_distant_sounds(delta: float) -> void:
	if GameStateManager.current_state != GameEnums.GameState.DESCENT or in_fatal_sequence:
		return
	var player := _get_player()
	if player == null:
		return

	_next_ice -= delta
	if _next_ice <= 0.0:
		_next_ice = AudioService.roll_range(22.0, 65.0)
		if _is_on_glacier(player.global_position):
			if AudioService.roll() < 0.25:
				play_ice_crack()
			else:
				_play_far("ice_creak", player.global_position, AudioService.roll_range(20.0, 60.0), -8.0, 25.0)

	_next_rockfall -= delta
	if _next_rockfall <= 0.0:
		_next_rockfall = AudioService.roll_range(150.0, 420.0)
		_play_far("rockfall_distant", player.global_position, AudioService.roll_range(140.0, 300.0), -4.0, 120.0)


func _play_far(id: String, from: Vector3, distance: float, volume_db: float, reach: float) -> void:
	var service := ServiceLocator.get_service("AudioService") as AudioService
	if service == null:
		return
	var angle := AudioService.roll() * TAU
	var where := from + Vector3(cos(angle) * distance, AudioService.roll_range(-10.0, 30.0), sin(angle) * distance)
	service.play_at(id, where, volume_db, AudioService.roll_range(0.9, 1.1), reach, AudioService.BUS_AMBIENT)


func _is_on_glacier(position: Vector3) -> bool:
	var terrain := ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain == null or terrain.glacier == null:
		return false
	return terrain.glacier.is_on_glacier(Vector2(position.x, position.z))


func _get_player() -> PlayerController:
	return ServiceLocator.get_service("PlayerController") as PlayerController


func _check_silence_moment(delta: float) -> void:
	if in_silence_moment or in_fatal_sequence:
		return

	# Silence moments are rare and meaningful
	# More likely when tension is moderate (not too high, not too low)
	var silence_chance := silence_moment_chance
	if tension_level > 0.3 and tension_level < 0.7:
		silence_chance *= 2.0

	# Less likely during severe weather
	if weather_intensity > 0.5:
		silence_chance *= 0.2

	if AudioService.roll() < silence_chance * delta:
		_start_silence_moment()


func _start_silence_moment() -> void:
	in_silence_moment = true
	silence_moment_started.emit()

	# Brief moment of quiet - wind drops
	var duration := AudioService.roll_range(silence_duration_range.x, silence_duration_range.y)

	# Camera system can use this signal for a "silence" shot
	EventBus.emit_camera_signal(GameEnums.CameraSignal.SILENCE_MOMENT, 0.5)

	# End silence after duration
	get_tree().create_timer(duration, false).timeout.connect(_end_silence_moment)


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
	if is_active:
		return
	is_active = true
	ambient_started.emit()


## Stop all ambient audio
func stop_ambient() -> void:
	is_active = false
	for key in _layers.keys():
		var fader: AudioFader = _layers[key]
		fader.cut()
	_summit_flags.cut()
	_camp_flags.cut()
	ambient_stopped.emit()


## Stop environmental sounds (not wind): the flags belong to a mountain
func stop_all_environmental() -> void:
	_summit_flags.cut()
	_camp_flags.cut()
	_summit_flags.player.set("stream", null)
	_camp_flags.player.set("stream", null)
	_rain_level = 0.0
	_sleet_level = 0.0


## Overall level of the ambience (0-1): low behind the menus
func set_presence(level: float) -> void:
	presence = clampf(level, 0.0, 1.0)


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


## Stop slide wind audio
func stop_slide_wind() -> void:
	is_sliding = false


func _on_descent_ready() -> void:
	# A new day: nothing carried over from the last run
	end_fatal_sequence()
	in_silence_moment = false
	_next_ice = AudioService.roll_range(15.0, 40.0)
	_next_rockfall = AudioService.roll_range(120.0, 300.0)

	# The flags at the summit cairn and at base camp
	var terrain := ServiceLocator.get_service("TerrainService") as TerrainService
	if terrain == null or _library == null or not _library.has_sound("flag_flap_loop"):
		return
	var stream := _library.get_stream("flag_flap_loop")
	_place_flags(_summit_flags, terrain.start_position + Vector3(0.0, 1.6, 0.0), stream)
	_place_flags(_camp_flags, terrain.goal_position + Vector3(0.0, 2.5, 0.0), stream)


func _place_flags(flags: AudioFader, where: Vector3, stream: AudioStream) -> void:
	var player := flags.player as AudioStreamPlayer3D
	if where == Vector3.ZERO or player == null:
		return
	player.stream = stream
	player.global_position = where


# =============================================================================
# FATAL EVENT AUDIO
# =============================================================================

## Start fatal event audio sequence
func start_fatal_sequence() -> void:
	in_fatal_sequence = true
	in_silence_moment = false
	# Wind begins to crescendo
	_fatal_wind = 0.8


## The fatal sequence sets the wind directly (FatalAudioController)
func _on_fatal_wind_changed(intensity: float) -> void:
	if in_fatal_sequence:
		_fatal_wind = clampf(intensity, 0.0, 1.0)


## Enter aftermath phase - only wind, settling
func enter_aftermath() -> void:
	# Wind still present but calming
	_fatal_wind = 0.5

	# Snow settling where it happened, and nothing else
	var service := ServiceLocator.get_service("AudioService") as AudioService
	if service != null:
		service.play("snow_settle", -12.0, 1.0, AudioService.BUS_AMBIENT)


## Fade all ambient to silence
func fade_to_silence(duration: float) -> void:
	var tween := create_tween()
	tween.tween_property(self, "presence", 0.0, duration)


## Back to the weather as it is (the sequence is over, or a new run began)
func end_fatal_sequence() -> void:
	in_fatal_sequence = false
	_fatal_wind = -1.0


# =============================================================================
# SPECIAL SOUNDS
# =============================================================================

## Play ice cracking ambient
func play_ice_crack() -> void:
	var player := _get_player()
	if player != null:
		_play_far("ice_crack", player.global_position, AudioService.roll_range(25.0, 80.0), -6.0, 50.0)


## Play distant avalanche rumble
func play_distant_avalanche() -> void:
	var player := _get_player()
	if player != null:
		_play_far("avalanche_distant", player.global_position, AudioService.roll_range(250.0, 500.0), -3.0, 300.0)


# =============================================================================
# QUERIES
# =============================================================================

func get_wind_intensity() -> float:
	return wind_intensity


func is_in_silence_moment() -> bool:
	return in_silence_moment


## Gain (linear) a layer is at right now: "low", "mid_left", "howl_left", ...
func get_layer_gain(key: String) -> float:
	if not _layers.has(key):
		return 0.0
	var fader: AudioFader = _layers[key]
	return fader.gain


## The wind layers' gains added up: how much wind is being heard in all
func get_wind_gain() -> float:
	var total := 0.0
	for key in ["low", "mid_left", "mid_right", "high", "howl_left", "howl_right", "whistle", "spindrift"]:
		total += get_layer_gain(key)
	return total


func get_summary() -> Dictionary:
	return {
		"wind_intensity": wind_intensity,
		"wind_now": _wind_now,
		"weather_intensity": weather_intensity,
		"tension_level": tension_level,
		"presence": presence,
		"is_sliding": is_sliding,
		"in_silence": in_silence_moment,
		"terrain_zone": GameEnums.TerrainZone.keys()[current_terrain_zone]
	}
