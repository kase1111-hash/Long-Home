class_name TemperatureSystem
extends Node
## Calculates temperature based on time, elevation, and weather
## Manages thermal effects on player and environment
##
## Design Philosophy:
## - Temperature is felt, not displayed
## - Cold exposure builds gradually
## - Elevation significantly affects temperature
## - Wind chill is the real danger

# =============================================================================
# SIGNALS
# =============================================================================

signal temperature_changed(temperature: float, feels_like: float)
signal freezing_threshold_crossed(is_below: bool)
signal dangerous_cold_warning()
signal hypothermia_risk()

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Base Temperature")
## Base temperature at sea level at noon (Celsius)
@export var base_temperature: float = 15.0
## Temperature drop per 1000m elevation
@export var lapse_rate: float = 6.5
## Daily temperature variation (half amplitude)
@export var daily_variation: float = 8.0
## Hour of maximum temperature
@export var max_temp_hour: float = 14.0

@export_group("Weather Effects")
## Cloud cover temperature reduction
@export var cloud_cooling: float = 3.0
## Precipitation temperature reduction
@export var precipitation_cooling: float = 2.0
## Storm temperature reduction
@export var storm_cooling: float = 5.0

@export_group("Wind Chill")
## Wind chill calculation enabled
@export var wind_chill_enabled: bool = true
## Minimum temperature for wind chill effect
@export var wind_chill_threshold: float = 10.0

@export_group("Thresholds")
## Freezing point
@export var freezing_point: float = 0.0
## Dangerous cold threshold
@export var dangerous_cold: float = -15.0
## Extreme cold threshold
@export var extreme_cold: float = -25.0

# =============================================================================
# STATE
# =============================================================================

## Current air temperature (Celsius)
var air_temperature: float = 5.0

## Feels-like temperature (with wind chill)
var feels_like_temperature: float = 5.0

## Current elevation
var current_elevation: float = 3000.0

## Time service reference
var time_service: TimeService

## Weather service reference
var weather_service: WeatherService

## Was below freezing last check
var was_below_freezing: bool = false


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TimeService", _on_time_ready)
	ServiceLocator.get_service_async("WeatherService", _on_weather_ready)
	ServiceLocator.register_service("TemperatureSystem", self)
	print("[TemperatureSystem] Initialized")


func _on_time_ready(service: Object) -> void:
	time_service = service as TimeService


func _on_weather_ready(service: Object) -> void:
	weather_service = service as WeatherService


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_temperature()
	_check_thresholds()


func _update_temperature() -> void:
	air_temperature = _calculate_air_temperature()
	feels_like_temperature = _calculate_feels_like()

	temperature_changed.emit(air_temperature, feels_like_temperature)
	EventBus.temperature_changed.emit(air_temperature, feels_like_temperature)


func _calculate_air_temperature() -> float:
	var temp := base_temperature

	# Elevation adjustment (lapse rate)
	temp -= (current_elevation / 1000.0) * lapse_rate

	# Time of day variation
	if time_service:
		var hour := time_service.current_time
		# Cosine curve with minimum at 4am, maximum at 2pm
		var time_factor := cos((hour - max_temp_hour) * PI / 12.0)
		temp += daily_variation * time_factor

	# Weather effects
	if weather_service:
		# Cloud cover cooling
		temp -= weather_service.cloud_cover * cloud_cooling

		# Precipitation cooling
		if weather_service.is_precipitating():
			temp -= precipitation_cooling

		# Storm cooling
		if weather_service.is_dangerous():
			temp -= storm_cooling

	return temp


func _calculate_feels_like() -> float:
	if not wind_chill_enabled:
		return air_temperature

	if air_temperature > wind_chill_threshold:
		return air_temperature

	var wind_speed := 0.0
	if weather_service:
		wind_speed = weather_service.wind_speed

	if wind_speed < 1.0:
		return air_temperature

	# Wind chill formula (simplified)
	# Based on Environment Canada formula
	var wind_chill := 13.12 + 0.6215 * air_temperature
	wind_chill -= 11.37 * pow(wind_speed * 3.6, 0.16)  # Convert m/s to km/h
	wind_chill += 0.3965 * air_temperature * pow(wind_speed * 3.6, 0.16)

	return minf(wind_chill, air_temperature)


func _check_thresholds() -> void:
	var is_below_freezing := feels_like_temperature < freezing_point

	if is_below_freezing != was_below_freezing:
		was_below_freezing = is_below_freezing
		freezing_threshold_crossed.emit(is_below_freezing)

	if feels_like_temperature < dangerous_cold:
		dangerous_cold_warning.emit()

	if feels_like_temperature < extreme_cold:
		hypothermia_risk.emit()


# =============================================================================
# ELEVATION UPDATES
# =============================================================================

## Update current elevation (called by player/terrain system)
func set_elevation(elevation: float) -> void:
	current_elevation = elevation


## Get temperature at specific elevation
func get_temperature_at_elevation(elevation: float) -> float:
	var elevation_diff := elevation - current_elevation
	return air_temperature - (elevation_diff / 1000.0) * lapse_rate


# =============================================================================
# QUERIES
# =============================================================================

## Get current air temperature
func get_air_temperature() -> float:
	return air_temperature


## Get feels-like temperature
func get_feels_like() -> float:
	return feels_like_temperature


## Check if below freezing
func is_below_freezing() -> bool:
	return feels_like_temperature < freezing_point


## Check if dangerously cold
func is_dangerous_cold() -> bool:
	return feels_like_temperature < dangerous_cold


## Get cold severity (0 = warm, 1 = extreme cold)
func get_cold_severity() -> float:
	if feels_like_temperature >= freezing_point:
		return 0.0
	elif feels_like_temperature <= extreme_cold:
		return 1.0
	else:
		return (freezing_point - feels_like_temperature) / (freezing_point - extreme_cold)


## Get ice formation probability (0-1)
func get_ice_formation_chance() -> float:
	if air_temperature >= freezing_point:
		return 0.0

	# More likely in temperature transition zone
	var temp_factor := clampf(-air_temperature / 10.0, 0.0, 1.0)

	# Moisture needed
	var moisture := 0.5
	if weather_service and weather_service.is_precipitating():
		moisture = 1.0

	return temp_factor * moisture


## Get snow condition based on temperature
func get_snow_condition() -> GameEnums.SurfaceType:
	if air_temperature > 2.0:
		return GameEnums.SurfaceType.SNOW_SOFT  # Melting
	elif air_temperature > -5.0:
		return GameEnums.SurfaceType.SNOW_FIRM  # Good conditions
	elif air_temperature > -15.0:
		return GameEnums.SurfaceType.SNOW_POWDER  # Cold, dry
	else:
		return GameEnums.SurfaceType.ICE  # Extremely cold, hard


## Get temperature impact on player (for body state)
func get_player_thermal_load() -> float:
	# Negative = cooling, Positive = heating
	# Neutral around 10°C feels-like

	var neutral_temp := 10.0
	var thermal_load := (neutral_temp - feels_like_temperature) / 30.0

	return clampf(thermal_load, -1.0, 1.0)


## Get temperature display (diegetic - breath vapor, etc.)
func get_breath_visibility() -> float:
	if feels_like_temperature > 5.0:
		return 0.0
	elif feels_like_temperature < -10.0:
		return 1.0
	else:
		return (5.0 - feels_like_temperature) / 15.0


## Get conditions summary
func get_summary() -> Dictionary:
	return {
		"air_temperature": air_temperature,
		"feels_like": feels_like_temperature,
		"elevation": current_elevation,
		"is_freezing": is_below_freezing(),
		"cold_severity": get_cold_severity(),
		"snow_condition": GameEnums.SurfaceType.keys()[get_snow_condition()],
		"breath_visibility": get_breath_visibility()
	}
