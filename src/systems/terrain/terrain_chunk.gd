class_name TerrainChunk
extends RefCounted
## Represents a chunk of terrain data for efficient spatial queries
## Terrain is divided into chunks for memory and performance management
##
## Height samples live on the chunk's grid corners: sample (x, z) sits at
## world_origin + (x, z) * cell_size. The sample at x == resolution belongs to
## the neighbouring chunk; set height_lookup so analysis can see across seams.

# =============================================================================
# CONSTANTS
# =============================================================================

## Default chunk size in world units
const DEFAULT_CHUNK_SIZE := 64.0

## Default resolution (cells per chunk side)
const DEFAULT_RESOLUTION := 32

## Distance reported when no cliff exists anywhere
const NO_CLIFF_DISTANCE := 1000.0

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

## Heightmap data (raw elevation values), row-major: index = z * resolution + x
var heightmap: PackedFloat32Array = PackedFloat32Array()

## Optional cross-seam height source: func(chunk_coords: Vector2i, x: int, z: int) -> float
## Called for grid indices outside [0, resolution). When unset, edges clamp.
var height_lookup: Callable = Callable()

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


## Recompute cell world positions after world_origin has been moved
func refresh_cell_positions() -> void:
	for x in range(resolution):
		for z in range(resolution):
			var cell: TerrainCell = cells[x][z]
			var pos := _grid_to_world(Vector2i(x, z))
			pos.y = cell.elevation
			cell.position = pos


# =============================================================================
# COORDINATE CONVERSION
# =============================================================================

## Convert grid coordinates to world position (the height sample's corner)
func _grid_to_world(grid_pos: Vector2i) -> Vector3:
	return Vector3(
		world_origin.x + grid_pos.x * cell_size,
		0.0,  # Y will be set from heightmap
		world_origin.z + grid_pos.y * cell_size
	)


## Convert world position to the nearest sample's grid coordinates
func world_to_grid(world_pos: Vector3) -> Vector2i:
	var local_x := (world_pos.x - world_origin.x) / cell_size
	var local_z := (world_pos.z - world_origin.z) / cell_size

	return Vector2i(
		clampi(roundi(local_x), 0, resolution - 1),
		clampi(roundi(local_z), 0, resolution - 1)
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


## Get height at grid indices that may spill into neighbouring chunks
## (uses height_lookup when set, otherwise clamps to this chunk's edge)
func sample_height(x: int, z: int) -> float:
	if x >= 0 and x < resolution and z >= 0 and z < resolution:
		return heightmap[z * resolution + x]
	if height_lookup.is_valid():
		return height_lookup.call(chunk_coords, x, z)
	return heightmap[clampi(z, 0, resolution - 1) * resolution + clampi(x, 0, resolution - 1)]


## Set height at grid position
func set_height(grid_pos: Vector2i, height: float) -> void:
	if not _is_valid_grid_pos(grid_pos):
		return
	heightmap[grid_pos.y * resolution + grid_pos.x] = height

	var cell := get_cell(grid_pos)
	if cell:
		cell.elevation = height
		cell.position.y = height


## Get interpolated height at world position, matching the render/collision
## triangulation (each cell split along the (x+1, z) -> (x, z+1) diagonal)
func get_height_at_world(world_pos: Vector3) -> float:
	if not contains_point(world_pos):
		return 0.0

	var local_x := (world_pos.x - world_origin.x) / cell_size
	var local_z := (world_pos.z - world_origin.z) / cell_size

	var x0 := clampi(int(floor(local_x)), 0, resolution - 1)
	var z0 := clampi(int(floor(local_z)), 0, resolution - 1)

	var fx := clampf(local_x - x0, 0.0, 1.0)
	var fz := clampf(local_z - z0, 0.0, 1.0)

	var h00 := heightmap[z0 * resolution + x0]
	var h10 := sample_height(x0 + 1, z0)
	var h01 := sample_height(x0, z0 + 1)
	var h11 := sample_height(x0 + 1, z0 + 1)

	if fx + fz <= 1.0:
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)


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
		push_error("[TerrainChunk] Heightmap data size mismatch")
		return

	# Resample if resolution differs
	if data_resolution == resolution:
		heightmap = data.duplicate()
	else:
		_resample_heightmap(data, data_resolution)

	# Update cell elevations
	for x in range(resolution):
		var column: Array = cells[x]
		for z in range(resolution):
			var height := heightmap[z * resolution + x]
			var cell: TerrainCell = column[z]
			cell.elevation = height
			cell.position.y = height

	_update_elevation_bounds()
	is_analyzed = false


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

## Analyze all cells in this chunk (slopes, normals, curvature, cliffs).
## With finalize = true this also computes cliff distances within the chunk and
## derives every dependent cell property. Pass false when a caller (TerrainService)
## computes cliff distances across the whole world and calls finalize_analysis().
func analyze(finalize: bool = true) -> void:
	var slope_sum := 0.0
	var cliff_min: float = GameEnums.SLOPE_THRESHOLDS.cliff_min
	var res := resolution
	var inv_2cs := 1.0 / (2.0 * cell_size)
	var inv_cs2 := 1.0 / (cell_size * cell_size)

	cliff_cells.clear()

	for x in range(res):
		var column: Array = cells[x]
		for z in range(res):
			var cell: TerrainCell = column[z]
			var idx := z * res + x
			var centre := heightmap[idx]
			var east: float = heightmap[idx + 1] if x < res - 1 else sample_height(x + 1, z)
			var west: float = heightmap[idx - 1] if x > 0 else sample_height(x - 1, z)
			var south: float = heightmap[idx + res] if z < res - 1 else sample_height(x, z + 1)
			var north: float = heightmap[idx - res] if z > 0 else sample_height(x, z - 1)

			var dx := (east - west) * inv_2cs
			var dz := (south - north) * inv_2cs
			var gradient := sqrt(dx * dx + dz * dz)

			cell.slope_angle = rad_to_deg(atan(gradient))
			cell.normal = Vector3(-dx, 1.0, -dz).normalized()

			if gradient > 0.001:
				# (dx, dz) is the height gradient, which points uphill; every
				# consumer (slide forces, slips, downclimb facing, anchors)
				# expects the downhill direction
				cell.slope_direction = -Vector3(dx, 0.0, dz).normalized()
				var aspect := rad_to_deg(atan2(dx, -dz))
				if aspect < 0.0:
					aspect += 360.0
				cell.aspect = aspect
			else:
				cell.slope_direction = Vector3.ZERO
				cell.aspect = 0.0

			# Curvature (Laplacian): positive = ridge, negative = gully
			var d2x := (east + west - 2.0 * centre) * inv_cs2
			var d2z := (north + south - 2.0 * centre) * inv_cs2
			cell.curvature = (d2x + d2z) * 0.5
			cell.drainage = clampf(-cell.curvature * 10.0, 0.0, 1.0)

			cell.is_cliff = cell.slope_angle >= cliff_min
			if cell.is_cliff:
				cliff_cells.append(Vector2i(x, z))

			slope_sum += cell.slope_angle

	average_slope = slope_sum / float(res * res)

	if finalize:
		_calculate_cliff_distances()
		finalize_analysis()


## Derive dependent cell properties (zones, exit zones, slide risk) and rebuild
## the special-cell lists. Call after cliff distances and surfaces are set.
func finalize_analysis() -> void:
	exit_zone_cells.clear()
	rope_required_cells.clear()

	for x in range(resolution):
		var column: Array = cells[x]
		for z in range(resolution):
			var cell: TerrainCell = column[z]
			cell.calculate_derived_properties()
			if cell.is_exit_zone:
				exit_zone_cells.append(Vector2i(x, z))
			if cell.requires_rope:
				rope_required_cells.append(Vector2i(x, z))

	is_analyzed = true


## Write cliff distance data from a nearest-cliff index into a cell
func set_cliff_reference(cell: TerrainCell, nearest_position: Vector3, has_cliff: bool) -> void:
	if not has_cliff:
		cell.distance_to_cliff = NO_CLIFF_DISTANCE
		cell.cliff_direction = Vector3.ZERO
		return
	var delta := nearest_position - cell.position
	cell.distance_to_cliff = delta.length()
	cell.cliff_direction = delta.normalized() if cell.distance_to_cliff > 0.001 else Vector3.ZERO


## Chunk-local cliff distances: two-pass chamfer transform, O(cells)
func _calculate_cliff_distances() -> void:
	var res := resolution
	var mask := PackedByteArray()
	mask.resize(res * res)
	mask.fill(0)
	for coords in cliff_cells:
		mask[coords.y * res + coords.x] = 1

	var nearest := CliffDistanceField.compute_nearest(res, res, mask)

	for x in range(res):
		var column: Array = cells[x]
		for z in range(res):
			var cell: TerrainCell = column[z]
			var index := nearest[z * res + x]
			if index == CliffDistanceField.NO_CLIFF:
				set_cliff_reference(cell, Vector3.ZERO, false)
			else:
				var cliff_cell: TerrainCell = cells[index % res][index / res]
				set_cliff_reference(cell, cliff_cell.position, true)


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
