class_name ImperfectionEngine
extends Node
## Adds human-like character to camera work
## The difference between a drone and a filmmaker
##
## Design Philosophy:
## - Perfect shots feel robotic
## - Small mistakes create authenticity
## - A documentary cameraman has personality
## - Fatigue and conditions affect performance
## - The camera should feel operated, not programmed

# =============================================================================
# SIGNALS
# =============================================================================

signal imperfection_triggered(type: String, magnitude: float)
signal operator_state_changed(state: OperatorState)

# =============================================================================
# ENUMS
# =============================================================================

enum OperatorState {
	ALERT,          # Fresh, responsive
	FOCUSED,        # In the zone, few mistakes
	ROUTINE,        # Normal performance
	FATIGUED,       # More mistakes, slower
	STRESSED        # Rushed, overcorrects
}

enum ImperfectionType {
	MISS_SHOT,      # Camera doesn't catch the action
	ARRIVE_LATE,    # Camera arrives after action starts
	HESITATE,       # Brief pause before responding
	OVERCORRECT,    # Overshoots then corrects
	DRIFT,          # Slow wandering from target
	ANTICIPATE_WRONG,  # Guesses wrong direction
	REFRAME,        # Adjusts framing mid-shot
	SHAKE,          # Nervous/startled shake
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Operator Personality")
## Base skill level (higher = fewer mistakes)
@export var skill_level: float = 0.7
## How quickly operator fatigues (0 = never, 1 = quickly)
@export var fatigue_rate: float = 0.3
## Stress response (higher = more reactive to danger)
@export var stress_sensitivity: float = 0.5

@export_group("Imperfection Rates")
## Base miss chance per significant event
@export var base_miss_rate: float = 0.05
## Base late arrival chance
@export var base_late_rate: float = 0.12
## Base hesitation chance
@export var base_hesitate_rate: float = 0.08
## Base overcorrection chance
@export var base_overcorrect_rate: float = 0.06
## Base drift rate (continuous)
@export var base_drift_rate: float = 0.02

@export_group("Timing")
## How long hesitation lasts
@export var hesitate_duration: Vector2 = Vector2(0.1, 0.4)
## How late "late" is
@export var late_delay: Vector2 = Vector2(0.2, 0.6)
## Overcorrection amount
@export var overcorrect_magnitude: Vector2 = Vector2(0.1, 0.3)

# =============================================================================
# STATE
# =============================================================================

## Current operator state
var operator_state: OperatorState = OperatorState.ROUTINE

## Fatigue level (0 = fresh, 1 = exhausted)
var fatigue: float = 0.0

## Stress level (0 = calm, 1 = panicked)
var stress: float = 0.0

## Active time (seconds)
var active_time: float = 0.0

## Recent imperfections (for variety)
var recent_imperfections: Array[String] = []

## Current drift offset
var drift_offset: Vector3 = Vector3.ZERO

## Drift direction
var drift_direction: Vector3 = Vector3.ZERO

## Time until next random event
var random_event_timer: float = 0.0

## Is engine active
var is_active: bool = false

## Drone camera reference
var drone_camera: DroneCamera

## Weather service reference
var weather_service: WeatherService

## Environment service reference (for temperature)
var environment_service: EnvironmentService


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("ImperfectionEngine", self)
	ServiceLocator.get_service_async("WeatherService", func(s): weather_service = s)
	ServiceLocator.get_service_async("EnvironmentService", func(s): environment_service = s)

	_connect_events()
	_randomize_event_timer()

	print("[ImperfectionEngine] The human touch - initialized")


func _connect_events() -> void:
	EventBus.game_state_changed.connect(_on_game_state_changed)
	EventBus.descent_ready.connect(_on_descent_ready)

	# Events that might cause imperfections
	EventBus.slide_started.connect(func(_s, _a): _on_sudden_event("slide"))
	EventBus.stumble_occurred.connect(func(_s, _r): _on_sudden_event("stumble"))
	EventBus.fatal_event_started.connect(func(_p): _on_sudden_event("fatal"))


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_active:
		return

	active_time += delta

	_update_fatigue(delta)
	_update_stress(delta)
	_update_operator_state()
	_update_drift(delta)
	_process_random_events(delta)


func _update_fatigue(delta: float) -> void:
	# Fatigue accumulates over time
	var fatigue_gain := fatigue_rate * 0.001 * delta  # Very slow

	# Environmental factors
	if weather_service:
		# Cold increases fatigue
		if environment_service and environment_service.temperature_system:
			var temp := environment_service.temperature_system.get_air_temperature()
			if temp < -10:
				fatigue_gain *= 1.5

		# Wind requires more effort
		var wind_speed: float = weather_service.wind_speed
		fatigue_gain *= 1.0 + (wind_speed / 30.0) * 0.5

	fatigue = minf(1.0, fatigue + fatigue_gain)


func _update_stress(delta: float) -> void:
	# Stress decays slowly when nothing is happening
	stress = maxf(0.0, stress - delta * 0.1)

	# High intensity maintains stress
	var signal_detector := ServiceLocator.get_service("SignalDetector") as SignalDetector
	if signal_detector:
		var intensity := signal_detector.get_total_intensity()
		if intensity > 0.5:
			stress = minf(1.0, stress + intensity * delta * stress_sensitivity)


func _update_operator_state() -> void:
	var new_state := _determine_operator_state()

	if new_state != operator_state:
		operator_state = new_state
		operator_state_changed.emit(new_state)


func _determine_operator_state() -> OperatorState:
	# High stress overrides fatigue
	if stress > 0.7:
		return OperatorState.STRESSED

	# Fresh start
	if fatigue < 0.1 and active_time < 60.0:
		return OperatorState.ALERT

	# Fatigued
	if fatigue > 0.6:
		return OperatorState.FATIGUED

	# In the zone (moderate activity, low stress)
	if active_time > 120.0 and stress < 0.3 and fatigue < 0.4:
		return OperatorState.FOCUSED

	return OperatorState.ROUTINE


func _update_drift(delta: float) -> void:
	# Drift happens more when fatigued
	var drift_strength := base_drift_rate * (1.0 + fatigue)

	# Change drift direction occasionally
	if randf() < 0.01:
		drift_direction = Vector3(
			randf_range(-1, 1),
			randf_range(-0.5, 0.5),
			randf_range(-1, 1)
		).normalized()

	drift_offset = drift_offset.lerp(
		drift_direction * drift_strength,
		delta * 0.5
	)


func _process_random_events(delta: float) -> void:
	random_event_timer -= delta

	if random_event_timer <= 0:
		_maybe_random_imperfection()
		_randomize_event_timer()


func _randomize_event_timer() -> void:
	# Random events every 5-30 seconds
	random_event_timer = randf_range(5.0, 30.0)

	# More frequent when fatigued
	random_event_timer /= (1.0 + fatigue * 0.5)


# =============================================================================
# IMPERFECTION GENERATION
# =============================================================================

func _on_sudden_event(event_type: String) -> void:
	# Sudden events can trigger imperfections
	var modifier := _get_event_modifier(event_type)

	if _should_miss(modifier):
		_trigger_imperfection(ImperfectionType.MISS_SHOT, event_type)
	elif _should_arrive_late(modifier):
		_trigger_imperfection(ImperfectionType.ARRIVE_LATE, event_type)
	elif _should_hesitate(modifier):
		_trigger_imperfection(ImperfectionType.HESITATE, event_type)

	# Sudden events cause stress
	stress = minf(1.0, stress + 0.2)


func _get_event_modifier(event_type: String) -> float:
	# Some events are harder to catch
	match event_type:
		"slide":
			return 1.5  # Fast, easy to miss
		"stumble":
			return 2.0  # Very quick
		"fatal":
			return 0.2  # Never miss these (mostly)
		_:
			return 1.0


func _should_miss(modifier: float) -> bool:
	var chance := _get_adjusted_rate(base_miss_rate) * modifier
	return randf() < chance


func _should_arrive_late(modifier: float) -> bool:
	var chance := _get_adjusted_rate(base_late_rate) * modifier
	return randf() < chance


func _should_hesitate(modifier: float) -> bool:
	var chance := _get_adjusted_rate(base_hesitate_rate) * modifier
	return randf() < chance


func _get_adjusted_rate(base_rate: float) -> float:
	var rate := base_rate

	# Skill reduces mistakes
	rate *= (1.0 - skill_level * 0.5)

	# Fatigue increases mistakes
	rate *= (1.0 + fatigue)

	# State modifiers
	match operator_state:
		OperatorState.ALERT:
			rate *= 0.5
		OperatorState.FOCUSED:
			rate *= 0.3
		OperatorState.FATIGUED:
			rate *= 1.5
		OperatorState.STRESSED:
			rate *= 1.2

	return rate


func _maybe_random_imperfection() -> void:
	# Random small imperfections during normal operation
	var roll := randf()

	if roll < base_drift_rate * (1.0 + fatigue):
		_trigger_imperfection(ImperfectionType.DRIFT, "random")
	elif roll < base_overcorrect_rate * (1.0 + stress):
		_trigger_imperfection(ImperfectionType.OVERCORRECT, "random")
	elif roll < base_hesitate_rate * fatigue:
		_trigger_imperfection(ImperfectionType.REFRAME, "random")


func _trigger_imperfection(type: ImperfectionType, trigger: String) -> void:
	# Avoid repeating same imperfection too often
	var type_name := ImperfectionType.keys()[type]
	if type_name in recent_imperfections:
		return

	recent_imperfections.append(type_name)
	if recent_imperfections.size() > 3:
		recent_imperfections.pop_front()

	var magnitude := _get_imperfection_magnitude(type)

	# Execute imperfection
	_execute_imperfection(type, magnitude)

	imperfection_triggered.emit(type_name, magnitude)
	print("[ImperfectionEngine] %s (%.2f) triggered by %s" % [type_name, magnitude, trigger])


func _get_imperfection_magnitude(type: ImperfectionType) -> float:
	match type:
		ImperfectionType.MISS_SHOT:
			return randf_range(0.3, 0.8)
		ImperfectionType.ARRIVE_LATE:
			return randf_range(late_delay.x, late_delay.y)
		ImperfectionType.HESITATE:
			return randf_range(hesitate_duration.x, hesitate_duration.y)
		ImperfectionType.OVERCORRECT:
			return randf_range(overcorrect_magnitude.x, overcorrect_magnitude.y)
		ImperfectionType.DRIFT:
			return drift_offset.length()
		ImperfectionType.SHAKE:
			return randf_range(0.1, 0.3)
		_:
			return 0.1


func _execute_imperfection(type: ImperfectionType, magnitude: float) -> void:
	# Get drone service
	var drone_service := ServiceLocator.get_service("DroneService") as DroneService
	if drone_service == null:
		return

	match type:
		ImperfectionType.MISS_SHOT:
			drone_service.miss_shot(magnitude)

		ImperfectionType.ARRIVE_LATE:
			drone_service.arrive_late(magnitude)

		ImperfectionType.HESITATE:
			drone_service.hesitate(magnitude)

		ImperfectionType.OVERCORRECT:
			# Overshoot then correct
			if drone_service.drone_camera:
				var original_smooth = drone_service.drone_camera.rotation_smoothing
				drone_service.drone_camera.rotation_smoothing = 6.0  # Faster
				await get_tree().create_timer(magnitude).timeout
				drone_service.drone_camera.rotation_smoothing = original_smooth

		ImperfectionType.REFRAME:
			# Small adjustment
			if drone_service.drone_camera:
				drone_service.drone_camera.frame_thirds(
					Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
				)


# =============================================================================
# EXTERNAL INTERFACE
# =============================================================================

## Get current drift offset (for camera)
func get_drift_offset() -> Vector3:
	return drift_offset


## Check if an imperfection should happen for an event
func should_imperfect(event_type: String) -> Dictionary:
	var modifier := _get_event_modifier(event_type)

	return {
		"miss": _should_miss(modifier),
		"late": _should_arrive_late(modifier),
		"hesitate": _should_hesitate(modifier)
	}


## Force an imperfection (for testing/scripted moments)
func force_imperfection(type: ImperfectionType, magnitude: float = -1.0) -> void:
	if magnitude < 0:
		magnitude = _get_imperfection_magnitude(type)

	_execute_imperfection(type, magnitude)
	imperfection_triggered.emit(ImperfectionType.keys()[type], magnitude)


## Reset operator to fresh state
func reset_operator() -> void:
	fatigue = 0.0
	stress = 0.0
	active_time = 0.0
	operator_state = OperatorState.ALERT
	recent_imperfections.clear()


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			is_active = true
		GameEnums.GameState.MAIN_MENU:
			is_active = false
			reset_operator()
		GameEnums.GameState.PAUSED:
			is_active = false


func _on_descent_ready() -> void:
	is_active = true
	reset_operator()


# =============================================================================
# QUERIES
# =============================================================================

func get_operator_state() -> OperatorState:
	return operator_state


func get_fatigue() -> float:
	return fatigue


func get_stress() -> float:
	return stress


func get_summary() -> Dictionary:
	return {
		"operator_state": OperatorState.keys()[operator_state],
		"fatigue": fatigue,
		"stress": stress,
		"active_time": active_time,
		"skill_level": skill_level,
		"drift": drift_offset.length(),
		"is_active": is_active
	}
