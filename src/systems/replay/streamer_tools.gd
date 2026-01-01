class_name StreamerTools
extends Node
## Tools for streamers and content creators
## Content safety, biases, and stream integration
##
## Design Philosophy:
## - Forewarning without spoilers
## - Player choice, not platform enforcement
## - Respectful abstraction over explicit depiction
## - Can reduce intensity, cannot increase it

# =============================================================================
# SIGNALS
# =============================================================================

signal streamer_mode_enabled()
signal streamer_mode_disabled()
signal content_warning_shown(text: String)
signal predictive_fade_active(active: bool)
signal shot_bias_changed(bias: String)
signal clip_excluded(reason: String)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Content Warnings")
## Show content warning at stream start
@export var show_start_warning: bool = true
## Content warning text
@export var warning_text: String = "This game depicts realistic mountaineering risk, including injury and death."
## Warning display duration
@export var warning_duration: float = 5.0

@export_group("Predictive Fades")
## Enable predictive fades for stream
@export var predictive_fades_enabled: bool = true
## Fade duration
@export var fade_duration: float = 2.0
## Exposure reduction during fade
@export var fade_exposure: float = 0.3

@export_group("Audio Options")
## Replace fatal audio with wind only
@export var wind_only_fatal: bool = false
## Audio compression during intense moments
@export var audio_compression: float = 0.8

@export_group("Replay Options")
## Delay fatal replays until end of stream
@export var delay_fatal_replay: bool = false
## Exclude fatal from auto-highlights
@export var exclude_fatal_highlights: bool = true

@export_group("Camera Biases")
## Shot intent bias (context-heavy, balanced, action-heavy)
@export_enum("context", "balanced", "action") var shot_bias: String = "balanced"
## Human error slider (0-1)
@export var human_error_amount: float = 0.5

# =============================================================================
# STATE
# =============================================================================

## Is streamer mode active
var is_active: bool = false

## Has start warning been shown
var start_warning_shown: bool = false

## Is currently in predictive fade
var is_fading: bool = false

## Fade progress (0-1)
var fade_progress: float = 0.0

## Clips excluded this session
var excluded_clips: Array[Dictionary] = []

## Risk warning showing
var risk_warning_active: bool = false

## Camera director reference
var camera_director: CameraDirector

## Imperfection engine reference
var imperfection_engine: ImperfectionEngine


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("StreamerTools", self)

	ServiceLocator.get_service_async("CameraDirector", func(c): camera_director = c)
	ServiceLocator.get_service_async("ImperfectionEngine", func(i): imperfection_engine = i)

	_connect_events()
	print("[StreamerTools] Initialized")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.run_started.connect(_on_run_started)
	EventBus.point_of_no_return_detected.connect(_on_point_of_no_return)
	EventBus.fatal_event_started.connect(_on_fatal_event)
	EventBus.high_risk_zone_entered.connect(_on_high_risk)


# =============================================================================
# STREAMER MODE
# =============================================================================

func enable_streamer_mode() -> void:
	is_active = true

	# Apply default streamer settings
	show_start_warning = true
	predictive_fades_enabled = true
	exclude_fatal_highlights = true

	# Apply to ethical constraints
	var constraints := ServiceLocator.get_service("EthicalConstraints") as EthicalConstraints
	if constraints:
		constraints.enable_streamer_mode()

	streamer_mode_enabled.emit()
	print("[StreamerTools] Streamer mode enabled")


func disable_streamer_mode() -> void:
	is_active = false
	streamer_mode_disabled.emit()
	print("[StreamerTools] Streamer mode disabled")


# =============================================================================
# CONTENT WARNINGS
# =============================================================================

func show_content_warning() -> void:
	if not show_start_warning:
		return

	if start_warning_shown:
		return

	start_warning_shown = true
	content_warning_shown.emit(warning_text)
	EventBus.diegetic_message.emit(warning_text, warning_duration)


func show_risk_warning(risk_type: String) -> void:
	## Contextual warning when entering dangerous areas
	## "Risk exposure increasing." - neutral, no drama

	if not is_active:
		return

	risk_warning_active = true

	var warning := "Risk exposure increasing."
	EventBus.diegetic_message.emit(warning, 3.0)

	# Clear after delay
	get_tree().create_timer(3.0).timeout.connect(func(): risk_warning_active = false)


# =============================================================================
# PREDICTIVE FADES
# =============================================================================

func begin_predictive_fade() -> void:
	if not predictive_fades_enabled:
		return

	if is_fading:
		return

	is_fading = true
	fade_progress = 0.0
	predictive_fade_active.emit(true)

	_execute_fade()


func _execute_fade() -> void:
	## Stream feed (not player feed) withdraws
	## 1. Drone pulls back
	## 2. Exposure lowers slightly
	## 3. Audio compresses
	## 4. Motion slows
	## 5. If death: drone loses subject
	## 6. Image holds on environment
	## 7. Fade to black after absence clear

	# Request drone pullback
	var drone_service := ServiceLocator.get_service("DroneService") as DroneService
	if drone_service and drone_service.drone:
		drone_service.drone.controller.pull_back(10.0, fade_duration)

	# Audio compression
	EventBus.audio_duck_requested.emit("predictive_fade")

	# Tween the fade
	var tween := create_tween()
	tween.tween_method(_update_fade, 0.0, 1.0, fade_duration)
	tween.tween_callback(_complete_fade)


func _update_fade(progress: float) -> void:
	fade_progress = progress

	# Would apply to stream output:
	# - Reduce exposure
	# - Slight vignette
	# - Audio compression increase


func _complete_fade() -> void:
	# Hold state - don't immediately restore
	pass


func end_predictive_fade() -> void:
	is_fading = false
	fade_progress = 0.0
	predictive_fade_active.emit(false)
	EventBus.audio_restore_requested.emit()


# =============================================================================
# CAMERA BIASES
# =============================================================================

func set_shot_bias(bias: String) -> void:
	## Streamers can bias shot intent preference
	## context-heavy: More establishing shots
	## balanced: Default behavior
	## action-heavy: More close-up action

	if bias not in ["context", "balanced", "action"]:
		return

	shot_bias = bias
	shot_bias_changed.emit(bias)

	# Apply to camera director
	if camera_director:
		match bias:
			"context":
				camera_director.reactivity = 0.4
				camera_director.anticipation = 0.6
			"balanced":
				camera_director.reactivity = 0.6
				camera_director.anticipation = 0.4
			"action":
				camera_director.reactivity = 0.8
				camera_director.anticipation = 0.3


func set_human_error(amount: float) -> void:
	## Adjust how much "human-like" imperfection the camera has
	## Higher = more missed shots, late arrivals, hesitation

	human_error_amount = clampf(amount, 0.0, 1.0)

	if imperfection_engine:
		imperfection_engine.base_miss_rate = 0.05 * human_error_amount
		imperfection_engine.base_late_rate = 0.12 * human_error_amount
		imperfection_engine.base_hesitate_rate = 0.08 * human_error_amount


## Streamers CANNOT:
## - Force angles
## - Teleport drone
## - Override safety limits

func force_camera_angle(_angle: Vector3) -> void:
	push_warning("[StreamerTools] Force camera angle is not permitted")


func teleport_drone(_position: Vector3) -> void:
	push_warning("[StreamerTools] Drone teleport is not permitted")


# =============================================================================
# CLIP MANAGEMENT
# =============================================================================

func should_exclude_from_clip(timestamp: float, recording: RecordingService.RecordingData) -> bool:
	## Check if timestamp should be excluded from auto-generated clips

	if not exclude_fatal_highlights:
		return false

	# Check for fatal events near this timestamp
	for event in recording.events:
		if event.event_type == "fatal_event":
			if absf(event.timestamp - timestamp) < 10.0:  # Within 10 seconds
				excluded_clips.append({
					"timestamp": timestamp,
					"reason": "fatal_proximity"
				})
				clip_excluded.emit("fatal_proximity")
				return true

	return false


func get_ethical_clip_title(original: String) -> String:
	## Generate ethical titles for clips
	## Never reference death or fatality

	var prohibited := ["death", "died", "fatal", "killed", "brutal", "fall", "crash"]

	var cleaned := original.to_lower()
	for word in prohibited:
		if word in cleaned:
			# Return generic title
			return _generate_neutral_title()

	return original


func _generate_neutral_title() -> String:
	var titles := [
		"Mountain Descent",
		"Alpine Journey",
		"Technical Terrain",
		"Challenging Route",
		"High Altitude Moment"
	]
	return titles[randi() % titles.size()]


# =============================================================================
# AUDIO OPTIONS
# =============================================================================

func enable_wind_only_fatal() -> void:
	wind_only_fatal = true

	var constraints := ServiceLocator.get_service("EthicalConstraints") as EthicalConstraints
	if constraints:
		constraints.wind_only_audio = true


func disable_wind_only_fatal() -> void:
	wind_only_fatal = false

	var constraints := ServiceLocator.get_service("EthicalConstraints") as EthicalConstraints
	if constraints:
		constraints.wind_only_audio = false


# =============================================================================
# REPLAY OPTIONS
# =============================================================================

func enable_delayed_fatal_replay() -> void:
	delay_fatal_replay = true

	var constraints := ServiceLocator.get_service("EthicalConstraints") as EthicalConstraints
	if constraints:
		constraints.delay_fatal_replay = true


func is_fatal_replay_allowed() -> bool:
	if not delay_fatal_replay:
		return true

	# Would check if stream has ended
	# For now, always delay
	return false


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	if new_state == GameEnums.GameState.DESCENT:
		if is_active:
			show_content_warning()


func _on_run_started(_context: RunContext) -> void:
	start_warning_shown = false
	excluded_clips.clear()

	if is_active:
		show_content_warning()


func _on_point_of_no_return() -> void:
	if is_active and predictive_fades_enabled:
		begin_predictive_fade()


func _on_fatal_event(_phase: GameEnums.FatalPhase) -> void:
	# Ensure fade is active
	if is_active and not is_fading:
		begin_predictive_fade()


func _on_high_risk(risk_type: String, severity: float) -> void:
	if severity > 0.7:
		show_risk_warning(risk_type)


# =============================================================================
# SETTINGS MANAGEMENT
# =============================================================================

func get_settings() -> Dictionary:
	return {
		"show_start_warning": show_start_warning,
		"predictive_fades_enabled": predictive_fades_enabled,
		"wind_only_fatal": wind_only_fatal,
		"delay_fatal_replay": delay_fatal_replay,
		"exclude_fatal_highlights": exclude_fatal_highlights,
		"shot_bias": shot_bias,
		"human_error_amount": human_error_amount
	}


func apply_settings(settings: Dictionary) -> void:
	show_start_warning = settings.get("show_start_warning", true)
	predictive_fades_enabled = settings.get("predictive_fades_enabled", true)
	wind_only_fatal = settings.get("wind_only_fatal", false)
	delay_fatal_replay = settings.get("delay_fatal_replay", false)
	exclude_fatal_highlights = settings.get("exclude_fatal_highlights", true)
	shot_bias = settings.get("shot_bias", "balanced")
	human_error_amount = settings.get("human_error_amount", 0.5)

	# Apply biases
	set_shot_bias(shot_bias)
	set_human_error(human_error_amount)


# =============================================================================
# QUERIES
# =============================================================================

func get_summary() -> Dictionary:
	return {
		"is_active": is_active,
		"is_fading": is_fading,
		"fade_progress": fade_progress,
		"shot_bias": shot_bias,
		"human_error": human_error_amount,
		"excluded_clips": excluded_clips.size(),
		"risk_warning_active": risk_warning_active
	}
