class_name TopoMapGenerator
extends RefCounted
## Generates topographic map representations for the planning UI
## Creates contour lines and visual overlays from terrain data

# =============================================================================
# CONFIGURATION
# =============================================================================

## Contour interval in meters (major contours)
var major_contour_interval: float = 100.0

## Contour interval for minor contours
var minor_contour_interval: float = 20.0

## Minimum segment length for contour simplification
var min_segment_length: float = 5.0

## Color for major contour lines
var major_contour_color: Color = Color(0.4, 0.3, 0.2, 0.9)

## Color for minor contour lines
var minor_contour_color: Color = Color(0.5, 0.4, 0.3, 0.5)

## Color for cliff markers
var cliff_color: Color = Color(0.8, 0.2, 0.2, 0.8)

## Color for exit zones
var exit_zone_color: Color = Color(0.2, 0.7, 0.3, 0.6)

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


# =============================================================================
# MAP GENERATION
# =============================================================================

## Generate topo map data from terrain chunks
func generate_map(chunks: Dictionary, bounds_min: Vector3, bounds_max: Vector3) -> TopoMapData:
	var map_data := TopoMapData.new()

	map_data.bounds_min = Vector2(bounds_min.x, bounds_min.z)
	map_data.bounds_max = Vector2(bounds_max.x, bounds_max.z)
	map_data.elevation_range = Vector2(bounds_min.y, bounds_max.y)

	# Generate contour lines
	map_data.contour_lines = _generate_contours(chunks, bounds_min.y, bounds_max.y)

	# Find cliff zones
	map_data.cliff_zones = _find_cliff_zones(chunks)

	# Find exit zones
	map_data.exit_zones = _find_exit_zone_markers(chunks)

	# Generate hazard markers
	map_data.hazard_markers = _generate_hazard_markers(chunks)

	return map_data


## Generate contour lines for elevation range
func _generate_contours(
	chunks: Dictionary,
	min_elev: float,
	max_elev: float
) -> Array[ContourLine]:
	var contours: Array[ContourLine] = []

	# Calculate contour elevations
	var start_elev := floor(min_elev / minor_contour_interval) * minor_contour_interval
	var elev := start_elev

	while elev <= max_elev:
		var is_major := fmod(elev, major_contour_interval) < 0.1
		var contour := _trace_contour_at_elevation(chunks, elev, is_major)

		if contour.points.size() > 2:
			contours.append(contour)

		elev += minor_contour_interval

	return contours


## Trace a contour line at a specific elevation using marching squares
func _trace_contour_at_elevation(
	chunks: Dictionary,
	elevation: float,
	is_major: bool
) -> ContourLine:
	var contour := ContourLine.new(elevation, is_major)

	# Collect all contour segments from all chunks
	for chunk in chunks.values():
		var segments := _march_squares_chunk(chunk, elevation)
		for segment in segments:
			contour.points.append(segment[0])
			contour.points.append(segment[1])

	return contour


## Marching squares algorithm for a single chunk
func _march_squares_chunk(chunk: TerrainChunk, elevation: float) -> Array:
	var segments := []

	for x in range(chunk.resolution - 1):
		for z in range(chunk.resolution - 1):
			# Get heights at corners of cell
			var h00 := chunk.get_height(Vector2i(x, z))
			var h10 := chunk.get_height(Vector2i(x + 1, z))
			var h01 := chunk.get_height(Vector2i(x, z + 1))
			var h11 := chunk.get_height(Vector2i(x + 1, z + 1))

			# Calculate marching squares case
			var case_index := 0
			if h00 >= elevation: case_index |= 1
			if h10 >= elevation: case_index |= 2
			if h11 >= elevation: case_index |= 4
			if h01 >= elevation: case_index |= 8

			# Skip if all above or all below
			if case_index == 0 or case_index == 15:
				continue

			# Get world position of cell corner
			var cell_pos := Vector2(
				chunk.world_origin.x + x * chunk.cell_size,
				chunk.world_origin.z + z * chunk.cell_size
			)

			# Calculate intersection points
			var cell_segments := _get_marching_squares_segments(
				case_index, cell_pos, chunk.cell_size,
				h00, h10, h01, h11, elevation
			)

			segments.append_array(cell_segments)

	return segments


## Get contour segments for a marching squares case
func _get_marching_squares_segments(
	case_index: int,
	cell_pos: Vector2,
	cell_size: float,
	h00: float, h10: float, h01: float, h11: float,
	elevation: float
) -> Array:
	var segments := []

	# Calculate interpolated edge positions
	var left := _interpolate_edge(cell_pos, cell_pos + Vector2(0, cell_size), h00, h01, elevation)
	var right := _interpolate_edge(cell_pos + Vector2(cell_size, 0), cell_pos + Vector2(cell_size, cell_size), h10, h11, elevation)
	var top := _interpolate_edge(cell_pos, cell_pos + Vector2(cell_size, 0), h00, h10, elevation)
	var bottom := _interpolate_edge(cell_pos + Vector2(0, cell_size), cell_pos + Vector2(cell_size, cell_size), h01, h11, elevation)

	# Marching squares lookup table (simplified)
	match case_index:
		1, 14:  # One corner
			segments.append([left, top])
		2, 13:
			segments.append([top, right])
		3, 12:
			segments.append([left, right])
		4, 11:
			segments.append([right, bottom])
		5:  # Saddle
			segments.append([left, top])
			segments.append([right, bottom])
		6, 9:
			segments.append([top, bottom])
		7, 8:
			segments.append([left, bottom])
		10:  # Other saddle
			segments.append([left, bottom])
			segments.append([top, right])

	return segments


## Interpolate position along an edge
func _interpolate_edge(
	p1: Vector2,
	p2: Vector2,
	h1: float,
	h2: float,
	elevation: float
) -> Vector2:
	if absf(h2 - h1) < 0.001:
		return (p1 + p2) * 0.5

	var t := (elevation - h1) / (h2 - h1)
	t = clampf(t, 0.0, 1.0)
	return p1.lerp(p2, t)


## Find cliff zones for marking
func _find_cliff_zones(chunks: Dictionary) -> Array[PackedVector2Array]:
	var zones: Array[PackedVector2Array] = []

	for chunk in chunks.values():
		for cliff_coords in chunk.cliff_cells:
			var cell := chunk.get_cell(cliff_coords)
			var zone := PackedVector2Array()

			# Create a small polygon around the cliff cell
			var half_size := chunk.cell_size * 0.5
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
			var cell := chunk.get_cell(exit_coords)
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
			var cell := chunk.get_cell(rope_coords)
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

	var scale := Vector2(
		resolution.x / (map_data.bounds_max.x - map_data.bounds_min.x),
		resolution.y / (map_data.bounds_max.y - map_data.bounds_min.y)
	)

	# Draw contour lines
	for contour in map_data.contour_lines:
		var color := major_contour_color if contour.is_major else minor_contour_color
		var width := 2 if contour.is_major else 1

		for i in range(0, contour.points.size() - 1, 2):
			var p1 := _world_to_image(contour.points[i], map_data.bounds_min, scale)
			var p2 := _world_to_image(contour.points[i + 1], map_data.bounds_min, scale)
			_draw_line(image, p1, p2, color, width)

	# Draw cliff zones
	for zone in map_data.cliff_zones:
		if zone.size() >= 3:
			var center := Vector2.ZERO
			for point in zone:
				center += point
			center /= zone.size()

			var img_pos := _world_to_image(center, map_data.bounds_min, scale)
			_draw_marker(image, img_pos, cliff_color, 3)

	# Draw exit zones
	for exit_pos in map_data.exit_zones:
		var img_pos := _world_to_image(exit_pos, map_data.bounds_min, scale)
		_draw_marker(image, img_pos, exit_zone_color, 4)

	return image


func _world_to_image(world_pos: Vector2, bounds_min: Vector2, scale: Vector2) -> Vector2i:
	return Vector2i(
		int((world_pos.x - bounds_min.x) * scale.x),
		int((world_pos.y - bounds_min.y) * scale.y)
	)


func _draw_line(image: Image, p1: Vector2i, p2: Vector2i, color: Color, width: int) -> void:
	# Bresenham's line algorithm
	var dx := absi(p2.x - p1.x)
	var dy := absi(p2.y - p1.y)
	var sx := 1 if p1.x < p2.x else -1
	var sy := 1 if p1.y < p2.y else -1
	var err := dx - dy

	var x := p1.x
	var y := p1.y

	while true:
		# Draw with width
		for wx in range(-width/2, width/2 + 1):
			for wy in range(-width/2, width/2 + 1):
				var px := x + wx
				var py := y + wy
				if px >= 0 and px < image.get_width() and py >= 0 and py < image.get_height():
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


func _draw_marker(image: Image, pos: Vector2i, color: Color, size: int) -> void:
	for dx in range(-size, size + 1):
		for dy in range(-size, size + 1):
			if dx * dx + dy * dy <= size * size:
				var px := pos.x + dx
				var py := pos.y + dy
				if px >= 0 and px < image.get_width() and py >= 0 and py < image.get_height():
					image.set_pixel(px, py, color)


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

		_draw_line(image, img_p1, img_p2, path_color, 3)

	# Mark start
	var start := Vector2(path[0].x, path[0].z)
	_draw_marker(image, _world_to_image(start, map_data.bounds_min, scale), Color(0.2, 0.8, 0.2), 5)

	# Mark end
	var end := Vector2(path[-1].x, path[-1].z)
	_draw_marker(image, _world_to_image(end, map_data.bounds_min, scale), Color(0.8, 0.2, 0.2), 5)

	return image
