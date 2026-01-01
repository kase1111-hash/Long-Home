class_name RoutePlanner
extends RefCounted
## Analyzes and validates planned routes
## Provides risk assessment and route recommendations
##
## Design Philosophy:
## - Route planning is part of the challenge
## - Show risks, don't hide them
## - Player makes informed decisions
## - No forced routes, just information

# =============================================================================
# SIGNALS
# =============================================================================

signal route_analyzed(analysis: RouteAnalysis)
signal segment_warning(segment_index: int, warning: String)

# =============================================================================
# DATA STRUCTURES
# =============================================================================

class RouteSegment:
	var start_pos: Vector3
	var end_pos: Vector3
	var distance: float
	var elevation_change: float
	var max_slope: float
	var avg_slope: float
	var terrain_types: Array[GameEnums.TerrainZone] = []
	var requires_rope: bool = false
	var has_cliff: bool = false
	var exit_zone_count: int = 0
	var estimated_time: float = 0.0  # Minutes
	var risk_level: float = 0.0

	func get_summary() -> Dictionary:
		return {
			"distance": distance,
			"elevation_change": elevation_change,
			"max_slope": max_slope,
			"avg_slope": avg_slope,
			"requires_rope": requires_rope,
			"has_cliff": has_cliff,
			"exit_zones": exit_zone_count,
			"time": estimated_time,
			"risk": risk_level
		}


class RouteAnalysis:
	var segments: Array[RouteSegment] = []
	var total_distance: float = 0.0
	var total_elevation_change: float = 0.0
	var estimated_total_time: float = 0.0  # Minutes
	var rope_sections: int = 0
	var cliff_exposures: int = 0
	var overall_risk: float = 0.0
	var warnings: Array[String] = []
	var recommendations: Array[String] = []
	var is_viable: bool = true
	var viability_reason: String = ""

	func get_summary() -> Dictionary:
		return {
			"distance": total_distance,
			"elevation": total_elevation_change,
			"time": estimated_total_time,
			"rope_sections": rope_sections,
			"cliff_exposures": cliff_exposures,
			"risk": overall_risk,
			"warnings": warnings.size(),
			"viable": is_viable
		}


# =============================================================================
# CONFIGURATION
# =============================================================================

## Sample interval for route analysis (meters)
var sample_interval: float = 10.0

## Walking speed on flat terrain (m/s)
var base_walk_speed: float = 1.2

## Speed reduction per degree of slope
var slope_speed_factor: float = 0.02

## Time for rope deployment (minutes)
var rope_deploy_time: float = 15.0

## Risk threshold for warning
var warning_risk_threshold: float = 0.6

## Maximum viable risk level
var max_viable_risk: float = 0.9


# =============================================================================
# ANALYSIS
# =============================================================================

## Analyze a planned route
func analyze_route(route: PackedVector3Array, terrain_service: TerrainService) -> RouteAnalysis:
	var analysis := RouteAnalysis.new()

	if route.size() < 2:
		analysis.is_viable = false
		analysis.viability_reason = "Route too short"
		return analysis

	# Analyze each segment between waypoints
	for i in range(route.size() - 1):
		var segment := _analyze_segment(route[i], route[i + 1], terrain_service)
		analysis.segments.append(segment)

		# Accumulate totals
		analysis.total_distance += segment.distance
		analysis.total_elevation_change += absf(segment.elevation_change)
		analysis.estimated_total_time += segment.estimated_time

		if segment.requires_rope:
			analysis.rope_sections += 1
			analysis.estimated_total_time += rope_deploy_time

		if segment.has_cliff:
			analysis.cliff_exposures += 1

		# Check for segment warnings
		if segment.risk_level > warning_risk_threshold:
			var warning := "Segment %d: High risk (%.0f%%)" % [i + 1, segment.risk_level * 100]
			analysis.warnings.append(warning)
			segment_warning.emit(i, warning)

	# Calculate overall risk
	analysis.overall_risk = _calculate_overall_risk(analysis)

	# Check viability
	if analysis.overall_risk > max_viable_risk:
		analysis.is_viable = false
		analysis.viability_reason = "Route risk exceeds survival threshold"

	# Generate recommendations
	analysis.recommendations = _generate_recommendations(analysis)

	route_analyzed.emit(analysis)
	return analysis


func _analyze_segment(start: Vector3, end: Vector3, terrain: TerrainService) -> RouteSegment:
	var segment := RouteSegment.new()
	segment.start_pos = start
	segment.end_pos = end
	segment.distance = start.distance_to(end)
	segment.elevation_change = start.y - end.y

	# Sample along segment
	var num_samples := int(ceil(segment.distance / sample_interval))
	num_samples = maxi(num_samples, 2)

	var slopes: Array[float] = []
	var terrain_zones: Dictionary = {}

	for i in range(num_samples):
		var t := float(i) / float(num_samples - 1)
		var sample_pos := start.lerp(end, t)

		# Get slope at sample
		var slope := terrain.get_slope_at(sample_pos)
		slopes.append(slope)

		# Get terrain zone
		var zone := GameEnums.get_terrain_zone(slope)
		terrain_zones[zone] = terrain_zones.get(zone, 0) + 1

		if zone not in segment.terrain_types:
			segment.terrain_types.append(zone)

		# Check for rope requirement
		if terrain.requires_rope_at(sample_pos):
			segment.requires_rope = true

		# Check for cliff proximity
		if terrain.is_near_cliff(sample_pos, 10.0):
			segment.has_cliff = true

		# Count exit zones
		if terrain.is_exit_zone_at(sample_pos):
			segment.exit_zone_count += 1

	# Calculate slope statistics
	segment.max_slope = slopes.max() if slopes.size() > 0 else 0.0
	segment.avg_slope = _array_average(slopes)

	# Estimate time
	segment.estimated_time = _estimate_segment_time(segment)

	# Calculate risk
	segment.risk_level = _calculate_segment_risk(segment)

	return segment


func _array_average(arr: Array) -> float:
	if arr.size() == 0:
		return 0.0
	var total := 0.0
	for v in arr:
		total += v
	return total / arr.size()


func _estimate_segment_time(segment: RouteSegment) -> float:
	# Base time from distance
	var effective_speed := base_walk_speed

	# Reduce speed for slope
	effective_speed *= maxf(0.2, 1.0 - segment.avg_slope * slope_speed_factor)

	# Reduce speed for difficult terrain
	if GameEnums.TerrainZone.DOWNCLIMB in segment.terrain_types:
		effective_speed *= 0.5
	elif GameEnums.TerrainZone.STEEP in segment.terrain_types:
		effective_speed *= 0.7

	var time_seconds := segment.distance / maxf(0.1, effective_speed)
	return time_seconds / 60.0  # Convert to minutes


func _calculate_segment_risk(segment: RouteSegment) -> float:
	var risk := 0.0

	# Slope risk
	if segment.max_slope > 70:
		risk += 0.5
	elif segment.max_slope > 50:
		risk += 0.3
	elif segment.max_slope > 35:
		risk += 0.15

	# Cliff risk
	if segment.has_cliff:
		risk += 0.3

	# Rope requirement (adds complexity, not direct risk)
	if segment.requires_rope:
		risk += 0.1

	# Exit zone availability reduces risk
	if segment.exit_zone_count > 0:
		risk *= 0.8

	# Terrain type risks
	if GameEnums.TerrainZone.CLIFF in segment.terrain_types:
		risk += 0.4
	if GameEnums.TerrainZone.RAPPEL_REQUIRED in segment.terrain_types:
		risk += 0.2

	return clampf(risk, 0.0, 1.0)


func _calculate_overall_risk(analysis: RouteAnalysis) -> float:
	if analysis.segments.size() == 0:
		return 0.0

	# Weighted average of segment risks
	var total_risk := 0.0
	var total_weight := 0.0

	for segment in analysis.segments:
		# Weight by distance
		var weight := segment.distance
		total_risk += segment.risk_level * weight
		total_weight += weight

	var avg_risk := total_risk / maxf(1.0, total_weight)

	# Cliff exposures compound risk
	avg_risk += analysis.cliff_exposures * 0.05

	# Long routes increase fatigue risk
	if analysis.estimated_total_time > 360:  # 6 hours
		avg_risk += 0.1
	if analysis.estimated_total_time > 480:  # 8 hours
		avg_risk += 0.15

	return clampf(avg_risk, 0.0, 1.0)


func _generate_recommendations(analysis: RouteAnalysis) -> Array[String]:
	var recommendations: Array[String] = []

	# Check rope requirements
	if analysis.rope_sections > 0:
		recommendations.append("Bring at least %d rope sections" % analysis.rope_sections)

	# Check cliff exposures
	if analysis.cliff_exposures > 2:
		recommendations.append("Consider alternative route with fewer cliff exposures")

	# Check time
	if analysis.estimated_total_time > 360:
		recommendations.append("Long route - consider weather window carefully")

	if analysis.estimated_total_time > 600:
		recommendations.append("Very long route - bivy gear recommended")

	# Check exit zones
	var total_exit_zones := 0
	for segment in analysis.segments:
		total_exit_zones += segment.exit_zone_count

	if total_exit_zones < 3:
		recommendations.append("Limited exit options - commit carefully")

	# Risk-based recommendations
	if analysis.overall_risk > 0.7:
		recommendations.append("High risk route - ensure good conditions")

	if analysis.overall_risk > 0.5:
		recommendations.append("Practice self-arrest before attempting")

	return recommendations


# =============================================================================
# ROUTE OPTIMIZATION
# =============================================================================

## Suggest waypoints to improve a route
func suggest_waypoints(
	start: Vector3,
	end: Vector3,
	terrain: TerrainService,
	max_waypoints: int = 5
) -> Array[Vector3]:
	var suggestions: Array[Vector3] = []

	# Simple A* pathfinding with risk cost
	var direct_analysis := _analyze_segment(start, end, terrain)

	# If direct route is fine, no suggestions needed
	if direct_analysis.risk_level < 0.3:
		return suggestions

	# Sample potential waypoint locations
	var mid := start.lerp(end, 0.5)
	var perpendicular := Vector3(end.z - start.z, 0, start.x - end.x).normalized()

	# Try offsets perpendicular to direct route
	for offset_mult in [-100.0, -50.0, 50.0, 100.0]:
		var test_point := mid + perpendicular * offset_mult
		test_point.y = terrain.get_height_at(test_point)

		# Analyze route through this point
		var seg1 := _analyze_segment(start, test_point, terrain)
		var seg2 := _analyze_segment(test_point, end, terrain)
		var combined_risk := (seg1.risk_level + seg2.risk_level) / 2

		if combined_risk < direct_analysis.risk_level * 0.8:
			suggestions.append(test_point)

	# Sort by quality and limit
	# (Would need more sophisticated scoring)

	if suggestions.size() > max_waypoints:
		suggestions.resize(max_waypoints)

	return suggestions


# =============================================================================
# ELEVATION PROFILE
# =============================================================================

## Generate elevation profile data for a route
func get_elevation_profile(
	route: PackedVector3Array,
	terrain: TerrainService,
	num_samples: int = 100
) -> Dictionary:
	var profile := {
		"distances": PackedFloat32Array(),
		"elevations": PackedFloat32Array(),
		"slopes": PackedFloat32Array(),
		"terrain_zones": [],
		"total_distance": 0.0
	}

	if route.size() < 2:
		return profile

	# Calculate total route length
	var total_length := 0.0
	for i in range(route.size() - 1):
		total_length += route[i].distance_to(route[i + 1])

	profile["total_distance"] = total_length

	# Sample along route
	var sample_interval := total_length / num_samples
	var current_distance := 0.0
	var route_index := 0
	var segment_progress := 0.0

	for i in range(num_samples + 1):
		var target_distance := i * sample_interval

		# Find position along route at this distance
		while route_index < route.size() - 1:
			var segment_length := route[route_index].distance_to(route[route_index + 1])
			var segment_end_distance := current_distance + segment_length

			if segment_end_distance >= target_distance:
				# Interpolate within this segment
				var t := (target_distance - current_distance) / maxf(0.001, segment_length)
				var pos := route[route_index].lerp(route[route_index + 1], t)

				profile["distances"].append(target_distance)
				profile["elevations"].append(pos.y)
				profile["slopes"].append(terrain.get_slope_at(pos))
				profile["terrain_zones"].append(GameEnums.get_terrain_zone(terrain.get_slope_at(pos)))
				break

			current_distance = segment_end_distance
			route_index += 1

	return profile


# =============================================================================
# TIME ESTIMATION
# =============================================================================

## Get detailed time breakdown
func get_time_breakdown(analysis: RouteAnalysis) -> Dictionary:
	var walking_time := 0.0
	var technical_time := 0.0
	var rest_time := 0.0

	for segment in analysis.segments:
		walking_time += segment.estimated_time

		if segment.requires_rope:
			technical_time += rope_deploy_time

	# Estimate rest stops
	rest_time = analysis.estimated_total_time * 0.1  # 10% rest

	return {
		"walking": walking_time,
		"technical": technical_time,
		"rest": rest_time,
		"total": walking_time + technical_time + rest_time
	}


## Format time as hours:minutes
static func format_time(minutes: float) -> String:
	var hours := int(minutes) / 60
	var mins := int(minutes) % 60

	if hours > 0:
		return "%dh %02dm" % [hours, mins]
	else:
		return "%dm" % mins
