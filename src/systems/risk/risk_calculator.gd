class_name RiskCalculator
extends RefCounted
## Calculates instantaneous risk from multiple factors
## Core engine for risk detection system
##
## Design Philosophy:
## - Risk is cumulative from multiple sources
## - Certain conditions multiply risk dramatically
## - No explicit risk meter - communicated through cues
## - Players learn to feel risk through experience

# =============================================================================
# CONFIGURATION
# =============================================================================

## Weights for different risk factors
var weights := {
	"slope": 0.2,
	"speed": 0.15,
	"fatigue": 0.15,
	"surface": 0.15,
	"weather": 0.1,
	"gear": 0.1,
	"stability": 0.15
}

## Multipliers for danger zones
var multipliers := {
	"near_cliff": 2.0,
	"no_exit_zone": 1.5,
	"whiteout": 1.8,
	"night": 1.4,
	"injured": 1.3
}

## Thresholds
var thresholds := {
	"safe_slope": 25.0,      # Degrees
	"dangerous_slope": 45.0,
	"safe_speed": 3.0,       # m/s
	"dangerous_speed": 10.0,
	"cliff_distance": 10.0   # meters
}


# =============================================================================
# RISK CALCULATION
# =============================================================================

## Calculate total risk from all factors
func calculate_risk(context: RiskContext) -> RiskResult:
	var result := RiskResult.new()

	# Calculate individual risk factors
	result.slope_risk = _calculate_slope_risk(context)
	result.speed_risk = _calculate_speed_risk(context)
	result.fatigue_risk = _calculate_fatigue_risk(context)
	result.surface_risk = _calculate_surface_risk(context)
	result.weather_risk = _calculate_weather_risk(context)
	result.gear_risk = _calculate_gear_risk(context)
	result.stability_risk = _calculate_stability_risk(context)

	# Weighted sum
	var base_risk := 0.0
	base_risk += result.slope_risk * weights.slope
	base_risk += result.speed_risk * weights.speed
	base_risk += result.fatigue_risk * weights.fatigue
	base_risk += result.surface_risk * weights.surface
	base_risk += result.weather_risk * weights.weather
	base_risk += result.gear_risk * weights.gear
	base_risk += result.stability_risk * weights.stability

	# Apply multipliers
	var total_multiplier := 1.0

	if context.cliff_distance < thresholds.cliff_distance:
		total_multiplier *= multipliers.near_cliff
		result.active_multipliers.append("near_cliff")

	if context.in_no_exit_zone:
		total_multiplier *= multipliers.no_exit_zone
		result.active_multipliers.append("no_exit_zone")

	if context.is_whiteout:
		total_multiplier *= multipliers.whiteout
		result.active_multipliers.append("whiteout")

	if context.is_night:
		total_multiplier *= multipliers.night
		result.active_multipliers.append("night")

	if context.is_injured:
		total_multiplier *= multipliers.injured
		result.active_multipliers.append("injured")

	result.base_risk = base_risk
	result.multiplier = total_multiplier
	result.total_risk = clampf(base_risk * total_multiplier, 0.0, 1.0)

	# Determine risk level
	result.risk_level = _determine_risk_level(result.total_risk)

	# Identify primary danger
	result.primary_danger = _identify_primary_danger(result)

	return result


# =============================================================================
# INDIVIDUAL RISK FACTORS
# =============================================================================

func _calculate_slope_risk(context: RiskContext) -> float:
	var slope := context.slope_angle

	if slope < thresholds.safe_slope:
		return 0.0
	elif slope > thresholds.dangerous_slope:
		return 1.0
	else:
		# Linear interpolation
		return (slope - thresholds.safe_slope) / (thresholds.dangerous_slope - thresholds.safe_slope)


func _calculate_speed_risk(context: RiskContext) -> float:
	var speed := context.speed

	if speed < thresholds.safe_speed:
		return 0.0
	elif speed > thresholds.dangerous_speed:
		return 1.0
	else:
		return (speed - thresholds.safe_speed) / (thresholds.dangerous_speed - thresholds.safe_speed)


func _calculate_fatigue_risk(context: RiskContext) -> float:
	# Fatigue above 0.5 starts adding risk
	if context.fatigue < 0.5:
		return 0.0
	else:
		return (context.fatigue - 0.5) * 2.0


func _calculate_surface_risk(context: RiskContext) -> float:
	match context.surface_type:
		GameEnums.SurfaceType.SNOW_POWDER:
			return 0.1
		GameEnums.SurfaceType.SNOW_SOFT:
			return 0.2
		GameEnums.SurfaceType.SNOW_FIRM:
			return 0.3
		GameEnums.SurfaceType.ICE:
			return 0.9
		GameEnums.SurfaceType.ROCK:
			return 0.5
		GameEnums.SurfaceType.SCREE:
			return 0.7
		_:
			return 0.3


func _calculate_weather_risk(context: RiskContext) -> float:
	var risk := 0.0

	# Wind risk
	match context.wind_strength:
		GameEnums.WindStrength.CALM:
			risk += 0.0
		GameEnums.WindStrength.LIGHT:
			risk += 0.1
		GameEnums.WindStrength.MODERATE:
			risk += 0.3
		GameEnums.WindStrength.STRONG:
			risk += 0.5
		GameEnums.WindStrength.SEVERE:
			risk += 0.8

	# Visibility risk
	risk += (1.0 - context.visibility) * 0.5

	return clampf(risk, 0.0, 1.0)


func _calculate_gear_risk(context: RiskContext) -> float:
	var risk := 0.0

	# No crampons on ice
	if context.surface_type == GameEnums.SurfaceType.ICE and not context.has_crampons:
		risk += 0.5

	# Poor gear condition
	risk += (1.0 - context.gear_condition) * 0.3

	# Wet/frozen rope
	if context.rope_compromised:
		risk += 0.2

	return clampf(risk, 0.0, 1.0)


func _calculate_stability_risk(context: RiskContext) -> float:
	# Low stability = high risk
	return 1.0 - context.stability


# =============================================================================
# HELPERS
# =============================================================================

func _determine_risk_level(risk: float) -> GameEnums.RiskLevel:
	if risk < 0.2:
		return GameEnums.RiskLevel.MINIMAL
	elif risk < 0.4:
		return GameEnums.RiskLevel.LOW
	elif risk < 0.6:
		return GameEnums.RiskLevel.MODERATE
	elif risk < 0.8:
		return GameEnums.RiskLevel.HIGH
	else:
		return GameEnums.RiskLevel.EXTREME


func _identify_primary_danger(result: RiskResult) -> String:
	var dangers := {
		"slope": result.slope_risk,
		"speed": result.speed_risk,
		"fatigue": result.fatigue_risk,
		"surface": result.surface_risk,
		"weather": result.weather_risk,
		"gear": result.gear_risk,
		"stability": result.stability_risk
	}

	var max_danger := ""
	var max_value := 0.0

	for danger in dangers:
		if dangers[danger] > max_value:
			max_value = dangers[danger]
			max_danger = danger

	return max_danger


# =============================================================================
# DATA CLASSES
# =============================================================================

class RiskContext:
	## Terrain
	var slope_angle: float = 0.0
	var surface_type: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
	var cliff_distance: float = 100.0
	var in_no_exit_zone: bool = false

	## Movement
	var speed: float = 0.0
	var stability: float = 1.0

	## Body
	var fatigue: float = 0.0
	var is_injured: bool = false

	## Weather
	var wind_strength: GameEnums.WindStrength = GameEnums.WindStrength.CALM
	var visibility: float = 1.0
	var is_whiteout: bool = false
	var is_night: bool = false

	## Gear
	var has_crampons: bool = true
	var gear_condition: float = 1.0
	var rope_compromised: bool = false


class RiskResult:
	## Individual risk factors (0-1)
	var slope_risk: float = 0.0
	var speed_risk: float = 0.0
	var fatigue_risk: float = 0.0
	var surface_risk: float = 0.0
	var weather_risk: float = 0.0
	var gear_risk: float = 0.0
	var stability_risk: float = 0.0

	## Combined values
	var base_risk: float = 0.0
	var multiplier: float = 1.0
	var total_risk: float = 0.0

	## Risk level enum
	var risk_level: GameEnums.RiskLevel = GameEnums.RiskLevel.MINIMAL

	## Active multipliers
	var active_multipliers: Array[String] = []

	## Primary danger source
	var primary_danger: String = ""

	func get_risk_level_name() -> String:
		return GameEnums.RiskLevel.keys()[risk_level]

	func is_dangerous() -> bool:
		return total_risk >= 0.6

	func is_critical() -> bool:
		return total_risk >= 0.8
