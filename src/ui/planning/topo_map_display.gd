class_name TopoMapDisplay
extends Control
## Interactive topo map display for route planning
## Shows terrain, hazards, and allows route drawing
##
## Design Philosophy:
## - Physical map feel (paper texture, fold lines)
## - Clear hazard visualization
## - Intuitive route drawing
## - Information degrades with weather (optional)

# =============================================================================
# SIGNALS
# =============================================================================

signal map_clicked(world_position: Vector2)
signal map_dragged(from_world: Vector2, to_world: Vector2)
signal zoom_changed(zoom_level: float)
signal waypoint_placed(world_position: Vector2)
signal waypoint_removed(index: int)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Display")
## Base map resolution
@export var map_resolution: Vector2i = Vector2i(1024, 1024)
## Minimum zoom level
@export var min_zoom: float = 0.5
## Maximum zoom level
@export var max_zoom: float = 3.0
## Zoom step per scroll
@export var zoom_step: float = 0.1

@export_group("Colors")
## Summit marker color
@export var summit_color: Color = Color(0.9, 0.3, 0.2, 1.0)
## Base/safety marker color
@export var base_color: Color = Color(0.2, 0.7, 0.3, 1.0)
## Planned route color
@export var route_color: Color = Color(0.2, 0.4, 0.9, 0.8)
## Waypoint color
@export var waypoint_color: Color = Color(0.9, 0.8, 0.2, 1.0)
## Selection highlight color
@export var selection_color: Color = Color(1.0, 1.0, 1.0, 0.3)

@export_group("Overlays")
## Show slope shading
@export var show_slope_shading: bool = true
## Show cliff hazards
@export var show_cliff_zones: bool = true
## Show exit zones
@export var show_exit_zones: bool = true
## Show rope-required zones
@export var show_rope_zones: bool = true

# =============================================================================
# STATE
# =============================================================================

## Current zoom level
var zoom: float = 1.0

## Pan offset (in map pixels)
var pan_offset: Vector2 = Vector2.ZERO

## Is currently panning
var is_panning: bool = false

## Pan start position
var pan_start: Vector2 = Vector2.ZERO

## Topo map data
var map_data: TopoMapGenerator.TopoMapData

## Map bounds in world coordinates
var world_bounds_min: Vector2 = Vector2.ZERO
var world_bounds_max: Vector2 = Vector2(1000, 1000)

## Rendered map textures
var base_map_texture: ImageTexture
var slope_overlay_texture: ImageTexture
var hazard_overlay_texture: ImageTexture
var route_overlay_texture: ImageTexture

## Placed waypoints (world coordinates)
var waypoints: Array[Vector2] = []

## Summit position (world)
var summit_position: Vector2 = Vector2.ZERO

## Base/safety position (world)
var base_position: Vector2 = Vector2.ZERO

## Current cursor world position
var cursor_world_pos: Vector2 = Vector2.ZERO

## Terrain service reference
var terrain_service: TerrainService

## Topo generator
var topo_generator: TopoMapGenerator


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	topo_generator = TopoMapGenerator.new()

	ServiceLocator.get_service_async("TerrainService", func(t):
		terrain_service = t
		_generate_map()
	)

	# Enable input processing
	mouse_filter = Control.MOUSE_FILTER_STOP


func _generate_map() -> void:
	if terrain_service == null:
		return

	# Get terrain bounds
	var bounds := terrain_service.get_bounds()
	world_bounds_min = Vector2(bounds["min"].x, bounds["min"].z)
	world_bounds_max = Vector2(bounds["max"].x, bounds["max"].z)

	# Set summit and base
	summit_position = Vector2(
		(world_bounds_min.x + world_bounds_max.x) / 2,
		world_bounds_min.y  # Top of map
	)
	base_position = Vector2(
		(world_bounds_min.x + world_bounds_max.x) / 2,
		world_bounds_max.y  # Bottom of map
	)

	# Generate map data
	map_data = topo_generator.generate_map(
		terrain_service.get_all_chunks(),
		Vector3(world_bounds_min.x, bounds["min"].y, world_bounds_min.y),
		Vector3(world_bounds_max.x, bounds["max"].y, world_bounds_max.y)
	)

	# Render base map
	var base_image := topo_generator.render_to_image(map_data, map_resolution)
	base_map_texture = ImageTexture.create_from_image(base_image)

	# Generate overlays
	_generate_slope_overlay()
	_generate_hazard_overlay()

	# Initial route overlay (empty)
	_update_route_overlay()

	queue_redraw()


func _generate_slope_overlay() -> void:
	if terrain_service == null:
		return

	var image := Image.create(map_resolution.x, map_resolution.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var scale := Vector2(
		map_resolution.x / (world_bounds_max.x - world_bounds_min.x),
		map_resolution.y / (world_bounds_max.y - world_bounds_min.y)
	)

	# Sample slope at each pixel
	for x in range(0, map_resolution.x, 4):  # Sample every 4 pixels for performance
		for y in range(0, map_resolution.y, 4):
			var world_pos := _image_to_world(Vector2i(x, y))
			var slope := terrain_service.get_slope_at(Vector3(world_pos.x, 0, world_pos.y))

			# Color based on slope angle
			var color := _get_slope_color(slope)
			if color.a > 0:
				for dx in range(4):
					for dy in range(4):
						if x + dx < map_resolution.x and y + dy < map_resolution.y:
							image.set_pixel(x + dx, y + dy, color)

	slope_overlay_texture = ImageTexture.create_from_image(image)


func _get_slope_color(slope_angle: float) -> Color:
	if slope_angle < 25:
		return Color(0, 0, 0, 0)  # Walkable - no overlay
	elif slope_angle < 35:
		return Color(0.9, 0.9, 0.2, 0.15)  # Steep - yellow tint
	elif slope_angle < 50:
		return Color(0.9, 0.5, 0.2, 0.25)  # Downclimb - orange tint
	elif slope_angle < 70:
		return Color(0.9, 0.2, 0.2, 0.35)  # Rappel required - red tint
	else:
		return Color(0.3, 0.0, 0.0, 0.5)  # Cliff - dark red


func _generate_hazard_overlay() -> void:
	var image := Image.create(map_resolution.x, map_resolution.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	if map_data == null:
		hazard_overlay_texture = ImageTexture.create_from_image(image)
		return

	var scale := Vector2(
		map_resolution.x / (world_bounds_max.x - world_bounds_min.x),
		map_resolution.y / (world_bounds_max.y - world_bounds_min.y)
	)

	# Draw cliff zones
	if show_cliff_zones:
		for zone in map_data.cliff_zones:
			if zone.size() >= 3:
				var center := Vector2.ZERO
				for point in zone:
					center += point
				center /= zone.size()

				var img_pos := _world_to_image(center)
				_draw_hazard_marker(image, img_pos, topo_generator.cliff_color, 6)

	# Draw exit zones
	if show_exit_zones:
		for exit_pos in map_data.exit_zones:
			var img_pos := _world_to_image(exit_pos)
			_draw_hazard_marker(image, img_pos, topo_generator.exit_zone_color, 4)

	# Draw rope-required zones
	if show_rope_zones:
		for marker in map_data.hazard_markers:
			if marker.get("type") == "rope_required":
				var pos: Vector2 = marker.get("position", Vector2.ZERO)
				var img_pos := _world_to_image(pos)
				_draw_hazard_marker(image, img_pos, Color(0.6, 0.3, 0.8, 0.7), 5)

	hazard_overlay_texture = ImageTexture.create_from_image(image)


func _draw_hazard_marker(image: Image, pos: Vector2i, color: Color, size: int) -> void:
	for dx in range(-size, size + 1):
		for dy in range(-size, size + 1):
			if dx * dx + dy * dy <= size * size:
				var px := pos.x + dx
				var py := pos.y + dy
				if px >= 0 and px < image.get_width() and py >= 0 and py < image.get_height():
					image.set_pixel(px, py, color)


func _update_route_overlay() -> void:
	var image := Image.create(map_resolution.x, map_resolution.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	# Draw route through waypoints
	var route_points: Array[Vector2] = []
	route_points.append(summit_position)
	route_points.append_array(waypoints)
	route_points.append(base_position)

	if route_points.size() >= 2:
		for i in range(route_points.size() - 1):
			var p1 := _world_to_image(route_points[i])
			var p2 := _world_to_image(route_points[i + 1])
			_draw_line(image, p1, p2, route_color, 3)

	# Draw waypoints
	for i in range(waypoints.size()):
		var img_pos := _world_to_image(waypoints[i])
		_draw_waypoint(image, img_pos, waypoint_color, i + 1)

	# Draw summit marker
	var summit_img := _world_to_image(summit_position)
	_draw_endpoint(image, summit_img, summit_color, "S")

	# Draw base marker
	var base_img := _world_to_image(base_position)
	_draw_endpoint(image, base_img, base_color, "B")

	route_overlay_texture = ImageTexture.create_from_image(image)
	queue_redraw()


func _draw_line(image: Image, p1: Vector2i, p2: Vector2i, color: Color, width: int) -> void:
	var dx := absi(p2.x - p1.x)
	var dy := absi(p2.y - p1.y)
	var sx := 1 if p1.x < p2.x else -1
	var sy := 1 if p1.y < p2.y else -1
	var err := dx - dy

	var x := p1.x
	var y := p1.y

	while true:
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


func _draw_waypoint(image: Image, pos: Vector2i, color: Color, number: int) -> void:
	# Draw circle
	var size := 8
	for dx in range(-size, size + 1):
		for dy in range(-size, size + 1):
			if dx * dx + dy * dy <= size * size:
				var px := pos.x + dx
				var py := pos.y + dy
				if px >= 0 and px < image.get_width() and py >= 0 and py < image.get_height():
					# Border
					if dx * dx + dy * dy >= (size - 2) * (size - 2):
						image.set_pixel(px, py, Color(0, 0, 0, 1))
					else:
						image.set_pixel(px, py, color)


func _draw_endpoint(image: Image, pos: Vector2i, color: Color, label: String) -> void:
	# Draw larger marker for start/end
	var size := 10
	for dx in range(-size, size + 1):
		for dy in range(-size, size + 1):
			if dx * dx + dy * dy <= size * size:
				var px := pos.x + dx
				var py := pos.y + dy
				if px >= 0 and px < image.get_width() and py >= 0 and py < image.get_height():
					if dx * dx + dy * dy >= (size - 2) * (size - 2):
						image.set_pixel(px, py, Color(0, 0, 0, 1))
					else:
						image.set_pixel(px, py, color)


# =============================================================================
# DRAWING
# =============================================================================

func _draw() -> void:
	# Calculate display rect with zoom and pan
	var map_size := Vector2(map_resolution) * zoom
	var display_rect := Rect2(
		(size - map_size) / 2 + pan_offset,
		map_size
	)

	# Draw base map
	if base_map_texture:
		draw_texture_rect(base_map_texture, display_rect, false)

	# Draw slope overlay
	if show_slope_shading and slope_overlay_texture:
		draw_texture_rect(slope_overlay_texture, display_rect, false)

	# Draw hazard overlay
	if hazard_overlay_texture:
		draw_texture_rect(hazard_overlay_texture, display_rect, false)

	# Draw route overlay
	if route_overlay_texture:
		draw_texture_rect(route_overlay_texture, display_rect, false)

	# Draw cursor position indicator
	if get_global_rect().has_point(get_global_mouse_position()):
		var cursor_screen := _world_to_screen(cursor_world_pos)
		draw_circle(cursor_screen, 5, Color(1, 1, 1, 0.5))


# =============================================================================
# INPUT
# =============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var local_pos := event.position

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var world_pos := _screen_to_world(local_pos)
			if event.double_click:
				# Double click to place waypoint
				_add_waypoint(world_pos)
			else:
				map_clicked.emit(world_pos)

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			# Start panning
			is_panning = true
			pan_start = local_pos
		else:
			is_panning = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(local_pos, zoom_step)

	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(local_pos, -zoom_step)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var local_pos := event.position
	cursor_world_pos = _screen_to_world(local_pos)

	if is_panning:
		var delta := local_pos - pan_start
		pan_offset += delta
		pan_start = local_pos
		queue_redraw()


func _zoom_at(screen_pos: Vector2, delta: float) -> void:
	var old_zoom := zoom
	zoom = clampf(zoom + delta, min_zoom, max_zoom)

	if zoom != old_zoom:
		# Adjust pan to zoom toward mouse position
		var center := size / 2 + pan_offset
		var offset := screen_pos - center
		pan_offset -= offset * (zoom / old_zoom - 1.0)

		zoom_changed.emit(zoom)
		queue_redraw()


# =============================================================================
# WAYPOINT MANAGEMENT
# =============================================================================

func _add_waypoint(world_pos: Vector2) -> void:
	waypoints.append(world_pos)
	waypoint_placed.emit(world_pos)
	_update_route_overlay()


func remove_waypoint(index: int) -> void:
	if index >= 0 and index < waypoints.size():
		waypoints.remove_at(index)
		waypoint_removed.emit(index)
		_update_route_overlay()


func clear_waypoints() -> void:
	waypoints.clear()
	_update_route_overlay()


func get_planned_route() -> Array[Vector2]:
	var route: Array[Vector2] = []
	route.append(summit_position)
	route.append_array(waypoints)
	route.append(base_position)
	return route


func get_planned_route_3d() -> PackedVector3Array:
	var route := PackedVector3Array()

	for pos_2d in get_planned_route():
		var height := 0.0
		if terrain_service:
			height = terrain_service.get_height_at(Vector3(pos_2d.x, 0, pos_2d.y))
		route.append(Vector3(pos_2d.x, height, pos_2d.y))

	return route


# =============================================================================
# COORDINATE CONVERSION
# =============================================================================

func _world_to_image(world_pos: Vector2) -> Vector2i:
	var normalized := (world_pos - world_bounds_min) / (world_bounds_max - world_bounds_min)
	return Vector2i(
		int(normalized.x * map_resolution.x),
		int(normalized.y * map_resolution.y)
	)


func _image_to_world(image_pos: Vector2i) -> Vector2:
	var normalized := Vector2(image_pos) / Vector2(map_resolution)
	return world_bounds_min + normalized * (world_bounds_max - world_bounds_min)


func _world_to_screen(world_pos: Vector2) -> Vector2:
	var image_pos := Vector2(_world_to_image(world_pos))
	var map_size := Vector2(map_resolution) * zoom
	var display_offset := (size - map_size) / 2 + pan_offset
	return display_offset + image_pos * zoom


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	var map_size := Vector2(map_resolution) * zoom
	var display_offset := (size - map_size) / 2 + pan_offset
	var image_pos := (screen_pos - display_offset) / zoom
	return _image_to_world(Vector2i(image_pos))


# =============================================================================
# QUERIES
# =============================================================================

func get_elevation_at(world_pos: Vector2) -> float:
	if terrain_service:
		return terrain_service.get_height_at(Vector3(world_pos.x, 0, world_pos.y))
	return 0.0


func get_slope_at(world_pos: Vector2) -> float:
	if terrain_service:
		return terrain_service.get_slope_at(Vector3(world_pos.x, 0, world_pos.y))
	return 0.0


func get_route_distance() -> float:
	var route := get_planned_route_3d()
	var total := 0.0

	for i in range(route.size() - 1):
		total += route[i].distance_to(route[i + 1])

	return total


func get_route_elevation_change() -> float:
	var route := get_planned_route_3d()
	if route.size() < 2:
		return 0.0

	return route[0].y - route[-1].y
