class_name EnvironmentService
extends Node
## Central service coordinating all environmental systems
## Provides unified API for querying environmental conditions
##
## Design Philosophy:
## - Single point of contact for environment queries
## - Coordinates time, weather, temperature, and surface systems
## - Manages environmental hazard detection
## - Provides diegetic feedback hooks

# =============================================================================
# SIGNALS
# =============================================================================

signal environment_hazard_detected(hazard_type: HazardType, severity: float)
signal conditions_deteriorating()
signal conditions_improving()
signal optimal_conditions_window(duration_hours: float)
signal environmental_decision_point(factors: Dictionary)

# =============================================================================
# ENUMS
# =============================================================================

enum HazardType {
	DARKNESS,
	EXTREME_COLD,
	WHITEOUT,
	ICE,
	AVALANCHE,
	HIGH_WIND,
	STORM
}

# =============================================================================
# CHILD SYSTEMS
# =============================================================================

## Time simulation
var time_service: TimeService

## Weather state machine
var weather_service: WeatherService

## Temperature calculations
var temperature_system: TemperatureSystem

## Surface condition tracking
var surface_manager: SurfaceConditionManager


# =============================================================================
# STATE
# =============================================================================

## Current overall condition rating (0 = terrible, 1 = ideal)
var condition_rating: float = 0.7

## Previous condition rating (for trend detection)
var previous_rating: float = 0.7

## Active hazards
var active_hazards: Array[HazardType] = []

## Player position for local queries
var player_position: Vector3 = Vector3.ZERO

## Player elevation
var player_elevation: float = 3000.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	# Create child systems
	time_service = TimeService.new()
	weather_service = WeatherService.new()
	temperature_system = TemperatureSystem.new()
	surface_manager = SurfaceConditionManager.new()

	# Add as children
	add_child(time_service)
	add_child(weather_service)
	add_child(temperature_system)
	add_child(surface_manager)

	# Connect signals
	_connect_signals()

	# Register service
	ServiceLocator.register_service("EnvironmentService", self)

	print("[EnvironmentService] Initialized with all subsystems")


func _connect_signals() -> void:
	# Time events
	time_service.time_of_day_changed.connect(_on_time_of_day_changed)
	time_service.sunset.connect(_on_sunset)
	time_service.night_fallen.connect(_on_night_fallen)

	# Weather events
	weather_service.weather_changed.connect(_on_weather_changed)
	weather_service.storm_warning.connect(_on_storm_warning)
	weather_service.whiteout_imminent.connect(_on_whiteout_imminent)

	# Temperature events
	temperature_system.dangerous_cold_warning.connect(_on_dangerous_cold)
	temperature_system.hypothermia_risk.connect(_on_hypothermia_risk)

	# Surface events
	surface_manager.avalanche_conditions_detected.connect(_on_avalanche_detected)
	surface_manager.widespread_ice_formation.connect(_on_ice_formation)


# =============================================================================
# RUN INITIALIZATION
# =============================================================================

## Initialize environment for a new run
func initialize_run(config: EnvironmentConfig) -> void:
	# Initialize time
	time_service.initialize_run(config.start_hour, config.day_of_year)

	# Generate weather windows
	weather_service.generate_weather_windows(config.start_hour, config.difficulty)

	# Set initial elevation
	player_elevation = config.start_elevation
	temperature_system.set_elevation(player_elevation)

	# Reset state
	condition_rating = _calculate_condition_rating()
	previous_rating = condition_rating
	active_hazards.clear()

	print("[EnvironmentService] Run initialized: %s, %.1f°C" % [
		time_service.get_time_string(),
		temperature_system.get_air_temperature()
	])


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	_update_condition_rating()
	_check_hazards()
	_check_trends()


func _update_condition_rating() -> void:
	previous_rating = condition_rating
	condition_rating = _calculate_condition_rating()


func _calculate_condition_rating() -> float:
	var rating := 1.0

	# Light conditions
	var light := time_service.get_light_intensity()
	rating *= 0.5 + light * 0.5  # 50-100% based on light

	# Weather
	match weather_service.get_weather():
		GameEnums.WeatherState.CLEAR:
			pass  # No penalty
		GameEnums.WeatherState.CLOUDY:
			rating *= 0.9
		GameEnums.WeatherState.DETERIORATING:
			rating *= 0.7
		GameEnums.WeatherState.STORM:
			rating *= 0.3
		GameEnums.WeatherState.WHITEOUT:
			rating *= 0.1

	# Temperature
	var cold_severity := temperature_system.get_cold_severity()
	rating *= 1.0 - cold_severity * 0.3

	# Visibility
	rating *= 0.5 + weather_service.visibility * 0.5

	# Avalanche risk
	rating *= 1.0 - surface_manager.get_avalanche_risk() * 0.4

	return clampf(rating, 0.0, 1.0)


func _check_hazards() -> void:
	var new_hazards: Array[HazardType] = []

	# Darkness
	if time_service.is_dark():
		new_hazards.append(HazardType.DARKNESS)

	# Extreme cold
	if temperature_system.is_dangerous_cold():
		new_hazards.append(HazardType.EXTREME_COLD)

	# Whiteout
	if weather_service.get_weather() == GameEnums.WeatherState.WHITEOUT:
		new_hazards.append(HazardType.WHITEOUT)

	# Ice
	if surface_manager.is_morning_ice_likely():
		new_hazards.append(HazardType.ICE)

	# Avalanche
	if surface_manager.get_avalanche_risk() > 0.5:
		new_hazards.append(HazardType.AVALANCHE)

	# High wind
	if weather_service.current_wind_strength >= GameEnums.WindStrength.STRONG:
		new_hazards.append(HazardType.HIGH_WIND)

	# Storm
	if weather_service.get_weather() == GameEnums.WeatherState.STORM:
		new_hazards.append(HazardType.STORM)

	# Emit new hazards
	for hazard in new_hazards:
		if not active_hazards.has(hazard):
			var severity := _get_hazard_severity(hazard)
			environment_hazard_detected.emit(hazard, severity)

	active_hazards = new_hazards


func _check_trends() -> void:
	var delta := condition_rating - previous_rating

	if delta < -0.1:
		conditions_deteriorating.emit()
	elif delta > 0.1:
		conditions_improving.emit()


func _get_hazard_severity(hazard: HazardType) -> float:
	match hazard:
		HazardType.DARKNESS:
			return 1.0 - time_service.get_light_intensity()
		HazardType.EXTREME_COLD:
			return temperature_system.get_cold_severity()
		HazardType.WHITEOUT:
			return 1.0
		HazardType.ICE:
			return surface_manager.get_ice_presence(player_position)
		HazardType.AVALANCHE:
			return surface_manager.get_avalanche_risk()
		HazardType.HIGH_WIND:
			return weather_service.wind_speed / weather_service.max_wind_speed
		HazardType.STORM:
			return 0.8
		_:
			return 0.5


# =============================================================================
# EVENT HANDLERS
# =============================================================================

func _on_time_of_day_changed(period: TimeService.TimePeriod) -> void:
	# Track surface near player for condition changes
	surface_manager.track_cell(player_position)


func _on_sunset() -> void:
	environmental_decision_point.emit({
		"type": "sunset",
		"time_until_dark": time_service.get_time_until_night(),
		"recommendation": "Find shelter or continue descent"
	})


func _on_night_fallen() -> void:
	environment_hazard_detected.emit(HazardType.DARKNESS, 1.0)


func _on_weather_changed(old: GameEnums.WeatherState, new: GameEnums.WeatherState) -> void:
	# Evaluate if this creates decision point
	if new == GameEnums.WeatherState.DETERIORATING:
		environmental_decision_point.emit({
			"type": "weather_worsening",
			"current": GameEnums.WeatherState.keys()[new],
			"recommendation": "Consider expediting descent"
		})


func _on_storm_warning() -> void:
	environment_hazard_detected.emit(HazardType.STORM, 0.7)


func _on_whiteout_imminent() -> void:
	environment_hazard_detected.emit(HazardType.WHITEOUT, 1.0)


func _on_dangerous_cold() -> void:
	environment_hazard_detected.emit(HazardType.EXTREME_COLD, 0.8)


func _on_hypothermia_risk() -> void:
	environment_hazard_detected.emit(HazardType.EXTREME_COLD, 1.0)


func _on_avalanche_detected(risk: float) -> void:
	environment_hazard_detected.emit(HazardType.AVALANCHE, risk)


func _on_ice_formation() -> void:
	environment_hazard_detected.emit(HazardType.ICE, 0.6)


# =============================================================================
# PLAYER POSITION UPDATES
# =============================================================================

## Update player position for local queries
func update_player_position(position: Vector3) -> void:
	player_position = position
	player_elevation = position.y
	temperature_system.set_elevation(player_elevation)
	surface_manager.track_cell(position)


# =============================================================================
# UNIFIED QUERIES
# =============================================================================

## Get all current conditions
func get_conditions() -> EnvironmentConditions:
	var conditions := EnvironmentConditions.new()

	conditions.game_time = time_service.current_time
	conditions.time_period = time_service.current_period
	conditions.light_intensity = time_service.get_light_intensity()
	conditions.sun_direction = time_service.get_sun_direction()

	conditions.weather = weather_service.get_weather()
	conditions.wind_speed = weather_service.wind_speed
	conditions.wind_direction = weather_service.wind_direction
	conditions.visibility = weather_service.visibility
	conditions.is_precipitating = weather_service.is_precipitating()

	conditions.air_temperature = temperature_system.get_air_temperature()
	conditions.feels_like = temperature_system.get_feels_like()
	conditions.cold_severity = temperature_system.get_cold_severity()

	conditions.surface_type = surface_manager.get_surface_at(player_position)
	conditions.avalanche_risk = surface_manager.get_avalanche_risk()
	conditions.ice_presence = surface_manager.get_ice_presence(player_position)

	conditions.overall_rating = condition_rating
	conditions.active_hazards = active_hazards.duplicate()

	return conditions


## Get visibility range at position
func get_visibility_at(position: Vector3) -> float:
	var weather_vis := weather_service.get_visibility_range()
	var light_vis := time_service.get_visibility_range()
	return minf(weather_vis, light_vis)


## Get surface friction at position
func get_friction_at(position: Vector3) -> float:
	return surface_manager.get_friction_modifier(position)


## Get temperature at elevation
func get_temperature_at_elevation(elevation: float) -> float:
	return temperature_system.get_temperature_at_elevation(elevation)


## Check if conditions are safe for activity
func is_safe_for_activity(activity: String) -> bool:
	match activity:
		"rappel":
			return not active_hazards.has(HazardType.HIGH_WIND) and \
				   not active_hazards.has(HazardType.WHITEOUT)
		"slide":
			return not active_hazards.has(HazardType.ICE) or condition_rating > 0.3
		"rest":
			return not active_hazards.has(HazardType.STORM) and \
				   not active_hazards.has(HazardType.EXTREME_COLD)
		_:
			return condition_rating > 0.2


## Get time pressure factor (0 = no pressure, 1 = extreme pressure)
func get_time_pressure() -> float:
	var pressure := 0.0

	# Darkness approaching
	var until_dark := time_service.get_time_until_night()
	if until_dark < 2.0:
		pressure += (2.0 - until_dark) / 2.0 * 0.4

	# Weather deteriorating
	if weather_service.is_transitioning and \
	   weather_service.target_weather > weather_service.current_weather and \
	   weather_service.target_weather != GameEnums.WeatherState.CLEARING:
		pressure += 0.3

	# Already in bad conditions
	pressure += (1.0 - condition_rating) * 0.3

	return clampf(pressure, 0.0, 1.0)


## Get optimal window info
func get_optimal_window() -> Dictionary:
	var windows := weather_service.weather_windows
	var current_hour := time_service.current_time

	for window in windows:
		if window.start_time > current_hour:
			if window.weather <= GameEnums.WeatherState.CLOUDY:
				return {
					"exists": true,
					"starts_in": window.start_time - current_hour,
					"duration": window.end_time - window.start_time,
					"weather": GameEnums.WeatherState.keys()[window.weather]
				}

	return {"exists": false}


# =============================================================================
# ENVIRONMENT CONDITIONS DATA CLASS
# =============================================================================

class EnvironmentConditions:
	# Time
	var game_time: float = 8.0
	var time_period: TimeService.TimePeriod = TimeService.TimePeriod.MORNING
	var light_intensity: float = 1.0
	var sun_direction: Vector3 = Vector3(0, 1, 0)

	# Weather
	var weather: GameEnums.WeatherState = GameEnums.WeatherState.CLEAR
	var wind_speed: float = 5.0
	var wind_direction: Vector3 = Vector3(1, 0, 0)
	var visibility: float = 1.0
	var is_precipitating: bool = false

	# Temperature
	var air_temperature: float = 0.0
	var feels_like: float = 0.0
	var cold_severity: float = 0.0

	# Surface
	var surface_type: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
	var avalanche_risk: float = 0.0
	var ice_presence: float = 0.0

	# Overall
	var overall_rating: float = 0.7
	var active_hazards: Array = []


# =============================================================================
# ENVIRONMENT CONFIG
# =============================================================================

class EnvironmentConfig:
	var start_hour: float = 8.0
	var day_of_year: int = 180
	var difficulty: float = 0.5
	var start_elevation: float = 4000.0

	static func create_default() -> EnvironmentConfig:
		return EnvironmentConfig.new()

	static func create_challenging() -> EnvironmentConfig:
		var config := EnvironmentConfig.new()
		config.start_hour = 10.0
		config.difficulty = 0.7
		return config

	static func create_extreme() -> EnvironmentConfig:
		var config := EnvironmentConfig.new()
		config.start_hour = 12.0
		config.difficulty = 0.9
		config.start_elevation = 5000.0
		return config
