class_name FatalityDetector
extends Node
## Detects conditions that lead to fatal outcomes
## Separate from FatalEventManager to allow prediction
##
## Detection Types:
## - Immediate: Impact, long fall
## - Threshold: Accumulated injury, exposure
## - Contextual: Terminal slide, no exit zone

# =============================================================================
# SIGNALS
# =============================================================================

signal fatal_condition_detected(trigger: FatalEventManager.FatalTrigger, severity: float)
signal near_fatal_detected(trigger: FatalEventManager.FatalTrigger, margin: float)
signal condition_cleared(trigger: FatalEventManager.FatalTrigger)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Impact Detection")
## Force threshold for instant death (Gs)
@export var instant_death_force: float = 50.0
## Force threshold for near-fatal (Gs)
@export var near_fatal_force: float = 30.0
## Minimum impact duration to register (seconds)
@export var impact_duration_threshold: float = 0.05

@export_group("Fall Detection")
## Fall distance that is unsurvivable (meters)
@export var unsurvivable_fall: float = 30.0
## Fall distance that is dangerous (meters)
@export var dangerous_fall: float = 15.0
## Impact surface affects survival
@export var surface_survival_modifiers: Dictionary = {
	"SNOW_SOFT": 1.5,   # More survivable
	"SNOW_POWDER": 1.8,
	"SNOW_FIRM": 1.0,
	"ICE": 0.6,         # Less survivable
	"ROCK": 0.5,
	"ROCK_WET": 0.4
}

@export_group("Slide Detection")
## Speed with no exit that is fatal (m/s)
@export var terminal_slide_speed: float = 25.0
## Speed threshold for concern (m/s)
@export var dangerous_slide_speed: float = 18.0
## Distance to cliff/drop that triggers terminal (m)
@export var terminal_cliff_distance: float = 5.0

@export_group("Exposure Detection")
## Cold level that is fatal
@export var fatal_cold_level: float = 1.0
## Cold level that is dangerous
@export var dangerous_cold_level: float = 0.8
## Time at dangerous cold before fatal (seconds)
@export var cold_fatal_duration: float = 120.0

@export_group("Injury Detection")
## Total severity that is fatal
@export var fatal_injury_total: float = 2.5
## Single injury severity that is fatal
@export var fatal_single_injury: float = 0.95

# =============================================================================
# STATE
# =============================================================================

## Player reference
var player: PlayerController

## Fatal event manager reference
var fatal_manager: FatalEventManager

## Current monitored conditions
var active_conditions: Dictionary = {}  # trigger -> severity

## Time spent at dangerous cold
var cold_danger_time: float = 0.0

## Is fall in progress
var is_falling: bool = false
var fall_start_height: float = 0.0
var fall_start_time: float = 0.0

## Current slide state
var is_sliding: bool = false
var slide_speed: float = 0.0
var cliff_distance: float = INF

## Detection active
var is_active: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("FatalityDetector", self)
	ServiceLocator.get_service_async("PlayerController", func(p): player = p)
	ServiceLocator.get_service_async("FatalEventManager", func(m): fatal_manager = m)

	_connect_events()
	print("[FatalityDetector] Initialized")


func _connect_events() -> void:
	EventBus.player_movement_changed.connect(_on_movement_changed)
	EventBus.player_position_updated.connect(_on_position_updated)
	EventBus.body_state_updated.connect(_on_body_state_updated)
	EventBus.injury_occurred.connect(_on_injury_occurred)
	EventBus.slide_started.connect(_on_slide_started)
	EventBus.slide_ended.connect(_on_slide_ended)
	EventBus.slide_state_updated.connect(_on_slide_state_updated)
	EventBus.cliff_proximity_changed.connect(_on_cliff_proximity)
	EventBus.game_state_changed.connect(_on_game_state_changed)


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if not is_active:
		return

	_update_fall_detection(delta)
	_update_cold_detection(delta)
	_update_slide_detection(delta)


func _update_fall_detection(delta: float) -> void:
	if not is_falling or player == null:
		return

	var current_height := player.global_position.y
	var fall_distance := fall_start_height - current_height

	# Check for near-fatal
	if fall_distance > dangerous_fall and fall_distance < unsurvivable_fall:
		_update_condition(FatalEventManager.FatalTrigger.FALL, fall_distance / unsurvivable_fall)
		near_fatal_detected.emit(FatalEventManager.FatalTrigger.FALL, unsurvivable_fall - fall_distance)


func _update_cold_detection(delta: float) -> void:
	if player == null or player.body_state == null:
		return

	var cold := player.body_state.cold_exposure

	if cold >= dangerous_cold_level:
		cold_danger_time += delta

		# Time-based fatality
		if cold_danger_time >= cold_fatal_duration:
			_trigger_fatal(FatalEventManager.FatalTrigger.EXPOSURE)
		elif cold >= fatal_cold_level:
			_trigger_fatal(FatalEventManager.FatalTrigger.EXPOSURE)
		else:
			# Near fatal warning
			var severity := cold / fatal_cold_level
			_update_condition(FatalEventManager.FatalTrigger.EXPOSURE, severity)
			near_fatal_detected.emit(FatalEventManager.FatalTrigger.EXPOSURE, 1.0 - severity)
	else:
		cold_danger_time = maxf(0, cold_danger_time - delta * 2)  # Recover faster
		_clear_condition(FatalEventManager.FatalTrigger.EXPOSURE)


func _update_slide_detection(delta: float) -> void:
	if not is_sliding:
		return

	# Check for terminal slide
	if slide_speed >= terminal_slide_speed and cliff_distance < terminal_cliff_distance:
		_trigger_fatal(FatalEventManager.FatalTrigger.TERMINAL_SLIDE)
	elif slide_speed >= dangerous_slide_speed:
		var severity := slide_speed / terminal_slide_speed
		_update_condition(FatalEventManager.FatalTrigger.TERMINAL_SLIDE, severity)

		if cliff_distance < terminal_cliff_distance * 2:
			near_fatal_detected.emit(
				FatalEventManager.FatalTrigger.TERMINAL_SLIDE,
				cliff_distance
			)


# =============================================================================
# IMMEDIATE DETECTION
# =============================================================================

## Check impact for fatality
func check_impact(force: float, surface: GameEnums.SurfaceType, position: Vector3) -> void:
	var modifier := surface_survival_modifiers.get(
		GameEnums.SurfaceType.keys()[surface],
		1.0
	)

	var effective_force := force / modifier

	if effective_force >= instant_death_force:
		_trigger_fatal_at(FatalEventManager.FatalTrigger.IMPACT, position)
	elif effective_force >= near_fatal_force:
		var severity := effective_force / instant_death_force
		_update_condition(FatalEventManager.FatalTrigger.IMPACT, severity)
		near_fatal_detected.emit(
			FatalEventManager.FatalTrigger.IMPACT,
			instant_death_force - effective_force
		)


## Check fall landing for fatality
func check_fall_landing(fall_distance: float, surface: GameEnums.SurfaceType, position: Vector3) -> void:
	is_falling = false

	var modifier := surface_survival_modifiers.get(
		GameEnums.SurfaceType.keys()[surface],
		1.0
	)

	var effective_distance := fall_distance / modifier

	if effective_distance >= unsurvivable_fall:
		_trigger_fatal_at(FatalEventManager.FatalTrigger.FALL, position)
	elif effective_distance >= dangerous_fall:
		var severity := effective_distance / unsurvivable_fall
		near_fatal_detected.emit(
			FatalEventManager.FatalTrigger.FALL,
			unsurvivable_fall - effective_distance
		)

	_clear_condition(FatalEventManager.FatalTrigger.FALL)


# =============================================================================
# CONDITION MANAGEMENT
# =============================================================================

func _update_condition(trigger: FatalEventManager.FatalTrigger, severity: float) -> void:
	var prev_severity: float = active_conditions.get(trigger, 0.0)

	if severity > prev_severity:
		active_conditions[trigger] = severity
		fatal_condition_detected.emit(trigger, severity)


func _clear_condition(trigger: FatalEventManager.FatalTrigger) -> void:
	if active_conditions.has(trigger):
		active_conditions.erase(trigger)
		condition_cleared.emit(trigger)


func _trigger_fatal(trigger: FatalEventManager.FatalTrigger) -> void:
	if fatal_manager and player:
		fatal_manager._trigger_fatal(trigger, player.global_position)


func _trigger_fatal_at(trigger: FatalEventManager.FatalTrigger, position: Vector3) -> void:
	if fatal_manager:
		fatal_manager._trigger_fatal(trigger, position)


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_movement_changed(old_state: GameEnums.PlayerMovementState, new_state: GameEnums.PlayerMovementState) -> void:
	# Track falling
	if new_state == GameEnums.PlayerMovementState.FALLING:
		is_falling = true
		if player:
			fall_start_height = player.global_position.y
		fall_start_time = Time.get_ticks_msec() / 1000.0
	elif old_state == GameEnums.PlayerMovementState.FALLING:
		# Fall ended - check landing
		if player:
			var fall_distance := fall_start_height - player.global_position.y
			var surface := player.current_cell.surface_type if player.current_cell else GameEnums.SurfaceType.ROCK_DRY
			check_fall_landing(fall_distance, surface, player.global_position)


func _on_position_updated(position: Vector3, velocity: Vector3) -> void:
	# Track for impact detection
	pass


func _on_body_state_updated(body_state: BodyState) -> void:
	if body_state == null:
		return

	# Check total injury
	var total_injury := 0.0
	for injury in body_state.injuries:
		total_injury += injury.severity

		# Check single severe injury
		if injury.severity >= fatal_single_injury:
			_trigger_fatal(FatalEventManager.FatalTrigger.ACCUMULATED_INJURY)
			return

	if total_injury >= fatal_injury_total:
		_trigger_fatal(FatalEventManager.FatalTrigger.ACCUMULATED_INJURY)
	elif total_injury >= fatal_injury_total * 0.8:
		var severity := total_injury / fatal_injury_total
		_update_condition(FatalEventManager.FatalTrigger.ACCUMULATED_INJURY, severity)
		near_fatal_detected.emit(
			FatalEventManager.FatalTrigger.ACCUMULATED_INJURY,
			fatal_injury_total - total_injury
		)


func _on_injury_occurred(injury: Injury) -> void:
	if injury.severity >= fatal_single_injury:
		if player:
			_trigger_fatal_at(FatalEventManager.FatalTrigger.ACCUMULATED_INJURY, player.global_position)


func _on_slide_started(entry_speed: float, slope_angle: float) -> void:
	is_sliding = true
	slide_speed = entry_speed


func _on_slide_ended(outcome: GameEnums.SlideOutcome, final_speed: float) -> void:
	is_sliding = false

	if outcome == GameEnums.SlideOutcome.TERMINAL_RUNOUT:
		if player:
			_trigger_fatal_at(FatalEventManager.FatalTrigger.TERMINAL_SLIDE, player.global_position)

	_clear_condition(FatalEventManager.FatalTrigger.TERMINAL_SLIDE)


func _on_slide_state_updated(control_level: float, speed: float, trajectory: Vector3) -> void:
	slide_speed = speed


func _on_cliff_proximity(distance: float) -> void:
	cliff_distance = distance


func _on_game_state_changed(_old: GameEnums.GameState, new_state: GameEnums.GameState) -> void:
	match new_state:
		GameEnums.GameState.DESCENT:
			is_active = true
			_reset()
		GameEnums.GameState.MAIN_MENU:
			is_active = false
			_reset()


func _reset() -> void:
	active_conditions.clear()
	cold_danger_time = 0.0
	is_falling = false
	is_sliding = false
	slide_speed = 0.0
	cliff_distance = INF


# =============================================================================
# QUERIES
# =============================================================================

func get_most_severe_condition() -> Dictionary:
	var most_severe: FatalEventManager.FatalTrigger = FatalEventManager.FatalTrigger.IMPACT
	var max_severity := 0.0

	for trigger in active_conditions:
		var severity: float = active_conditions[trigger]
		if severity > max_severity:
			max_severity = severity
			most_severe = trigger

	if max_severity > 0:
		return {
			"trigger": most_severe,
			"severity": max_severity
		}

	return {}


func is_near_fatal() -> bool:
	for trigger in active_conditions:
		if active_conditions[trigger] > 0.8:
			return true
	return false


func get_summary() -> Dictionary:
	return {
		"is_active": is_active,
		"active_conditions": active_conditions.size(),
		"most_severe": get_most_severe_condition(),
		"is_falling": is_falling,
		"is_sliding": is_sliding,
		"slide_speed": slide_speed,
		"cliff_distance": cliff_distance,
		"cold_danger_time": cold_danger_time
	}
