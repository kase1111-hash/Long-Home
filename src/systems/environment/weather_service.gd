class_name WeatherService
extends Node
## Manages weather state and transitions
## No explicit forecast - players read the environment
##
## Design Philosophy:
## - Weather is observed, not predicted by UI
## - Cloud patterns, wind changes indicate transitions
## - Weather windows are generated at run start, from the weather, wind and
##   stability the run starts with (StartConditions): the first window is
##   that weather, and the day moves on from it a step at a time
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
		# Handle midnight wrapping (e.g., start=22, end=2 means 22:00-02:00)
		if end_time > start_time:
			# Normal case: window doesn't cross midnight
			return current_time >= start_time and current_time < end_time
		else:
			# Window wraps around midnight
			return current_time >= start_time or current_time < end_time


# =============================================================================
# THE DAY'S WEATHER
# =============================================================================

## Weather from best to worst: a window's weather moves along this a step at
## a time. SNOW (steady snowfall) shares a rung with DETERIORATING.
const WEATHER_LADDER: Array[GameEnums.WeatherState] = [
	GameEnums.WeatherState.CLEAR,
	GameEnums.WeatherState.PARTLY_CLOUDY,
	GameEnums.WeatherState.CLOUDY,
	GameEnums.WeatherState.OVERCAST,
	GameEnums.WeatherState.DETERIORATING,
	GameEnums.WeatherState.STORM,
	GameEnums.WeatherState.WHITEOUT,
]
const SNOW_RUNG := 4

## The two wind strengths typical of each kind of weather (lighter, stronger)
const WINDOW_WINDS := {
	GameEnums.WeatherState.CLEAR: [GameEnums.WindStrength.CALM, GameEnums.WindStrength.LIGHT],
	GameEnums.WeatherState.PARTLY_CLOUDY: [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE],
	GameEnums.WeatherState.CLOUDY: [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE],
	GameEnums.WeatherState.CLEARING: [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE],
	GameEnums.WeatherState.OVERCAST: [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE],
	GameEnums.WeatherState.SNOW: [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE],
	GameEnums.WeatherState.DETERIORATING: [GameEnums.WindStrength.MODERATE, GameEnums.WindStrength.STRONG],
	GameEnums.WeatherState.STORM: [GameEnums.WindStrength.STRONG, GameEnums.WindStrength.GALE],
	GameEnums.WeatherState.WHITEOUT: [GameEnums.WindStrength.GALE, GameEnums.WindStrength.SEVERE],
}

## A window lasts this many game hours (a game hour is six real minutes):
## long enough to read the sky, short enough that a day can turn in one descent
const WINDOW_HOURS_MIN := 1.0
const WINDOW_HOURS_MAX := 2.0
## Chance that a window is a step worse than the last, on a day with no stability at all
const WORSEN_RATE := 0.75
## Chance that it is a step better, on a perfectly settled day
const IMPROVE_RATE := 0.25
const MAX_WORSEN_CHANCE := 0.9
## How much of a day's stability a mountain with the most volatile weather wears away
const VOLATILITY_WEAR := 0.35
## A storm closes in to a whiteout this much less readily than weather worsens otherwise
const WHITEOUT_SHARE := 0.25
## Chance per window that a whiteout lifts back to a storm
const WHITEOUT_LIFT_CHANCE := 0.5

## How settled today is, 0-1 (the day's stability after the mountain's volatility)
var day_stability: float = 0.6


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


## Lay out the day's weather from where it stands when the run starts.
##
## The first window is the weather and wind the run starts in; each later one
## holds, worsens by a step or improves by a step (WEATHER_LADDER). How often
## it holds is the day's stability, worn down by a mountain whose weather
## turns fast, and the afternoon is less settled than the morning.
##   stability: 0-1 (StartConditions.weather_stability)
##   volatility: 0-1, how fast this mountain's weather turns (MountainData)
##   exposure: 0-1, how open the mountain is to the wind (MountainData)
func generate_weather_windows(start_hour: float, start_weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR,
		start_wind: GameEnums.WindStrength = GameEnums.WindStrength.LIGHT, stability: float = 0.6,
		volatility: float = 0.3, exposure: float = 0.5) -> void:
	weather_windows.clear()
	day_stability = clampf(stability * (1.0 - VOLATILITY_WEAR * clampf(volatility, 0.0, 1.0)), 0.0, 1.0)

	var weather := start_weather
	var wind := start_wind
	var hour := start_hour
	var day_end := start_hour + 24.0
	while hour < day_end - 0.01:
		var length := minf(randf_range(WINDOW_HOURS_MIN, WINDOW_HOURS_MAX), day_end - hour)
		# No sliver of a window at the end of the day
		if day_end - (hour + length) < WINDOW_HOURS_MIN * 0.5:
			length = day_end - hour
		var window := WeatherWindow.new()
		window.start_time = fposmod(hour, 24.0)
		window.end_time = fposmod(hour + length, 24.0)
		window.weather = weather
		window.wind_strength = wind
		window.intensity = randf_range(0.5, 1.0)
		weather_windows.append(window)

		hour += length
		weather = _next_window_weather(weather, day_stability, fposmod(hour, 24.0))
		wind = _next_window_wind(weather, wind, exposure)

	current_window_index = 0
	_apply_window(weather_windows[0])


## The weather that follows a window: the same, a step worse or a step better
func _next_window_weather(weather: GameEnums.WeatherState, stability: float, hour: float) -> GameEnums.WeatherState:
	var worse_chance := (1.0 - stability) * WORSEN_RATE
	# Afternoon build-up
	if hour >= 12.0 and hour < 20.0:
		worse_chance *= afternoon_instability
	var better_chance := stability * IMPROVE_RATE
	match weather:
		GameEnums.WeatherState.STORM:
			# A storm closes in to a whiteout less often than cloud thickens
			worse_chance *= WHITEOUT_SHARE
		GameEnums.WeatherState.WHITEOUT:
			# Whiteouts come in waves
			better_chance = maxf(better_chance, WHITEOUT_LIFT_CHANCE)
	worse_chance = minf(worse_chance, MAX_WORSEN_CHANCE)

	var roll := randf()
	if roll < worse_chance:
		return step_weather(weather, 1, stability)
	if roll < worse_chance + better_chance:
		return step_weather(weather, -1, stability)
	return weather


## The wind that goes with a window's weather: one of the two strengths
## typical of it (the stronger more often on an exposed mountain), reached
## from the last window's wind a step at a time
func _next_window_wind(weather: GameEnums.WeatherState, previous: GameEnums.WindStrength, exposure: float) -> GameEnums.WindStrength:
	var typical: Array = WINDOW_WINDS.get(weather, [GameEnums.WindStrength.LIGHT, GameEnums.WindStrength.MODERATE])
	var target: int = typical[1] if randf() < 0.2 + 0.6 * clampf(exposure, 0.0, 1.0) else typical[0]
	return clampi(target, int(previous) - 1, int(previous) + 1) as GameEnums.WindStrength


## Weather one step worse (direction 1) or better (-1) than a state. Thick
## cloud turns to steady snowfall on a settled day and to the leading edge of
## a storm (DETERIORATING) on an unsettled one.
static func step_weather(weather: GameEnums.WeatherState, direction: int, stability: float = 0.5) -> GameEnums.WeatherState:
	var rung := weather_rung(weather)
	var next := clampi(rung + signi(direction), 0, WEATHER_LADDER.size() - 1)
	if next == rung:
		return weather
	if next == SNOW_RUNG:
		if direction < 0:
			return GameEnums.WeatherState.SNOW
		return GameEnums.WeatherState.SNOW if stability >= 0.5 else GameEnums.WeatherState.DETERIORATING
	return WEATHER_LADDER[next]


## Where a weather state stands on WEATHER_LADDER (0 = clear)
static func weather_rung(weather: GameEnums.WeatherState) -> int:
	match weather:
		GameEnums.WeatherState.SNOW:
			return SNOW_RUNG
		GameEnums.WeatherState.CLEARING:
			return WEATHER_LADDER.find(GameEnums.WeatherState.CLOUDY)
	return maxi(WEATHER_LADDER.find(weather), 0)


## Put the weather into a clean, settled state for a new run
func reset_for_run(start_weather: GameEnums.WeatherState) -> void:
	current_weather = start_weather
	target_weather = start_weather
	is_transitioning = false
	transition_progress = 1.0
	precipitation = _get_precipitation_for_weather(start_weather)
	cloud_cover = _get_cloud_cover_for_weather(start_weather)
	visibility = _calculate_visibility()
	target_wind_direction = wind_direction
	current_window_index = 0
	print("[WeatherService] Reset for run: %s" % GameEnums.WeatherState.keys()[start_weather])


## The day's weather as plain data, for a suspended run's save file
func to_save() -> Dictionary:
	var windows: Array = []
	for window in weather_windows:
		windows.append({
			"start": window.start_time,
			"end": window.end_time,
			"weather": int(window.weather),
			"wind": int(window.wind_strength),
			"intensity": window.intensity,
		})
	return {
		# A change that is under way is saved as arrived
		"weather": int(target_weather if is_transitioning else current_weather),
		"wind": int(current_wind_strength),
		"wind_direction": wind_direction,
		"day_stability": day_stability,
		"windows": windows,
	}


## Put the day's weather back as to_save() found it. hour: the time of day,
## which decides which window the day is in (it is not applied again: the
## weather saved may have drifted from it).
func restore(data: Dictionary, hour: float) -> void:
	var weather := int(data.get("weather", current_weather))
	if weather < 0 or weather >= GameEnums.WeatherState.size():
		weather = int(current_weather)
	reset_for_run(weather as GameEnums.WeatherState)
	var wind := int(data.get("wind", current_wind_strength))
	if wind >= 0 and wind < GameEnums.WindStrength.size():
		_set_wind_strength(wind as GameEnums.WindStrength)
	if data.get("wind_direction") is Vector3 and (data["wind_direction"] as Vector3).length_squared() > 0.01:
		wind_direction = (data["wind_direction"] as Vector3).normalized()
		target_wind_direction = wind_direction
	day_stability = clampf(float(data.get("day_stability", day_stability)), 0.0, 1.0)

	weather_windows.clear()
	var saved: Variant = data.get("windows")
	if saved is Array:
		for entry in saved:
			if not (entry is Dictionary):
				continue
			var window_weather := int(entry.get("weather", -1))
			var window_wind := int(entry.get("wind", -1))
			if window_weather < 0 or window_weather >= GameEnums.WeatherState.size() \
					or window_wind < 0 or window_wind >= GameEnums.WindStrength.size():
				continue
			var window := WeatherWindow.new()
			window.start_time = fposmod(float(entry.get("start", 0.0)), 24.0)
			window.end_time = fposmod(float(entry.get("end", 0.0)), 24.0)
			window.weather = window_weather as GameEnums.WeatherState
			window.wind_strength = window_wind as GameEnums.WindStrength
			window.intensity = clampf(float(entry.get("intensity", 1.0)), 0.0, 1.0)
			weather_windows.append(window)
	current_window_index = 0
	for i in range(weather_windows.size()):
		if weather_windows[i].is_active(hour):
			current_window_index = i
			break


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
	return step_weather(weather, 1, day_stability)


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
		GameEnums.WindStrength.GALE:
			return 23.0
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
		GameEnums.WindStrength.GALE:
			return 0.6
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
		GameEnums.WeatherState.PARTLY_CLOUDY:
			return 0.3
		GameEnums.WeatherState.CLOUDY:
			return 0.5
		GameEnums.WeatherState.OVERCAST:
			return 0.8
		GameEnums.WeatherState.DETERIORATING:
			return 0.8
		GameEnums.WeatherState.SNOW:
			return 0.9
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
		GameEnums.WeatherState.DETERIORATING, GameEnums.WeatherState.SNOW:
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
