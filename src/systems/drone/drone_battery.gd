class_name DroneBattery
extends Node
## Manages drone battery life and signal strength
## Battery affects flight time; signal affects video quality
##
## Design Philosophy:
## - Battery is a real constraint, not a game mechanic
## - Cold and wind drain battery faster
## - Signal degrades with distance and terrain occlusion
## - Low battery/signal affects camera quality

# =============================================================================
# SIGNALS
# =============================================================================

signal battery_changed(level: float)
signal battery_low(level: float)
signal battery_critical(level: float)
signal battery_dead()
signal signal_changed(strength: float)
signal signal_lost()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Battery")
## Maximum battery capacity (seconds of flight)
@export var max_battery: float = 1800.0  # 30 minutes
## Base drain rate (per second)
@export var base_drain_rate: float = 1.0
## Cold drain multiplier (at -20°C)
@export var cold_drain_max: float = 2.0
## Wind drain multiplier (at max wind)
@export var wind_drain_max: float = 1.5
## Low battery threshold
@export var low_threshold: float = 0.3
## Critical battery threshold
@export var critical_threshold: float = 0.1

@export_group("Signal")
## Maximum signal range (m)
@export var max_signal_range: float = 200.0
## Optimal signal range (m)
@export var optimal_range: float = 50.0
## Signal strength at max range
@export var min_signal_strength: float = 0.2
## Terrain occlusion factor
@export var occlusion_penalty: float = 0.3

# =============================================================================
# STATE
# =============================================================================

## Current battery level (0-1)
var battery_level: float = 1.0

## Current drain multiplier
var drain_multiplier: float = 1.0

## Is draining active
var is_draining: bool = false

## Current signal strength (0-1)
var signal_strength: float = 1.0

## Is signal lost
var signal_lost_flag: bool = false

## Weather service reference (for temperature/wind)
var weather_service: WeatherService

## Last low battery warning time
var last_low_warning: float = 0.0

## Last critical warning time
var last_critical_warning: float = 0.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("WeatherService", func(s): weather_service = s)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	if not is_draining:
		return

	_update_drain(delta)
	_check_thresholds()


func _update_drain(delta: float) -> void:
	var drain := base_drain_rate * drain_multiplier

	# Environmental modifiers
	if weather_service:
		# Cold effect
		var temp := weather_service.get_conditions_summary().get("temperature", 0.0)
		if temp < 0:
			var cold_factor := clampf(absf(temp) / 20.0, 0.0, 1.0)
			drain *= 1.0 + cold_factor * (cold_drain_max - 1.0)

		# Wind effect
		var wind_speed: float = weather_service.wind_speed
		var wind_factor := clampf(wind_speed / 25.0, 0.0, 1.0)
		drain *= 1.0 + wind_factor * (wind_drain_max - 1.0)

	# Apply drain
	var drain_amount := drain * delta / max_battery
	battery_level = maxf(0.0, battery_level - drain_amount)

	battery_changed.emit(battery_level)


func _check_thresholds() -> void:
	var current_time := Time.get_ticks_msec() / 1000.0

	if battery_level <= 0.0:
		is_draining = false
		battery_dead.emit()
		return

	if battery_level <= critical_threshold:
		if current_time - last_critical_warning > 30.0:
			battery_critical.emit(battery_level)
			last_critical_warning = current_time

	elif battery_level <= low_threshold:
		if current_time - last_low_warning > 60.0:
			battery_low.emit(battery_level)
			last_low_warning = current_time


# =============================================================================
# CONTROL
# =============================================================================

## Start battery drain
func start_drain() -> void:
	is_draining = true


## Stop battery drain
func stop_drain() -> void:
	is_draining = false


## Set drain multiplier
func set_drain_multiplier(multiplier: float) -> void:
	drain_multiplier = maxf(0.1, multiplier)


## Charge battery (when docked)
func charge(amount: float) -> void:
	battery_level = minf(1.0, battery_level + amount)
	battery_changed.emit(battery_level)


## Set battery level directly (for initialization)
func set_level(level: float) -> void:
	battery_level = clampf(level, 0.0, 1.0)
	battery_changed.emit(battery_level)


# =============================================================================
# SIGNAL STRENGTH
# =============================================================================

## Calculate signal strength based on distance
func get_signal_strength(distance: float) -> float:
	if distance <= optimal_range:
		signal_strength = 1.0
	elif distance >= max_signal_range:
		signal_strength = min_signal_strength
	else:
		# Linear falloff
		var falloff := (distance - optimal_range) / (max_signal_range - optimal_range)
		signal_strength = lerpf(1.0, min_signal_strength, falloff)

	# Battery affects signal
	if battery_level < 0.2:
		signal_strength *= battery_level / 0.2

	# Check for signal loss
	if signal_strength < 0.1:
		if not signal_lost_flag:
			signal_lost_flag = true
			signal_lost.emit()
			EventBus.drone_signal_lost.emit()
	else:
		signal_lost_flag = false

	signal_changed.emit(signal_strength)
	return signal_strength


## Calculate signal with terrain occlusion
func get_signal_with_occlusion(distance: float, occluded: bool) -> float:
	var base_signal := get_signal_strength(distance)

	if occluded:
		base_signal *= (1.0 - occlusion_penalty)

	return base_signal


# =============================================================================
# QUERIES
# =============================================================================

## Get current battery level (0-1)
func get_level() -> float:
	return battery_level


## Get battery as percentage
func get_percentage() -> float:
	return battery_level * 100.0


## Get remaining time in seconds
func get_remaining_time() -> float:
	if not is_draining or base_drain_rate <= 0:
		return INF

	var drain := base_drain_rate * drain_multiplier
	return (battery_level * max_battery) / drain


## Check if battery is low
func is_low() -> bool:
	return battery_level <= low_threshold


## Check if battery is critical
func is_critical() -> bool:
	return battery_level <= critical_threshold


## Check if battery is dead
func is_dead() -> bool:
	return battery_level <= 0.0


## Check if signal is lost
func is_signal_lost() -> bool:
	return signal_lost_flag


func get_summary() -> Dictionary:
	return {
		"level": battery_level,
		"percentage": get_percentage(),
		"remaining_time": get_remaining_time(),
		"is_draining": is_draining,
		"drain_multiplier": drain_multiplier,
		"signal_strength": signal_strength,
		"is_low": is_low(),
		"is_critical": is_critical()
	}
