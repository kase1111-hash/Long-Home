class_name AnchorDetector
extends Node
## Detects potential anchor points in the terrain
## Provides visual/audio hints without explicit ratings
##
## Design Philosophy:
## - No UI indicators for anchor quality
## - Players learn to read terrain visually
## - Hints are subtle and diegetic (sound, visual)
## - Quality is never explicitly shown

# =============================================================================
# SIGNALS
# =============================================================================

signal anchor_detected(anchor: AnchorPoint)
signal anchor_in_range(anchor: AnchorPoint, distance: float)
signal anchor_lost(anchor: AnchorPoint)
signal no_anchors_found()
signal scanning_complete(anchors: Array[AnchorPoint])

# =============================================================================
# CONFIGURATION
# =============================================================================

## Maximum detection range
@export var detection_range: float = 8.0

## Scan update interval
@export var scan_interval: float = 0.5

## Maximum anchors to track
@export var max_tracked: int = 5

## Range for "in reach" detection
@export var reach_range: float = 2.0


# =============================================================================
# STATE
# =============================================================================

## Terrain service reference
var terrain_service: TerrainService

## Player reference
var player: Node3D

## Currently detected anchors
var detected_anchors: Array[AnchorPoint] = []

## Anchor currently in reach
var anchor_in_reach: AnchorPoint = null

## Scan timer
var scan_timer: float = 0.0

## Last scan position
var last_scan_position: Vector3 = Vector3.ZERO

## Minimum movement before rescan
var rescan_threshold: float = 2.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	ServiceLocator.get_service_async("TerrainService", _on_terrain_ready)
	ServiceLocator.get_service_async("PlayerController", _on_player_ready)


func _on_terrain_ready(service: Object) -> void:
	terrain_service = service as TerrainService


func _on_player_ready(service: Object) -> void:
	player = service as Node3D


# =============================================================================
# UPDATE
# =============================================================================

func _physics_process(delta: float) -> void:
	if player == null or terrain_service == null:
		return

	scan_timer += delta

	# Check if rescan needed
	var should_rescan := false
	if scan_timer >= scan_interval:
		should_rescan = true
	if player.global_position.distance_to(last_scan_position) > rescan_threshold:
		should_rescan = true

	if should_rescan:
		_perform_scan()
		scan_timer = 0.0
		last_scan_position = player.global_position

	# Update anchor reach status
	_update_reach_status()


func _perform_scan() -> void:
	var player_pos := player.global_position

	# Clear old anchors that are now out of range
	var to_remove: Array[AnchorPoint] = []
	for anchor in detected_anchors:
		if player_pos.distance_to(anchor.position) > detection_range * 1.5:
			to_remove.append(anchor)
			anchor_lost.emit(anchor)

	for anchor in to_remove:
		detected_anchors.erase(anchor)

	# Scan for new anchors
	var new_anchors := _scan_terrain_for_anchors(player_pos)

	for anchor in new_anchors:
		if not _is_anchor_known(anchor):
			detected_anchors.append(anchor)
			anchor_detected.emit(anchor)

	# Limit tracked anchors
	while detected_anchors.size() > max_tracked:
		var farthest := _get_farthest_anchor(player_pos)
		if farthest:
			detected_anchors.erase(farthest)
			anchor_lost.emit(farthest)

	# Emit result
	if detected_anchors.is_empty():
		no_anchors_found.emit()
	else:
		scanning_complete.emit(detected_anchors)


func _update_reach_status() -> void:
	var player_pos := player.global_position
	var closest: AnchorPoint = null
	var closest_dist := reach_range

	for anchor in detected_anchors:
		var dist := player_pos.distance_to(anchor.position)
		if dist < closest_dist:
			closest_dist = dist
			closest = anchor

	if closest != anchor_in_reach:
		anchor_in_reach = closest
		if closest:
			anchor_in_range.emit(closest, closest_dist)


# =============================================================================
# TERRAIN SCANNING
# =============================================================================

func _scan_terrain_for_anchors(center: Vector3) -> Array[AnchorPoint]:
	var anchors: Array[AnchorPoint] = []

	# Scan in a grid pattern
	var scan_step := 2.0
	var half_range := detection_range / 2.0

	for x in range(-int(half_range / scan_step), int(half_range / scan_step) + 1):
		for z in range(-int(half_range / scan_step), int(half_range / scan_step) + 1):
			var scan_pos := center + Vector3(x * scan_step, 0, z * scan_step)

			# Get terrain cell
			var cell := terrain_service.get_cell_at(scan_pos)
			if cell == null:
				continue

			# Check for anchor potential based on terrain
			var anchor := _evaluate_anchor_potential(scan_pos, cell)
			if anchor:
				anchors.append(anchor)

	return anchors


func _evaluate_anchor_potential(pos: Vector3, cell: TerrainCell) -> AnchorPoint:
	# Different surfaces provide different anchor types

	# Rock surfaces
	if cell.surface_type == GameEnums.SurfaceType.ROCK:
		# Steep rock may have horns or cracks
		if cell.slope_angle > 40.0:
			if randf() < 0.3:  # Not every rock is suitable
				return _create_rock_anchor(pos, cell)

	# Ice surfaces
	if cell.surface_type == GameEnums.SurfaceType.ICE:
		# Thick ice can take screws
		if randf() < 0.2:
			return _create_ice_anchor(pos, cell)

	# Firm snow
	if cell.surface_type == GameEnums.SurfaceType.SNOW_FIRM:
		# Can place snow stakes
		if cell.slope_angle > 30.0 and randf() < 0.15:
			return _create_snow_anchor(pos, cell)

	# Check for fixed anchors (pre-placed bolts on popular routes)
	if _is_on_route(pos) and randf() < 0.05:
		return AnchorPoint.create_fixed(pos)

	return null


func _create_rock_anchor(pos: Vector3, cell: TerrainCell) -> AnchorPoint:
	var anchor := AnchorPoint.new()
	anchor.position = pos

	# Determine type based on terrain
	var type_roll := randf()
	if type_roll < 0.4:
		anchor.anchor_type = AnchorPoint.AnchorType.ROCK_HORN
		anchor.base_quality = 0.7 + randf() * 0.2
	elif type_roll < 0.7:
		anchor.anchor_type = AnchorPoint.AnchorType.ROCK_CRACK
		anchor.base_quality = 0.5 + randf() * 0.3
	else:
		anchor.anchor_type = AnchorPoint.AnchorType.BOULDER
		anchor.base_quality = 0.6 + randf() * 0.3

	# Set load direction (generally downward with slope influence)
	anchor.load_direction = Vector3(
		-cell.slope_direction.x * 0.3,
		-0.9,
		-cell.slope_direction.z * 0.3
	).normalized()

	# Apply rock type modifier
	anchor.rock_type_modifier = _get_rock_type_modifier(cell)

	# Apply angle modifier (overhangs are worse)
	if cell.slope_angle > 60.0:
		anchor.angle_modifier = 0.7
	elif cell.slope_angle > 45.0:
		anchor.angle_modifier = 0.85

	return anchor


func _create_ice_anchor(pos: Vector3, cell: TerrainCell) -> AnchorPoint:
	var anchor := AnchorPoint.create_ice_placement(pos, 0.6 + randf() * 0.3)

	# Adjust for slope
	anchor.load_direction = Vector3(
		-cell.slope_direction.x * 0.2,
		-0.95,
		-cell.slope_direction.z * 0.2
	).normalized()

	return anchor


func _create_snow_anchor(pos: Vector3, cell: TerrainCell) -> AnchorPoint:
	var anchor := AnchorPoint.new()
	anchor.position = pos
	anchor.anchor_type = AnchorPoint.AnchorType.SNOW_STAKE
	anchor.base_quality = 0.4 + randf() * 0.3  # Snow is unreliable
	anchor.load_direction = Vector3.DOWN

	return anchor


func _get_rock_type_modifier(cell: TerrainCell) -> float:
	# Different rock types have different reliability
	# This would ideally come from terrain data
	# For now, use a simple heuristic based on position
	var noise_val := sin(cell.position.x * 0.1) * cos(cell.position.z * 0.1)
	return 0.8 + noise_val * 0.2  # Range 0.6-1.0


func _is_on_route(pos: Vector3) -> bool:
	# Check if position is on a common route
	# Would integrate with route system
	# For now, simple probability
	return false


func _is_anchor_known(anchor: AnchorPoint) -> bool:
	for known in detected_anchors:
		if known.position.distance_to(anchor.position) < 1.0:
			return true
	return false


func _get_farthest_anchor(from: Vector3) -> AnchorPoint:
	var farthest: AnchorPoint = null
	var max_dist := 0.0

	for anchor in detected_anchors:
		var dist := from.distance_to(anchor.position)
		if dist > max_dist:
			max_dist = dist
			farthest = anchor

	return farthest


# =============================================================================
# QUERIES
# =============================================================================

## Get closest anchor to position
func get_closest_anchor(pos: Vector3) -> AnchorPoint:
	var closest: AnchorPoint = null
	var min_dist := INF

	for anchor in detected_anchors:
		var dist := pos.distance_to(anchor.position)
		if dist < min_dist:
			min_dist = dist
			closest = anchor

	return closest


## Get anchor in reach (if any)
func get_reachable_anchor() -> AnchorPoint:
	return anchor_in_reach


## Check if any anchor is available
func has_anchor_available() -> bool:
	return not detected_anchors.is_empty()


## Get all detected anchors
func get_all_anchors() -> Array[AnchorPoint]:
	return detected_anchors.duplicate()


## Get anchors by type
func get_anchors_by_type(type: AnchorPoint.AnchorType) -> Array[AnchorPoint]:
	var result: Array[AnchorPoint] = []
	for anchor in detected_anchors:
		if anchor.anchor_type == type:
			result.append(anchor)
	return result


## Get best anchor in range (highest quality, never shown to player)
func get_best_anchor() -> AnchorPoint:
	var best: AnchorPoint = null
	var best_quality := 0.0

	for anchor in detected_anchors:
		var quality := anchor.get_effective_quality()
		if quality > best_quality:
			best_quality = quality
			best = anchor

	return best


## Force immediate rescan
func force_rescan() -> void:
	scan_timer = scan_interval
