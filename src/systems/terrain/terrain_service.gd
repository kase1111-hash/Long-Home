class_name TerrainService
extends Node
## Central service for terrain queries and management
## Provides the main API for other systems to interact with terrain
##
## Owns a TerrainGenerator child, so loading terrain automatically produces
## render meshes and StaticBody3D collision (collision_layer 1).

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

## Chunks per side for procedural mountains (world = world_chunks * chunk_size metres)
@export var world_chunks: int = 10

## Radius of the base camp goal area (metres)
@export var goal_radius: float = 15.0

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

## Safe spawn point on the summit plateau (y = ground height)
var start_position: Vector3 = Vector3.ZERO

## Base camp centre on the low side (y = ground height)
var goal_position: Vector3 = Vector3.ZERO

## True while load_terrain() is running (chunk_loaded signals are bulk)
var is_loading: bool = false

## Incremented on every load_terrain(); lets the generator skip duplicate rebuilds
var load_serial: int = 0

## Corridor polyline from summit to base camp (world positions, procedural terrain only)
var corridor: PackedVector3Array = PackedVector3Array()

## Analysis tools
var slope_analyzer: SlopeAnalyzer
var surface_classifier: SurfaceClassifier

## DEM data loader
var dem_loader: DEMLoader

## Mesh + collision builder (child node)
var generator: TerrainGenerator

## Current mountain manifest (loaded from DEM files)
var current_manifest: Dictionary = {}

## Result of the last procedural generation (null for DEM terrain)
var procedural_result: ProceduralMountainGenerator.Result = null

## World xz of chunk (0, 0)'s origin (DEM terrain may be offset)
var _chunk_origin: Vector2 = Vector2.ZERO

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

	dem_loader = DEMLoader.new()

	# Mesh/collision builder must exist before anyone can load terrain
	generator = TerrainGenerator.new()
	generator.name = "TerrainGenerator"
	add_child(generator)

	# Register with service locator
	ServiceLocator.register_service("TerrainService", self)

	print("[TerrainService] Initialized")


# =============================================================================
# TERRAIN LOADING
# =============================================================================

## Load terrain for a mountain
func load_terrain(mountain_id: String) -> bool:
	print("[TerrainService] Loading terrain: %s" % mountain_id)
	var started := Time.get_ticks_msec()

	is_loading = true
	current_mountain = mountain_id
	chunks.clear()
	current_manifest.clear()
	corridor.clear()
	procedural_result = null
	_chunk_origin = Vector2.ZERO
	_cached_cell = null
	_cached_position = Vector3.INF

	var loaded_from_dem := false
	if dem_loader.mountain_exists(mountain_id):
		loaded_from_dem = _load_terrain_from_dem(mountain_id)
		if not loaded_from_dem:
			push_warning("[TerrainService] No usable DEM data for %s, using procedural terrain" % mountain_id)
			chunks.clear()
			current_manifest.clear()
			_chunk_origin = Vector2.ZERO

	if not loaded_from_dem:
		_generate_procedural_terrain(mountain_id)

	_finalize_world(mountain_id if loaded_from_dem else "")

	if loaded_from_dem:
		_apply_manifest_positions()

	is_loading = false
	load_serial += 1

	# Meshes + collision (the generator skips the duplicate rebuild on terrain_loaded)
	if generator != null:
		generator.rebuild_all()

	print("[TerrainService] Terrain ready in %d ms" % (Time.get_ticks_msec() - started))
	_print_terrain_stats()

	var emit_started := Time.get_ticks_msec()
	terrain_loaded.emit(mountain_id)
	terrain_updated.emit()
	var listeners_ms := Time.get_ticks_msec() - emit_started
	if listeners_ms > 50:
		print("[TerrainService] terrain_loaded listeners took %d ms" % listeners_ms)
	return true


## Load terrain from DEM data files (chunks only; analysis happens in _finalize_world)
func _load_terrain_from_dem(mountain_id: String) -> bool:
	print("[TerrainService] Loading from DEM files: %s" % mountain_id)

	current_manifest = dem_loader.load_mountain_manifest(mountain_id)
	if current_manifest.is_empty():
		return false

	# Get chunk configuration
	var chunk_config := dem_loader.get_chunk_config(mountain_id)
	var uses_chunks: bool = chunk_config.get("enabled", false)

	if uses_chunks:
		# Load multi-chunk terrain
		return _load_chunked_dem_terrain(mountain_id, chunk_config)
	else:
		# Load single heightmap terrain
		return _load_single_dem_terrain(mountain_id)


## Load terrain from a single DEM heightmap file
func _load_single_dem_terrain(mountain_id: String) -> bool:
	var heightmap_result := dem_loader.load_heightmap(mountain_id)

	if heightmap_result.has("error"):
		push_warning("[TerrainService] %s" % heightmap_result.error)
		return false

	var heightmap_data: PackedFloat32Array = heightmap_result.data
	var heightmap_resolution: int = heightmap_result.resolution
	var manifest: Dictionary = heightmap_result.manifest

	# Get terrain bounds from manifest
	var bounds: Dictionary = manifest.get("bounds", {})
	var min_x: float = bounds.get("min_x", 0.0)
	var min_z: float = bounds.get("min_z", 0.0)
	var world_width: float = bounds.get("max_x", 1000.0) - min_x
	var world_depth: float = bounds.get("max_z", 1000.0) - min_z
	_chunk_origin = Vector2(min_x, min_z)

	# Calculate how many chunks we need
	var chunks_x := maxi(1, int(ceil(world_width / chunk_size)))
	var chunks_z := maxi(1, int(ceil(world_depth / chunk_size)))

	print("[TerrainService] Creating %dx%d chunks from %dx%d heightmap" % [
		chunks_x, chunks_z, heightmap_resolution, heightmap_resolution
	])

	# Create chunks from the heightmap
	for cz in range(chunks_z):
		for cx in range(chunks_x):
			var chunk_coords := Vector2i(cx, cz)
			var chunk := _create_chunk_from_heightmap(
				chunk_coords,
				heightmap_data,
				heightmap_resolution,
				world_width,
				world_depth,
				min_x,
				min_z
			)
			chunks[chunk_coords] = chunk
			chunk_loaded.emit(chunk_coords)

	print("[TerrainService] DEM terrain loaded: %d chunks" % chunks.size())
	return true


## Load multi-chunk DEM terrain
func _load_chunked_dem_terrain(mountain_id: String, chunk_config: Dictionary) -> bool:
	var count_x: int = chunk_config.get("count_x", 1)
	var count_z: int = chunk_config.get("count_z", 1)
	var config_chunk_size: float = chunk_config.get("chunk_size", chunk_size)
	var config_resolution: int = chunk_config.get("chunk_resolution", chunk_resolution)

	# Update service configuration to match DEM data
	chunk_size = config_chunk_size
	chunk_resolution = config_resolution
	slope_analyzer.cell_size = chunk_size / chunk_resolution

	print("[TerrainService] Loading %dx%d chunks" % [count_x, count_z])

	for cz in range(count_z):
		for cx in range(count_x):
			var chunk_coords := Vector2i(cx, cz)
			var heightmap_result := dem_loader.load_heightmap(mountain_id, chunk_coords)

			if heightmap_result.has("error"):
				push_warning("[TerrainService] Failed to load chunk %s: %s" % [
					chunk_coords, heightmap_result.error
				])
				continue

			var chunk := TerrainChunk.new(chunk_coords, chunk_size, chunk_resolution)
			chunk.height_lookup = get_grid_height
			chunk.load_heightmap(heightmap_result.data, heightmap_result.resolution)

			chunks[chunk_coords] = chunk
			chunk_loaded.emit(chunk_coords)

	print("[TerrainService] Chunked DEM terrain loaded: %d chunks" % chunks.size())
	return chunks.size() > 0


## Create a chunk from a portion of the full heightmap
func _create_chunk_from_heightmap(
	chunk_coords: Vector2i,
	full_heightmap: PackedFloat32Array,
	heightmap_resolution: int,
	world_width: float,
	world_depth: float,
	origin_x: float,
	origin_z: float
) -> TerrainChunk:
	var chunk := TerrainChunk.new(chunk_coords, chunk_size, chunk_resolution)
	chunk.height_lookup = get_grid_height

	# Adjust world origin based on terrain origin offset
	chunk.world_origin.x = origin_x + chunk_coords.x * chunk_size
	chunk.world_origin.z = origin_z + chunk_coords.y * chunk_size
	chunk.refresh_cell_positions()

	# Sample from full heightmap into chunk heightmap
	var chunk_heightmap := PackedFloat32Array()
	chunk_heightmap.resize(chunk_resolution * chunk_resolution)

	for z in range(chunk_resolution):
		for x in range(chunk_resolution):
			# Calculate world position for this sample
			var world_x := chunk.world_origin.x + x * chunk.cell_size
			var world_z := chunk.world_origin.z + z * chunk.cell_size

			# Map to heightmap coordinates
			var hm_x := (world_x - origin_x) / world_width * (heightmap_resolution - 1)
			var hm_z := (world_z - origin_z) / world_depth * (heightmap_resolution - 1)

			# Bilinear sample from heightmap
			var height := _sample_heightmap_bilinear(
				full_heightmap,
				heightmap_resolution,
				hm_x,
				hm_z
			)

			chunk_heightmap[z * chunk_resolution + x] = height

	chunk.load_heightmap(chunk_heightmap, chunk_resolution)

	return chunk


## Bilinear sample from heightmap array
func _sample_heightmap_bilinear(
	heightmap: PackedFloat32Array,
	resolution: int,
	x: float,
	z: float
) -> float:
	var x0 := clampi(int(x), 0, resolution - 1)
	var z0 := clampi(int(z), 0, resolution - 1)
	var x1 := mini(x0 + 1, resolution - 1)
	var z1 := mini(z0 + 1, resolution - 1)

	var fx := clampf(x - x0, 0.0, 1.0)
	var fz := clampf(z - z0, 0.0, 1.0)

	var h00 := heightmap[z0 * resolution + x0]
	var h10 := heightmap[z0 * resolution + x1]
	var h01 := heightmap[z1 * resolution + x0]
	var h11 := heightmap[z1 * resolution + x1]

	var h0 := lerpf(h00, h10, fx)
	var h1 := lerpf(h01, h11, fx)

	return lerpf(h0, h1, fz)


## Apply surface type overlay from DEM data
func _apply_surface_overlay(mountain_id: String) -> void:
	var overlay_data := dem_loader.load_surface_overlay(mountain_id)
	if overlay_data.is_empty():
		return

	var image: Image = overlay_data.get("image")
	var color_map: Dictionary = overlay_data.get("color_map", {})

	if image == null or color_map.is_empty():
		return

	print("[TerrainService] Applying surface overlay")

	# Get terrain bounds for coordinate mapping
	var bounds := dem_loader.get_terrain_bounds(mountain_id)
	var world_width: float = bounds.max_x - bounds.min_x
	var world_depth: float = bounds.max_z - bounds.min_z

	for chunk in chunks.values():
		for x in range(chunk.resolution):
			for z in range(chunk.resolution):
				var cell: TerrainCell = chunk.get_cell(Vector2i(x, z))

				# Map cell position to image coordinates
				var world_x: float = cell.position.x
				var world_z: float = cell.position.z
				var img_x := int((world_x - bounds.min_x) / world_width * image.get_width())
				var img_z := int((world_z - bounds.min_z) / world_depth * image.get_height())

				img_x = clampi(img_x, 0, image.get_width() - 1)
				img_z = clampi(img_z, 0, image.get_height() - 1)

				var pixel := image.get_pixel(img_x, img_z)
				var surface_type := _color_to_surface_type(pixel, color_map)

				if surface_type != -1:
					cell.surface_type = surface_type as GameEnums.SurfaceType
					cell.surface_firmness = surface_classifier.get_firmness(cell.surface_type)
					cell.friction = surface_classifier.get_friction(cell.surface_type)


## Convert color to surface type based on color map
func _color_to_surface_type(color: Color, color_map: Dictionary) -> int:
	var best_match := -1
	var best_distance := 1000.0

	for surface_name in color_map:
		var map_color: Dictionary = color_map[surface_name]
		var target := Color(
			map_color.get("r", 0.0),
			map_color.get("g", 0.0),
			map_color.get("b", 0.0)
		)

		# Color distance
		var dist := sqrt(
			pow(color.r - target.r, 2) +
			pow(color.g - target.g, 2) +
			pow(color.b - target.b, 2)
		)

		if dist < best_distance and dist < 0.1:  # Threshold for matching
			best_distance = dist
			var enum_value: Variant = GameEnums.SurfaceType.get(String(surface_name).to_upper(), -1)
			best_match = int(enum_value)

	return best_match


## Start / goal from the DEM manifest (falls back to the procedural-style guess)
func _apply_manifest_positions() -> void:
	var starts: Array = current_manifest.get("start_positions", [])
	if not starts.is_empty():
		var entry: Dictionary = starts[0]
		var x: float = entry.get("x", 0.0)
		var z: float = entry.get("z", 0.0)
		start_position = Vector3(x, get_height_at(Vector3(x, 0.0, z)), z)

	var exits: Array = current_manifest.get("exit_zones", [])
	if not exits.is_empty():
		var entry: Dictionary = exits[0]
		var x: float = entry.get("x", 0.0)
		var z: float = entry.get("z", 0.0)
		goal_position = Vector3(x, get_height_at(Vector3(x, 0.0, z)), z)
		goal_radius = float(entry.get("radius", goal_radius))


## Get list of available mountains
func get_available_mountains() -> Array[String]:
	return dem_loader.get_available_mountains()


# =============================================================================
# PROCEDURAL TERRAIN
# =============================================================================

## Build the procedural mountain used by every mountain without heightmap data
func _generate_procedural_terrain(mountain_id: String) -> void:
	var mountain: MountainDatabase.MountainData = null
	var mountain_db := ServiceLocator.get_service("MountainDatabase") as MountainDatabase
	if mountain_db != null:
		mountain = mountain_db.get_mountain(mountain_id)
	if mountain == null:
		print("[TerrainService] No mountain data for '%s', using default parameters" % mountain_id)

	var started := Time.get_ticks_msec()
	var proc_gen := ProceduralMountainGenerator.new()
	procedural_result = proc_gen.generate(mountain_id, mountain, world_chunks, chunk_size, chunk_resolution)
	print("[TerrainService] Procedural heightfield %dx%d in %d ms (seed %d, %d cliff bands)" % [
		procedural_result.grid_size, procedural_result.grid_size,
		Time.get_ticks_msec() - started, procedural_result.seed, procedural_result.cliff_band_count
	])

	var half := world_chunks / 2
	var res := chunk_resolution
	var grid := procedural_result.grid_size
	var heights := procedural_result.heights
	started = Time.get_ticks_msec()

	for cz in range(-half, world_chunks - half):
		for cx in range(-half, world_chunks - half):
			var coords := Vector2i(cx, cz)
			var chunk := TerrainChunk.new(coords, chunk_size, res)
			chunk.height_lookup = get_grid_height

			var gx0 := (cx + half) * res
			var gz0 := (cz + half) * res
			var chunk_heights := PackedFloat32Array()
			chunk_heights.resize(res * res)
			for z in range(res):
				var src_row := (gz0 + z) * grid + gx0
				var dst_row := z * res
				for x in range(res):
					chunk_heights[dst_row + x] = heights[src_row + x]

			chunk.load_heightmap(chunk_heights, res)
			chunks[coords] = chunk
			chunk_loaded.emit(coords)
	print("[TerrainService] %d chunks (%d cells) created in %d ms" % [
		chunks.size(), chunks.size() * res * res, Time.get_ticks_msec() - started
	])

	# Corridor polyline in world space (y filled after analysis)
	corridor.clear()
	for point in procedural_result.corridor:
		corridor.append(Vector3(point.x, 0.0, point.y))

	start_position = Vector3(procedural_result.start_xz.x, 0.0, procedural_result.start_xz.y)
	goal_position = Vector3(procedural_result.goal_xz.x, 0.0, procedural_result.goal_xz.y)
	goal_radius = 15.0


# =============================================================================
# WORLD ANALYSIS
# =============================================================================

## Analyse every chunk, classify surfaces, compute world-wide cliff distances.
## dem_mountain_id is non-empty for DEM terrain (enables the surface overlay).
func _finalize_world(dem_mountain_id: String = "") -> void:
	if chunks.is_empty():
		return

	var started := Time.get_ticks_msec()

	# Geometry: slopes, normals, curvature (seam-aware through height_lookup)
	for chunk in chunks.values():
		chunk.analyze(false)
	var analyzed := Time.get_ticks_msec()

	_update_terrain_bounds()

	# Surfaces: snow line relative to this mountain's elevation range
	surface_classifier.configure_for_elevation_range(terrain_bounds_min.y, terrain_bounds_max.y)
	for chunk in chunks.values():
		_classify_chunk_surfaces(chunk)
	if not dem_mountain_id.is_empty():
		_apply_surface_overlay(dem_mountain_id)
	var classified := Time.get_ticks_msec()

	# Hazards: nearest cliff across chunk borders
	_compute_world_cliff_distances()
	var cliffs := Time.get_ticks_msec()

	# Derived properties (zones, exit zones, slide risk) now that surfaces + cliffs are known
	for chunk in chunks.values():
		chunk.finalize_analysis()

	# Ground heights for the special positions
	start_position.y = get_height_at(start_position)
	goal_position.y = get_height_at(goal_position)
	for i in range(corridor.size()):
		var point := corridor[i]
		point.y = get_height_at(point)
		corridor[i] = point

	print("[TerrainService] Analysis %d ms (slopes %d, surfaces %d, cliffs %d, derived %d)" % [
		Time.get_ticks_msec() - started,
		analyzed - started, classified - analyzed, cliffs - classified, Time.get_ticks_msec() - cliffs
	])


func _classify_chunk_surfaces(chunk: TerrainChunk) -> void:
	var classifier := surface_classifier
	for x in range(chunk.resolution):
		var column: Array = chunk.cells[x]
		for z in range(chunk.resolution):
			var cell: TerrainCell = column[z]
			cell.surface_type = classifier.classify_surface(cell)
			cell.surface_firmness = classifier.get_firmness(cell.surface_type)
			cell.friction = classifier.get_friction(cell.surface_type)


## Chamfer distance transform over the whole chunk grid so cliff distances and
## directions are correct across chunk borders. O(cells).
func _compute_world_cliff_distances() -> void:
	var min_cx := 1 << 30
	var min_cz := 1 << 30
	var max_cx := -(1 << 30)
	var max_cz := -(1 << 30)
	for key in chunks:
		var coords: Vector2i = key
		min_cx = mini(min_cx, coords.x)
		min_cz = mini(min_cz, coords.y)
		max_cx = maxi(max_cx, coords.x)
		max_cz = maxi(max_cz, coords.y)

	var res := chunk_resolution
	var width := (max_cx - min_cx + 1) * res
	var depth := (max_cz - min_cz + 1) * res

	var mask := PackedByteArray()
	mask.resize(width * depth)
	mask.fill(0)

	var any_cliff := false
	for key in chunks:
		var coords: Vector2i = key
		var chunk: TerrainChunk = chunks[coords]
		if chunk.resolution != res:
			continue
		var gx0 := (coords.x - min_cx) * res
		var gz0 := (coords.y - min_cz) * res
		for cliff in chunk.cliff_cells:
			mask[(gz0 + cliff.y) * width + gx0 + cliff.x] = 1
			any_cliff = true

	var nearest := PackedInt32Array()
	if any_cliff:
		nearest = CliffDistanceField.compute_nearest(width, depth, mask)

	for key in chunks:
		var coords: Vector2i = key
		var chunk: TerrainChunk = chunks[coords]
		if chunk.resolution != res:
			continue
		var gx0 := (coords.x - min_cx) * res
		var gz0 := (coords.y - min_cz) * res
		for x in range(res):
			var column: Array = chunk.cells[x]
			for z in range(res):
				var cell: TerrainCell = column[z]
				if not any_cliff:
					chunk.set_cliff_reference(cell, Vector3.ZERO, false)
					continue
				var index := nearest[(gz0 + z) * width + gx0 + x]
				if index == CliffDistanceField.NO_CLIFF:
					chunk.set_cliff_reference(cell, Vector3.ZERO, false)
					continue
				var nx := index % width
				var nz := index / width
				var cliff_cell := _cell_at_world_grid(nx, nz, min_cx, min_cz)
				if cliff_cell == null:
					chunk.set_cliff_reference(cell, Vector3.ZERO, false)
				else:
					chunk.set_cliff_reference(cell, cliff_cell.position, true)


func _cell_at_world_grid(gx: int, gz: int, min_cx: int, min_cz: int) -> TerrainCell:
	var res := chunk_resolution
	var coords := Vector2i(min_cx + gx / res, min_cz + gz / res)
	var chunk: TerrainChunk = chunks.get(coords, null)
	if chunk == null:
		return null
	return chunk.cells[gx % res][gz % res]


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


## Summarise the loaded world: elevation range, zone mix, corridor
func _print_terrain_stats() -> void:
	if chunks.is_empty():
		return

	var counts := PackedInt32Array()
	counts.resize(GameEnums.TerrainZone.size())
	counts.fill(0)
	var total := 0
	for chunk in chunks.values():
		for x in range(chunk.resolution):
			var column: Array = chunk.cells[x]
			for z in range(chunk.resolution):
				var cell: TerrainCell = column[z]
				counts[cell.terrain_zone] += 1
				total += 1
	if total == 0:
		return

	var pct := func(zone: int) -> float: return 100.0 * float(counts[zone]) / float(total)
	print("[TerrainService] World %.0fx%.0f m, elevation %.0f-%.0f m, %d chunks, %d cells" % [
		terrain_bounds_max.x - terrain_bounds_min.x, terrain_bounds_max.z - terrain_bounds_min.z,
		terrain_bounds_min.y, terrain_bounds_max.y, chunks.size(), total
	])
	print("[TerrainService] Zones: walkable %.1f%% | steep %.1f%% | slideable %.1f%% | downclimb %.1f%% | rappel %.1f%% | cliff %.1f%%" % [
		pct.call(GameEnums.TerrainZone.WALKABLE),
		pct.call(GameEnums.TerrainZone.STEEP),
		pct.call(GameEnums.TerrainZone.SLIDEABLE),
		pct.call(GameEnums.TerrainZone.DOWNCLIMB),
		pct.call(GameEnums.TerrainZone.RAPPEL_REQUIRED),
		pct.call(GameEnums.TerrainZone.CLIFF)
	])
	print("[TerrainService] Start %s (ground %.2f) -> goal %s (ground %.2f), drop %.1f m, goal radius %.0f m" % [
		start_position, get_height_at(start_position),
		goal_position, get_height_at(goal_position),
		start_position.y - goal_position.y, goal_radius
	])

	if procedural_result != null:
		var corridor_stats := get_corridor_stats()
		print("[TerrainService] Corridor %.0f m long, max slope %.1f deg, mean %.1f deg, %d/%d samples over 34 deg (requested drop %.0f m)" % [
			procedural_result.corridor_length,
			corridor_stats.max_slope, corridor_stats.mean_slope,
			corridor_stats.over_limit, corridor_stats.samples,
			procedural_result.requested_drop
		])


## Slope statistics along the corridor polyline (procedural terrain)
func get_corridor_stats() -> Dictionary:
	var stats := {"max_slope": 0.0, "mean_slope": 0.0, "over_limit": 0, "samples": 0}
	if corridor.is_empty():
		return stats
	var sum := 0.0
	for point in corridor:
		var cell := get_cell_at(point)
		if cell == null:
			continue
		stats.samples += 1
		sum += cell.slope_angle
		stats.max_slope = maxf(stats.max_slope, cell.slope_angle)
		if cell.slope_angle > 34.0:
			stats.over_limit += 1
	if stats.samples > 0:
		stats.mean_slope = sum / float(stats.samples)
	return stats


# =============================================================================
# GRID ACCESS (seam-aware)
# =============================================================================

## Resolve grid indices relative to a chunk, spilling into neighbours.
## Returns (chunk_x, chunk_z, local_x, local_z); clamps at the world edge.
func _resolve_grid(chunk_coords: Vector2i, x: int, z: int) -> Vector4i:
	var res := chunk_resolution
	var cx := chunk_coords.x
	var cz := chunk_coords.y
	var lx := x
	var lz := z

	if lx < 0 or lx >= res:
		var shift := int(floor(float(lx) / float(res)))
		if chunks.has(Vector2i(cx + shift, cz)):
			cx += shift
			lx -= shift * res
		else:
			lx = clampi(lx, 0, res - 1)

	if lz < 0 or lz >= res:
		var shift := int(floor(float(lz) / float(res)))
		if chunks.has(Vector2i(cx, cz + shift)):
			cz += shift
			lz -= shift * res
		else:
			lz = clampi(lz, 0, res - 1)

	return Vector4i(cx, cz, lx, lz)


## Height sample at grid indices relative to a chunk; indices may spill into
## neighbouring chunks (e.g. x == resolution is the next chunk's first column)
func get_grid_height(chunk_coords: Vector2i, x: int, z: int) -> float:
	var resolved := _resolve_grid(chunk_coords, x, z)
	var chunk: TerrainChunk = chunks.get(Vector2i(resolved.x, resolved.y), null)
	if chunk == null:
		chunk = chunks.get(chunk_coords, null)
		if chunk == null:
			return 0.0
		resolved.z = clampi(x, 0, chunk.resolution - 1)
		resolved.w = clampi(z, 0, chunk.resolution - 1)
	return chunk.heightmap[resolved.w * chunk.resolution + resolved.z]


## Cell at grid indices relative to a chunk, spilling into neighbours like get_grid_height
func get_grid_cell(chunk_coords: Vector2i, x: int, z: int) -> TerrainCell:
	var resolved := _resolve_grid(chunk_coords, x, z)
	var chunk: TerrainChunk = chunks.get(Vector2i(resolved.x, resolved.y), null)
	if chunk == null:
		chunk = chunks.get(chunk_coords, null)
		if chunk == null:
			return null
		resolved.z = clampi(x, 0, chunk.resolution - 1)
		resolved.w = clampi(z, 0, chunk.resolution - 1)
	return chunk.cells[resolved.z][resolved.w]


# =============================================================================
# POSITION QUERIES
# =============================================================================

## Get all loaded chunks keyed by chunk coordinates (Vector2i -> TerrainChunk)
func get_all_chunks() -> Dictionary:
	return chunks


## Get the chunk containing a world position
func get_chunk_at(world_pos: Vector3) -> TerrainChunk:
	var chunk_x := int(floor((world_pos.x - _chunk_origin.x) / chunk_size))
	var chunk_z := int(floor((world_pos.z - _chunk_origin.y) / chunk_size))
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


## Get height at world position (interpolated on the render/collision triangles)
func get_height_at(world_pos: Vector3) -> float:
	var chunk := get_chunk_at(world_pos)
	if chunk == null:
		return 0.0
	return chunk.get_height_at_world(world_pos)


## Whether a world position lies over loaded terrain
func has_terrain_at(world_pos: Vector3) -> bool:
	return get_chunk_at(world_pos) != null


## Whether a world position lies inside the base camp goal area
func is_at_goal(world_pos: Vector3) -> bool:
	var flat := Vector2(world_pos.x, world_pos.z)
	return flat.distance_to(Vector2(goal_position.x, goal_position.z)) <= goal_radius


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
		int(floor((center.x - _chunk_origin.x) / chunk_size)),
		int(floor((center.z - _chunk_origin.y) / chunk_size))
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

	# Re-classify surfaces and refresh the properties that depend on them
	for chunk in chunks.values():
		_classify_chunk_surfaces(chunk)
		chunk.finalize_analysis()

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
