class_name SurfaceClassifier
extends RefCounted
## Classifies terrain surface types based on environmental conditions
## Determines snow, ice, rock, and mixed surfaces

# =============================================================================
# CONFIGURATION
# =============================================================================

## Snow line elevation (meters) - below this is rock/mixed
var snow_line: float = 2500.0

## Permanent snow line - always snow above this
var permanent_snow_line: float = 3500.0

## Temperature threshold for ice formation (Celsius)
var freeze_threshold: float = 0.0

## Temperature threshold for snow softening
var soft_snow_threshold: float = -5.0

## Minimum slope for scree formation (degrees)
var scree_min_slope: float = 30.0

## Maximum slope for snow accumulation (degrees)
var snow_max_slope: float = 55.0

# =============================================================================
# ENVIRONMENTAL STATE
# =============================================================================

## Current temperature at reference elevation (Celsius)
var base_temperature: float = -10.0

## Temperature lapse rate (degrees per 100m elevation)
var lapse_rate: float = 0.65

## Current sun angle (altitude in degrees)
var sun_altitude: float = 45.0

## Current sun azimuth (compass direction in degrees)
var sun_azimuth: float = 180.0

## Time since last precipitation (hours)
var time_since_precipitation: float = 24.0

## Recent precipitation type (snow, rain, none)
var recent_precipitation: String = "none"

## Is it currently precipitating
var is_precipitating: bool = false


# =============================================================================
# SURFACE CLASSIFICATION
# =============================================================================

## Classify surface at a given cell
func classify_surface(cell: TerrainCell, time_of_day: float = 12.0) -> GameEnums.SurfaceType:
	var temp := get_temperature_at(cell.elevation)
	var sun_exposure := _calculate_sun_exposure(cell, time_of_day)

	# Determine base surface
	if cell.elevation < snow_line:
		return _classify_rock_surface(cell, temp)
	elif cell.slope_angle > snow_max_slope:
		return _classify_steep_surface(cell, temp)
	else:
		return _classify_snow_surface(cell, temp, sun_exposure)


## Classify rock/below snow line surfaces
func _classify_rock_surface(cell: TerrainCell, temp: float) -> GameEnums.SurfaceType:
	# Wet rock near drainage/water
	if cell.drainage > 0.6 or cell.is_wet:
		return GameEnums.SurfaceType.ROCK_WET

	# Scree on steep rocky slopes
	if cell.slope_angle >= scree_min_slope:
		return GameEnums.SurfaceType.SCREE

	# Ice on cold rock with moisture
	if temp < freeze_threshold and cell.drainage > 0.3:
		return GameEnums.SurfaceType.ICE

	return GameEnums.SurfaceType.ROCK_DRY


## Classify steep surfaces (cliffs, very steep faces)
func _classify_steep_surface(cell: TerrainCell, temp: float) -> GameEnums.SurfaceType:
	# Too steep for snow to accumulate - mostly rock
	if temp < freeze_threshold:
		# Cold enough for ice
		if cell.drainage > 0.2:
			return GameEnums.SurfaceType.ICE
		return GameEnums.SurfaceType.MIXED

	return GameEnums.SurfaceType.ROCK_DRY


## Classify snow surfaces
func _classify_snow_surface(
	cell: TerrainCell,
	temp: float,
	sun_exposure: float
) -> GameEnums.SurfaceType:
	# Fresh powder
	if is_precipitating and recent_precipitation == "snow":
		return GameEnums.SurfaceType.SNOW_POWDER

	if time_since_precipitation < 6.0 and recent_precipitation == "snow":
		return GameEnums.SurfaceType.SNOW_POWDER

	# Ice formation conditions
	if _should_form_ice(cell, temp, sun_exposure):
		return GameEnums.SurfaceType.ICE

	# Soft snow (warm enough to soften)
	if temp > soft_snow_threshold:
		return GameEnums.SurfaceType.SNOW_SOFT

	# Firm snow (cold, consolidated)
	return GameEnums.SurfaceType.SNOW_FIRM


## Check if ice should form
func _should_form_ice(cell: TerrainCell, temp: float, sun_exposure: float) -> bool:
	# Ice forms from melt-freeze cycles
	# High sun exposure during day + freezing at night

	# Recent melt conditions
	var had_melt := temp > -2.0 or sun_exposure > 0.7

	# Current freeze conditions
	var is_freezing := temp < freeze_threshold

	# Shaded aspects hold ice longer
	var shade_factor := 1.0 - sun_exposure

	# Concave areas collect water and ice
	var drainage_factor := cell.drainage

	# Ice probability
	var ice_prob := 0.0

	if had_melt and is_freezing:
		ice_prob += 0.4

	ice_prob += shade_factor * 0.3
	ice_prob += drainage_factor * 0.2

	# North-facing slopes in northern hemisphere hold ice
	if cell.aspect > 315.0 or cell.aspect < 45.0:
		ice_prob += 0.2

	return ice_prob > 0.5


# =============================================================================
# TEMPERATURE CALCULATIONS
# =============================================================================

## Get temperature at a given elevation
func get_temperature_at(elevation: float) -> float:
	# Temperature decreases with elevation (lapse rate)
	var elevation_diff := elevation - snow_line
	return base_temperature - (elevation_diff / 100.0) * lapse_rate


## Update environmental state
func update_environment(
	temp: float,
	sun_alt: float,
	sun_az: float,
	precipitating: bool = false,
	precip_type: String = "none"
) -> void:
	base_temperature = temp
	sun_altitude = sun_alt
	sun_azimuth = sun_az

	if precipitating:
		is_precipitating = true
		recent_precipitation = precip_type
		time_since_precipitation = 0.0
	else:
		is_precipitating = false


## Advance time (for precipitation tracking)
func advance_time(hours: float) -> void:
	if not is_precipitating:
		time_since_precipitation += hours


func _calculate_sun_exposure(cell: TerrainCell, time_of_day: float) -> float:
	# Simplified sun exposure calculation
	if sun_altitude < 0:
		return 0.0  # Sun below horizon

	# Calculate based on aspect vs sun direction
	var aspect_diff := absf(cell.aspect - sun_azimuth)
	if aspect_diff > 180.0:
		aspect_diff = 360.0 - aspect_diff

	# South-facing gets most sun (in northern hemisphere)
	var aspect_factor := 1.0 - (aspect_diff / 180.0)

	# Steeper slopes facing sun get more exposure
	var slope_factor := sin(deg_to_rad(cell.slope_angle)) * aspect_factor

	# Sun altitude affects overall exposure
	var altitude_factor := sin(deg_to_rad(sun_altitude))

	return clampf(altitude_factor * (0.5 + 0.5 * slope_factor), 0.0, 1.0)


# =============================================================================
# SURFACE PROPERTIES
# =============================================================================

## Get friction coefficient for surface type
func get_friction(surface: GameEnums.SurfaceType) -> float:
	return GameEnums.get_surface_friction(surface)


## Get firmness for surface type (0 = very soft, 1 = rock hard)
func get_firmness(surface: GameEnums.SurfaceType) -> float:
	match surface:
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.2
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.4
		GameEnums.SurfaceType.SNOW_FIRM:
			return 0.7
		GameEnums.SurfaceType.ICE:
			return 0.95
		GameEnums.SurfaceType.SCREE:
			return 0.5
		GameEnums.SurfaceType.ROCK_WET:
			return 1.0
		GameEnums.SurfaceType.ROCK_DRY:
			return 1.0
		GameEnums.SurfaceType.MIXED:
			return 0.6
		_:
			return 0.5


## Check if surface allows sliding
func allows_sliding(surface: GameEnums.SurfaceType) -> bool:
	return surface in [
		GameEnums.SurfaceType.SNOW_FIRM,
		GameEnums.SurfaceType.SNOW_SOFT,
		GameEnums.SurfaceType.SNOW_POWDER,
		GameEnums.SurfaceType.SCREE,
		GameEnums.SurfaceType.ICE  # Can slide but very dangerous
	]


## Get crampon effectiveness on surface
func get_crampon_effectiveness(surface: GameEnums.SurfaceType) -> float:
	match surface:
		GameEnums.SurfaceType.ICE:
			return 0.9  # Crampons essential
		GameEnums.SurfaceType.SNOW_FIRM:
			return 0.8
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.5
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.3  # Crampons less effective
		GameEnums.SurfaceType.ROCK_DRY:
			return 0.6
		GameEnums.SurfaceType.ROCK_WET:
			return 0.4
		_:
			return 0.5


## Get ice axe arrest effectiveness on surface
func get_arrest_effectiveness(surface: GameEnums.SurfaceType) -> float:
	match surface:
		GameEnums.SurfaceType.SNOW_FIRM:
			return 0.9  # Ideal for arrest
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.7
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.4  # Hard to arrest in powder
		GameEnums.SurfaceType.ICE:
			return 0.3  # Very difficult
		GameEnums.SurfaceType.SCREE:
			return 0.2  # Nearly impossible
		GameEnums.SurfaceType.ROCK_WET, GameEnums.SurfaceType.ROCK_DRY:
			return 0.1  # Can't really arrest on rock
		_:
			return 0.5


# =============================================================================
# SURFACE DESCRIPTION
# =============================================================================

## Get human-readable description of surface
func describe_surface(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.SNOW_POWDER:
			return "Fresh powder snow - soft and deep"
		GameEnums.SurfaceType.SNOW_SOFT:
			return "Soft snow - warming and loose"
		GameEnums.SurfaceType.SNOW_FIRM:
			return "Firm consolidated snow - good purchase"
		GameEnums.SurfaceType.ICE:
			return "Ice - slick and unforgiving"
		GameEnums.SurfaceType.ROCK_DRY:
			return "Dry rock - solid footing"
		GameEnums.SurfaceType.ROCK_WET:
			return "Wet rock - slippery"
		GameEnums.SurfaceType.SCREE:
			return "Loose scree - unstable footing"
		GameEnums.SurfaceType.MIXED:
			return "Mixed terrain - variable conditions"
		_:
			return "Unknown surface"


## Get risk warning for surface
func get_surface_warning(surface: GameEnums.SurfaceType) -> String:
	match surface:
		GameEnums.SurfaceType.ICE:
			return "Extreme slip hazard. Crampons essential."
		GameEnums.SurfaceType.ROCK_WET:
			return "Slippery when wet. Take care."
		GameEnums.SurfaceType.SCREE:
			return "Unstable. Watch your footing."
		GameEnums.SurfaceType.SNOW_POWDER:
			return "Deep snow. Exhausting to travel through."
		_:
			return ""
