class_name EthicalConstraints
extends Node
## Enforces ethical constraints during fatal events
## "Witness without harm"
##
## Core Principles:
## 1. Forewarning without spoilers
## 2. Player choice, not platform enforcement
## 3. Respectful abstraction over explicit depiction
## 4. Consistency—never tone-police only sometimes
## 5. Silence and distance instead of dramatization

# =============================================================================
# SIGNALS
# =============================================================================

signal predictive_fade_started()
signal predictive_fade_complete()
signal constraint_violated(constraint: String, action: String)
signal streamer_mode_changed(enabled: bool)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Predictive Fade")
## Enable predictive fade for streaming
@export var predictive_fade_enabled: bool = true
## Duration of fade transition
@export var fade_duration: float = 2.0
## Exposure reduction during fade
@export var exposure_reduction: float = 0.3
## Audio compression during fade
@export var audio_compression: float = 0.7

@export_group("Streamer Mode")
## Replace fatal audio with wind only
@export var wind_only_audio: bool = false
## Delay fatal replays until stream end
@export var delay_fatal_replay: bool = false
## Show static content warning
@export var show_content_warning: bool = true

@export_group("Content Warning")
## Warning display duration
@export var warning_duration: float = 5.0
## Warning text
@export var warning_text: String = "This game depicts realistic mountaineering risk, including injury and death."

# =============================================================================
# PROHIBITED BEHAVIORS
# =============================================================================

## Actions the camera must NEVER take during fatal events
const PROHIBITED_CAMERA_ACTIONS := [
	"zoom_in_on_impact",
	"follow_into_void",
	"reframe_to_show_body",
	"circle_stopped_body",
	"hover_overhead",
	"slow_motion_death",
	"replay_impact",
	"focus_on_injury"
]

## UI elements that must NEVER appear during fatal events
const PROHIBITED_UI := [
	"death_text",
	"skull_icon",
	"you_died",
	"game_over",
	"respawn_prompt",
	"death_counter"
]

## Audio that must be suppressed during fatal events
const PROHIBITED_AUDIO := [
	"impact_sfx",
	"scream_sfx",
	"dramatic_music",
	"horror_sting",
	"death_jingle"
]

# =============================================================================
# STATE
# =============================================================================

## Is streamer mode active
var streamer_mode: bool = false

## Is predictive fade in progress
var is_fading: bool = false

## Current fade progress
var fade_progress: float = 0.0

## Current fatal phase
var current_phase: GameEnums.FatalPhase = GameEnums.FatalPhase.NONE

## Violations logged this session
var violation_log: Array[Dictionary] = []

## Content warning shown this session
var warning_shown: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("EthicalConstraints", self)
	_connect_events()
	print("[EthicalConstraints] Initialized - Witness without harm")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.run_started.connect(_on_run_started)


# =============================================================================
# PREDICTIVE FADE
# =============================================================================

func begin_predictive_fade() -> void:
	if not predictive_fade_enabled or is_fading:
		return

	is_fading = true
	fade_progress = 0.0
	predictive_fade_started.emit()

	# Start fade process
	_execute_predictive_fade()


func _execute_predictive_fade() -> void:
	## When system detects irreversible loss of control:
	## 1. Drone pulls back
	## 2. Exposure lowers slightly
	## 3. Audio compresses
	## 4. Motion slows
	## 5. If death occurs: drone loses subject naturally
	## 6. Image holds on environment
	## 7. Fade to black after absence is clear

	# Request drone pullback
	var drone_service := ServiceLocator.get_service("DroneService") as DroneService
	if drone_service and drone_service.drone:
		drone_service.drone.controller.pull_back(10.0, 2.0)

	# Request audio compression
	EventBus.audio_duck_requested.emit("predictive_fade")

	# Begin tween for fade
	var tween := create_tween()
	tween.tween_method(_update_fade_progress, 0.0, 1.0, fade_duration)
	tween.tween_callback(_complete_predictive_fade)


func _update_fade_progress(progress: float) -> void:
	fade_progress = progress

	# Gradual exposure reduction
	# (Would connect to rendering system)


func _complete_predictive_fade() -> void:
	is_fading = false
	fade_progress = 1.0
	predictive_fade_complete.emit()


# =============================================================================
# PHASE RESPONSE
# =============================================================================

func on_phase_changed(phase: GameEnums.FatalPhase) -> void:
	current_phase = phase

	match phase:
		GameEnums.FatalPhase.MOMENT_OF_ERROR:
			_enforce_moment_of_error()
		GameEnums.FatalPhase.LOSS_OF_CONTROL:
			_enforce_loss_of_control()
		GameEnums.FatalPhase.VANISHING:
			_enforce_vanishing()
		GameEnums.FatalPhase.AFTERMATH:
			_enforce_aftermath()
		GameEnums.FatalPhase.ACKNOWLEDGMENT:
			_enforce_acknowledgment()
		GameEnums.FatalPhase.NONE:
			_clear_fatal_constraints()


func _enforce_moment_of_error() -> void:
	# Ensure no UI appears
	_suppress_prohibited_ui()

	# No music stings
	_suppress_prohibited_audio()


func _enforce_loss_of_control() -> void:
	# Verify camera is pulling back, not in
	_verify_camera_constraints()


func _enforce_vanishing() -> void:
	# Ensure camera stops following
	# Ensure audio transition to wind

	if wind_only_audio:
		_force_wind_only_audio()


func _enforce_aftermath() -> void:
	# Maximum silence enforcement
	# No motion, no music, no interruption

	_enforce_silence()


func _enforce_acknowledgment() -> void:
	# Ensure reveal is slow and reverent
	# No text, no markers
	pass


func _clear_fatal_constraints() -> void:
	# Restore normal operation
	EventBus.audio_restore_requested.emit()


# =============================================================================
# CONSTRAINT ENFORCEMENT
# =============================================================================

func _suppress_prohibited_ui() -> void:
	# Signal to UI system to hide prohibited elements
	# This would connect to actual UI management
	pass


func _suppress_prohibited_audio() -> void:
	# Signal to audio system to suppress prohibited sounds
	if wind_only_audio:
		_force_wind_only_audio()


func _force_wind_only_audio() -> void:
	EventBus.wind_audio_changed.emit(1.0)
	EventBus.breathing_changed.emit(0.0)


func _enforce_silence() -> void:
	EventBus.silence_moment.emit(true)


func _verify_camera_constraints() -> void:
	# Would verify camera is following ethical constraints
	pass


# =============================================================================
# VALIDATION
# =============================================================================

## Check if a camera action is permitted
func is_camera_action_permitted(action: String) -> bool:
	if current_phase == GameEnums.FatalPhase.NONE:
		return true

	if action in PROHIBITED_CAMERA_ACTIONS:
		_log_violation("camera", action)
		return false

	return true


## Check if a UI element is permitted
func is_ui_permitted(element: String) -> bool:
	if current_phase == GameEnums.FatalPhase.NONE:
		return true

	if element in PROHIBITED_UI:
		_log_violation("ui", element)
		return false

	return true


## Check if audio is permitted
func is_audio_permitted(audio: String) -> bool:
	if current_phase == GameEnums.FatalPhase.NONE:
		return true

	if audio in PROHIBITED_AUDIO:
		_log_violation("audio", audio)
		return false

	return true


func _log_violation(category: String, action: String) -> void:
	var violation := {
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"category": category,
		"action": action,
		"phase": GameEnums.FatalPhase.keys()[current_phase]
	}

	violation_log.append(violation)
	constraint_violated.emit(category, action)

	push_warning("[EthicalConstraints] Violation blocked: %s/%s during %s" % [
		category, action, violation["phase"]
	])


# =============================================================================
# CONTENT WARNING
# =============================================================================

func show_content_warning_if_needed() -> void:
	if not show_content_warning or warning_shown:
		return

	_display_content_warning()


func _display_content_warning() -> void:
	# Would trigger actual UI display
	# Neutral, no flashing, no icons, no voiceover
	warning_shown = true

	EventBus.diegetic_message.emit(warning_text, warning_duration)


# =============================================================================
# STREAMER MODE
# =============================================================================

func enable_streamer_mode() -> void:
	streamer_mode = true
	predictive_fade_enabled = true
	wind_only_audio = true
	delay_fatal_replay = true
	show_content_warning = true

	streamer_mode_changed.emit(true)


func disable_streamer_mode() -> void:
	streamer_mode = false
	# Keep user preferences for individual settings

	streamer_mode_changed.emit(false)


func is_streamer_mode() -> bool:
	return streamer_mode


# =============================================================================
# REPLAY ETHICS
# =============================================================================

## Check if fatal replay is permitted now
func is_fatal_replay_permitted() -> bool:
	if delay_fatal_replay:
		# Only permit at stream end
		return false

	return true


## Get ethical replay rules
func get_replay_rules() -> Dictionary:
	return {
		"speed": "normal_only",  # No slow motion
		"camera_switching": false,
		"continuous_take": true,
		"replay_count": 1,  # Once only
		"show_path_after": true,
		"show_fall": false
	}


# =============================================================================
# HIGHLIGHT ETHICS
# =============================================================================

## Check if moment should be excluded from highlights
func should_exclude_from_highlights() -> bool:
	return current_phase != GameEnums.FatalPhase.NONE


## Get ethical highlight title
func get_ethical_highlight_title(original: String) -> String:
	# Remove death references
	var sanitized := original
	var prohibited_words := ["death", "died", "fatal", "killed", "brutal", "fall"]

	for word in prohibited_words:
		sanitized = sanitized.replacen(word, "")

	# Suggest neutral alternative
	if sanitized.strip_edges().is_empty():
		return "Mountain Descent"

	return sanitized.strip_edges()


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	if new_state == GameEnums.GameState.DESCENT:
		show_content_warning_if_needed()


func _on_run_started(_context: RunContext) -> void:
	warning_shown = false
	violation_log.clear()


# =============================================================================
# QUERIES
# =============================================================================

func get_summary() -> Dictionary:
	return {
		"streamer_mode": streamer_mode,
		"predictive_fade_enabled": predictive_fade_enabled,
		"is_fading": is_fading,
		"fade_progress": fade_progress,
		"wind_only_audio": wind_only_audio,
		"current_phase": GameEnums.FatalPhase.keys()[current_phase],
		"violations_blocked": violation_log.size()
	}


func get_violation_log() -> Array[Dictionary]:
	return violation_log
