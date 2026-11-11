class_name AudioService
extends Node
## Central audio coordinator for the game
## Owns the one-shot voices and the mix, and passes game events to the managers
##
## Design Philosophy:
## - Audio is diegetic first - sounds have in-world sources
## - Silence is intentional and meaningful
## - Breathing and wind are the primary soundscape
## - No music during gameplay - only environmental audio
##
## Who plays what:
##   AmbientAudioManager   wind layers, precipitation, the mountain in the distance
##   PlayerAudioManager    breath, heart, footsteps, the body sliding, skiing, landing
##   GearAudioManager      rope, anchors, axe, crampons, bindings, probe, shovel
##   HazardAudioManager    avalanches, burial, crevasses
##   UIAudioManager        menus, map, guidebook
## Any system can also play a sound by id: play("carabiner_clip") or
## play_at("ice_crack", position). Ids are file names in assets/audio
## (see SoundLibrary).

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
const BUS_AMBIENT_LEFT := "AmbientLeft"
const BUS_AMBIENT_RIGHT := "AmbientRight"
const BUS_PLAYER := "Player"
const BUS_EFFECTS := "Effects"
const BUS_UI := "UI"

## Where AudioInitializer puts each effect on its bus
const FX_AMBIENT_LOWPASS := 0
const FX_EFFECTS_LOWPASS := 0
const FX_EFFECTS_REVERB := 1
const FX_PLAYER_REVERB := 0

## One-shot voices
const POOL_2D := 16
const POOL_3D := 12

## The world through snow: cut-off of the low-pass when fully muffled (Hz)
const MUFFLE_OPEN_HZ := 20000.0
const MUFFLE_CLOSED_HZ := 320.0

## How much quieter the weather is at full risk focus, and deep in a crevasse (dB)
const RISK_DAMPEN_DB := 5.0
const CAVERN_AMBIENT_DB := 9.0

# =============================================================================
# STATE
# =============================================================================

## The sounds
var library: SoundLibrary

## Child audio managers
var ambient_manager: AmbientAudioManager
var player_audio: PlayerAudioManager
var ui_audio: UIAudioManager
var gear_audio: GearAudioManager
var hazard_audio: HazardAudioManager

## Is audio ducked
var is_ducked: bool = false

## Duck tween reference
var duck_tween: Tween

## Current game state
var current_game_state: GameEnums.GameState = GameEnums.GameState.NONE

static var _dice := RandomNumberGenerator.new()

var _pool_2d: Array[AudioStreamPlayer] = []
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _next_2d: int = 0
var _next_3d: int = 0

## Mix controls: where each is heading and where it is now
var _duck: float = 1.0
var _muffle_target: float = 0.0
var _muffle: float = 0.0
var _cavern_target: float = 0.0
var _cavern: float = 0.0
var _risk_dampen: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("AudioService", self)
	_create_voices()
	_connect_event_bus()
	print("[AudioService] Initialized")


func _create_voices() -> void:
	for i in range(POOL_2D):
		var voice := AudioStreamPlayer.new()
		voice.bus = BUS_EFFECTS
		add_child(voice)
		_pool_2d.append(voice)
	for i in range(POOL_3D):
		var voice := AudioStreamPlayer3D.new()
		voice.bus = BUS_EFFECTS
		add_child(voice)
		_pool_3d.append(voice)


func _connect_event_bus() -> void:
	EventBus.audio_restore_requested.connect(restore_audio)
	EventBus.audio_duck_requested.connect(duck_audio)
	# Game state
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.descent_ready.connect(_on_descent_ready)
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.summit_reached.connect(_on_summit_reached)

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
	ServiceLocator.get_service_async("RiskFeedback", _on_risk_feedback_ready)

	# Fatal events trigger dramatic audio changes
	EventBus.fatal_event_started.connect(_on_fatal_event_started)
	EventBus.fatal_phase_changed.connect(_on_fatal_phase_changed)
	EventBus.fatal_event_completed.connect(_on_fatal_event_completed)

	# The pause menu's own screens
	EventBus.self_check_started.connect(_on_self_check_started)


func _on_risk_feedback_ready(service: Object) -> void:
	var feedback := service as RiskFeedback
	if feedback != null and not feedback.audio_dampen_requested.is_connected(set_risk_dampen):
		feedback.audio_dampen_requested.connect(set_risk_dampen)


## Set ambient audio manager reference
func set_ambient_manager(manager: AmbientAudioManager) -> void:
	ambient_manager = manager


## Set player audio manager reference
func set_player_audio(manager: PlayerAudioManager) -> void:
	player_audio = manager


# =============================================================================
# ONE-SHOT SOUNDS
# =============================================================================

## Play a sound by id, not placed in the world (the climber's own sounds, or
## anything meant to be heard the same wherever the camera is).
## Returns the voice playing it, or null when there is no such sound.
func play(id: String, volume_db: float = 0.0, pitch: float = 1.0, bus: String = BUS_EFFECTS) -> AudioStreamPlayer:
	if not audio_enabled or library == null:
		return null
	var stream := library.get_stream(id)
	if stream == null:
		return null
	var voice := _free_voice_2d()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = maxf(pitch, 0.05)
	voice.bus = bus
	voice.play()
	return voice


## Play a sound by id at a place in the world. reach is the distance (m) at
## which it is heard at volume_db; it fades with distance beyond that.
func play_at(id: String, position: Vector3, volume_db: float = 0.0, pitch: float = 1.0,
		reach: float = 12.0, bus: String = BUS_EFFECTS) -> AudioStreamPlayer3D:
	if not audio_enabled or library == null:
		return null
	var stream := library.get_stream(id)
	if stream == null:
		return null
	var voice := _free_voice_3d()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = maxf(pitch, 0.05)
	voice.unit_size = reach
	voice.max_distance = 0.0
	voice.max_db = 0.0
	voice.bus = bus
	voice.global_position = position
	voice.play()
	return voice


## Play a sound a moment from now (a second click, the breath after the fall)
func play_later(delay: float, id: String, volume_db: float = 0.0, pitch: float = 1.0, bus: String = BUS_EFFECTS) -> void:
	if not is_inside_tree():
		return
	# A timer that stops with the game, so a paused sound does not arrive early
	get_tree().create_timer(maxf(delay, 0.01), false).timeout.connect(func() -> void:
		play(id, volume_db, pitch, bus))


## Pitch for a one-shot: a little different every time
static func vary(amount: float = 0.06) -> float:
	return 1.0 + _dice.randf_range(-amount, amount)


## Audio's own dice. Nothing that only changes what is heard may draw from
## the global generator: gameplay does, and a gust or a footstep's pitch must
## never change what the mountain does next (or what a seeded test sees).
static func roll() -> float:
	return _dice.randf()


static func roll_range(from: float, to: float) -> float:
	return _dice.randf_range(from, to)


## A whole number from 0 up to (not including) count
static func roll_index(count: int) -> int:
	return _dice.randi_range(0, maxi(count, 1) - 1)


func _free_voice_2d() -> AudioStreamPlayer:
	for i in range(_pool_2d.size()):
		var voice := _pool_2d[(_next_2d + i) % _pool_2d.size()]
		if not voice.playing:
			_next_2d = (_next_2d + i + 1) % _pool_2d.size()
			return voice
	# All busy: take the one that has been playing longest
	var oldest := _pool_2d[_next_2d]
	_next_2d = (_next_2d + 1) % _pool_2d.size()
	return oldest


func _free_voice_3d() -> AudioStreamPlayer3D:
	for i in range(_pool_3d.size()):
		var voice := _pool_3d[(_next_3d + i) % _pool_3d.size()]
		if not voice.playing:
			_next_3d = (_next_3d + i + 1) % _pool_3d.size()
			return voice
	var oldest := _pool_3d[_next_3d]
	_next_3d = (_next_3d + 1) % _pool_3d.size()
	return oldest


## Stop every one-shot (leaving a run)
func stop_one_shots() -> void:
	for voice in _pool_2d:
		voice.stop()
	for voice in _pool_3d:
		voice.stop()


## Play a stream that is not in the library
func play_effect(stream: AudioStream, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not audio_enabled or stream == null:
		return
	var voice := _free_voice_2d()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = maxf(pitch, 0.05)
	voice.bus = BUS_EFFECTS
	voice.play()


## Play a stream that is not in the library at a place in the world
func play_effect_3d(stream: AudioStream, position: Vector3, volume_db: float = 0.0) -> void:
	if not audio_enabled or stream == null:
		return
	var voice := _free_voice_3d()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = 1.0
	voice.unit_size = 12.0
	voice.bus = BUS_EFFECTS
	voice.global_position = position
	voice.play()


## Play a footstep sound (called from FootstepSystem). sound_id is a library id
func play_footstep(sound_id: String, volume_db: float, pitch: float, _position: Vector3) -> void:
	if not audio_enabled:
		return
	if player_audio != null:
		player_audio.play_footstep_sound(sound_id, volume_db, pitch)
	else:
		play(sound_id, volume_db, pitch, BUS_PLAYER)


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
	duck_tween.tween_method(_set_ducked_volume, _duck, ducked_volume, duck_transition_time)


## Restore audio after ducking
func restore_audio() -> void:
	if not is_ducked:
		return

	is_ducked = false
	audio_restored.emit()

	if duck_tween:
		duck_tween.kill()

	duck_tween = create_tween()
	duck_tween.tween_method(_set_ducked_volume, _duck, 1.0, duck_transition_time)


func _set_ducked_volume(volume: float) -> void:
	# Ducking applies to ambient and effects, not UI; _apply_mix does the work
	_duck = volume


# =============================================================================
# THE MIX
# =============================================================================

## Muffle the world (0 open .. 1 buried in snow): the weather and everything
## out there loses its highs; the climber's own breath and heart do not
func set_muffle(amount: float) -> void:
	_muffle_target = clampf(amount, 0.0, 1.0)


## Put the climber in a hollow of ice (0 open .. 1 deep in a crevasse): their
## own sounds ring, and the weather is somewhere far above
func set_cavern(amount: float) -> void:
	_cavern_target = clampf(amount, 0.0, 1.0)


## Attention narrowing on dangerous ground (0..1, from RiskFeedback): the
## weather recedes a little and the climber's own sounds come forward
func set_risk_dampen(amount: float) -> void:
	_risk_dampen = clampf(amount, 0.0, 1.0)


func _process(delta: float) -> void:
	_muffle = move_toward(_muffle, _muffle_target, delta * 1.6)
	_cavern = move_toward(_cavern, _cavern_target, delta * 1.2)
	_apply_mix()


func _apply_mix() -> void:
	var duck_db := linear_to_db(maxf(_duck, 0.0001))
	var ambient := AudioServer.get_bus_index(BUS_AMBIENT)
	var effects := AudioServer.get_bus_index(BUS_EFFECTS)
	var player_bus := AudioServer.get_bus_index(BUS_PLAYER)

	if ambient >= 0:
		AudioServer.set_bus_volume_db(ambient, duck_db - RISK_DAMPEN_DB * _risk_dampen - CAVERN_AMBIENT_DB * _cavern)
	if effects >= 0:
		AudioServer.set_bus_volume_db(effects, duck_db)

	# One low-pass on each of the two "world" buses
	var cutoff := MUFFLE_OPEN_HZ * pow(MUFFLE_CLOSED_HZ / MUFFLE_OPEN_HZ, pow(_muffle, 0.6))
	var muffled := _muffle > 0.01
	_set_lowpass(ambient, FX_AMBIENT_LOWPASS, muffled, cutoff)
	_set_lowpass(effects, FX_EFFECTS_LOWPASS, muffled, cutoff)

	# One reverb on the climber's own sounds and one on what they do
	var ringing := _cavern > 0.01
	_set_reverb(player_bus, FX_PLAYER_REVERB, ringing, 0.3 * _cavern)
	_set_reverb(effects, FX_EFFECTS_REVERB, ringing, 0.42 * _cavern)


func _set_lowpass(bus: int, slot: int, enabled: bool, cutoff: float) -> void:
	if bus < 0 or slot >= AudioServer.get_bus_effect_count(bus):
		return
	var filter := AudioServer.get_bus_effect(bus, slot) as AudioEffectLowPassFilter
	if filter == null:
		return
	if enabled:
		filter.cutoff_hz = cutoff
	if AudioServer.is_bus_effect_enabled(bus, slot) != enabled:
		AudioServer.set_bus_effect_enabled(bus, slot, enabled)


func _set_reverb(bus: int, slot: int, enabled: bool, wet: float) -> void:
	if bus < 0 or slot >= AudioServer.get_bus_effect_count(bus):
		return
	var reverb := AudioServer.get_bus_effect(bus, slot) as AudioEffectReverb
	if reverb == null:
		return
	if enabled:
		reverb.wet = wet
	if AudioServer.is_bus_effect_enabled(bus, slot) != enabled:
		AudioServer.set_bus_effect_enabled(bus, slot, enabled)


func get_muffle() -> float:
	return _muffle


func get_cavern() -> float:
	return _cavern


# =============================================================================
# GAME STATE HANDLERS
# =============================================================================

func _on_game_state_changed(old_state: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	current_game_state = new_state

	match new_state:
		GameEnums.GameState.MAIN_MENU:
			restore_audio()
			_enter_menu_audio()
		GameEnums.GameState.DESCENT:
			if old_state != GameEnums.GameState.PAUSED and old_state != GameEnums.GameState.MAP_CHECK:
				restore_audio()
			_enter_descent_audio()
		GameEnums.GameState.RESOLUTION:
			_enter_resolution_audio()
		GameEnums.GameState.MAP_CHECK:
			play_map_open()

	if old_state == GameEnums.GameState.MAP_CHECK:
		play_map_close()


func _on_descent_ready() -> void:
	# Start all ambient audio for descent
	if ambient_manager:
		ambient_manager.set_presence(1.0)
		ambient_manager.start_ambient()
	if player_audio:
		player_audio.enable()


func _enter_menu_audio() -> void:
	# Menus have a quiet wind and nothing else: no run, so no hazards, no body
	stop_one_shots()
	set_muffle(0.0)
	set_cavern(0.0)
	_risk_dampen = 0.0
	if ambient_manager:
		ambient_manager.end_fatal_sequence()
		ambient_manager.stop_all_environmental()
		ambient_manager.set_presence(0.5)
		ambient_manager.start_ambient()
	if player_audio:
		player_audio.disable()
	if hazard_audio:
		hazard_audio.reset()
	if gear_audio:
		gear_audio.reset()


func _enter_descent_audio() -> void:
	# Full audio during descent. Pausing stops the scene tree and every sound
	# with it, so there is nothing to restore on the way back from the pause menu
	if player_audio:
		player_audio.enable()


func _enter_resolution_audio() -> void:
	# Quiet, reflective audio
	duck_audio("resolution")
	set_muffle(0.0)
	set_cavern(0.0)
	_risk_dampen = 0.0
	if player_audio:
		player_audio.disable()
	if hazard_audio:
		hazard_audio.reset()
	if gear_audio:
		gear_audio.reset()


func _on_run_ended(_run: RunContext, outcome: GameEnums.ResolutionType) -> void:
	# Home: the pack comes off and the climber lets a long breath go
	if outcome == GameEnums.ResolutionType.CLEAN_RETURN or outcome == GameEnums.ResolutionType.INJURED_RETURN:
		play("pack_drop", -8.0, 1.0, BUS_UI)
		play_later(0.5, "reaction_relief", -10.0, 1.0, BUS_UI)


func _on_summit_reached(_run: RunContext) -> void:
	# No fanfare: a breath, and the wind
	play("reaction_relief", -12.0, 1.0, BUS_PLAYER)
	if ambient_manager:
		ambient_manager.trigger_gust(0.8)


func _on_self_check_started() -> void:
	if ui_audio:
		ui_audio.play_sound("watch_check")


# =============================================================================
# WEATHER EVENT HANDLERS
# =============================================================================

func _on_weather_changed(_old_weather: GameEnums.WeatherState, new_weather: GameEnums.WeatherState) -> void:
	if ambient_manager == null:
		return
	ambient_manager.set_weather_intensity(weather_intensity_for(new_weather))


func _on_wind_changed(strength: GameEnums.WindStrength, _direction: Vector3) -> void:
	if ambient_manager == null:
		return
	ambient_manager.set_wind_intensity(wind_intensity_for(strength))


## How much the wind is heard (0-1) at each wind strength
static func wind_intensity_for(strength: GameEnums.WindStrength) -> float:
	match strength:
		GameEnums.WindStrength.CALM:
			return 0.1
		GameEnums.WindStrength.LIGHT:
			return 0.3
		GameEnums.WindStrength.MODERATE:
			return 0.5
		GameEnums.WindStrength.STRONG:
			return 0.75
		GameEnums.WindStrength.GALE:
			return 0.88
		GameEnums.WindStrength.SEVERE:
			return 1.0
	return 0.3


## How stormy the air sounds (0-1) in each kind of weather
static func weather_intensity_for(weather: GameEnums.WeatherState) -> float:
	match weather:
		GameEnums.WeatherState.CLEAR:
			return 0.0
		GameEnums.WeatherState.PARTLY_CLOUDY:
			return 0.1
		GameEnums.WeatherState.CLEARING:
			return 0.15
		GameEnums.WeatherState.CLOUDY:
			return 0.2
		GameEnums.WeatherState.OVERCAST:
			return 0.3
		GameEnums.WeatherState.SNOW:
			return 0.4
		GameEnums.WeatherState.DETERIORATING:
			return 0.5
		GameEnums.WeatherState.STORM:
			return 0.8
		GameEnums.WeatherState.WHITEOUT:
			return 1.0
	return 0.0


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
	# Begin fatal event audio sequence: no impact, no cry, nothing dramatic
	duck_audio("fatal_event")
	stop_one_shots()

	if ambient_manager:
		ambient_manager.start_fatal_sequence()
	if player_audio:
		player_audio.start_fatal_sequence()
	if hazard_audio:
		hazard_audio.reset()
	if gear_audio:
		gear_audio.reset()


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


func _on_fatal_event_completed() -> void:
	set_muffle(0.0)
	set_cavern(0.0)


# =============================================================================
# UI & GEAR AUDIO
# =============================================================================

## Play a UI sound
func play_ui_sound(sound_name: String) -> void:
	if ui_audio:
		ui_audio.play_sound(sound_name)


## Play menu select sound
func play_menu_select() -> void:
	if ui_audio:
		ui_audio.play_menu_select()


## Play menu confirm sound
func play_menu_confirm() -> void:
	if ui_audio:
		ui_audio.play_menu_confirm()


## Play map open sound
func play_map_open() -> void:
	if ui_audio:
		ui_audio.play_map_open()


## Play map close sound
func play_map_close() -> void:
	if ui_audio:
		ui_audio.play_map_close()


## Play gear sound at position
func play_gear_sound(sound_name: String, position: Vector3) -> void:
	if gear_audio:
		gear_audio.play_sound_3d(sound_name, position)


## Play rope deployment
func play_rope_deploy(position: Vector3) -> void:
	if gear_audio:
		gear_audio.play_rope_deploy(position)


## Play ice axe self-arrest
func play_self_arrest(position: Vector3) -> void:
	if gear_audio:
		gear_audio.play_self_arrest(position)


# =============================================================================
# QUERIES
# =============================================================================

func is_audio_enabled() -> bool:
	return audio_enabled


func get_master_volume() -> float:
	return master_volume


## How many one-shot voices are sounding right now
func get_active_voice_count() -> int:
	var count := 0
	for voice in _pool_2d:
		if voice.playing:
			count += 1
	for voice in _pool_3d:
		if voice.playing:
			count += 1
	return count


func get_summary() -> Dictionary:
	return {
		"enabled": audio_enabled,
		"master_volume": master_volume,
		"is_ducked": is_ducked,
		"muffle": _muffle,
		"cavern": _cavern,
		"voices": get_active_voice_count(),
		"game_state": GameEnums.GameState.keys()[current_game_state]
	}
