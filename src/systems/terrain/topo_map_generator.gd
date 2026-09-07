class_name TopoMapGenerator
extends RefCounted
## Generates topographic map representations for the planning UI
## Creates contour lines and visual overlays from terrain data
##
## One map is generated per terrain load and shared by every display
## (planning, physical, pause and replay maps) through get_terrain_map() /
## get_terrain_image(); generate_map() and render_to_image() are the uncached
## building blocks.

# =============================================================================
# CONFIGURATION
# =============================================================================

## Contour interval in meters (major contours)
var major_contour_interval: float = 100.0

## Contour interval for minor contours
var minor_contour_interval: float = 20.0

## Minimum segment length for contour simplification
var min_segment_length: float = 5.0

## Height samples per contour grid sample (2 = every other sample). Contours
## traced from a 161x161 grid are indistinguishable from 321x321 at the sizes
## the maps are shown, for a quarter of the work.
var detail_step: int = 2

## Color for major contour lines
var major_contour_color: Color = Color(0.4, 0.3, 0.2, 0.9)

## Color for minor contour lines
var minor_contour_color: Color = Color(0.5, 0.4, 0.3, 0.5)

## Color for cliff markers
var cliff_color: Color = Color(0.8, 0.2, 0.2, 0.8)

## Color for exit zones
var exit_zone_color: Color = Color(0.2, 0.7, 0.3, 0.6)

## Height grid value where no chunk is loaded
const MISSING_HEIGHT := -1.0e30

# =============================================================================
# CACHE
# =============================================================================

## Map of the current terrain load, shared by every generator instance
static var _cache_key: String = ""
static var _cached_map: TopoMapData = null

## Rendered base images of the cached map (style/resolution hash -> Image)
static var _cached_images: Dictionary = {}

## Marker stamp images ([color, size] -> Image), blitted instead of per-pixel loops
var _marker_stamps: Dictionary = {}

# =============================================================================
# CONTOUR LINE DATA
# =============================================================================

class ContourLine:
	var elevation: float = 0.0
	var is_major: bool = false
	var points: PackedVector2Array = PackedVector2Array()

	func _init(elev: float, major: bool = false) -> void:
		elevation = elev
		is_major = major


class TopoMapData:
	var bounds_min: Vector2 = Vector2.ZERO
	var bounds_max: Vector2 = Vector2.ZERO
	var contour_lines: Array[ContourLine] = []
	var cliff_zones: Array[PackedVector2Array] = []
	var exit_zones: Array[Vector2] = []
	var hazard_markers: Array[Dictionary] = []
	var elevation_range: Vector2 = Vector2.ZERO  # min, max
	var sample_count: Vector2i = Vector2i.ZERO  # contour grid samples (x, z)


## Height samples of the whole loaded world on one regular grid (row-major,
## index = row * width + column), so contours run across chunk seams
class HeightGrid:
	var width: int = 0
	var depth: int = 0
	var heights: PackedFloat32Array = PackedFloat32Array()
	var xs: PackedFloat32Array = PackedFloat32Array()  # world x per column
	var zs: PackedFloat32Array = PackedFloat32Array()  # world z per row


# =============================================================================
# SHARED MAP (CACHED PER TERRAIN LOAD)
# =============================================================================

## Map data for the currently loaded terrain; generated on the first call after
## each load_terrain() and reused by every display until the next load
func get_terrain_map(terrain_service: TerrainService) -> TopoMapData:
	var key := "%d:%s#%d@%d/%.2f/%.2f" % [
		terrain_service.get_instance_id(), terrain_service.current_mountain,
		terrain_service.load_serial, detail_step,
		minor_contour_interval, major_contour_interval
	]
	if _cached_map != null and _cache_key == key:
		return _cached_map

	_cached_map = generate_map(
		terrain_service.get_all_chunks(),
		terrain_service.terrain_bounds_min,
		terrain_service.terrain_bounds_max
	)
	_cached_images.clear()
	_cache_key = key
	return _cached_map


## Rendered base map of the current terrain at the given resolution (cached
## alongside the map data, so displays sharing a size render once)
func get_terrain_image(terrain_service: TerrainService, resolution: Vector2i) -> Image:
	var map_data := get_terrain_map(terrain_service)
	var style_key := hash([resolution, major_contour_color, minor_contour_color, cliff_color, exit_zone_color])
	var cached: Image = _cached_images.get(style_key, null)
	if cached != null:
		return cached

	var image := render_to_image(map_data, resolution)
	_cached_images[style_key] = image
	return image


# =============================================================================
# MAP GENERATION
# =============================================================================

## Generate topo map data from terrain chunks
func generate_map(chunks: Dictionary, bounds_min: Vector3, bounds_max: Vector3) -> TopoMapData:
	var started := Time.get_ticks_msec()
	var map_data := TopoMapData.new()

	map_data.bounds_min = Vector2(bounds_min.x, bounds_min.z)
	map_data.bounds_max = Vector2(bounds_max.x, bounds_max.z)
	map_data.elevation_range = Vector2(bounds_min.y, bounds_max.y)

	# Generate contour lines
	var grid := _build_height_grid(chunks)
	map_data.sample_count = Vector2i(grid.width, grid.depth)
	map_data.contour_lines = _generate_contours(grid, bounds_min.y, bounds_max.y)

	# Find cliff zones
	map_data.cliff_zones = _find_cliff_zones(chunks)

	# Find exit zones
	map_data.exit_zones = _find_exit_zone_markers(chunks)

	# Generate hazard markers
	map_data.hazard_markers = _generate_hazard_markers(chunks)

	print("[TopoMapGenerator] Map %dx%d generated in %d ms (%d contours, %d cliffs, %d exits, %d rope)" % [
		grid.width, grid.depth, Time.get_ticks_msec() - started,
		map_data.contour_lines.size(), map_data.cliff_zones.size(),
		map_data.exit_zones.size(), map_data.hazard_markers.size()
	])
	return map_data


## Gather every chunk's height samples onto one grid, taking every
## detail_step-th sample (the world's far edge is always included)
func _build_height_grid(chunks: Dictionary) -> HeightGrid:
	var grid := HeightGrid.new()
	if chunks.is_empty():
		return grid

	var first: TerrainChunk = chunks.values()[0]
	var res: int = first.resolution
	var cell_size: float = first.cell_size
	var chunk_size: float = first.chunk_size
	var step := maxi(detail_step, 1)

	# Chunk grid extent (chunks may be sparse or offset)
	var origin_x := INF
	var origin_z := INF
	for chunk in chunks.values():
		origin_x = minf(origin_x, chunk.world_origin.x)
		origin_z = minf(origin_z, chunk.world_origin.z)
	var chunks_x := 0
	var chunks_z := 0
	for chunk in chunks.values():
		chunks_x = maxi(chunks_x, int(round((chunk.world_origin.x - origin_x) / chunk_size)) + 1)
		chunks_z = maxi(chunks_z, int(round((chunk.world_origin.z - origin_z) / chunk_size)) + 1)

	# Full-resolution sample index of each grid column/row
	var total_x := chunks_x * res
	var total_z := chunks_z * res
	var width := (total_x - 1 + step - 1) / step + 1
	var depth := (total_z - 1 + step - 1) / step + 1
	var col_index := PackedInt32Array()
	var row_index := PackedInt32Array()
	col_index.resize(width)
	row_index.resize(depth)
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	xs.resize(width)
	zs.resize(depth)
	for i in range(width):
		col_index[i] = mini(i * step, total_x - 1)
		xs[i] = origin_x + col_index[i] * cell_size
	for j in range(depth):
		row_index[j] = mini(j * step, total_z - 1)
		zs[j] = origin_z + row_index[j] * cell_size

	var heights := PackedFloat32Array()
	heights.resize(width * depth)
	heights.fill(MISSING_HEIGHT)

	for chunk in chunks.values():
		var cx := int(round((chunk.world_origin.x - origin_x) / chunk_size))
		var cz := int(round((chunk.world_origin.z - origin_z) / chunk_size))
		var x_start := cx * res
		var z_start := cz * res

		# Grid columns/rows whose sample lies inside this chunk
		var i_min := (x_start + step - 1) / step
		var i_max := mini((x_start + res - 1) / step, width - 1)
		if cx == chunks_x - 1:
			i_max = width - 1
		var j_min := (z_start + step - 1) / step
		var j_max := mini((z_start + res - 1) / step, depth - 1)
		if cz == chunks_z - 1:
			j_max = depth - 1

		var heightmap: PackedFloat32Array = chunk.heightmap
		for j in range(j_min, j_max + 1):
			var src_row := (row_index[j] - z_start) * res - x_start
			var dst_row := j * width
			for i in range(i_min, i_max + 1):
				heights[dst_row + i] = heightmap[src_row + col_index[i]]

	grid.width = width
	grid.depth = depth
	grid.heights = heights
	grid.xs = xs
	grid.zs = zs
	return grid


## Trace every contour level in one marching-squares pass over the grid: each
## cell only visits the levels that fall between its lowest and highest corner
func _generate_contours(grid: HeightGrid, min_elev: float, max_elev: float) -> Array[ContourLine]:
	var contours: Array[ContourLine] = []
	var interval := minor_contour_interval
	if grid.width < 2 or grid.depth < 2 or interval <= 0.0:
		return contours

	var start_elev: float = floorf(min_elev / interval) * interval
	var level_count := int(floorf((max_elev - start_elev) / interval)) + 1
	if level_count <= 0:
		return contours

	var levels: Array[ContourLine] = []
	for k in range(level_count):
		var elev := start_elev + k * interval
		levels.append(ContourLine.new(elev, fmod(elev, major_contour_interval) < 0.1))

	var width := grid.width
	var heights := grid.heights
	var xs := grid.xs
	var zs := grid.zs

	for j in range(grid.depth - 1):
		var z0 := zs[j]
		var z1 := zs[j + 1]
		var row0 := j * width
		var row1 := row0 + width

		for i in range(width - 1):
			var h00 := heights[row0 + i]
			var h10 := heights[row0 + i + 1]
			var h01 := heights[row1 + i]
			var h11 := heights[row1 + i + 1]

			var hmin := minf(minf(h00, h10), minf(h01, h11))
			if hmin < -1.0e29:
				continue  # Touches a missing chunk
			var hmax := maxf(maxf(h00, h10), maxf(h01, h11))

			# Levels crossing this cell: hmin < level <= hmax
			var k0 := maxi(int(floorf((hmin - start_elev) / interval)) + 1, 0)
			var k1 := mini(int(floorf((hmax - start_elev) / interval)), level_count - 1)
			if k1 < k0:
				continue

			var x0 := xs[i]
			var x1 := xs[i + 1]
			for k in range(k0, k1 + 1):
				var elevation := start_elev + k * interval
				var case_index := 0
				if h00 >= elevation: case_index |= 1
				if h10 >= elevation: case_index |= 2
				if h11 >= elevation: case_index |= 4
				if h01 >= elevation: case_index |= 8

				if case_index == 0 or case_index == 15:
					continue

				_append_cell_segments(levels[k], case_index, x0, x1, z0, z1, h00, h10, h01, h11, elevation)

	for contour in levels:
		if contour.points.size() > 2:
			contours.append(contour)

	return contours


## Append the marching-squares segments of one cell (as point pairs) to a contour
func _append_cell_segments(
	contour: ContourLine,
	case_index: int,
	x0: float, x1: float, z0: float, z1: float,
	h00: float, h10: float, h01: float, h11: float,
	elevation: float
) -> void:
	# Interpolated edge crossings
	var left := Vector2(x0, _interpolate_edge(z0, z1, h00, h01, elevation))
	var right := Vector2(x1, _interpolate_edge(z0, z1, h10, h11, elevation))
	var top := Vector2(_interpolate_edge(x0, x1, h00, h10, elevation), z0)
	var bottom := Vector2(_interpolate_edge(x0, x1, h01, h11, elevation), z1)
	var points := contour.points

	# Marching squares lookup table (simplified)
	match case_index:
		1, 14:  # One corner
			points.append(left)
			points.append(top)
		2, 13:
			points.append(top)
			points.append(right)
		3, 12:
			points.append(left)
			points.append(right)
		4, 11:
			points.append(right)
			points.append(bottom)
		5:  # Saddle
			points.append(left)
			points.append(top)
			points.append(right)
			points.append(bottom)
		6, 9:
			points.append(top)
			points.append(bottom)
		7, 8:
			points.append(left)
			points.append(bottom)
		10:  # Other saddle
			points.append(left)
			points.append(bottom)
			points.append(top)
			points.append(right)


## Interpolate the crossing position along an edge from a to b
func _interpolate_edge(a: float, b: float, h1: float, h2: float, elevation: float) -> float:
	if absf(h2 - h1) < 0.001:
		return (a + b) * 0.5

	var t := clampf((elevation - h1) / (h2 - h1), 0.0, 1.0)
	return a + (b - a) * t


## Find cliff zones for marking
func _find_cliff_zones(chunks: Dictionary) -> Array[PackedVector2Array]:
	var zones: Array[PackedVector2Array] = []

	for chunk in chunks.values():
		for cliff_coords in chunk.cliff_cells:
			var cell: TerrainCell = chunk.get_cell(cliff_coords)
			var zone := PackedVector2Array()

			# Create a small polygon around the cliff cell
			var half_size: float = chunk.cell_size * 0.5
			zone.append(Vector2(cell.position.x - half_size, cell.position.z - half_size))
			zone.append(Vector2(cell.position.x + half_size, cell.position.z - half_size))
			zone.append(Vector2(cell.position.x + half_size, cell.position.z + half_size))
			zone.append(Vector2(cell.position.x - half_size, cell.position.z + half_size))

			zones.append(zone)

	return zones


## Find exit zone markers
func _find_exit_zone_markers(chunks: Dictionary) -> Array[Vector2]:
	var markers: Array[Vector2] = []

	for chunk in chunks.values():
		for exit_coords in chunk.exit_zone_cells:
			var cell: TerrainCell = chunk.get_cell(exit_coords)
			# Only mark high-quality exit zones
			if cell.exit_zone_quality > 0.5:
				markers.append(Vector2(cell.position.x, cell.position.z))

	return markers


## Generate hazard markers (rope required, danger zones)
func _generate_hazard_markers(chunks: Dictionary) -> Array[Dictionary]:
	var markers: Array[Dictionary] = []

	for chunk in chunks.values():
		# Mark rope-required zones
		for rope_coords in chunk.rope_required_cells:
			var cell: TerrainCell = chunk.get_cell(rope_coords)
			markers.append({
				"type": "rope_required",
				"position": Vector2(cell.position.x, cell.position.z),
				"slope": cell.slope_angle
			})

	return markers


# =============================================================================
# MAP RENDERING
# =============================================================================

## Render topo map to an image
func render_to_image(map_data: TopoMapData, resolution: Vector2i) -> Image:
	var image := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.95, 0.93, 0.88, 1.0))  # Paper color

	var extent := map_data.bounds_max - map_data.bounds_min
	if extent.x <= 0.0 or extent.y <= 0.0:
		return image
	var scale := Vector2(resolution.x / extent.x, resolution.y / extent.y)

	# Draw contour lines
	for contour in map_data.contour_lines:
		var color := major_contour_color if contour.is_major else minor_contour_color
		var width := 2 if contour.is_major else 1
		var points: PackedVector2Array = contour.points

		for i in range(0, points.size() - 1, 2):
			var p1 := _world_to_image(points[i], map_data.bounds_min, scale)
			var p2 := _world_to_image(points[i + 1], map_data.bounds_min, scale)
			draw_line(image, p1, p2, color, width)

	# Draw cliff zones
	for zone in map_data.cliff_zones:
		if zone.size() >= 3:
			var center := Vector2.ZERO
			for point in zone:
				center += point
			center /= zone.size()

			var img_pos := _world_to_image(center, map_data.bounds_min, scale)
			draw_marker(image, img_pos, cliff_color, 3)

	# Draw exit zones
	for exit_pos in map_data.exit_zones:
		var img_pos := _world_to_image(exit_pos, map_data.bounds_min, scale)
		draw_marker(image, img_pos, exit_zone_color, 4)

	return image


func _world_to_image(world_pos: Vector2, bounds_min: Vector2, scale: Vector2) -> Vector2i:
	return Vector2i(
		int((world_pos.x - bounds_min.x) * scale.x),
		int((world_pos.y - bounds_min.y) * scale.y)
	)


## Draw a line of the given pixel width (Bresenham, clipped to the image)
func draw_line(image: Image, p1: Vector2i, p2: Vector2i, color: Color, width: int) -> void:
	var img_w := image.get_width()
	var img_h := image.get_height()
	var lo := -width / 2
	var hi := width / 2

	var dx := absi(p2.x - p1.x)
	var dy := absi(p2.y - p1.y)
	var sx := 1 if p1.x < p2.x else -1
	var sy := 1 if p1.y < p2.y else -1
	var err := dx - dy

	var x := p1.x
	var y := p1.y

	while true:
		if lo == hi:
			if x >= 0 and x < img_w and y >= 0 and y < img_h:
				image.set_pixel(x, y, color)
		else:
			# Draw with width
			for wx in range(lo, hi + 1):
				var px := x + wx
				if px < 0 or px >= img_w:
					continue
				for wy in range(lo, hi + 1):
					var py := y + wy
					if py >= 0 and py < img_h:
						image.set_pixel(px, py, color)

		if x == p2.x and y == p2.y:
			break

		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy


## Draw a filled disc of the given radius centred on pos (clipped to the image)
func draw_marker(image: Image, pos: Vector2i, color: Color, size: int) -> void:
	var stamp := _get_marker_stamp(color, size)
	var diameter := size * 2 + 1
	image.blit_rect_mask(stamp, stamp, Rect2i(0, 0, diameter, diameter), pos - Vector2i(size, size))


## Disc image used as both source and mask by draw_marker (built once per color/size)
func _get_marker_stamp(color: Color, size: int) -> Image:
	var key := [color, size]
	var stamp: Image = _marker_stamps.get(key, null)
	if stamp != null:
		return stamp

	var diameter := size * 2 + 1
	stamp = Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	stamp.fill(Color(0, 0, 0, 0))
	for dx in range(-size, size + 1):
		for dy in range(-size, size + 1):
			if dx * dx + dy * dy <= size * size:
				stamp.set_pixel(dx + size, dy + size, color)

	_marker_stamps[key] = stamp
	return stamp


# =============================================================================
# PATH OVERLAY
# =============================================================================

## Create a path overlay for replay/planning
func create_path_overlay(
	path: PackedVector3Array,
	map_data: TopoMapData,
	resolution: Vector2i
) -> Image:
	var image := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))  # Transparent

	if path.size() < 2:
		return image

	var scale := Vector2(
		resolution.x / (map_data.bounds_max.x - map_data.bounds_min.x),
		resolution.y / (map_data.bounds_max.y - map_data.bounds_min.y)
	)

	var path_color := Color(0.9, 0.3, 0.2, 0.8)

	for i in range(path.size() - 1):
		var p1 := Vector2(path[i].x, path[i].z)
		var p2 := Vector2(path[i + 1].x, path[i + 1].z)

		var img_p1 := _world_to_image(p1, map_data.bounds_min, scale)
		var img_p2 := _world_to_image(p2, map_data.bounds_min, scale)

		draw_line(image, img_p1, img_p2, path_color, 3)

	# Mark start
	var start := Vector2(path[0].x, path[0].z)
	draw_marker(image, _world_to_image(start, map_data.bounds_min, scale), Color(0.2, 0.8, 0.2), 5)

	# Mark end
	var end := Vector2(path[-1].x, path[-1].z)
	draw_marker(image, _world_to_image(end, map_data.bounds_min, scale), Color(0.8, 0.2, 0.2), 5)

	return image
