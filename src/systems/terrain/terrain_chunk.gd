class_name TerrainChunk
extends RefCounted
## Represents a chunk of terrain data for efficient spatial queries
## Terrain is divided into chunks for memory and performance management

# =============================================================================
# CONSTANTS
# =============================================================================

## Default chunk size in world units
const DEFAULT_CHUNK_SIZE := 64.0

## Default resolution (cells per chunk side)
const DEFAULT_RESOLUTION := 32

# =============================================================================
# PROPERTIES
# =============================================================================

## Chunk position in chunk grid coordinates
var chunk_coords: Vector2i = Vector2i.ZERO

## World position of chunk origin (corner)
var world_origin: Vector3 = Vector3.ZERO

## Size of this chunk in world units
var chunk_size: float = DEFAULT_CHUNK_SIZE

## Number of cells per side
var resolution: int = DEFAULT_RESOLUTION

## Cell size in world units
var cell_size: float = DEFAULT_CHUNK_SIZE / DEFAULT_RESOLUTION

## 2D array of terrain cells [x][z]
var cells: Array[Array] = []

## Heightmap data (raw elevation values)
var heightmap: PackedFloat32Array = PackedFloat32Array()

## Bounds of this chunk
var bounds_min: Vector3 = Vector3.ZERO
var bounds_max: Vector3 = Vector3.ZERO

## Whether this chunk has been fully analyzed
var is_analyzed: bool = false

## Minimum elevation in chunk
var min_elevation: float = 0.0

## Maximum elevation in chunk
var max_elevation: float = 0.0

## Average slope in chunk (for LOD decisions)
var average_slope: float = 0.0

# =============================================================================
# PRECOMPUTED DATA
# =============================================================================

## Cliff cells for quick proximity queries
var cliff_cells: Array[Vector2i] = []

## Exit zone cells
var exit_zone_cells: Array[Vector2i] = []

## Cells requiring rope
var rope_required_cells: Array[Vector2i] = []


# =============================================================================
# INITIALIZATION
# =============================================================================

func _init(
	coords: Vector2i = Vector2i.ZERO,
	size: float = DEFAULT_CHUNK_SIZE,
	res: int = DEFAULT_RESOLUTION
) -> void:
	chunk_coords = coords
	chunk_size = size
	resolution = res
	cell_size = chunk_size / resolution

	world_origin = Vector3(
		coords.x * chunk_size,
		0.0,
		coords.y * chunk_size
	)

	_initialize_cells()


func _initialize_cells() -> void:
	cells.clear()
	cells.resize(resolution)

	for x in range(resolution):
		var column: Array = []
		column.resize(resolution)

		for z in range(resolution):
			var world_pos := _grid_to_world(Vector2i(x, z))
			column[z] = TerrainCell.new(world_pos, Vector2i(x, z))

		cells[x] = column

	heightmap.resize(resolution * resolution)


# =============================================================================
# COORDINATE CONVERSION
# =============================================================================

## Convert grid coordinates to world position
func _grid_to_world(grid_pos: Vector2i) -> Vector3:
	return Vector3(
		world_origin.x + grid_pos.x * cell_size + cell_size * 0.5,
		0.0,  # Y will be set from heightmap
		world_origin.z + grid_pos.y * cell_size + cell_size * 0.5
	)


## Convert world position to grid coordinates
func world_to_grid(world_pos: Vector3) -> Vector2i:
	var local_x := (world_pos.x - world_origin.x) / cell_size
	var local_z := (world_pos.z - world_origin.z) / cell_size

	return Vector2i(
		clampi(int(local_x), 0, resolution - 1),
		clampi(int(local_z), 0, resolution - 1)
	)


## Check if a world position is within this chunk
func contains_point(world_pos: Vector3) -> bool:
	return (
		world_pos.x >= world_origin.x and
		world_pos.x < world_origin.x + chunk_size and
		world_pos.z >= world_origin.z and
		world_pos.z < world_origin.z + chunk_size
	)


# =============================================================================
# DATA ACCESS
# =============================================================================

## Get cell at grid coordinates
func get_cell(grid_pos: Vector2i) -> TerrainCell:
	if not _is_valid_grid_pos(grid_pos):
		return null
	return cells[grid_pos.x][grid_pos.y]


## Get cell at world position
func get_cell_at_world(world_pos: Vector3) -> TerrainCell:
	if not contains_point(world_pos):
		return null
	return get_cell(world_to_grid(world_pos))


## Get height at grid position
func get_height(grid_pos: Vector2i) -> float:
	if not _is_valid_grid_pos(grid_pos):
		return 0.0
	return heightmap[grid_pos.y * resolution + grid_pos.x]


## Set height at grid position
func set_height(grid_pos: Vector2i, height: float) -> void:
	if not _is_valid_grid_pos(grid_pos):
		return
	heightmap[grid_pos.y * resolution + grid_pos.x] = height

	var cell := get_cell(grid_pos)
	if cell:
		cell.elevation = height
		cell.position.y = height


## Get interpolated height at world position
func get_height_at_world(world_pos: Vector3) -> float:
	if not contains_point(world_pos):
		return 0.0

	# Bilinear interpolation
	var local_x := (world_pos.x - world_origin.x) / cell_size
	var local_z := (world_pos.z - world_origin.z) / cell_size

	var x0 := int(local_x)
	var z0 := int(local_z)
	var x1 := mini(x0 + 1, resolution - 1)
	var z1 := mini(z0 + 1, resolution - 1)

	var fx := local_x - x0
	var fz := local_z - z0

	var h00 := get_height(Vector2i(x0, z0))
	var h10 := get_height(Vector2i(x1, z0))
	var h01 := get_height(Vector2i(x0, z1))
	var h11 := get_height(Vector2i(x1, z1))

	var h0 := lerpf(h00, h10, fx)
	var h1 := lerpf(h01, h11, fx)

	return lerpf(h0, h1, fz)


func _is_valid_grid_pos(grid_pos: Vector2i) -> bool:
	return (
		grid_pos.x >= 0 and grid_pos.x < resolution and
		grid_pos.y >= 0 and grid_pos.y < resolution
	)


# =============================================================================
# HEIGHTMAP LOADING
# =============================================================================

## Load heightmap from a packed float array
func load_heightmap(data: PackedFloat32Array, data_resolution: int) -> void:
	if data.size() != data_resolution * data_resolution:
		push_error("Heightmap data size mismatch")
		return

	# Resample if resolution differs
	if data_resolution == resolution:
		heightmap = data.duplicate()
	else:
		_resample_heightmap(data, data_resolution)

	# Update cell elevations
	for x in range(resolution):
		for z in range(resolution):
			var height := get_height(Vector2i(x, z))
			var cell := get_cell(Vector2i(x, z))
			cell.elevation = height
			cell.position.y = height

	_update_elevation_bounds()


func _resample_heightmap(data: PackedFloat32Array, data_res: int) -> void:
	for z in range(resolution):
		for x in range(resolution):
			# Map to source coordinates
			var src_x := float(x) / resolution * data_res
			var src_z := float(z) / resolution * data_res

			var x0 := int(src_x)
			var z0 := int(src_z)
			var x1 := mini(x0 + 1, data_res - 1)
			var z1 := mini(z0 + 1, data_res - 1)

			var fx := src_x - x0
			var fz := src_z - z0

			var h00 := data[z0 * data_res + x0]
			var h10 := data[z0 * data_res + x1]
			var h01 := data[z1 * data_res + x0]
			var h11 := data[z1 * data_res + x1]

			var h0 := lerpf(h00, h10, fx)
			var h1 := lerpf(h01, h11, fx)
			var height := lerpf(h0, h1, fz)

			heightmap[z * resolution + x] = height


func _update_elevation_bounds() -> void:
	if heightmap.is_empty():
		return

	min_elevation = heightmap[0]
	max_elevation = heightmap[0]

	for height in heightmap:
		min_elevation = minf(min_elevation, height)
		max_elevation = maxf(max_elevation, height)

	bounds_min = Vector3(world_origin.x, min_elevation, world_origin.z)
	bounds_max = Vector3(
		world_origin.x + chunk_size,
		max_elevation,
		world_origin.z + chunk_size
	)


# =============================================================================
# ANALYSIS
# =============================================================================

## Analyze all cells in this chunk (calculate slopes, surfaces, etc.)
func analyze() -> void:
	var slope_sum := 0.0

	cliff_cells.clear()
	exit_zone_cells.clear()
	rope_required_cells.clear()

	for x in range(resolution):
		for z in range(resolution):
			var cell := get_cell(Vector2i(x, z))
			_analyze_cell(cell, x, z)

			slope_sum += cell.slope_angle

			# Collect special cells
			if cell.is_cliff:
				cliff_cells.append(Vector2i(x, z))
			if cell.is_exit_zone:
				exit_zone_cells.append(Vector2i(x, z))
			if cell.requires_rope:
				rope_required_cells.append(Vector2i(x, z))

	average_slope = slope_sum / (resolution * resolution)

	# Second pass: calculate cliff distances
	_calculate_cliff_distances()

	# Final pass: derive all dependent properties
	for x in range(resolution):
		for z in range(resolution):
			get_cell(Vector2i(x, z)).calculate_derived_properties()

	is_analyzed = true


func _analyze_cell(cell: TerrainCell, x: int, z: int) -> void:
	# Calculate slope from neighbors
	var neighbors := _get_neighbor_heights(x, z)

	# Gradient using Sobel-like filter
	var dx := (neighbors.e - neighbors.w) / (2.0 * cell_size)
	var dz := (neighbors.s - neighbors.n) / (2.0 * cell_size)

	# Slope angle
	var gradient := sqrt(dx * dx + dz * dz)
	cell.slope_angle = rad_to_deg(atan(gradient))

	# Normal vector
	cell.normal = Vector3(-dx, 1.0, -dz).normalized()

	# Slope direction (downhill)
	if gradient > 0.001:
		cell.slope_direction = Vector3(dx, 0.0, dz).normalized()
	else:
		cell.slope_direction = Vector3.ZERO

	# Aspect (compass direction of slope face)
	if gradient > 0.001:
		cell.aspect = rad_to_deg(atan2(dx, -dz))
		if cell.aspect < 0:
			cell.aspect += 360.0

	# Curvature (second derivative)
	var center := cell.elevation
	var d2x := (neighbors.e + neighbors.w - 2.0 * center) / (cell_size * cell_size)
	var d2z := (neighbors.n + neighbors.s - 2.0 * center) / (cell_size * cell_size)
	cell.curvature = (d2x + d2z) * 0.5

	# Drainage (how much water would collect here)
	# Positive curvature = ridge, negative = gully
	cell.drainage = clampf(-cell.curvature * 10.0, 0.0, 1.0)


func _get_neighbor_heights(x: int, z: int) -> Dictionary:
	return {
		"n": get_height(Vector2i(x, maxi(z - 1, 0))),
		"s": get_height(Vector2i(x, mini(z + 1, resolution - 1))),
		"e": get_height(Vector2i(mini(x + 1, resolution - 1), z)),
		"w": get_height(Vector2i(maxi(x - 1, 0), z)),
		"c": get_height(Vector2i(x, z))
	}


func _calculate_cliff_distances() -> void:
	# For each cell, find distance to nearest cliff
	for x in range(resolution):
		for z in range(resolution):
			var cell := get_cell(Vector2i(x, z))
			var min_dist := 1000.0
			var cliff_dir := Vector3.ZERO

			for cliff_pos in cliff_cells:
				var cliff_cell := get_cell(cliff_pos)
				var dist := cell.position.distance_to(cliff_cell.position)

				if dist < min_dist:
					min_dist = dist
					cliff_dir = (cliff_cell.position - cell.position).normalized()

			cell.distance_to_cliff = min_dist
			cell.cliff_direction = cliff_dir


# =============================================================================
# QUERIES
# =============================================================================

## Find cells matching a condition
func find_cells(condition: Callable) -> Array[TerrainCell]:
	var results: Array[TerrainCell] = []

	for x in range(resolution):
		for z in range(resolution):
			var cell := get_cell(Vector2i(x, z))
			if condition.call(cell):
				results.append(cell)

	return results


## Get all cells in a radius around a world position
func get_cells_in_radius(center: Vector3, radius: float) -> Array[TerrainCell]:
	var results: Array[TerrainCell] = []
	var radius_sq := radius * radius

	# Calculate grid bounds to check
	var grid_radius := ceili(radius / cell_size)
	var center_grid := world_to_grid(center)

	for dx in range(-grid_radius, grid_radius + 1):
		for dz in range(-grid_radius, grid_radius + 1):
			var grid_pos := center_grid + Vector2i(dx, dz)
			var cell := get_cell(grid_pos)

			if cell and cell.position.distance_squared_to(center) <= radius_sq:
				results.append(cell)

	return results


## Get nearest exit zone to a position
func get_nearest_exit_zone(world_pos: Vector3) -> TerrainCell:
	var nearest: TerrainCell = null
	var min_dist := INF

	for exit_pos in exit_zone_cells:
		var cell := get_cell(exit_pos)
		var dist := cell.position.distance_to(world_pos)

		if dist < min_dist:
			min_dist = dist
			nearest = cell

	return nearest
