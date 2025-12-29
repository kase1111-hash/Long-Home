class_name FatigueManager
extends Node
## Manages fatigue accumulation and effects
## Fatigue is the core physical limitation in descent
##
## Design Philosophy:
## - Fatigue is felt through movement and audio cues
## - No stamina bar - players learn their limits
## - Recovery is slow and situational
## - Fatigue affects everything else

# =============================================================================
# SIGNALS
# =============================================================================

signal fatigue_changed(fatigue: float)
signal threshold_crossed(threshold_name: String, fatigue: float)
signal breathing_changed(intensity: float)
signal critical_fatigue()
signal collapse_imminent()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Base Rates")
## Base fatigue rate per second when moving
@export var base_fatigue_rate: float = 0.001
## Recovery rate per second when resting
@export var base_recovery_rate: float = 0.005

@export_group("Modifiers")
## Fatigue multiplier for running/fast movement
@export var speed_multiplier: float = 2.5
## Fatigue per degree of slope over threshold
@export var slope_fatigue_per_degree: float = 0.05
## Slope threshold for extra fatigue
@export var slope_threshold: float = 20.0
## Weight fatigue multiplier (per kg over base)
@export var weight_fatigue_per_kg: float = 0.02
## Base weight (no penalty)
@export var base_weight: float = 10.0

@export_group("Thresholds")
## Fatigue level for breathing changes
@export var breathing_threshold: float = 0.3
## Fatigue level for movement slowing
@export var movement_threshold: float = 0.5
## Fatigue level for input delay
@export var input_delay_threshold: float = 0.7
## Critical fatigue level
@export var critical_threshold: float = 0.9
## Collapse fatigue level
@export var collapse_threshold: float = 1.0

# =============================================================================
# STATE
# =============================================================================

## Reference to body state
var body_state: BodyState

## Current activity level (0 = resting, 1 = max exertion)
var activity_level: float = 0.0

## Current slope angle
var current_slope: float = 0.0

## Current carried weight
var carried_weight: float = 15.0

## Is player resting
var is_resting: bool = false

## Last crossed threshold (for change detection)
var last_threshold: String = ""

## Breathing intensity (for audio feedback)
var breathing_intensity: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.register_service("FatigueManager", self)


## Set body state reference
func set_body_state(state: BodyState) -> void:
	body_state = state


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if body_state == null:
		return

	if is_resting:
		_apply_recovery(delta)
	else:
		_apply_fatigue(delta)

	_update_breathing()
	_check_thresholds()


func _apply_fatigue(delta: float) -> void:
	var rate := _calculate_fatigue_rate()
	var amount := rate * delta

	# Apply body state modifiers
	amount *= body_state.get_fatigue_rate_modifier()

	body_state.add_fatigue(amount)
	fatigue_changed.emit(body_state.fatigue)


func _apply_recovery(delta: float) -> void:
	var recovery := base_recovery_rate * delta

	# Slower recovery when conditions are poor
	if body_state.cold_exposure > 0.5:
		recovery *= 0.5

	# Injuries slow recovery
	for injury in body_state.injuries:
		recovery *= injury.get_capability_modifier("recovery_rate")

	body_state.recover_fatigue(recovery)
	fatigue_changed.emit(body_state.fatigue)


func _calculate_fatigue_rate() -> float:
	var rate := base_fatigue_rate

	# Activity level (movement speed)
	rate *= 1.0 + activity_level * (speed_multiplier - 1.0)

	# Slope effect
	if current_slope > slope_threshold:
		var slope_extra := current_slope - slope_threshold
		rate *= 1.0 + slope_extra * slope_fatigue_per_degree

	# Weight effect
	if carried_weight > base_weight:
		var extra_weight := carried_weight - base_weight
		rate *= 1.0 + extra_weight * weight_fatigue_per_kg

	# Altitude effect (would integrate with environment)
	# Higher altitude = faster fatigue due to thin air

	return rate


func _update_breathing() -> void:
	var target_breathing := 0.0

	if body_state.fatigue > breathing_threshold:
		target_breathing = (body_state.fatigue - breathing_threshold) / (1.0 - breathing_threshold)

	# Activity also affects breathing
	target_breathing = maxf(target_breathing, activity_level * 0.5)

	breathing_intensity = lerpf(breathing_intensity, target_breathing, 0.1)
	breathing_changed.emit(breathing_intensity)


func _check_thresholds() -> void:
	var fatigue := body_state.fatigue
	var current_threshold := ""

	if fatigue >= collapse_threshold:
		current_threshold = "collapse"
	elif fatigue >= critical_threshold:
		current_threshold = "critical"
	elif fatigue >= input_delay_threshold:
		current_threshold = "input_delay"
	elif fatigue >= movement_threshold:
		current_threshold = "movement_slow"
	elif fatigue >= breathing_threshold:
		current_threshold = "breathing_change"

	if current_threshold != last_threshold and current_threshold != "":
		last_threshold = current_threshold
		threshold_crossed.emit(current_threshold, fatigue)
		EventBus.fatigue_threshold_crossed.emit(fatigue, current_threshold)

		if current_threshold == "critical":
			critical_fatigue.emit()
		elif current_threshold == "collapse":
			collapse_imminent.emit()


# =============================================================================
# INPUT FROM OTHER SYSTEMS
# =============================================================================

## Set current activity level (from movement system)
func set_activity_level(level: float) -> void:
	activity_level = clampf(level, 0.0, 1.0)
	is_resting = level < 0.05


## Set current slope (from terrain system)
func set_slope(angle: float) -> void:
	current_slope = angle


## Set carried weight (from gear system)
func set_weight(weight: float) -> void:
	carried_weight = weight


## Apply burst fatigue (from actions like jumping, sliding)
func apply_burst_fatigue(amount: float) -> void:
	if body_state:
		body_state.add_fatigue(amount)
		fatigue_changed.emit(body_state.fatigue)


## Force rest state
func start_resting() -> void:
	is_resting = true
	activity_level = 0.0


## End rest state
func stop_resting() -> void:
	is_resting = false


# =============================================================================
# QUERIES
# =============================================================================

## Get current fatigue level
func get_fatigue() -> float:
	if body_state:
		return body_state.fatigue
	return 0.0


## Get fatigue as percentage
func get_fatigue_percent() -> float:
	return get_fatigue() * 100.0


## Get movement speed modifier from fatigue
func get_movement_modifier() -> float:
	if body_state == null:
		return 1.0

	var fatigue := body_state.fatigue
	if fatigue < movement_threshold:
		return 1.0

	# Linear reduction from threshold to collapse
	var reduction := (fatigue - movement_threshold) / (collapse_threshold - movement_threshold)
	return 1.0 - reduction * 0.5  # Up to 50% slower


## Get input delay from fatigue
func get_input_delay() -> float:
	if body_state == null:
		return 0.0

	var fatigue := body_state.fatigue
	if fatigue < input_delay_threshold:
		return 0.0

	# Up to 0.15s delay at max fatigue
	return (fatigue - input_delay_threshold) / (collapse_threshold - input_delay_threshold) * 0.15


## Get camera sway amount
func get_camera_sway() -> float:
	if body_state == null:
		return 0.0
	return body_state.get_camera_sway()


## Check if at critical fatigue
func is_critical() -> bool:
	return get_fatigue() >= critical_threshold


## Check if collapse is imminent
func is_collapse_imminent() -> bool:
	return get_fatigue() >= collapse_threshold * 0.95


## Get time until collapse at current rate (seconds)
func get_time_until_collapse() -> float:
	if body_state == null or is_resting:
		return INF

	var remaining := collapse_threshold - body_state.fatigue
	var rate := _calculate_fatigue_rate() * body_state.get_fatigue_rate_modifier()

	if rate <= 0:
		return INF

	return remaining / rate


## Get summary for debug/UI
func get_summary() -> Dictionary:
	return {
		"fatigue": get_fatigue(),
		"activity_level": activity_level,
		"is_resting": is_resting,
		"breathing": breathing_intensity,
		"time_to_collapse": get_time_until_collapse(),
		"movement_modifier": get_movement_modifier(),
		"is_critical": is_critical()
	}
