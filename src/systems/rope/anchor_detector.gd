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

## Range for "in reach" detection (an anchor you can rig from where you stand)
@export var reach_range: float = 3.5

## Carrying screws, pickets and nuts (set by RopeService from the loadout)
var has_anchor_kit: bool = true


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
			var anchor := anchor_at_cell(cell, has_anchor_kit)
			if anchor:
				anchors.append(anchor)

	anchors.append_array(scatter_anchors(center, half_range))
	return anchors


## The best anchor within reach of a stance, or null. A natural feature
## (horn, boulder) beats building one; with an anchor kit a crack takes a nut
## or cam, ice takes screws or a V-thread, snow takes a buried picket; without
## one, snow can still be cut into a bollard. Quality is never shown.
func find_anchor(center: Vector3, with_kit: bool, exclude: Array = []) -> AnchorPoint:
	if terrain_service == null:
		return null
	var best: AnchorPoint = null
	var best_score := -INF
	var steps := int(ceil(reach_range / 2.0))
	for x in range(-steps, steps + 1):
		for z in range(-steps, steps + 1):
			var at := center + Vector3(x * 2.0, 0.0, z * 2.0)
			var cell := terrain_service.get_cell_at(at)
			if cell == null:
				continue
			var anchor := anchor_at_cell(cell, with_kit)
			if anchor == null or _is_excluded(anchor, exclude):
				continue
			var distance := Vector2(anchor.position.x - center.x, anchor.position.z - center.z).length()
			if distance > reach_range + 1.0:
				continue
			# A climber picks what looks solid and is quick to rig, close by
			var score := anchor.get_effective_quality() - 0.08 * distance - 0.1 * anchor.get_placement_difficulty()
			if score > best_score:
				best_score = score
				best = anchor
	# A sling round a tree or a big boulder standing within reach
	for natural in scatter_anchors(center, reach_range + 1.0):
		if _is_excluded(natural, exclude):
			continue
		var natural_distance := Vector2(natural.position.x - center.x, natural.position.z - center.z).length()
		var natural_score := natural.get_effective_quality() - 0.08 * natural_distance - 0.1 * natural.get_placement_difficulty()
		if natural_score > best_score:
			best_score = natural_score
			best = natural
	return best


## Anchors offered by the trees and boulders standing near a point
## (TerrainScatter): a sound conifer or a big boulder takes a sling and is as
## good as anchors get; a dead snag is a gamble. Quality is never shown.
func scatter_anchors(center: Vector3, radius: float) -> Array[AnchorPoint]:
	var anchors: Array[AnchorPoint] = []
	if terrain_service == null or terrain_service.scatter == null:
		return anchors
	for obj in terrain_service.scatter.get_objects_near(center, radius):
		var roll := float(absi(hash(Vector3i(int(obj.position.x * 10.0), 0, int(obj.position.z * 10.0)))) % 1000) / 1000.0
		var anchor: AnchorPoint = null
		match obj.kind:
			TerrainScatter.Kind.CONIFER:
				if obj.size >= 3.0:
					anchor = AnchorPoint.new()
					anchor.anchor_type = AnchorPoint.AnchorType.TREE
					anchor.base_quality = clampf(0.78 + obj.size * 0.012 + 0.04 * roll, 0.78, 0.96)
			TerrainScatter.Kind.SNAG:
				anchor = AnchorPoint.new()
				anchor.anchor_type = AnchorPoint.AnchorType.TREE
				anchor.base_quality = 0.35 + 0.25 * roll  # Dead wood
			TerrainScatter.Kind.BOULDER:
				if obj.size >= 1.2:
					anchor = AnchorPoint.new()
					anchor.anchor_type = AnchorPoint.AnchorType.BOULDER
					anchor.base_quality = clampf(0.6 + obj.size * 0.12 + 0.05 * roll, 0.6, 0.95)
		if anchor == null:
			continue
		anchor.position = obj.position + Vector3(0.0, minf(1.0, obj.size * 0.3), 0.0)
		anchor.load_direction = Vector3.DOWN
		anchors.append(anchor)
	return anchors


## Anchor a terrain cell offers. Deterministic per cell so the same ledge
## offers the same horn every time you look at it
func anchor_at_cell(cell: TerrainCell, with_kit: bool) -> AnchorPoint:
	var roll_a := _cell_roll(cell, 17)
	var roll_b := _cell_roll(cell, 53)
	var roll_q := _cell_roll(cell, 91)
	var pos := cell.position

	match cell.surface_type:
		GameEnums.SurfaceType.ROCK, GameEnums.SurfaceType.ROCK_DRY, GameEnums.SurfaceType.ROCK_WET, GameEnums.SurfaceType.MIXED:
			if cell.slope_angle < 20.0:
				return null
			var anchor: AnchorPoint = null
			if roll_a < 0.35:
				anchor = AnchorPoint.new()
				anchor.anchor_type = AnchorPoint.AnchorType.ROCK_HORN if (cell.slope_angle > 45.0 or roll_b < 0.6) else AnchorPoint.AnchorType.BOULDER
				anchor.base_quality = 0.7 + 0.25 * roll_q
			elif with_kit and roll_b < 0.65:
				anchor = AnchorPoint.new()
				anchor.anchor_type = AnchorPoint.AnchorType.ROCK_CRACK
				anchor.base_quality = 0.55 + 0.3 * roll_q
			if anchor == null:
				return null
			anchor.position = pos
			anchor.rock_type_modifier = _get_rock_type_modifier(cell)
			if cell.surface_type == GameEnums.SurfaceType.ROCK_WET:
				anchor.weather_modifier = 0.85
			elif cell.surface_type == GameEnums.SurfaceType.MIXED:
				anchor.ice_coverage_modifier = 0.85
			if cell.slope_angle > 75.0:
				anchor.angle_modifier = 0.85
			anchor.load_direction = _load_direction(cell, 0.3)
			return anchor

		GameEnums.SurfaceType.ICE:
			if not with_kit:
				return null
			var ice: AnchorPoint
			if roll_a < 0.5:
				ice = AnchorPoint.create_ice_placement(pos, 0.65 + 0.25 * roll_q)
			else:
				ice = AnchorPoint.new()
				ice.position = pos
				ice.anchor_type = AnchorPoint.AnchorType.V_THREAD
				ice.base_quality = 0.7 + 0.2 * roll_q
			ice.load_direction = _load_direction(cell, 0.2)
			return ice

		GameEnums.SurfaceType.SNOW_FIRM, GameEnums.SurfaceType.SNOW_PACKED, GameEnums.SurfaceType.SNOW_SOFT, GameEnums.SurfaceType.SNOW_POWDER:
			var snow := AnchorPoint.new()
			snow.position = pos
			snow.load_direction = Vector3.DOWN
			var firmness := 1.0
			match cell.surface_type:
				GameEnums.SurfaceType.SNOW_SOFT:
					firmness = 0.75
				GameEnums.SurfaceType.SNOW_POWDER:
					firmness = 0.45
			if with_kit:
				snow.anchor_type = AnchorPoint.AnchorType.SNOW_STAKE
				snow.base_quality = (0.6 + 0.25 * roll_q) * firmness
			else:
				snow.anchor_type = AnchorPoint.AnchorType.SNOW_BOLLARD
				snow.base_quality = (0.5 + 0.25 * roll_q) * firmness
			return snow

		GameEnums.SurfaceType.SCREE:
			if roll_a < 0.15:
				var boulder := AnchorPoint.new()
				boulder.position = pos
				boulder.anchor_type = AnchorPoint.AnchorType.BOULDER
				boulder.base_quality = 0.4 + 0.3 * roll_q  # Loose ground
				boulder.load_direction = _load_direction(cell, 0.3)
				return boulder

	return null


## Repeatable 0-1 value for a cell
func _cell_roll(cell: TerrainCell, salt: int) -> float:
	var h := hash(Vector3i(cell.grid_coords.x, cell.grid_coords.y, salt) + Vector3i(int(cell.position.x), 0, int(cell.position.z)))
	return float(absi(h) % 10000) / 10000.0


func _load_direction(cell: TerrainCell, slope_lean: float) -> Vector3:
	return Vector3(
		-cell.slope_direction.x * slope_lean,
		-0.9,
		-cell.slope_direction.z * slope_lean
	).normalized()


func _is_excluded(anchor: AnchorPoint, exclude: Array) -> bool:
	for other in exclude:
		var other_anchor := other as AnchorPoint
		if other_anchor != null and other_anchor.position.distance_to(anchor.position) < 0.5:
			return true
	return false


func _get_rock_type_modifier(cell: TerrainCell) -> float:
	# Different rock types have different reliability
	# This would ideally come from terrain data
	# For now, use a simple heuristic based on position
	var noise_val := sin(cell.position.x * 0.1) * cos(cell.position.z * 0.1)
	return 0.8 + noise_val * 0.2  # Range 0.6-1.0


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
