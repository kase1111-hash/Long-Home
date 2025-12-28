class_name TerrainService
extends Node
## Central service for terrain queries and management
## Provides the main API for other systems to interact with terrain

# =============================================================================
# SIGNALS
# =============================================================================

signal terrain_loaded(mountain_id: String)
signal chunk_loaded(chunk_coords: Vector2i)
signal terrain_updated()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Size of each chunk in world units
@export var chunk_size: float = 64.0

## Resolution of each chunk (cells per side)
@export var chunk_resolution: int = 32

## How many chunks to keep loaded around player
@export var load_radius: int = 3

# =============================================================================
# STATE
# =============================================================================

## Currently loaded mountain ID
var current_mountain: String = ""

## Loaded terrain chunks (chunk_coords -> TerrainChunk)
var chunks: Dictionary = {}

## Terrain bounds
var terrain_bounds_min: Vector3 = Vector3.ZERO
var terrain_bounds_max: Vector3 = Vector3.ZERO

## Analysis tools
var slope_analyzer: SlopeAnalyzer
var surface_classifier: SurfaceClassifier

## Cached cell for frequent queries
var _cached_cell: TerrainCell = null
var _cached_position: Vector3 = Vector3.INF

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	slope_analyzer = SlopeAnalyzer.new()
	slope_analyzer.cell_size = chunk_size / chunk_resolution

	surface_classifier = SurfaceClassifier.new()

	# Register with service locator
	ServiceLocator.register_service("TerrainService", self)

	print("[TerrainService] Initialized")


# =============================================================================
# TERRAIN LOADING
# =============================================================================

## Load terrain for a mountain
func load_terrain(mountain_id: String) -> bool:
	print("[TerrainService] Loading terrain: %s" % mountain_id)

	current_mountain = mountain_id
	chunks.clear()

	# For now, generate procedural terrain
	# TODO: Load from DEM data files
	_generate_test_terrain()

	terrain_loaded.emit(mountain_id)
	return true


## Generate test terrain for development
func _generate_test_terrain() -> void:
	# Generate a 3x3 grid of chunks for testing
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			var chunk := _generate_test_chunk(Vector2i(cx, cz))
			chunks[Vector2i(cx, cz)] = chunk
			chunk_loaded.emit(Vector2i(cx, cz))

	_update_terrain_bounds()
	terrain_updated.emit()


func _generate_test_chunk(coords: Vector2i) -> TerrainChunk:
	var chunk := TerrainChunk.new(coords, chunk_size, chunk_resolution)

	# Generate heightmap with realistic mountain features
	var heightmap := PackedFloat32Array()
	heightmap.resize(chunk_resolution * chunk_resolution)

	var base_elevation := 3000.0  # Summit area
	var noise_scale := 0.02

	for z in range(chunk_resolution):
		for x in range(chunk_resolution):
			var world_x := chunk.world_origin.x + x * chunk.cell_size
			var world_z := chunk.world_origin.z + z * chunk.cell_size

			# Multi-octave noise for natural terrain
			var height := base_elevation
			height += _fbm_noise(world_x * noise_scale, world_z * noise_scale, 4) * 200.0

			# Add ridge features
			height += _ridge_noise(world_x * noise_scale * 0.5, world_z * noise_scale * 0.5) * 100.0

			# Descending gradient (summit at center)
			var dist_from_center := Vector2(world_x, world_z).length()
			height -= dist_from_center * 0.3

			# Add some cliffs
			if _cliff_noise(world_x * 0.01, world_z * 0.01) > 0.7:
				height -= 30.0  # Sudden drop

			heightmap[z * chunk_resolution + x] = height

	chunk.load_heightmap(heightmap, chunk_resolution)
	chunk.analyze()

	# Classify surfaces
	_classify_chunk_surfaces(chunk)

	return chunk


func _classify_chunk_surfaces(chunk: TerrainChunk) -> void:
	for x in range(chunk.resolution):
		for z in range(chunk.resolution):
			var cell := chunk.get_cell(Vector2i(x, z))
			cell.surface_type = surface_classifier.classify_surface(cell)
			cell.surface_firmness = surface_classifier.get_firmness(cell.surface_type)
			cell.friction = surface_classifier.get_friction(cell.surface_type)


## Simple noise functions for terrain generation
func _fbm_noise(x: float, z: float, octaves: int) -> float:
	var value := 0.0
	var amplitude := 1.0
	var frequency := 1.0
	var max_value := 0.0

	for i in range(octaves):
		value += _simple_noise(x * frequency, z * frequency) * amplitude
		max_value += amplitude
		amplitude *= 0.5
		frequency *= 2.0

	return value / max_value


func _simple_noise(x: float, z: float) -> float:
	# Simple pseudo-random noise based on position
	var n := sin(x * 12.9898 + z * 78.233) * 43758.5453
	return fmod(n, 1.0) * 2.0 - 1.0


func _ridge_noise(x: float, z: float) -> float:
	var n := absf(_simple_noise(x, z))
	return 1.0 - n


func _cliff_noise(x: float, z: float) -> float:
	return (_simple_noise(x * 3.7, z * 2.9) + 1.0) * 0.5


func _update_terrain_bounds() -> void:
	if chunks.is_empty():
		return

	terrain_bounds_min = Vector3(INF, INF, INF)
	terrain_bounds_max = Vector3(-INF, -INF, -INF)

	for chunk in chunks.values():
		terrain_bounds_min.x = minf(terrain_bounds_min.x, chunk.bounds_min.x)
		terrain_bounds_min.y = minf(terrain_bounds_min.y, chunk.bounds_min.y)
		terrain_bounds_min.z = minf(terrain_bounds_min.z, chunk.bounds_min.z)
		terrain_bounds_max.x = maxf(terrain_bounds_max.x, chunk.bounds_max.x)
		terrain_bounds_max.y = maxf(terrain_bounds_max.y, chunk.bounds_max.y)
		terrain_bounds_max.z = maxf(terrain_bounds_max.z, chunk.bounds_max.z)


# =============================================================================
# POSITION QUERIES
# =============================================================================

## Get the chunk containing a world position
func get_chunk_at(world_pos: Vector3) -> TerrainChunk:
	var chunk_x := int(floor(world_pos.x / chunk_size))
	var chunk_z := int(floor(world_pos.z / chunk_size))
	return chunks.get(Vector2i(chunk_x, chunk_z), null)


## Get terrain cell at world position
func get_cell_at(world_pos: Vector3) -> TerrainCell:
	# Check cache first
	if _cached_cell and _cached_position.distance_to(world_pos) < 0.5:
		return _cached_cell

	var chunk := get_chunk_at(world_pos)
	if chunk == null:
		return null

	var cell := chunk.get_cell_at_world(world_pos)

	# Update cache
	_cached_cell = cell
	_cached_position = world_pos

	return cell


## Get height at world position (interpolated)
func get_height_at(world_pos: Vector3) -> float:
	var chunk := get_chunk_at(world_pos)
	if chunk == null:
		return 0.0
	return chunk.get_height_at_world(world_pos)


## Get slope angle at world position (degrees)
func get_slope_at(world_pos: Vector3) -> float:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return 0.0
	return cell.slope_angle


## Get slope direction at world position (downhill)
func get_slope_direction_at(world_pos: Vector3) -> Vector3:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return Vector3.ZERO
	return cell.slope_direction


## Get surface type at world position
func get_surface_at(world_pos: Vector3) -> GameEnums.SurfaceType:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return GameEnums.SurfaceType.ROCK_DRY
	return cell.surface_type


## Get terrain zone at world position
func get_terrain_zone_at(world_pos: Vector3) -> GameEnums.TerrainZone:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return GameEnums.TerrainZone.WALKABLE
	return cell.terrain_zone


## Get surface normal at world position
func get_normal_at(world_pos: Vector3) -> Vector3:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return Vector3.UP
	return cell.normal


## Get friction coefficient at world position
func get_friction_at(world_pos: Vector3) -> float:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return 0.5
	return cell.friction


# =============================================================================
# HAZARD QUERIES
# =============================================================================

## Check if position is near a cliff
func is_near_cliff(world_pos: Vector3, threshold: float = 10.0) -> bool:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return false
	return cell.distance_to_cliff < threshold


## Get distance to nearest cliff
func get_cliff_distance(world_pos: Vector3) -> float:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return 1000.0
	return cell.distance_to_cliff


## Get direction to nearest cliff
func get_cliff_direction(world_pos: Vector3) -> Vector3:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return Vector3.ZERO
	return cell.cliff_direction


## Check if rope is required at position
func requires_rope_at(world_pos: Vector3) -> bool:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return false
	return cell.requires_rope


## Check if position is slideable
func is_slideable_at(world_pos: Vector3) -> bool:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return false
	return cell.is_slideable


## Get slide risk at position (0-1)
func get_slide_risk_at(world_pos: Vector3) -> float:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return 0.0
	return cell.slide_risk


## Check if position is an exit zone
func is_exit_zone_at(world_pos: Vector3) -> bool:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return false
	return cell.is_exit_zone


# =============================================================================
# AREA QUERIES
# =============================================================================

## Get all cells in a radius
func get_cells_in_radius(center: Vector3, radius: float) -> Array[TerrainCell]:
	var results: Array[TerrainCell] = []

	# Find all chunks that might contain cells in radius
	var chunk_radius := int(ceil(radius / chunk_size)) + 1
	var center_chunk := Vector2i(
		int(floor(center.x / chunk_size)),
		int(floor(center.z / chunk_size))
	)

	for dx in range(-chunk_radius, chunk_radius + 1):
		for dz in range(-chunk_radius, chunk_radius + 1):
			var chunk_coords := center_chunk + Vector2i(dx, dz)
			var chunk: TerrainChunk = chunks.get(chunk_coords, null)
			if chunk:
				results.append_array(chunk.get_cells_in_radius(center, radius))

	return results


## Find nearest exit zone to position
func find_nearest_exit_zone(world_pos: Vector3, max_distance: float = 100.0) -> TerrainCell:
	var nearest: TerrainCell = null
	var min_dist := max_distance

	var cells := get_cells_in_radius(world_pos, max_distance)
	for cell in cells:
		if cell.is_exit_zone:
			var dist := cell.position.distance_to(world_pos)
			if dist < min_dist:
				min_dist = dist
				nearest = cell

	return nearest


## Find cells matching a condition
func find_cells(center: Vector3, radius: float, condition: Callable) -> Array[TerrainCell]:
	var results: Array[TerrainCell] = []
	var cells := get_cells_in_radius(center, radius)

	for cell in cells:
		if condition.call(cell):
			results.append(cell)

	return results


# =============================================================================
# SLIDE PATH ANALYSIS
# =============================================================================

## Predict where a slide from this position would end up
func predict_slide_path(start_pos: Vector3, start_velocity: Vector3 = Vector3.ZERO) -> PackedVector3Array:
	var chunk := get_chunk_at(start_pos)
	if chunk == null:
		return PackedVector3Array()

	return slope_analyzer.predict_slide_path(start_pos, start_velocity, chunk)


## Check if a slide from here would be fatal
func would_slide_be_fatal(start_pos: Vector3) -> bool:
	var path := predict_slide_path(start_pos)

	if path.is_empty():
		return false

	# Check if path ends at a cliff or terminal area
	var end_pos := path[-1]
	var end_cell := get_cell_at(end_pos)

	if end_cell == null:
		return true  # Off terrain = fatal

	return end_cell.is_cliff or end_cell.distance_to_cliff < 5.0


# =============================================================================
# RAYCAST QUERIES
# =============================================================================

## Cast a ray along terrain and find intersections
func raycast_terrain(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Dictionary:
	var result := {
		"hit": false,
		"position": Vector3.ZERO,
		"normal": Vector3.UP,
		"cell": null,
		"distance": max_distance
	}

	var step_size := chunk_size / chunk_resolution * 0.5
	var steps := int(max_distance / step_size)

	for i in range(steps):
		var pos := origin + direction * (i * step_size)
		var terrain_height := get_height_at(pos)

		if pos.y <= terrain_height:
			result.hit = true
			result.position = Vector3(pos.x, terrain_height, pos.z)
			result.cell = get_cell_at(result.position)
			result.normal = get_normal_at(result.position)
			result.distance = i * step_size
			break

	return result


# =============================================================================
# ENVIRONMENTAL UPDATES
# =============================================================================

## Update surface conditions based on weather/time
func update_surface_conditions(temperature: float, sun_altitude: float, sun_azimuth: float) -> void:
	surface_classifier.update_environment(temperature, sun_altitude, sun_azimuth)

	# Re-classify surfaces (could be optimized to only do visible chunks)
	for chunk in chunks.values():
		_classify_chunk_surfaces(chunk)

	terrain_updated.emit()


## Advance time for surface condition changes
func advance_time(hours: float) -> void:
	surface_classifier.advance_time(hours)


# =============================================================================
# DEBUG
# =============================================================================

## Get debug info for position
func get_debug_info_at(world_pos: Vector3) -> Dictionary:
	var cell := get_cell_at(world_pos)
	if cell == null:
		return {"error": "No terrain at position"}

	return {
		"position": world_pos,
		"elevation": cell.elevation,
		"slope_angle": cell.slope_angle,
		"aspect": cell.aspect,
		"terrain_zone": GameEnums.TerrainZone.keys()[cell.terrain_zone],
		"surface_type": GameEnums.SurfaceType.keys()[cell.surface_type],
		"friction": cell.friction,
		"distance_to_cliff": cell.distance_to_cliff,
		"is_slideable": cell.is_slideable,
		"slide_risk": cell.slide_risk,
		"is_exit_zone": cell.is_exit_zone,
		"requires_rope": cell.requires_rope
	}
