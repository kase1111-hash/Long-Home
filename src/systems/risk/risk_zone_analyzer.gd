class_name RiskZoneAnalyzer
extends Node
## Analyzes terrain for risk zones and point-of-no-return detection
## Pre-computes risk fields for efficient real-time queries
##
## Design Philosophy:
## - Risk zones are invisible but felt
## - Players learn danger through experience
## - Point of no return is a real concept
## - Some risks can be predicted, some cannot

# =============================================================================
# SIGNALS
# =============================================================================

signal risk_zone_entered(zone_type: ZoneType, position: Vector3)
signal risk_zone_exited(zone_type: ZoneType)
signal point_of_no_return_detected(distance: float)
signal commitment_zone_entered(escape_difficulty: float)
signal safe_zone_found(position: Vector3, quality: float)

# =============================================================================
# ENUMS
# =============================================================================

enum ZoneType {
	SAFE,              # Low risk, multiple escape options
	CAUTION,           # Elevated risk, limited options
	DANGER,            # High risk, few escape options
	CRITICAL,          # Very high risk, committed
	TERMINAL           # No recovery possible
}

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Zone Detection")
## Range to scan for risk zones
@export var scan_range: float = 50.0
## Update interval for zone analysis
@export var update_interval: float = 0.5
## Grid resolution for risk field
@export var grid_resolution: float = 5.0

@export_group("Thresholds")
## Distance to cliff for danger zone
@export var cliff_danger_distance: float = 15.0
## Slope angle for caution zone
@export var caution_slope: float = 35.0
## Slope angle for danger zone
@export var danger_slope: float = 50.0

# =============================================================================
# STATE
# =============================================================================

## Terrain service reference
var terrain_service: TerrainService

## Current player position
var player_position: Vector3 = Vector3.ZERO

## Current player velocity
var player_velocity: Vector3 = Vector3.ZERO

## Current zone type
var current_zone: ZoneType = ZoneType.SAFE

## Risk field (position hash -> risk value)
var risk_field: Dictionary = {}

## Update timer
var update_timer: float = 0.0

## Cached escape routes
var escape_routes: Array[EscapeRoute] = []

## Detected point of no return
var point_of_no_return_distance: float = INF


# =============================================================================
# DATA CLASSES
# =============================================================================

class EscapeRoute:
	var direction: Vector3 = Vector3.ZERO
	var distance: float = 0.0
	var difficulty: float = 0.0  # 0 = easy, 1 = very hard
	var safe_zone_position: Vector3 = Vector3.ZERO

	func is_viable() -> bool:
		return difficulty < 0.8


class RiskZone:
	var center: Vector3 = Vector3.ZERO
	var radius: float = 10.0
	var zone_type: ZoneType = ZoneType.CAUTION
	var risk_value: float = 0.5
	var reason: String = ""


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.register_service("RiskZoneAnalyzer", self)


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	update_timer += delta

	if update_timer >= update_interval:
		update_timer = 0.0
		_update_risk_analysis()


func _update_risk_analysis() -> void:
	if terrain_service == null:
		return

	# Analyze current position
	var new_zone := _analyze_current_zone()

	if new_zone != current_zone:
		var old_zone := current_zone
		current_zone = new_zone

		if new_zone > old_zone:
			risk_zone_entered.emit(new_zone, player_position)
		else:
			risk_zone_exited.emit(old_zone)

	# Update risk field around player
	_update_risk_field()

	# Find escape routes
	_analyze_escape_routes()

	# Check for point of no return
	_check_point_of_no_return()


func _analyze_current_zone() -> ZoneType:
	var cell := terrain_service.get_cell_at(player_position)
	if cell == null:
		return ZoneType.CAUTION

	# Check cliff proximity
	if cell.distance_to_cliff < 5.0:
		return ZoneType.TERMINAL
	elif cell.distance_to_cliff < cliff_danger_distance:
		return ZoneType.CRITICAL

	# Check slope
	if cell.slope_angle >= danger_slope:
		return ZoneType.DANGER
	elif cell.slope_angle >= caution_slope:
		return ZoneType.CAUTION

	# Check surface
	if cell.surface_type == GameEnums.SurfaceType.ICE:
		return ZoneType.DANGER

	# Check for exit zones
	if cell.is_exit_zone:
		return ZoneType.SAFE

	return ZoneType.SAFE


func _update_risk_field() -> void:
	risk_field.clear()

	var half_range := scan_range / 2.0
	var step := grid_resolution

	for x in range(-int(half_range / step), int(half_range / step) + 1):
		for z in range(-int(half_range / step), int(half_range / step) + 1):
			var pos := player_position + Vector3(x * step, 0, z * step)
			var risk := _calculate_position_risk(pos)
			var hash := _position_hash(pos)
			risk_field[hash] = risk


func _calculate_position_risk(position: Vector3) -> float:
	var cell := terrain_service.get_cell_at(position)
	if cell == null:
		return 0.5  # Unknown = moderate risk

	var risk := 0.0

	# Slope contribution
	risk += clampf(cell.slope_angle / 60.0, 0.0, 1.0) * 0.4

	# Cliff contribution
	if cell.distance_to_cliff < cliff_danger_distance:
		risk += (1.0 - cell.distance_to_cliff / cliff_danger_distance) * 0.4

	# Surface contribution
	match cell.surface_type:
		GameEnums.SurfaceType.ICE:
			risk += 0.3
		GameEnums.SurfaceType.SCREE:
			risk += 0.2
		GameEnums.SurfaceType.ROCK:
			risk += 0.1

	return clampf(risk, 0.0, 1.0)


func _analyze_escape_routes() -> void:
	escape_routes.clear()

	# Check 8 directions
	var directions := [
		Vector3(1, 0, 0),
		Vector3(-1, 0, 0),
		Vector3(0, 0, 1),
		Vector3(0, 0, -1),
		Vector3(1, 0, 1).normalized(),
		Vector3(-1, 0, 1).normalized(),
		Vector3(1, 0, -1).normalized(),
		Vector3(-1, 0, -1).normalized()
	]

	for dir in directions:
		var route := _analyze_escape_direction(dir)
		if route:
			escape_routes.append(route)

	# Sort by difficulty
	escape_routes.sort_custom(func(a, b): return a.difficulty < b.difficulty)


func _analyze_escape_direction(direction: Vector3) -> EscapeRoute:
	var route := EscapeRoute.new()
	route.direction = direction

	var check_distance := 5.0
	var max_distance := 30.0
	var total_difficulty := 0.0
	var samples := 0

	while check_distance < max_distance:
		var check_pos := player_position + direction * check_distance
		var cell := terrain_service.get_cell_at(check_pos)

		if cell == null:
			break

		# Calculate difficulty for this segment
		var segment_difficulty := 0.0

		# Uphill is harder
		if cell.slope_direction.dot(direction) < 0:
			segment_difficulty += cell.slope_angle / 45.0 * 0.5

		# Bad surface is harder
		if cell.surface_type == GameEnums.SurfaceType.ICE:
			segment_difficulty += 0.4

		# Near cliff is impossible
		if cell.distance_to_cliff < 3.0:
			route.difficulty = 1.0
			return route

		total_difficulty += segment_difficulty
		samples += 1

		# Check if we've reached safety
		if cell.is_exit_zone or cell.slope_angle < 25.0:
			route.distance = check_distance
			route.difficulty = total_difficulty / samples if samples > 0 else 0.5
			route.safe_zone_position = check_pos
			return route

		check_distance += 5.0

	# Didn't find safety
	route.distance = max_distance
	route.difficulty = total_difficulty / samples if samples > 0 else 0.8
	return route


func _check_point_of_no_return() -> void:
	# Check if any escape route is viable
	var has_viable_escape := false
	var best_escape_difficulty := 1.0

	for route in escape_routes:
		if route.is_viable():
			has_viable_escape = true
			best_escape_difficulty = minf(best_escape_difficulty, route.difficulty)

	if not has_viable_escape:
		# Calculate distance to point of no return
		# (how far until even the best route becomes unviable)
		point_of_no_return_distance = _calculate_distance_to_ponr()

		if point_of_no_return_distance < 20.0:
			point_of_no_return_detected.emit(point_of_no_return_distance)
			EventBus.point_of_no_return_detected.emit()
	else:
		point_of_no_return_distance = INF

	# Check commitment zones
	if best_escape_difficulty > 0.5 and best_escape_difficulty < 0.8:
		commitment_zone_entered.emit(best_escape_difficulty)


func _calculate_distance_to_ponr() -> float:
	# Project forward along velocity to see when escape becomes impossible
	if player_velocity.length() < 0.5:
		return INF

	var velocity_dir := player_velocity.normalized()
	var check_distance := 5.0

	while check_distance < 100.0:
		var check_pos := player_position + velocity_dir * check_distance

		# Check if any escape from this position
		var has_escape := false
		for dir_offset in [0, 45, -45, 90, -90]:
			var escape_dir := velocity_dir.rotated(Vector3.UP, deg_to_rad(dir_offset))
			var escape_pos := check_pos + escape_dir * 20.0
			var cell := terrain_service.get_cell_at(escape_pos)

			if cell and (cell.is_exit_zone or cell.slope_angle < 30.0):
				has_escape = true
				break

		if not has_escape:
			return check_distance

		check_distance += 10.0

	return INF


# =============================================================================
# QUERIES
# =============================================================================

## Update player state
func update_player(position: Vector3, velocity: Vector3) -> void:
	player_position = position
	player_velocity = velocity


## Get risk at position
func get_risk_at(position: Vector3) -> float:
	var hash := _position_hash(position)
	return risk_field.get(hash, _calculate_position_risk(position))


## Get current zone type
func get_current_zone() -> ZoneType:
	return current_zone


## Get zone type name
func get_zone_name() -> String:
	return ZoneType.keys()[current_zone]


## Get best escape route
func get_best_escape() -> EscapeRoute:
	if escape_routes.is_empty():
		return null
	return escape_routes[0]


## Get all viable escape routes
func get_viable_escapes() -> Array[EscapeRoute]:
	var viable: Array[EscapeRoute] = []
	for route in escape_routes:
		if route.is_viable():
			viable.append(route)
	return viable


## Check if in danger zone
func is_in_danger() -> bool:
	return current_zone >= ZoneType.DANGER


## Check if committed (hard to escape)
func is_committed() -> bool:
	return current_zone >= ZoneType.CRITICAL or get_viable_escapes().is_empty()


## Get distance to point of no return
func get_ponr_distance() -> float:
	return point_of_no_return_distance


## Find nearest safe zone
func find_nearest_safe_zone() -> Vector3:
	var best := get_best_escape()
	if best:
		return best.safe_zone_position
	return Vector3.ZERO


func _position_hash(position: Vector3) -> int:
	var x := int(position.x / grid_resolution) * int(grid_resolution)
	var z := int(position.z / grid_resolution) * int(grid_resolution)
	return x * 10000 + z


## Get summary
func get_summary() -> Dictionary:
	return {
		"current_zone": get_zone_name(),
		"is_in_danger": is_in_danger(),
		"is_committed": is_committed(),
		"viable_escapes": get_viable_escapes().size(),
		"ponr_distance": point_of_no_return_distance if point_of_no_return_distance < INF else -1
	}
