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
##
## Breath is played one inhale and one exhale at a time, so its pace and depth
## follow the climber continuously instead of switching between loops. The
## heart is only heard when things are going badly. Sliding, skiing and
## falling are looping textures whose level and pitch follow the speed.

# =============================================================================
# SIGNALS
# =============================================================================

signal breathing_intensity_changed(intensity: float)
signal footstep_played(surface: GameEnums.SurfaceType)
signal gear_sound_played(gear_type: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Volume Settings")
## Breathing volume when calm and when gasping (dB)
@export var breathing_quiet_volume: float = -26.0
@export var breathing_loud_volume: float = -9.0
## Gear sound volume
@export var gear_volume: float = -20.0

## Seconds for one breath when calm and when at the limit
const BREATH_SLOW := 4.4
const BREATH_FAST := 1.15

## Breathing intensity above which the hard and the gasping breaths are used
const HARD_BREATH_FROM := 0.35
const GASP_BREATH_FROM := 0.75

## Heart rate (beats per minute) at the edge of hearing and at full fright
const HEART_SLOW := 84.0
const HEART_FAST := 156.0
## Tension below which the heart is not heard
const HEART_FROM := 0.4

## Speed (m/s) at which the air starts to be heard and at which it roars
const AIR_RUSH_FROM := 4.0
const AIR_RUSH_FULL := 24.0

## Landings softer than this (cushioned m/s) make no sound of their own
const LANDING_QUIET := 1.5

## Seconds between two cries of pain, rustles of cloth, shivers
const PAIN_GAP := 1.5
const RUSTLE_GAP := 1.5

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

## Is sliding
var is_sliding: bool = false

## Current slide control level
var slide_control: GameEnums.SlideControlLevel = GameEnums.SlideControlLevel.CONTROLLED

## In fatal sequence
var in_fatal_sequence: bool = false

## How hard the heart is going (0-1): set by whatever frightens (a slide out
## of control, a burial); it settles by itself
var tension: float = 0.0

var _library: SoundLibrary
var _service: AudioService
var _player: PlayerController
var _slides: SlideSystem

## Voices for breath (inhale and exhale overlap a little) and footsteps
var _breath_voices: Array[AudioStreamPlayer] = []
var _step_voices: Array[AudioStreamPlayer] = []
var _heart_voice: AudioStreamPlayer
var _next_breath_voice: int = 0
var _next_step_voice: int = 0

## Looping textures: name -> AudioFader
var _loops: Dictionary = {}

## Breath cycle: seconds into the current breath, and its length
var _breath_time: float = 0.0
var _breath_length: float = BREATH_SLOW
var _exhaled: bool = true
## A fright makes the next breaths quick whatever the fatigue; it wears off
var _fright: float = 0.0
## Tension asked for from outside (HazardAudioManager while buried), and by
## the slide's own feedback while it lasts
var _tension_floor: float = 0.0
var _slide_tension: float = 0.0

var _heart_time: float = 0.0
var _slide_speed: float = 0.0
var _slide_surface: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
var _next_bump: float = 1.0
var _was_braking: bool = false
var _pain_cooldown: float = 0.0
var _rustle_cooldown: float = 0.0
var _next_shiver: float = 15.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_library = ServiceLocator.get_service("SoundLibrary") as SoundLibrary
	_create_audio_players()
	ServiceLocator.register_service("PlayerAudioManager", self)

	# Register with audio service
	ServiceLocator.get_service_async("AudioService", func(service):
		if service:
			_service = service as AudioService
			service.set_player_audio(self)
	)
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)
	ServiceLocator.get_service_async("SlideSystem", _on_slide_system_ready)

	EventBus.slide_state_updated.connect(_on_slide_state_updated)
	EventBus.incident_recorded.connect(_on_incident)
	EventBus.breathing_changed.connect(_on_breathing_forced)

	print("[PlayerAudioManager] Initialized")


func _create_audio_players() -> void:
	for i in range(3):
		var voice := AudioStreamPlayer.new()
		voice.bus = AudioService.BUS_PLAYER
		add_child(voice)
		_breath_voices.append(voice)
	for i in range(4):
		var voice := AudioStreamPlayer.new()
		voice.bus = AudioService.BUS_PLAYER
		add_child(voice)
		_step_voices.append(voice)
	_heart_voice = AudioStreamPlayer.new()
	_heart_voice.bus = AudioService.BUS_PLAYER
	add_child(_heart_voice)

	_add_loop("slide_snow", "slide_snow_loop", -2.0)
	_add_loop("slide_ice", "slide_ice_loop", -3.0)
	_add_loop("slide_scree", "slide_scree_loop", -3.0)
	_add_loop("ski_glide", "ski_glide_loop", -12.0)
	_add_loop("ski_carve", "ski_carve_loop", -8.0)
	_add_loop("ski_rock", "ski_rock_loop", -6.0)
	_add_loop("air_rush", "air_rush_loop", -5.0)


func _add_loop(key: String, sound_id: String, trim_db: float) -> void:
	var player := AudioStreamPlayer.new()
	player.name = "Loop_" + key
	player.bus = AudioService.BUS_PLAYER
	if _library != null and _library.has_sound(sound_id):
		player.stream = _library.get_stream(sound_id)
	add_child(player)
	_loops[key] = AudioFader.new(player, trim_db, 0.25, 0.5)


func _on_player_ready(service: Object) -> void:
	_player = service as PlayerController
	if _player != null and not _player.landed.is_connected(_on_landed):
		_player.landed.connect(_on_landed)


func _on_slide_system_ready(service: Object) -> void:
	_slides = service as SlideSystem
	if _slides != null and _slides.feedback != null:
		if not _slides.feedback.audio_event_requested.is_connected(_on_slide_feedback):
			_slides.feedback.audio_event_requested.connect(_on_slide_feedback)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_pain_cooldown = maxf(0.0, _pain_cooldown - delta)
	_rustle_cooldown = maxf(0.0, _rustle_cooldown - delta)
	if not is_enabled or is_paused:
		_update_loops(delta, false)
		return

	_update_body_state()
	_update_breathing(delta)
	_update_heart(delta)
	_update_loops(delta, true)
	_update_cold(delta)


## Fatigue and the surface come straight from the run, every frame
func _update_body_state() -> void:
	var run := GameStateManager.get_current_run()
	if run != null and run.body_state != null:
		fatigue_level = clampf(run.body_state.fatigue, 0.0, 1.0)
	if _player != null and is_instance_valid(_player) and _player.current_cell != null:
		current_surface = _player.current_cell.surface_type


func _update_breathing(delta: float) -> void:
	# Calculate target breathing intensity
	var target_intensity := fatigue_level * 0.75

	# Work: moving costs breath, steep ground and skis more
	match movement_state:
		GameEnums.PlayerMovementState.WALKING, GameEnums.PlayerMovementState.TRAVERSING:
			target_intensity += 0.08
		GameEnums.PlayerMovementState.DOWNCLIMBING:
			target_intensity += 0.15
		GameEnums.PlayerMovementState.SKIING:
			target_intensity += 0.12
		GameEnums.PlayerMovementState.ROPING:
			target_intensity += 0.1
		GameEnums.PlayerMovementState.CAUGHT, GameEnums.PlayerMovementState.FALLING:
			target_intensity = maxf(target_intensity, 0.9)

	# Thin air: every breath buys less the higher you are
	var run := GameStateManager.get_current_run()
	if run != null:
		target_intensity += 0.12 * clampf((run.current_elevation - 3500.0) / 3500.0, 0.0, 1.0)

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

	# A fright is breathed off over a few seconds
	_fright = maxf(0.0, _fright - delta / 6.0)
	target_intensity = clampf(maxf(target_intensity, _fright), 0.0, 1.0)

	# Smooth transition
	breathing_intensity = lerpf(breathing_intensity, target_intensity, 2.0 * delta)
	breathing_intensity_changed.emit(breathing_intensity)

	# One breath after another: in, out, and a rest that shortens with effort
	_breath_time += delta
	if _breath_time >= _breath_length:
		_breath_time = 0.0
		_exhaled = false
		_breath_length = lerpf(BREATH_SLOW, BREATH_FAST, pow(breathing_intensity, 0.85)) * AudioService.roll_range(0.93, 1.08)
		_play_breath("in", _breath_length * 0.4)
	elif not _exhaled and _breath_time >= _breath_length * 0.42:
		_exhaled = true
		_play_breath("out", _breath_length * 0.5)


## Which set of breaths the climber is on: "calm", "hard" or "gasp"
func get_breath_set() -> String:
	if breathing_intensity >= GASP_BREATH_FROM:
		return "gasp"
	if breathing_intensity >= HARD_BREATH_FROM:
		return "hard"
	return "calm"


func _play_breath(phase: String, wanted_length: float) -> void:
	if _library == null:
		return
	var stream := _library.get_stream("breath_%s_%s" % [get_breath_set(), phase])
	if stream == null:
		return
	var voice := _breath_voices[_next_breath_voice]
	_next_breath_voice = (_next_breath_voice + 1) % _breath_voices.size()
	voice.stream = stream
	# Stretch or squeeze the breath a little to fit the pace
	voice.pitch_scale = clampf(stream.get_length() / maxf(wanted_length, 0.1), 0.82, 1.3)
	var volume := lerpf(breathing_quiet_volume, breathing_loud_volume, breathing_intensity)
	# Risk amplifies breathing volume
	if risk_level > 0.6:
		volume += (risk_level - 0.6) * 10.0
	voice.volume_db = volume + AudioService.roll_range(-1.5, 1.0)
	voice.play()


func _update_heart(delta: float) -> void:
	# What frightens: losing a slide, a fall, whatever is set from outside
	var target := _tension_floor
	if is_sliding:
		target = maxf(target, _slide_tension)
		if slide_control == GameEnums.SlideControlLevel.UNSTABLE:
			target = maxf(target, 0.65)
		elif slide_control == GameEnums.SlideControlLevel.LOST:
			target = maxf(target, 1.0)
	if movement_state == GameEnums.PlayerMovementState.FALLING or movement_state == GameEnums.PlayerMovementState.CAUGHT:
		target = maxf(target, 0.9)
	if risk_level > 0.8:
		target = maxf(target, risk_level * 0.7)
	# Up at once, down slowly
	if target > tension:
		tension = lerpf(tension, target, 1.0 - exp(-delta / 0.4))
	else:
		tension = lerpf(tension, target, 1.0 - exp(-delta / 5.0))

	if tension < HEART_FROM:
		_heart_time = 0.0
		return
	var strength := inverse_lerp(HEART_FROM, 1.0, tension)
	_heart_time -= delta
	if _heart_time <= 0.0:
		_heart_time = 60.0 / lerpf(HEART_SLOW, HEART_FAST, strength)
		if _library == null or not _library.has_sound("heartbeat"):
			return
		_heart_voice.stream = _library.get_variant("heartbeat", 1 if strength > 0.6 else 0)
		_heart_voice.volume_db = lerpf(-24.0, -10.0, strength)
		_heart_voice.pitch_scale = 0.96 + 0.1 * strength
		_heart_voice.play()


## Sliding, skiing and the air at speed: levels and pitch follow the motion
func _update_loops(delta: float, active: bool) -> void:
	var speed := 0.0
	var skiing := false
	if active and _player != null and is_instance_valid(_player):
		speed = _player.smooth_velocity.length()
		skiing = movement_state == GameEnums.PlayerMovementState.SKIING

	# --- Body on the slope ---
	var snow := 0.0
	var ice := 0.0
	var scree := 0.0
	if active and is_sliding:
		var loss := float(slide_control) / 3.0
		var level := clampf(pow(clampf(_slide_speed / 12.0, 0.0, 1.0), 0.8), 0.15, 1.0) * (1.0 + 0.15 * loss)
		match _slide_surface:
			GameEnums.SurfaceType.ICE:
				ice = level
			GameEnums.SurfaceType.SCREE, GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET:
				scree = level
			_:
				snow = level
		var pitch := 0.9 + 0.02 * minf(_slide_speed, 20.0) + 0.1 * loss
		_set_loop("slide_snow", snow, pitch, delta)
		_set_loop("slide_ice", ice, pitch, delta)
		_set_loop("slide_scree", scree, pitch, delta)
		_update_slide_bumps(delta)
	else:
		_set_loop("slide_snow", 0.0, 1.0, delta)
		_set_loop("slide_ice", 0.0, 1.0, delta)
		_set_loop("slide_scree", 0.0, 1.0, delta)

	# --- Skis ---
	var glide := 0.0
	var carve := 0.0
	var grind := 0.0
	if skiing and _player.ski != null:
		var ski := _player.ski
		var run := clampf(ski.speed / 14.0, 0.0, 1.0)
		if TractionModel.is_snow(current_surface) or current_surface == GameEnums.SurfaceType.ICE:
			glide = pow(run, 0.7) * (1.0 - 0.5 * clampf(ski.skid, 0.0, 1.0))
			carve = clampf(ski.skid * 1.6 + maxf(ski.edge_load - 0.7, 0.0), 0.0, 1.0) * clampf(ski.speed / 8.0, 0.0, 1.0)
		else:
			grind = clampf(ski.speed / 5.0, 0.0, 1.0)
		# Throwing the skis sideways at speed sends up a wall of snow
		if ski.braking and not _was_braking and ski.speed > 5.0 and glide > 0.0:
			_play("ski_stop", lerpf(-12.0, -3.0, clampf(ski.speed / 15.0, 0.0, 1.0)))
		_was_braking = ski.braking
		_set_loop("ski_glide", glide, 0.8 + 0.025 * minf(ski.speed, 24.0), delta)
		_set_loop("ski_carve", carve, 0.85 + 0.015 * minf(ski.speed, 24.0), delta)
		_set_loop("ski_rock", grind, 0.9 + 0.03 * minf(ski.speed, 10.0), delta)
	else:
		_was_braking = false
		_set_loop("ski_glide", 0.0, 1.0, delta)
		_set_loop("ski_carve", 0.0, 1.0, delta)
		_set_loop("ski_rock", 0.0, 1.0, delta)

	# --- Air ---
	var rush := smoothstep(AIR_RUSH_FROM, AIR_RUSH_FULL, speed)
	_set_loop("air_rush", rush, 0.8 + 0.5 * rush, delta)


func _set_loop(key: String, level: float, pitch: float, delta: float) -> void:
	var fader: AudioFader = _loops[key]
	fader.level = level
	fader.pitch = pitch
	fader.update(delta)


## Lumps in the slope, felt more often the faster the slide
func _update_slide_bumps(delta: float) -> void:
	if _slide_surface == GameEnums.SurfaceType.ICE or _slide_speed < 3.0:
		return
	_next_bump -= delta * clampf(_slide_speed / 8.0, 0.4, 2.0)
	if _next_bump <= 0.0:
		_next_bump = AudioService.roll_range(0.6, 1.8)
		_play("slide_bump", lerpf(-18.0, -8.0, clampf(_slide_speed / 14.0, 0.0, 1.0)), AudioService.vary(0.1))


## A climber who is getting cold shivers
func _update_cold(delta: float) -> void:
	var run := GameStateManager.get_current_run()
	if run == null or run.body_state == null or run.body_state.cold_exposure < 0.6:
		return
	_next_shiver -= delta
	if _next_shiver <= 0.0:
		_next_shiver = AudioService.roll_range(10.0, 24.0) * lerpf(1.0, 0.5, inverse_lerp(0.6, 1.0, run.body_state.cold_exposure))
		_play("reaction_shiver", -14.0, AudioService.vary(0.05))


# =============================================================================
# PLAYING
# =============================================================================

func _play(id: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if _service != null and is_enabled:
		_service.play(id, volume_db, pitch, AudioService.BUS_PLAYER)


## Play a footstep (called through AudioService by FootstepSystem). sound_id
## is a library id such as "footstep_snow_firm" or "crampon_ice"
func play_footstep_sound(sound_id: String, volume_db: float, pitch: float) -> void:
	if not is_enabled or is_paused or _library == null:
		return
	var stream := _library.get_stream(sound_id)
	if stream == null:
		return
	var voice := _step_voices[_next_step_voice]
	_next_step_voice = (_next_step_voice + 1) % _step_voices.size()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = maxf(pitch, 0.05)
	voice.play()
	footstep_played.emit(current_surface)


## The id of the sound a foot (or a body) makes skidding on this surface
static func slip_sound_for(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "slip_ice"
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, \
		GameEnums.SurfaceType.SCREE, GameEnums.SurfaceType.MIXED:
			return "slip_rock"
	return "slip_snow"


## The id of the sound a body makes landing on this surface
static func impact_sound_for(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "impact_ice"
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, \
		GameEnums.SurfaceType.SCREE, GameEnums.SurfaceType.MIXED:
			return "impact_rock"
	return "impact_snow"


# =============================================================================
# PUBLIC CONTROL
# =============================================================================

## Enable player audio
func enable() -> void:
	if is_enabled and not is_paused:
		return
	is_enabled = true
	is_paused = false
	in_fatal_sequence = false
	tension = 0.0
	_tension_floor = 0.0
	_fright = 0.0
	# The first breath comes after a moment, not on the first frame
	_breath_time = 0.0
	_breath_length = 1.2
	_exhaled = true


## Disable player audio
func disable() -> void:
	is_enabled = false
	is_sliding = false
	tension = 0.0
	_tension_floor = 0.0
	_stop_voices()


## Pause audio (keeps state)
func pause_audio() -> void:
	is_paused = true


## Resume audio
func resume_audio() -> void:
	is_paused = false


func _stop_voices() -> void:
	for voice in _breath_voices:
		voice.stop()
	for voice in _step_voices:
		voice.stop()
	_heart_voice.stop()
	for key in _loops.keys():
		var fader: AudioFader = _loops[key]
		fader.cut()


## Set movement state
func set_movement_state(state: GameEnums.PlayerMovementState) -> void:
	var old_state := movement_state
	movement_state = state
	if old_state == state or not is_enabled:
		return

	# Cloth moves when the body changes what it is doing, not on every step
	var still := [GameEnums.PlayerMovementState.STANDING, GameEnums.PlayerMovementState.WALKING]
	if not (old_state in still and state in still) and _rustle_cooldown <= 0.0:
		_rustle_cooldown = RUSTLE_GAP
		_play("cloth_rustle", gear_volume, AudioService.vary(0.08))
		gear_sound_played.emit("cloth")

	if state == GameEnums.PlayerMovementState.FALLING:
		startle(1.0)


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


## Keep the heart at least this hard at work (0-1) until told otherwise
func set_tension(level: float) -> void:
	_tension_floor = clampf(level, 0.0, 1.0)


## A fright: a snatched breath now and quick breathing for a while (0-1)
func startle(amount: float = 0.7) -> void:
	if not is_enabled:
		return
	_fright = maxf(_fright, clampf(amount, 0.0, 1.0))
	_play("breath_gasp_in", lerpf(-16.0, -8.0, amount), AudioService.vary(0.06))
	# The gasp is the breath in: the next thing is the breath out
	_breath_time = 0.0
	_breath_length = 0.9
	_exhaled = false


## Trigger breathing change audio cue
func trigger_breathing_change() -> void:
	# The breath catches as the work starts to tell
	startle(0.35)


## Trigger critical fatigue audio
func trigger_critical_fatigue() -> void:
	# Nothing left: every breath is a gasp from here (the breathing does the rest)
	startle(0.9)


## Play micro-slip reaction
func play_micro_slip(severity: float) -> void:
	if not is_enabled:
		return
	_play(slip_sound_for(current_surface), lerpf(-16.0, -6.0, clampf(severity, 0.0, 1.0)), AudioService.vary(0.1))
	if severity > 0.35:
		startle(clampf(severity, 0.0, 1.0) * 0.8)


## Play risk cue (entering danger zone)
func play_risk_cue(severity: float) -> void:
	# Sharp intake of breath
	startle(clampf(severity, 0.0, 1.0) * 0.6)


## Pain: a hiss through the teeth (never a cry)
func play_pain(severity: float = 0.5) -> void:
	if not is_enabled or _pain_cooldown > 0.0:
		return
	_pain_cooldown = PAIN_GAP
	_play("reaction_pain", lerpf(-12.0, -4.0, clampf(severity, 0.0, 1.0)), AudioService.vary(0.06))


## The breath driven out by a hard pull or a heave
func play_effort() -> void:
	if is_enabled:
		_play("reaction_effort", -10.0, AudioService.vary(0.08))


## The long breath out when something held
func play_relief() -> void:
	if is_enabled:
		_play("reaction_relief", -9.0, AudioService.vary(0.05))


# =============================================================================
# SLIDE AUDIO
# =============================================================================

## Start slide audio
func start_slide_audio(entry_speed: float, slope_angle: float) -> void:
	is_sliding = true
	_slide_tension = 0.0
	_slide_speed = entry_speed
	_slide_surface = current_surface
	_next_bump = AudioService.roll_range(0.5, 1.2)

	# Sitting down and letting go: cloth, the snow starting to move, a breath in
	_play("slide_start", -8.0, AudioService.vary(0.06))
	startle(0.45)


func _on_slide_state_updated(_control: float, speed: float, _trajectory: Vector3) -> void:
	_slide_speed = speed
	if _slides != null and is_instance_valid(_slides) and _slides.current_state != null:
		_slide_surface = _slides.current_state.surface_type


## Stop slide audio
func stop_slide_audio(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	is_sliding = false
	if not is_enabled:
		return

	# Play outcome sound
	match outcome:
		GameEnums.SlideOutcome.CLEAN_STOP:
			# Stopped: the snow packs under the body and the breath comes back
			_play("arrest_stop", -8.0, AudioService.vary(0.05))
			if _service != null:
				_service.play_later(0.5, "reaction_relief", -9.0, 1.0, AudioService.BUS_PLAYER)

		GameEnums.SlideOutcome.TUMBLE_STOP:
			_play("tumble", -6.0, AudioService.vary(0.05))
			if _service != null:
				_service.play_later(0.6, "reaction_pain", -7.0, 1.0, AudioService.BUS_PLAYER)

		GameEnums.SlideOutcome.TERRAIN_CATCH:
			# Abrupt stop: harder the faster it was
			_play(impact_sound_for(_slide_surface), clampf(-14.0 + final_speed * 0.8, -14.0, -5.0), AudioService.vary(0.06))

		# A slide that runs out over the edge ends in the fatal sequence: wind,
		# and nothing of the climber (see FatalAudioController)


## Set slide control level
func set_slide_control(control: GameEnums.SlideControlLevel) -> void:
	slide_control = control


## What SlideFeedback asks for. The spec wants no warning tones: the heart and
## the breath carry it, so "warning" and "heartbeat" both become tension
func _on_slide_feedback(event: SlideFeedback.AudioEvent) -> void:
	match event.type:
		"heartbeat":
			_slide_tension = clampf(event.intensity, 0.0, 1.0)
		"warning":
			if event.intensity > 0.0 and is_sliding:
				tension = maxf(tension, clampf(event.intensity, 0.0, 1.0))
				if event.data.get("warning_type", "") == "point_of_no_return":
					startle(0.8)
		"opportunity":
			# A place to stop coming up: nothing is said. Terrain cues only
			pass


# =============================================================================
# THE BODY MEETING THINGS
# =============================================================================

## Touched down after being in the air (signal from PlayerController)
func _on_landed(impact: float) -> void:
	if not is_enabled or in_fatal_sequence or impact < LANDING_QUIET:
		return
	var hard := clampf((impact - LANDING_QUIET) / 9.0, 0.0, 1.0)
	var volume := lerpf(-18.0, -4.0, hard)
	if movement_state == GameEnums.PlayerMovementState.SKIING:
		_play("ski_land", volume, AudioService.vary(0.06))
	else:
		_play(impact_sound_for(current_surface), volume, AudioService.vary(0.08))
	if impact >= PlayerController.LANDING_HARD:
		_play("reaction_effort", -9.0, AudioService.vary(0.08))


func _on_incident(incident_type: String, context: Dictionary) -> void:
	if not is_enabled or in_fatal_sequence:
		return
	match incident_type:
		"obstacle_impact":
			var speed: float = context.get("speed", 4.0)
			var kind: String = context.get("object", "")
			var volume := clampf(-14.0 + speed, -14.0, -4.0)
			_play("impact_tree" if kind == "tree" else "impact_rock", volume, AudioService.vary(0.06))
		"injury", "fall_injury":
			var severity: float = context.get("severity", 0.4)
			play_pain(severity)
		"slide_impact":
			var speed: float = context.get("speed", 5.0)
			_play("impact_rock", clampf(-16.0 + speed, -16.0, -5.0), AudioService.vary(0.08))
		"slide_upset":
			_play("slide_bump", -7.0, AudioService.vary(0.1))
			startle(0.7)
		"fall_from_slip", "fall_over", "slide_from_slip":
			_play(slip_sound_for(current_surface), -6.0, AudioService.vary(0.08))
			startle(0.8)
		"ski_crash":
			_play("ski_crash", -6.0, AudioService.vary(0.05))
			startle(0.7)
		"skis_broken":
			_play("binding_release", -4.0, 0.8)
			_play("impact_rock", -8.0, 1.2)
		"collapse":
			# Legs gone: the body folds into the snow
			_play("impact_snow", -8.0, 0.9)
			if _service != null:
				_service.play_later(0.4, "reaction_relief", -9.0, 0.9, AudioService.BUS_PLAYER)
		"crevasse_slip":
			_play("slip_ice", -5.0, AudioService.vary(0.06))
			startle(0.7)


# =============================================================================
# FATAL EVENT AUDIO
# =============================================================================

## Start fatal event audio sequence
func start_fatal_sequence() -> void:
	in_fatal_sequence = true
	# Breathing becomes desperate
	breathing_intensity = 1.0


## The fatal sequence takes the breath away (FatalAudioController)
func _on_breathing_forced(intensity: float) -> void:
	if in_fatal_sequence and intensity <= 0.0:
		silence()


## Cut player audio abruptly (loss of control phase)
func cut_player_audio() -> void:
	# Abrupt cut, not fade
	_stop_voices()
	is_enabled = false


## Complete silence
func silence() -> void:
	_stop_voices()
	is_enabled = false


# =============================================================================
# ROPE AUDIO
# =============================================================================

## Play rope handling sound
func play_rope_handling() -> void:
	_play("rope_thread", gear_volume, AudioService.vary(0.05))
	gear_sound_played.emit("rope")


## Play ice axe placement
func play_ice_axe() -> void:
	_play("axe_plant", gear_volume + 3.0, AudioService.vary(0.1))
	gear_sound_played.emit("ice_axe")


# =============================================================================
# QUERIES
# =============================================================================

func get_breathing_intensity() -> float:
	return breathing_intensity


func is_audio_enabled() -> bool:
	return is_enabled


## Gain (linear) a looping texture is at: "slide_snow", "ski_glide", "air_rush", ...
func get_loop_gain(key: String) -> float:
	if not _loops.has(key):
		return 0.0
	var fader: AudioFader = _loops[key]
	return fader.gain


func get_summary() -> Dictionary:
	return {
		"enabled": is_enabled,
		"breathing_intensity": breathing_intensity,
		"breath_set": get_breath_set(),
		"tension": tension,
		"fatigue_level": fatigue_level,
		"risk_level": risk_level,
		"is_sliding": is_sliding,
		"surface": GameEnums.SurfaceType.keys()[current_surface],
		"movement": GameEnums.PlayerMovementState.keys()[movement_state]
	}
