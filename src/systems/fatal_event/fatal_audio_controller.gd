class_name FatalAudioController
extends Node
## Controls audio behavior during fatal events
## Implements ethical audio handling
##
## Design Philosophy:
## - Wind overtakes all other sound
## - No dramatic stings or horror audio
## - Silence and absence, not spectacle
## - After vanish: pure wind, settling

# =============================================================================
# SIGNALS
# =============================================================================

signal audio_transition_started(phase: GameEnums.FatalPhase)
signal audio_transition_complete(phase: GameEnums.FatalPhase)
signal wind_takeover_complete()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Volume Targets")
## Final wind volume during fatal
@export var wind_final_volume: float = 1.0
## Motor fade target during vanishing
@export var motor_fade_volume: float = 0.1
## Breathing fade during vanishing
@export var breathing_fade_volume: float = 0.0

@export_group("Transition Timing")
## Wind rise duration
@export var wind_rise_duration: float = 2.0
## Wind takeover duration
@export var wind_takeover_duration: float = 1.5
## Aftermath silence duration
@export var aftermath_silence_duration: float = 4.0
## Final fade duration
@export var final_fade_duration: float = 3.0

@export_group("Ethical Audio")
## Replace all audio with wind only
@export var wind_only_mode: bool = false
## Suppress impact sounds
@export var suppress_impact: bool = true
## Suppress screams/distress
@export var suppress_distress: bool = true

# =============================================================================
# STATE
# =============================================================================

## Current phase
var current_phase: GameEnums.FatalPhase = GameEnums.FatalPhase.NONE

## Is in fatal audio mode
var is_active: bool = false

## Audio service reference
var audio_service: AudioService

## Active tweens
var active_tweens: Array[Tween] = []


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("FatalAudioController", self)
	ServiceLocator.get_service_async("AudioService", func(s): audio_service = s)

	_connect_events()
	print("[FatalAudioController] Initialized")


func _connect_events() -> void:
	EventBus.fatal_event_started.connect(_on_fatal_event_started)
	EventBus.fatal_phase_changed.connect(_on_fatal_phase_changed)
	EventBus.fatal_event_completed.connect(_on_fatal_event_completed)


# =============================================================================
# PHASE AUDIO
# =============================================================================

func _on_fatal_event_started(phase: GameEnums.FatalPhase) -> void:
	is_active = true
	current_phase = phase

	# Immediately suppress prohibited audio
	_suppress_prohibited_audio()


func _on_fatal_phase_changed(old_phase: GameEnums.FatalPhase, new_phase: GameEnums.FatalPhase) -> void:
	current_phase = new_phase
	audio_transition_started.emit(new_phase)

	# Cancel existing transitions
	_cancel_active_tweens()

	match new_phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			_transition_moment_of_error()
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			_transition_loss_of_control()
		GameEnums.FatalPhase.VANISHING:
			_transition_vanishing()
		GameEnums.FatalPhase.AFTERMATH:
			_transition_aftermath()
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			_transition_acknowledgment()


func _on_fatal_event_completed() -> void:
	is_active = false
	current_phase = GameEnums.FatalPhase.NONE
	_cancel_active_tweens()
	_restore_audio()


# =============================================================================
# PHASE TRANSITIONS
# =============================================================================

func _transition_moment_of_error() -> void:
	## Subtle audio compression - hint of wrongness

	# Slight compression
	EventBus.audio_duck_requested.emit("fatal_moment")

	# Continue ambient sounds, just compressed
	audio_transition_complete.emit(GameEnums.FatalPhase.MOMENT_OF_ERROR)


func _transition_loss_of_control() -> void:
	## Wind begins to dominate, motor starts to fade

	var tween := create_tween()
	active_tweens.append(tween)

	# Wind rises
	tween.tween_method(_set_wind_intensity, 0.5, 0.8, wind_rise_duration)

	# Motor starts fading
	tween.parallel().tween_method(_set_motor_volume, 1.0, 0.5, wind_rise_duration)

	tween.tween_callback(func():
		audio_transition_complete.emit(GameEnums.FatalPhase.LOSS_OF_CONTROL)
	)


func _transition_vanishing() -> void:
	## Wind overtakes everything - the key moment

	var tween := create_tween()
	active_tweens.append(tween)

	# Wind takes over completely
	tween.tween_method(_set_wind_intensity, 0.8, wind_final_volume, wind_takeover_duration)

	# Motor fades to whisper
	tween.parallel().tween_method(_set_motor_volume, 0.5, motor_fade_volume, wind_takeover_duration)

	# Breathing disappears (subject audio)
	tween.parallel().tween_method(_set_breathing_intensity, 1.0, breathing_fade_volume, wind_takeover_duration)

	# Player audio fades
	tween.parallel().tween_method(_set_player_audio, 1.0, 0.0, wind_takeover_duration)

	tween.tween_callback(func():
		wind_takeover_complete.emit()
		audio_transition_complete.emit(GameEnums.FatalPhase.VANISHING)
	)


func _transition_aftermath() -> void:
	## Pure wind, settling snow - THE silence

	# Emit silence moment
	EventBus.silence_moment.emit(true)

	# Wind continues but at contemplative level
	_set_wind_intensity(wind_final_volume * 0.8)

	# Motor essentially silent
	_set_motor_volume(0.05)

	# No breathing, no player audio
	_set_breathing_intensity(0.0)
	_set_player_audio(0.0)

	# Hold this state
	var tween := create_tween()
	active_tweens.append(tween)

	tween.tween_interval(aftermath_silence_duration)
	tween.tween_callback(func():
		audio_transition_complete.emit(GameEnums.FatalPhase.AFTERMATH)
	)


func _transition_acknowledgment() -> void:
	## Gentle fade, preparing for what comes next

	# End active silence
	EventBus.silence_moment.emit(false)

	var tween := create_tween()
	active_tweens.append(tween)

	# Gentle wind fade
	tween.tween_method(_set_wind_intensity, wind_final_volume * 0.8, 0.6, final_fade_duration)

	tween.tween_callback(func():
		audio_transition_complete.emit(GameEnums.FatalPhase.ACKNOWLEDGMENT)
	)


# =============================================================================
# AUDIO CONTROL METHODS
# =============================================================================

func _set_wind_intensity(intensity: float) -> void:
	EventBus.wind_audio_changed.emit(intensity)


func _set_motor_volume(volume: float) -> void:
	# Would control drone motor audio
	# For now, use audio service if available
	pass


func _set_breathing_intensity(intensity: float) -> void:
	EventBus.breathing_changed.emit(intensity)


func _set_player_audio(volume: float) -> void:
	# Controls all player-associated audio (footsteps, gear, breathing)
	pass


# =============================================================================
# PROHIBITED AUDIO
# =============================================================================

func _suppress_prohibited_audio() -> void:
	## Ensure prohibited sounds never play during fatal events

	# These would connect to actual audio system
	# Suppress:
	# - Impact SFX
	# - Scream/distress SFX
	# - Dramatic music
	# - Horror stings
	# - Death jingles

	if wind_only_mode:
		_force_wind_only()


func _force_wind_only() -> void:
	## Complete wind-only mode for streaming

	_set_wind_intensity(wind_final_volume)
	_set_motor_volume(0.0)
	_set_breathing_intensity(0.0)
	_set_player_audio(0.0)


# =============================================================================
# UTILITY
# =============================================================================

func _cancel_active_tweens() -> void:
	for tween in active_tweens:
		if tween and tween.is_valid():
			tween.kill()
	active_tweens.clear()


func _restore_audio() -> void:
	## Restore normal audio state after fatal sequence

	EventBus.audio_restore_requested.emit()
	EventBus.silence_moment.emit(false)


# =============================================================================
# QUERIES
# =============================================================================

func is_in_fatal_audio() -> bool:
	return is_active


func get_current_phase() -> GameEnums.FatalPhase:
	return current_phase


func get_summary() -> Dictionary:
	return {
		"is_active": is_active,
		"current_phase": GameEnums.FatalPhase.keys()[current_phase],
		"wind_only_mode": wind_only_mode,
		"active_tweens": active_tweens.size()
	}
