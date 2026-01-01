class_name SignalDetector
extends Node
## Detects events that warrant camera attention
## First layer of the Camera Director AI
##
## Design Philosophy:
## - Everything is a signal with weight and decay
## - Signals accumulate to indicate intensity
## - The director doesn't see health bars, it sees body language
## - Anticipation is as important as reaction

# =============================================================================
# SIGNALS
# =============================================================================

signal signal_detected(signal_type: GameEnums.CameraSignal, intensity: float, source: Vector3)
signal signal_cleared(signal_type: GameEnums.CameraSignal)
signal intensity_changed(total_intensity: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Detection Thresholds")
## Slope change threshold (degrees)
@export var slope_change_threshold: float = 10.0
## Speed change threshold (m/s)
@export var speed_change_threshold: float = 2.0
## Cliff proximity warning distance (m)
@export var cliff_warning_distance: float = 10.0
## Fatigue threshold for camera attention
@export var fatigue_attention_threshold: float = 0.5

@export_group("Signal Weights")
## Base weights for signal types
@export var signal_weights: Dictionary = {
	"SLOPE_CHANGE": 0.4,
	"SPEED_CHANGE": 0.3,
	"SLIDE_ENTRY": 0.9,
	"DESCENT_START": 0.7,
	"ROPE_DEPLOYMENT": 0.6,
	"FATIGUE_THRESHOLD": 0.5,
	"MICRO_SLIP": 0.7,
	"CLIFF_PROXIMITY": 0.8,
	"CRITICAL_MOMENT": 1.0,
	"FATAL_MOMENT": 1.0,
	"WEATHER_SHIFT": 0.3,
	"LIGHT_CHANGE": 0.2,
	"ISOLATION": 0.4,
	"SILENCE_MOMENT": 0.5
}

@export_group("Decay")
## Signal decay rate per second
@export var signal_decay_rate: float = 0.3
## Minimum signal intensity to track
@export var signal_min_intensity: float = 0.1

# =============================================================================
# STATE
# =============================================================================

## Active signals with their current intensity
var active_signals: Dictionary = {}  # CameraSignal -> SignalData

## Total accumulated intensity
var total_intensity: float = 0.0

## Player reference
var player: PlayerController

## Previous state tracking (for change detection)
var prev_slope: float = 0.0
var prev_speed: float = 0.0
var prev_fatigue: float = 0.0
var prev_position: Vector3 = Vector3.ZERO

## Cliff proximity
var cliff_distance: float = INF

## Is in critical moment
var in_critical_moment: bool = false

## Time since last significant event
var quiet_time: float = 0.0


# =============================================================================
# SIGNAL DATA
# =============================================================================

class SignalData:
	var type: GameEnums.CameraSignal
	var intensity: float
	var source_position: Vector3
	var timestamp: float
	var is_sustained: bool  # Does this signal persist?

	func _init(t: GameEnums.CameraSignal, i: float, pos: Vector3, sustained: bool = false):
		type = t
		intensity = i
		source_position = pos
		timestamp = Time.get_ticks_msec() / 1000.0
		is_sustained = sustained


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	_connect_events()
	ServiceLocator.register_service("SignalDetector", self)
	print("[SignalDetector] Initialized")


func _connect_events() -> void:
	# Player events
	EventBus.player_movement_changed.connect(_on_player_movement_changed)
	EventBus.player_position_updated.connect(_on_player_position_updated)
	EventBus.player_stability_changed.connect(_on_player_stability_changed)
	EventBus.micro_slip_occurred.connect(_on_micro_slip)

	# Sliding events
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.slide_control_changed.connect(_on_slide_control_changed)

	# Terrain events
	EventBus.terrain_zone_changed.connect(_on_terrain_zone_changed)
	EventBus.cliff_proximity_warning.connect(_on_cliff_proximity)
	EventBus.cliff_proximity_changed.connect(_on_cliff_proximity_changed)

	# Body events
	EventBus.fatigue_threshold_crossed.connect(_on_fatigue_threshold)
	EventBus.injury_occurred.connect(_on_injury)

	# Environment events
	EventBus.weather_changed.connect(_on_weather_changed)
	EventBus.time_milestone.connect(_on_time_milestone)

	# Rope events
	EventBus.rope_deployment_started.connect(_on_rope_deployment)
	EventBus.rappel_started.connect(_on_rappel_started)

	# Risk events
	EventBus.risk_level_changed.connect(_on_risk_changed)
	EventBus.point_of_no_return_detected.connect(_on_point_of_no_return)

	# Fatal events
	EventBus.fatal_event_started.connect(_on_fatal_event)

	# Audio events (silence moments)
	EventBus.silence_moment.connect(_on_silence_moment)

	# Get player reference
	ServiceLocator.get_service_async("PlayerController", func(p): player = p)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_continuous_detection(delta)
	_decay_signals(delta)
	_update_total_intensity()
	_check_quiet_time(delta)


func _update_continuous_detection(delta: float) -> void:
	if player == null:
		return

	# Speed change detection
	var current_speed := player.smooth_velocity.length()
	var speed_delta := absf(current_speed - prev_speed)
	if speed_delta > speed_change_threshold:
		_emit_signal(GameEnums.CameraSignal.SPEED_CHANGE, speed_delta / 10.0)
	prev_speed = current_speed

	# Slope change detection
	if player.current_cell:
		var current_slope := player.current_cell.slope_angle
		var slope_delta := absf(current_slope - prev_slope)
		if slope_delta > slope_change_threshold:
			_emit_signal(GameEnums.CameraSignal.SLOPE_CHANGE, slope_delta / 45.0)
		prev_slope = current_slope

	# Fatigue monitoring
	if player.body_state:
		var fatigue := player.body_state.fatigue
		if fatigue > fatigue_attention_threshold and fatigue > prev_fatigue + 0.1:
			_emit_signal(GameEnums.CameraSignal.FATIGUE_THRESHOLD, fatigue)
		prev_fatigue = fatigue

	# Position tracking
	prev_position = player.global_position


func _decay_signals(delta: float) -> void:
	var to_remove: Array[GameEnums.CameraSignal] = []

	for signal_type in active_signals:
		var data: SignalData = active_signals[signal_type]

		if not data.is_sustained:
			data.intensity -= signal_decay_rate * delta

			if data.intensity <= signal_min_intensity:
				to_remove.append(signal_type)

	for signal_type in to_remove:
		active_signals.erase(signal_type)
		signal_cleared.emit(signal_type)


func _update_total_intensity() -> void:
	var new_total := 0.0

	for signal_type in active_signals:
		var data: SignalData = active_signals[signal_type]
		var weight: float = signal_weights.get(GameEnums.CameraSignal.keys()[signal_type], 0.5)
		new_total += data.intensity * weight

	if absf(new_total - total_intensity) > 0.05:
		total_intensity = new_total
		intensity_changed.emit(total_intensity)


func _check_quiet_time(delta: float) -> void:
	if total_intensity < 0.2:
		quiet_time += delta

		# Extended quiet periods create isolation signal
		if quiet_time > 10.0:
			_emit_signal(GameEnums.CameraSignal.ISOLATION, 0.5, true)
			quiet_time = 0.0  # Reset to not spam
	else:
		quiet_time = 0.0


# =============================================================================
# SIGNAL EMISSION
# =============================================================================

func _emit_signal(type: GameEnums.CameraSignal, intensity: float, sustained: bool = false) -> void:
	var source_pos := player.global_position if player else Vector3.ZERO

	# Create or update signal
	if active_signals.has(type):
		var existing: SignalData = active_signals[type]
		existing.intensity = maxf(existing.intensity, intensity)
		existing.timestamp = Time.get_ticks_msec() / 1000.0
	else:
		active_signals[type] = SignalData.new(type, intensity, source_pos, sustained)

	signal_detected.emit(type, intensity, source_pos)

	# Also emit to EventBus for other systems
	EventBus.camera_signal_detected.emit(type, intensity)


func _emit_signal_at(type: GameEnums.CameraSignal, intensity: float, position: Vector3) -> void:
	if active_signals.has(type):
		var existing: SignalData = active_signals[type]
		existing.intensity = maxf(existing.intensity, intensity)
		existing.source_position = position
	else:
		active_signals[type] = SignalData.new(type, intensity, position, false)

	signal_detected.emit(type, intensity, position)
	EventBus.camera_signal_detected.emit(type, intensity)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_player_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	match new_state:
		GameEnums.PlayerMovementState.SLIDING:
			_emit_signal(GameEnums.CameraSignal.SLIDE_ENTRY, 1.0)
		GameEnums.PlayerMovementState.FALLING:
			_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 1.0)
		GameEnums.PlayerMovementState.ROPING:
			_emit_signal(GameEnums.CameraSignal.ROPE_DEPLOYMENT, 0.7)


func _on_player_position_updated(position: Vector3, velocity: Vector3) -> void:
	# Handled in continuous detection
	pass


func _on_player_stability_changed(stability: float, posture: GameEnums.PostureState) -> void:
	if posture == GameEnums.PostureState.UNSTABLE:
		_emit_signal(GameEnums.CameraSignal.MICRO_SLIP, 0.6)
	elif posture == GameEnums.PostureState.FALLING:
		_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 1.0)


func _on_micro_slip(severity: float, position: Vector3) -> void:
	_emit_signal_at(GameEnums.CameraSignal.MICRO_SLIP, severity, position)


func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	var intensity := clampf(entry_speed / 10.0 + slope_angle / 45.0, 0.5, 1.0)
	_emit_signal(GameEnums.CameraSignal.SLIDE_ENTRY, intensity)


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	if outcome == GameEnums.SlideOutcome.TERMINAL_RUNOUT:
		_emit_signal(GameEnums.CameraSignal.FATAL_MOMENT, 1.0)
	elif outcome == GameEnums.SlideOutcome.TUMBLE_STOP:
		_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 0.8)


func _on_slide_control_changed(old_level: GameEnums.SlideControlLevel, new_level: GameEnums.SlideControlLevel) -> void:
	if new_level == GameEnums.SlideControlLevel.LOST:
		_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 0.9)
	elif new_level == GameEnums.SlideControlLevel.UNSTABLE:
		_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, 0.6)


func _on_terrain_zone_changed(old_zone: GameEnums.TerrainZone, new_zone: GameEnums.TerrainZone) -> void:
	if new_zone == GameEnums.TerrainZone.CLIFF:
		_emit_signal(GameEnums.CameraSignal.CLIFF_PROXIMITY, 1.0)
	elif new_zone == GameEnums.TerrainZone.RAPPEL_REQUIRED:
		_emit_signal(GameEnums.CameraSignal.SLOPE_CHANGE, 0.7)


func _on_cliff_proximity(distance: float, direction: Vector3) -> void:
	cliff_distance = distance
	var intensity := 1.0 - (distance / cliff_warning_distance)
	_emit_signal(GameEnums.CameraSignal.CLIFF_PROXIMITY, intensity)


func _on_cliff_proximity_changed(distance: float) -> void:
	cliff_distance = distance
	if distance < cliff_warning_distance:
		var intensity := 1.0 - (distance / cliff_warning_distance)
		_emit_signal(GameEnums.CameraSignal.CLIFF_PROXIMITY, intensity)


func _on_fatigue_threshold(fatigue: float, threshold_name: String) -> void:
	var intensity := 0.5
	if threshold_name == "critical":
		intensity = 0.9
	elif threshold_name == "input_delay":
		intensity = 0.7

	_emit_signal(GameEnums.CameraSignal.FATIGUE_THRESHOLD, intensity)


func _on_injury(injury: Injury) -> void:
	_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, injury.severity)


func _on_weather_changed(old_weather: GameEnums.WeatherState, new_weather: GameEnums.WeatherState) -> void:
	var intensity := 0.3
	if new_weather == GameEnums.WeatherState.STORM:
		intensity = 0.7
	elif new_weather == GameEnums.WeatherState.WHITEOUT:
		intensity = 0.9

	_emit_signal(GameEnums.CameraSignal.WEATHER_SHIFT, intensity)


func _on_time_milestone(game_time: float, event: String) -> void:
	if event in ["dusk", "dawn"]:
		_emit_signal(GameEnums.CameraSignal.LIGHT_CHANGE, 0.6)
	elif event == "night":
		_emit_signal(GameEnums.CameraSignal.LIGHT_CHANGE, 0.8)


func _on_rope_deployment(anchor_quality: GameEnums.AnchorQuality) -> void:
	var intensity := 0.5
	if anchor_quality == GameEnums.AnchorQuality.MARGINAL:
		intensity = 0.7
	elif anchor_quality == GameEnums.AnchorQuality.POOR:
		intensity = 0.9

	_emit_signal(GameEnums.CameraSignal.ROPE_DEPLOYMENT, intensity)


func _on_rappel_started() -> void:
	_emit_signal(GameEnums.CameraSignal.DESCENT_START, 0.6)


func _on_risk_changed(risk: float, factors: Dictionary) -> void:
	if risk > 0.7:
		_emit_signal(GameEnums.CameraSignal.CRITICAL_MOMENT, risk)
	elif risk > 0.5:
		# Heightened attention but not critical
		if active_signals.has(GameEnums.CameraSignal.CLIFF_PROXIMITY):
			active_signals[GameEnums.CameraSignal.CLIFF_PROXIMITY].intensity = maxf(
				active_signals[GameEnums.CameraSignal.CLIFF_PROXIMITY].intensity,
				risk
			)


func _on_point_of_no_return() -> void:
	_emit_signal(GameEnums.CameraSignal.FATAL_MOMENT, 1.0)
	in_critical_moment = true


func _on_fatal_event(phase: GameEnums.FatalPhase) -> void:
	_emit_signal(GameEnums.CameraSignal.FATAL_MOMENT, 1.0, true)
	in_critical_moment = true


func _on_silence_moment(is_active: bool) -> void:
	if is_active:
		_emit_signal(GameEnums.CameraSignal.SILENCE_MOMENT, 0.6)


# =============================================================================
# QUERIES
# =============================================================================

## Get the strongest active signal
func get_dominant_signal() -> Dictionary:
	var dominant_type: GameEnums.CameraSignal = GameEnums.CameraSignal.SLOPE_CHANGE
	var max_weighted := 0.0

	for signal_type in active_signals:
		var data: SignalData = active_signals[signal_type]
		var weight: float = signal_weights.get(GameEnums.CameraSignal.keys()[signal_type], 0.5)
		var weighted := data.intensity * weight

		if weighted > max_weighted:
			max_weighted = weighted
			dominant_type = signal_type

	if max_weighted > 0:
		var data: SignalData = active_signals[dominant_type]
		return {
			"type": dominant_type,
			"intensity": data.intensity,
			"position": data.source_position,
			"weighted": max_weighted
		}

	return {}


## Get all signals above threshold
func get_active_signals(threshold: float = 0.0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for signal_type in active_signals:
		var data: SignalData = active_signals[signal_type]
		if data.intensity > threshold:
			result.append({
				"type": signal_type,
				"intensity": data.intensity,
				"position": data.source_position
			})

	return result


## Get total signal intensity
func get_total_intensity() -> float:
	return total_intensity


## Check if in critical moment
func is_critical() -> bool:
	return in_critical_moment or total_intensity > 0.8


## Get cliff distance
func get_cliff_distance() -> float:
	return cliff_distance


func get_summary() -> Dictionary:
	return {
		"active_signals": active_signals.size(),
		"total_intensity": total_intensity,
		"dominant": get_dominant_signal(),
		"is_critical": is_critical(),
		"cliff_distance": cliff_distance,
		"quiet_time": quiet_time
	}
