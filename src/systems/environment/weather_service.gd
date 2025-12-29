class_name WeatherService
extends Node
## Manages weather state and transitions
## No explicit forecast - players read the environment
##
## Design Philosophy:
## - Weather is observed, not predicted by UI
## - Cloud patterns, wind changes indicate transitions
## - Weather windows are generated at run start
## - Transitions are gradual, not instant

# =============================================================================
# SIGNALS
# =============================================================================

signal weather_changed(old_state: GameEnums.WeatherState, new_state: GameEnums.WeatherState)
signal weather_transitioning(from: GameEnums.WeatherState, to: GameEnums.WeatherState, progress: float)
signal wind_changed(old_strength: GameEnums.WindStrength, new_strength: GameEnums.WindStrength)
signal wind_direction_changed(direction: Vector3)
signal precipitation_started(type: PrecipitationType)
signal precipitation_stopped()
signal visibility_changed(visibility: float)
signal storm_warning()
signal whiteout_imminent()

# =============================================================================
# ENUMS
# =============================================================================

enum PrecipitationType {
	NONE,
	LIGHT_SNOW,
	HEAVY_SNOW,
	SLEET,
	FREEZING_RAIN
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Transition Timing")
## Base transition duration (seconds)
@export var base_transition_time: float = 60.0
## Storm approach time (seconds)
@export var storm_approach_time: float = 120.0
## Clearing time after storm (seconds)
@export var clearing_time: float = 180.0

@export_group("Probabilities")
## Base probability of weather change per game hour
@export var base_change_probability: float = 0.1
## Afternoon instability multiplier
@export var afternoon_instability: float = 1.5
## High elevation instability multiplier
@export var elevation_instability: float = 1.3

@export_group("Wind")
## Base wind speed (m/s)
@export var base_wind_speed: float = 5.0
## Maximum wind speed (m/s)
@export var max_wind_speed: float = 30.0
## Wind direction change rate (degrees/second)
@export var wind_direction_change_rate: float = 2.0

# =============================================================================
# STATE
# =============================================================================

## Current weather state
var current_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Target weather (during transition)
var target_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR

## Transition progress (0-1)
var transition_progress: float = 1.0

## Is transitioning
var is_transitioning: bool = false

## Current wind strength
var current_wind_strength: GameEnums.WindStrength = GameEnums.WindStrength.CALM

## Current wind speed (m/s)
var wind_speed: float = 3.0

## Current wind direction (normalized)
var wind_direction: Vector3 = Vector3(1, 0, 0)

## Target wind direction
var target_wind_direction: Vector3 = Vector3(1, 0, 0)

## Current precipitation type
var precipitation: PrecipitationType = PrecipitationType.NONE

## Current visibility (0-1)
var visibility: float = 1.0

## Cloud cover (0-1)
var cloud_cover: float = 0.0

## Time service reference
var time_service: TimeService

## Weather window (pre-generated for this run)
var weather_windows: Array[WeatherWindow] = []

## Current window index
var current_window_index: int = 0


# =============================================================================
# WEATHER WINDOW
# =============================================================================

class WeatherWindow:
	var start_time: float = 0.0
	var end_time: float = 24.0
	var weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR
	var intensity: float = 1.0
	var wind_strength: GameEnums.WindStrength = GameEnums.WindStrength.CALM

	func is_active(current_time: float) -> bool:
		return current_time >= start_time and current_time < end_time


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TimeService", _on_time_service_ready)
	ServiceLocator.register_service("WeatherService", self)
	print("[WeatherService] Initialized")


func _on_time_service_ready(service: Object) -> void:
	time_service = service as TimeService
	time_service.hour_changed.connect(_on_hour_changed)


## Generate weather windows for a run
func generate_weather_windows(start_hour: float, difficulty: float = 0.5) -> void:
	weather_windows.clear()

	# Generate windows based on difficulty
	var num_windows := 3 + int(difficulty * 4)  # 3-7 windows
	var window_duration := 24.0 / num_windows

	for i in range(num_windows):
		var window := WeatherWindow.new()
		window.start_time = start_hour + i * window_duration
		if window.start_time >= 24.0:
			window.start_time -= 24.0
		window.end_time = window.start_time + window_duration
		if window.end_time >= 24.0:
			window.end_time -= 24.0

		# Determine weather for this window
		window.weather = _generate_window_weather(i, num_windows, difficulty)
		window.wind_strength = _generate_window_wind(window.weather)
		window.intensity = 0.5 + randf() * 0.5

		weather_windows.append(window)

	current_window_index = 0
	_apply_window(weather_windows[0])


func _generate_window_weather(index: int, total: int, difficulty: float) -> GameEnums.WeatherState:
	# Early windows tend to be better
	var position_factor := float(index) / float(total)

	# Higher difficulty = worse weather more likely
	var bad_weather_chance := difficulty * 0.4 + position_factor * 0.3

	var roll := randf()
	if roll < 0.3 - bad_weather_chance * 0.2:
		return GameEnums.WeatherState.CLEAR
	elif roll < 0.6 - bad_weather_chance * 0.1:
		return GameEnums.WeatherState.CLOUDY
	elif roll < 0.8:
		return GameEnums.WeatherState.DETERIORATING
	elif roll < 0.95:
		return GameEnums.WeatherState.STORM
	else:
		return GameEnums.WeatherState.WHITEOUT


func _generate_window_wind(weather: GameEnums.WeatherState) -> GameEnums.WindStrength:
	match weather:
		GameEnums.WeatherState.CLEAR:
			return GameEnums.WindStrength.CALM if randf() < 0.7 else GameEnums.WindStrength.LIGHT
		GameEnums.WeatherState.CLOUDY:
			return GameEnums.WindStrength.LIGHT if randf() < 0.6 else GameEnums.WindStrength.MODERATE
		GameEnums.WeatherState.DETERIORATING:
			return GameEnums.WindStrength.MODERATE if randf() < 0.5 else GameEnums.WindStrength.STRONG
		GameEnums.WeatherState.STORM:
			return GameEnums.WindStrength.STRONG if randf() < 0.4 else GameEnums.WindStrength.SEVERE
		GameEnums.WeatherState.WHITEOUT:
			return GameEnums.WindStrength.SEVERE
		_:
			return GameEnums.WindStrength.LIGHT


func _apply_window(window: WeatherWindow) -> void:
	if window.weather != current_weather:
		_begin_transition(window.weather)

	_set_wind_strength(window.wind_strength)


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	# Update transition
	if is_transitioning:
		_update_transition(delta)

	# Update wind direction
	_update_wind(delta)

	# Update visibility
	_update_visibility()

	# Check weather windows
	_check_weather_windows()


func _update_transition(delta: float) -> void:
	var transition_time := _get_transition_time()
	transition_progress += delta / transition_time

	if transition_progress >= 1.0:
		transition_progress = 1.0
		_complete_transition()
	else:
		weather_transitioning.emit(current_weather, target_weather, transition_progress)
		_update_interpolated_values()


func _update_interpolated_values() -> void:
	# Interpolate cloud cover
	var target_clouds := _get_cloud_cover_for_weather(target_weather)
	var current_clouds := _get_cloud_cover_for_weather(current_weather)
	cloud_cover = lerpf(current_clouds, target_clouds, transition_progress)

	# Interpolate precipitation
	var target_precip := _get_precipitation_for_weather(target_weather)
	var current_precip := _get_precipitation_for_weather(current_weather)
	if transition_progress > 0.5 and precipitation != target_precip:
		precipitation = target_precip
		if target_precip != PrecipitationType.NONE:
			precipitation_started.emit(target_precip)
		else:
			precipitation_stopped.emit()


func _update_wind(delta: float) -> void:
	# Gradually shift wind direction
	var angle_diff := wind_direction.signed_angle_to(target_wind_direction, Vector3.UP)
	if absf(angle_diff) > 0.01:
		var rotation := signf(angle_diff) * minf(absf(angle_diff), deg_to_rad(wind_direction_change_rate) * delta)
		wind_direction = wind_direction.rotated(Vector3.UP, rotation).normalized()

	# Occasionally shift target wind direction
	if randf() < 0.001 * delta:
		var random_angle := randf_range(-PI / 4, PI / 4)
		target_wind_direction = target_wind_direction.rotated(Vector3.UP, random_angle).normalized()
		wind_direction_changed.emit(target_wind_direction)

	# Add gustiness based on weather
	var gust_factor := _get_gust_factor()
	var gust := sin(Time.get_ticks_msec() * 0.001 * 3.0) * gust_factor
	wind_speed = _get_base_wind_speed() * (1.0 + gust)


func _update_visibility() -> void:
	var target_visibility := _calculate_visibility()
	visibility = lerpf(visibility, target_visibility, 0.1)

	# Clamp and emit if significantly changed
	visibility = clampf(visibility, 0.0, 1.0)


func _check_weather_windows() -> void:
	if time_service == null or weather_windows.is_empty():
		return

	var current_time := time_service.current_time

	# Check if we need to move to next window
	for i in range(weather_windows.size()):
		if weather_windows[i].is_active(current_time):
			if i != current_window_index:
				current_window_index = i
				_apply_window(weather_windows[i])
			break


func _on_hour_changed(hour: int) -> void:
	# Random weather fluctuations
	if randf() < base_change_probability:
		_consider_weather_change()


func _consider_weather_change() -> void:
	# Small chance of unplanned weather shift
	var instability := 1.0

	# Afternoon is more unstable
	if time_service and time_service.current_time > 12.0:
		instability *= afternoon_instability

	if randf() < 0.1 * instability:
		# Minor shift toward worse weather
		var next_worse := _get_worse_weather(current_weather)
		if next_worse != current_weather:
			_begin_transition(next_worse)


# =============================================================================
# TRANSITIONS
# =============================================================================

func _begin_transition(new_weather: GameEnums.WeatherState) -> void:
	if new_weather == current_weather:
		return

	target_weather = new_weather
	transition_progress = 0.0
	is_transitioning = true

	# Emit warnings for dangerous weather
	if new_weather == GameEnums.WeatherState.STORM:
		storm_warning.emit()
	elif new_weather == GameEnums.WeatherState.WHITEOUT:
		whiteout_imminent.emit()


func _complete_transition() -> void:
	var old_weather := current_weather
	current_weather = target_weather
	is_transitioning = false

	weather_changed.emit(old_weather, current_weather)
	EventBus.weather_changed.emit(old_weather, current_weather)

	# Update precipitation
	precipitation = _get_precipitation_for_weather(current_weather)


func _get_transition_time() -> float:
	# Storms approach faster than they clear
	if target_weather == GameEnums.WeatherState.STORM or target_weather == GameEnums.WeatherState.WHITEOUT:
		return storm_approach_time
	elif current_weather == GameEnums.WeatherState.STORM or current_weather == GameEnums.WeatherState.WHITEOUT:
		return clearing_time
	else:
		return base_transition_time


func _get_worse_weather(weather: GameEnums.WeatherState) -> GameEnums.WeatherState:
	match weather:
		GameEnums.WeatherState.CLEAR:
			return GameEnums.WeatherState.CLOUDY
		GameEnums.WeatherState.CLOUDY:
			return GameEnums.WeatherState.DETERIORATING
		GameEnums.WeatherState.DETERIORATING:
			return GameEnums.WeatherState.STORM
		GameEnums.WeatherState.STORM:
			return GameEnums.WeatherState.WHITEOUT
		_:
			return weather


# =============================================================================
# WIND
# =============================================================================

func _set_wind_strength(strength: GameEnums.WindStrength) -> void:
	if strength != current_wind_strength:
		var old := current_wind_strength
		current_wind_strength = strength
		wind_changed.emit(old, strength)
		EventBus.wind_changed.emit(strength, wind_direction)


func _get_base_wind_speed() -> float:
	match current_wind_strength:
		GameEnums.WindStrength.CALM:
			return 2.0
		GameEnums.WindStrength.LIGHT:
			return 5.0
		GameEnums.WindStrength.MODERATE:
			return 10.0
		GameEnums.WindStrength.STRONG:
			return 18.0
		GameEnums.WindStrength.SEVERE:
			return 28.0
		_:
			return 5.0


func _get_gust_factor() -> float:
	match current_wind_strength:
		GameEnums.WindStrength.CALM:
			return 0.1
		GameEnums.WindStrength.LIGHT:
			return 0.2
		GameEnums.WindStrength.MODERATE:
			return 0.3
		GameEnums.WindStrength.STRONG:
			return 0.5
		GameEnums.WindStrength.SEVERE:
			return 0.7
		_:
			return 0.2


# =============================================================================
# WEATHER PROPERTIES
# =============================================================================

func _get_cloud_cover_for_weather(weather: GameEnums.WeatherState) -> float:
	match weather:
		GameEnums.WeatherState.CLEAR:
			return 0.1
		GameEnums.WeatherState.CLOUDY:
			return 0.5
		GameEnums.WeatherState.DETERIORATING:
			return 0.8
		GameEnums.WeatherState.STORM:
			return 1.0
		GameEnums.WeatherState.WHITEOUT:
			return 1.0
		GameEnums.WeatherState.CLEARING:
			return 0.4
		_:
			return 0.3


func _get_precipitation_for_weather(weather: GameEnums.WeatherState) -> PrecipitationType:
	match weather:
		GameEnums.WeatherState.CLEAR, GameEnums.WeatherState.CLOUDY:
			return PrecipitationType.NONE
		GameEnums.WeatherState.DETERIORATING:
			return PrecipitationType.LIGHT_SNOW
		GameEnums.WeatherState.STORM:
			return PrecipitationType.HEAVY_SNOW
		GameEnums.WeatherState.WHITEOUT:
			return PrecipitationType.HEAVY_SNOW
		_:
			return PrecipitationType.NONE


func _calculate_visibility() -> float:
	var base_vis := 1.0

	# Cloud cover reduces visibility
	base_vis -= cloud_cover * 0.2

	# Precipitation heavily reduces visibility
	match precipitation:
		PrecipitationType.LIGHT_SNOW:
			base_vis *= 0.7
		PrecipitationType.HEAVY_SNOW:
			base_vis *= 0.4
		PrecipitationType.SLEET:
			base_vis *= 0.5
		PrecipitationType.FREEZING_RAIN:
			base_vis *= 0.6

	# Wind-blown snow
	if precipitation != PrecipitationType.NONE:
		var wind_factor := wind_speed / max_wind_speed
		base_vis *= 1.0 - wind_factor * 0.3

	# Whiteout
	if current_weather == GameEnums.WeatherState.WHITEOUT:
		base_vis *= 0.1

	return clampf(base_vis, 0.05, 1.0)


# =============================================================================
# QUERIES
# =============================================================================

## Get current weather state
func get_weather() -> GameEnums.WeatherState:
	return current_weather


## Get wind as vector (direction * speed)
func get_wind_vector() -> Vector3:
	return wind_direction * wind_speed


## Check if weather is dangerous
func is_dangerous() -> bool:
	return current_weather == GameEnums.WeatherState.STORM or \
		   current_weather == GameEnums.WeatherState.WHITEOUT


## Check if precipitation active
func is_precipitating() -> bool:
	return precipitation != PrecipitationType.NONE


## Get visibility range in meters
func get_visibility_range() -> float:
	return visibility * 1000.0  # Base 1km visibility


## Get weather impact on surface conditions
func get_surface_impact() -> Dictionary:
	return {
		"snow_accumulation": precipitation == PrecipitationType.HEAVY_SNOW,
		"ice_formation": precipitation == PrecipitationType.FREEZING_RAIN,
		"wind_crust": wind_speed > 15.0 and precipitation != PrecipitationType.NONE,
		"drifting": wind_speed > 10.0 and precipitation == PrecipitationType.LIGHT_SNOW
	}


## Get current conditions summary
func get_conditions_summary() -> Dictionary:
	return {
		"weather": GameEnums.WeatherState.keys()[current_weather],
		"wind_strength": GameEnums.WindStrength.keys()[current_wind_strength],
		"wind_speed": wind_speed,
		"visibility": visibility,
		"cloud_cover": cloud_cover,
		"precipitation": PrecipitationType.keys()[precipitation],
		"is_transitioning": is_transitioning,
		"transition_target": GameEnums.WeatherState.keys()[target_weather] if is_transitioning else ""
	}
