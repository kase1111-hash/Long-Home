class_name ExitZoneDetector
extends Node
## Detects and tracks exit zones during sliding
## Exit zones are where slides can be safely stopped

# =============================================================================
# SIGNALS
# =============================================================================

signal exit_zone_detected(zone: ExitZone)
signal exit_zone_entered(zone: ExitZone)
signal exit_zone_missed(zone: ExitZone)
signal no_exit_zones_ahead()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Maximum distance to scan for exit zones
var scan_distance: float = 50.0

## Scan update interval
var scan_interval: float = 0.2

## Minimum quality to consider viable
var min_viable_quality: float = 0.3

## Warning distance for approaching exit
var approach_warning_distance: float = 15.0

# =============================================================================
# STATE
# =============================================================================

## Reference to slide system
var slide_system: SlideSystem

## Terrain service reference
var terrain_service: TerrainService

## Currently tracked exit zones ahead
var tracked_zones: Array[ExitZone] = []

## Current best exit zone
var best_zone: ExitZone = null

## Time since last scan
var scan_timer: float = 0.0

## Has warned about no exits
var no_exit_warning_emitted: bool = false


# =============================================================================
# EXIT ZONE DATA
# =============================================================================

class ExitZone:
	var position: Vector3 = Vector3.ZERO
	var quality: float = 0.0  # 0-1, how good of a stop
	var distance: float = 0.0  # Distance from player
	var angle: float = 0.0  # Angle from current trajectory
	var slope: float = 0.0  # Slope at exit
	var surface: GameEnums.SurfaceType = GameEnums.SurfaceType.SNOW_FIRM
	var is_viable: bool = true  # Can actually reach it
	var time_to_reach: float = 0.0  # Estimated time

	func calculate_viability(player_speed: float, player_control: float) -> void:
		# Can't reach if angle too steep
		if absf(angle) > 45.0:
			is_viable = false
			return

		# Can't reach if too far and low control
		if distance > 30.0 and player_control < 0.5:
			is_viable = false
			return

		# Calculate time to reach
		if player_speed > 0.1:
			time_to_reach = distance / player_speed
		else:
			time_to_reach = 999.0

		is_viable = true


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(system: SlideSystem) -> void:
	slide_system = system


func _ready() -> void:
	ServiceLocator.get_service_async("TerrainService", func(service):
		terrain_service = service as TerrainService
	)


# =============================================================================
# UPDATE
# =============================================================================

func update(delta: float) -> void:
	if not slide_system.is_sliding:
		_reset()
		return

	scan_timer += delta
	if scan_timer >= scan_interval:
		scan_timer = 0.0
		_scan_for_exits()

	_update_zone_tracking()
	_check_zone_proximity()


func _reset() -> void:
	tracked_zones.clear()
	best_zone = null
	no_exit_warning_emitted = false


# =============================================================================
# SCANNING
# =============================================================================

func _scan_for_exits() -> void:
	if terrain_service == null:
		return

	var state := slide_system.current_state
	var position := state.position
	var velocity := state.velocity

	# Clear old zones
	tracked_zones.clear()

	# Scan ahead in velocity direction
	var scan_dir := velocity.normalized() if velocity.length() > 0.5 else state.slope_direction

	# Get cells in a cone ahead
	var cells := terrain_service.get_cells_in_radius(position, scan_distance)

	for cell in cells:
		if not cell.is_exit_zone:
			continue

		if cell.exit_zone_quality < min_viable_quality:
			continue

		# Check if zone is ahead (not behind)
		var to_zone := cell.position - position
		var dot := to_zone.normalized().dot(scan_dir)

		if dot < 0.3:  # Behind or too far to side
			continue

		# Create exit zone data
		var zone := ExitZone.new()
		zone.position = cell.position
		zone.quality = cell.exit_zone_quality
		zone.distance = to_zone.length()
		zone.angle = rad_to_deg(acos(clampf(dot, -1.0, 1.0)))
		zone.slope = cell.slope_angle
		zone.surface = cell.surface_type

		zone.calculate_viability(state.speed, state.control)

		if zone.is_viable:
			tracked_zones.append(zone)

	# Sort by quality * distance factor
	tracked_zones.sort_custom(func(a: ExitZone, b: ExitZone):
		var score_a := a.quality / (a.distance + 1.0)
		var score_b := b.quality / (b.distance + 1.0)
		return score_a > score_b
	)

	# Update best zone
	if tracked_zones.size() > 0:
		var new_best := tracked_zones[0]
		if best_zone == null or new_best.position != best_zone.position:
			best_zone = new_best
			exit_zone_detected.emit(best_zone)
		no_exit_warning_emitted = false
	else:
		best_zone = null
		if not no_exit_warning_emitted:
			no_exit_warning_emitted = true
			no_exit_zones_ahead.emit()


func _update_zone_tracking() -> void:
	var state := slide_system.current_state
	var position := state.position

	# Update distances for tracked zones
	for zone in tracked_zones:
		zone.distance = position.distance_to(zone.position)

		# Recalculate angle
		var to_zone := zone.position - position
		if state.velocity.length() > 0.5:
			var dot := to_zone.normalized().dot(state.velocity.normalized())
			zone.angle = rad_to_deg(acos(clampf(dot, -1.0, 1.0)))

		zone.calculate_viability(state.speed, state.control)

	# Remove zones we've passed
	tracked_zones = tracked_zones.filter(func(z: ExitZone):
		return z.distance > 2.0 and z.is_viable
	)


func _check_zone_proximity() -> void:
	var state := slide_system.current_state
	var position := state.position

	for zone in tracked_zones:
		# Check if approaching
		if zone.distance < approach_warning_distance and zone == best_zone:
			slide_system.exit_zone_approached.emit(zone.distance, zone.quality)

		# Check if entered
		if zone.distance < 3.0:
			exit_zone_entered.emit(zone)

		# Check if missed (passed by)
		if zone.distance < 10.0:
			var to_zone := zone.position - position
			var dot := to_zone.normalized().dot(state.velocity.normalized())
			if dot < -0.5:  # Moving away from zone
				exit_zone_missed.emit(zone)
				tracked_zones.erase(zone)


# =============================================================================
# QUERIES
# =============================================================================

## Get the best exit zone ahead
func get_best_exit() -> ExitZone:
	return best_zone


## Get all viable exit zones
func get_viable_exits() -> Array[ExitZone]:
	return tracked_zones.filter(func(z): return z.is_viable)


## Check if there are any viable exits
func has_viable_exit() -> bool:
	return best_zone != null and best_zone.is_viable


## Get distance to nearest exit
func get_nearest_exit_distance() -> float:
	if best_zone:
		return best_zone.distance
	return 999.0


## Get time to reach best exit
func get_time_to_exit() -> float:
	if best_zone:
		return best_zone.time_to_reach
	return 999.0


## Get guidance direction to best exit (-1 to 1, negative = go left)
func get_exit_guidance() -> float:
	if best_zone == null:
		return 0.0

	var state := slide_system.current_state
	var to_zone := best_zone.position - state.position

	# Get perpendicular direction
	var velocity_dir := state.velocity.normalized() if state.velocity.length() > 0.5 else state.slope_direction
	var right := velocity_dir.cross(Vector3.UP).normalized()

	var lateral := to_zone.dot(right)

	# Normalize to -1 to 1
	return clampf(lateral / 10.0, -1.0, 1.0)
