class_name SurfaceConditionManager
extends Node
## Manages dynamic surface conditions based on weather and time
## Tracks sun exposure, snow firmness, and ice formation
##
## Design Philosophy:
## - Surface conditions change realistically over time
## - Morning ice, afternoon slush, evening refreeze
## - Players learn to read and predict conditions
## - No explicit condition indicators

# =============================================================================
# SIGNALS
# =============================================================================

signal surface_conditions_changed(cell_position: Vector3, new_type: GameEnums.SurfaceType)
signal widespread_ice_formation()
signal thaw_conditions_starting()
signal refreeze_warning()
signal avalanche_conditions_detected(risk_level: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Sun Exposure")
## Hours of sun needed to soften snow
@export var softening_threshold: float = 2.0
## Sun intensity threshold for heating
@export var sun_intensity_threshold: float = 0.4

@export_group("Temperature Thresholds")
## Temperature for snow softening
@export var softening_temp: float = -2.0
## Temperature for melting
@export var melting_temp: float = 0.0
## Temperature for refreezing
@export var refreeze_temp: float = -3.0

@export_group("Time Constants")
## Hours for full freeze-thaw cycle effect
@export var cycle_effect_hours: float = 6.0
## Update interval for condition checks
@export var update_interval: float = 60.0  # Game seconds

# =============================================================================
# STATE
# =============================================================================

## Terrain service reference
var terrain_service: TerrainService

## Time service reference
var time_service: TimeService

## Weather service reference
var weather_service: WeatherService

## Temperature system reference
var temperature_system: TemperatureSystem

## Tracked cell conditions (position hash -> CellCondition)
var cell_conditions: Dictionary = {}

## Update timer
var update_timer: float = 0.0

## Current avalanche risk
var avalanche_risk: float = 0.0


# =============================================================================
# CELL CONDITION DATA
# =============================================================================

class CellCondition:
	## Position of this cell
	var position: Vector3 = Vector3.ZERO
	## Cumulative sun exposure (hours)
	var sun_exposure: float = 0.0
	## Current moisture content (0-1)
	var moisture: float = 0.5
	## Has been through freeze-thaw cycle
	var freeze_thaw_cycles: int = 0
	## Current surface state
	var surface_state: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
	## Temperature history (for cycle detection)
	var was_above_freezing: bool = false
	## Snow depth modification (negative = melted)
	var snow_depth_mod: float = 0.0
	## Ice layer thickness
	var ice_layer: float = 0.0

	func get_hash() -> int:
		return int(position.x * 1000 + position.z)


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.get_service_async("TimeService", _on_time_ready)
	ServiceLocator.get_service_async("WeatherService", _on_weather_ready)
	ServiceLocator.get_service_async("TemperatureSystem", _on_temperature_ready)
	ServiceLocator.register_service("SurfaceConditionManager", self)
	print("[SurfaceConditionManager] Initialized")


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


func _on_time_ready(service: Object) -> void:
	time_service = service as TimeService


func _on_weather_ready(service: Object) -> void:
	weather_service = service as WeatherService


func _on_temperature_ready(service: Object) -> void:
	temperature_system = service as TemperatureSystem


# =============================================================================
# UPDATE
# =============================================================================

func _process(delta: float) -> void:
	update_timer += delta

	if update_timer >= update_interval:
		update_timer = 0.0
		_update_conditions()


func _update_conditions() -> void:
	if time_service == null or temperature_system == null:
		return

	var temp := temperature_system.get_air_temperature()
	var sun_intensity := time_service.get_light_intensity()
	var is_precipitating := weather_service != null and weather_service.is_precipitating()

	# Update tracked cells
	for hash in cell_conditions:
		var cell: CellCondition = cell_conditions[hash]
		_update_cell(cell, temp, sun_intensity, is_precipitating)

	# Check avalanche conditions
	_update_avalanche_risk(temp, sun_intensity)


func _update_cell(cell: CellCondition, temp: float, sun_intensity: float, is_precipitating: bool) -> void:
	var old_state := cell.surface_state

	# Sun exposure (only if visible and above threshold)
	if sun_intensity > sun_intensity_threshold:
		var aspect_factor := _get_aspect_sun_factor(cell.position)
		cell.sun_exposure += (update_interval / 3600.0) * sun_intensity * aspect_factor

	# Temperature effects
	_apply_temperature_effects(cell, temp)

	# Precipitation effects
	if is_precipitating:
		_apply_precipitation_effects(cell, temp)

	# Determine new surface state
	cell.surface_state = _calculate_surface_state(cell, temp)

	# Emit change if significant
	if cell.surface_state != old_state:
		surface_conditions_changed.emit(cell.position, cell.surface_state)


func _apply_temperature_effects(cell: CellCondition, temp: float) -> void:
	var is_above_freezing := temp > melting_temp

	# Detect freeze-thaw cycle
	if is_above_freezing and not cell.was_above_freezing:
		# Just thawed
		cell.moisture = minf(1.0, cell.moisture + 0.3)
	elif not is_above_freezing and cell.was_above_freezing:
		# Just refroze
		cell.freeze_thaw_cycles += 1
		cell.ice_layer = minf(1.0, cell.ice_layer + 0.2 * cell.moisture)
		refreeze_warning.emit()

	cell.was_above_freezing = is_above_freezing

	# Melting
	if temp > melting_temp:
		var melt_rate := (temp - melting_temp) * 0.1 * (update_interval / 3600.0)
		cell.snow_depth_mod -= melt_rate
		cell.moisture = minf(1.0, cell.moisture + melt_rate * 0.5)

	# Sublimation (very cold, dry)
	if temp < -15.0 and weather_service and not weather_service.is_precipitating():
		cell.moisture = maxf(0.0, cell.moisture - 0.01)


func _apply_precipitation_effects(cell: CellCondition, temp: float) -> void:
	if weather_service == null:
		return

	match weather_service.precipitation:
		WeatherService.PrecipitationType.LIGHT_SNOW:
			cell.snow_depth_mod += 0.01  # Accumulation
		WeatherService.PrecipitationType.HEAVY_SNOW:
			cell.snow_depth_mod += 0.05
			cell.moisture = minf(1.0, cell.moisture + 0.1)
		WeatherService.PrecipitationType.FREEZING_RAIN:
			cell.ice_layer = minf(1.0, cell.ice_layer + 0.1)
			cell.moisture = 1.0


func _calculate_surface_state(cell: CellCondition, temp: float) -> GameEnums.SurfaceType:
	# Ice layer dominates
	if cell.ice_layer > 0.5:
		return GameEnums.SurfaceType.ICE

	# Check base terrain (might be rock)
	if terrain_service:
		var terrain_cell := terrain_service.get_cell_at(cell.position)
		if terrain_cell and terrain_cell.surface_type == GameEnums.SurfaceType.ROCK:
			if cell.ice_layer > 0.1:
				return GameEnums.SurfaceType.ICE  # Iced rock
			return GameEnums.SurfaceType.ROCK

	# Snow conditions based on temperature and exposure
	if temp > melting_temp:
		return GameEnums.SurfaceType.SNOW_SOFT  # Melting
	elif temp > softening_temp:
		if cell.sun_exposure > softening_threshold:
			return GameEnums.SurfaceType.SNOW_SOFT
		else:
			return GameEnums.SurfaceType.SNOW_FIRM
	elif temp > -10.0:
		return GameEnums.SurfaceType.SNOW_FIRM
	else:
		# Very cold = powder or wind crust
		if weather_service and weather_service.wind_speed > 10.0:
			return GameEnums.SurfaceType.SNOW_FIRM  # Wind packed
		return GameEnums.SurfaceType.SNOW_POWDER


func _get_aspect_sun_factor(position: Vector3) -> float:
	# Calculate sun exposure based on slope aspect
	if terrain_service == null or time_service == null:
		return 1.0

	var cell := terrain_service.get_cell_at(position)
	if cell == null:
		return 1.0

	var sun_dir := time_service.get_sun_direction()
	var slope_normal := Vector3(
		-sin(deg_to_rad(cell.aspect_angle)),
		cos(deg_to_rad(cell.slope_angle)),
		-cos(deg_to_rad(cell.aspect_angle))
	).normalized()

	# Dot product gives sun exposure
	var exposure := maxf(0.0, slope_normal.dot(sun_dir))
	return exposure


# =============================================================================
# AVALANCHE RISK
# =============================================================================

func _update_avalanche_risk(temp: float, sun_intensity: float) -> void:
	var risk := 0.0

	# Recent heavy snowfall
	if weather_service and weather_service.precipitation == WeatherService.PrecipitationType.HEAVY_SNOW:
		risk += 0.3

	# Warming after cold
	if temp > softening_temp and temperature_system and temperature_system.get_cold_severity() > 0:
		risk += 0.2

	# Strong sun on steep slopes
	if sun_intensity > 0.6 and temp > -5.0:
		risk += 0.2

	# Wind loading
	if weather_service and weather_service.wind_speed > 15.0:
		risk += 0.15

	# Rain on snow
	if weather_service and weather_service.precipitation == WeatherService.PrecipitationType.FREEZING_RAIN:
		risk += 0.35

	avalanche_risk = clampf(risk, 0.0, 1.0)

	if avalanche_risk > 0.6:
		avalanche_conditions_detected.emit(avalanche_risk)


# =============================================================================
# CELL TRACKING
# =============================================================================

## Track a cell for condition updates
func track_cell(position: Vector3) -> void:
	var hash := _position_hash(position)
	if not cell_conditions.has(hash):
		var cell := CellCondition.new()
		cell.position = position
		cell_conditions[hash] = cell


## Stop tracking a cell
func untrack_cell(position: Vector3) -> void:
	var hash := _position_hash(position)
	cell_conditions.erase(hash)


## Get condition for position
func get_condition(position: Vector3) -> CellCondition:
	var hash := _position_hash(position)
	if cell_conditions.has(hash):
		return cell_conditions[hash]
	return null


func _position_hash(position: Vector3) -> int:
	# Quantize to cell size
	var x := int(position.x / 5.0) * 5
	var z := int(position.z / 5.0) * 5
	return x * 10000 + z


# =============================================================================
# QUERIES
# =============================================================================

## Get surface type at position
func get_surface_at(position: Vector3) -> GameEnums.SurfaceType:
	var condition := get_condition(position)
	if condition:
		return condition.surface_state

	# Fall back to base calculation
	if temperature_system:
		return temperature_system.get_snow_condition()

	return GameEnums.SurfaceType.SNOW_FIRM


## Get friction modifier at position
func get_friction_modifier(position: Vector3) -> float:
	var condition := get_condition(position)
	if condition == null:
		return 1.0

	var modifier := 1.0

	# Ice reduces friction
	if condition.ice_layer > 0.3:
		modifier *= 0.5

	# Wet snow is slippery
	if condition.moisture > 0.7 and condition.surface_state == GameEnums.SurfaceType.SNOW_SOFT:
		modifier *= 0.7

	# Fresh powder provides good friction
	if condition.surface_state == GameEnums.SurfaceType.SNOW_POWDER:
		modifier *= 1.2

	return modifier


## Get ice presence (0-1)
func get_ice_presence(position: Vector3) -> float:
	var condition := get_condition(position)
	if condition:
		return condition.ice_layer
	return 0.0


## Check if morning ice likely
func is_morning_ice_likely() -> bool:
	if time_service == null or temperature_system == null:
		return false

	var hour := time_service.current_time
	var temp := temperature_system.get_air_temperature()

	# Early morning after clear night
	return hour < 9.0 and hour > 5.0 and temp < 0.0


## Check if afternoon thaw expected
func is_afternoon_thaw_expected() -> bool:
	if time_service == null or temperature_system == null:
		return false

	var hour := time_service.current_time
	var temp := temperature_system.get_air_temperature()
	var sun := time_service.get_light_intensity()

	return hour > 11.0 and hour < 16.0 and temp > -5.0 and sun > 0.5


## Get current avalanche risk
func get_avalanche_risk() -> float:
	return avalanche_risk


## Get conditions summary
func get_summary() -> Dictionary:
	return {
		"tracked_cells": cell_conditions.size(),
		"avalanche_risk": avalanche_risk,
		"morning_ice_likely": is_morning_ice_likely(),
		"afternoon_thaw_expected": is_afternoon_thaw_expected()
	}
