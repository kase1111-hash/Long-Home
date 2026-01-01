class_name ElevationProfileDisplay
extends Control
## Displays elevation profile of planned route
## Shows terrain zones and key points along the route
##
## Visual Design:
## - Clean graph with elevation line
## - Color-coded terrain zones
## - Markers for waypoints
## - Slope indicators

# =============================================================================
# SIGNALS
# =============================================================================

signal position_hovered(distance: float, elevation: float)
signal position_clicked(distance: float)

# =============================================================================
# CONFIGURATION
# =============================================================================

@export_group("Colors")
## Line color for elevation
@export var elevation_color: Color = Color(0.2, 0.6, 1.0, 1.0)
## Fill color under elevation line
@export var fill_color: Color = Color(0.2, 0.4, 0.8, 0.3)
## Grid line color
@export var grid_color: Color = Color(0.5, 0.5, 0.5, 0.3)
## Axis label color
@export var label_color: Color = Color(0.8, 0.8, 0.8, 1.0)
## Waypoint marker color
@export var waypoint_color: Color = Color(0.9, 0.8, 0.2, 1.0)

@export_group("Terrain Zone Colors")
@export var walkable_color: Color = Color(0.2, 0.7, 0.2, 0.3)
@export var steep_color: Color = Color(0.8, 0.8, 0.2, 0.3)
@export var downclimb_color: Color = Color(0.9, 0.5, 0.2, 0.3)
@export var rappel_color: Color = Color(0.9, 0.2, 0.2, 0.3)
@export var cliff_color: Color = Color(0.5, 0.0, 0.0, 0.5)

@export_group("Layout")
## Padding around the graph
@export var padding: float = 40.0
## Height of terrain zone strip
@export var zone_strip_height: float = 20.0
## Number of horizontal grid lines
@export var grid_lines_h: int = 5
## Number of vertical grid lines
@export var grid_lines_v: int = 10

# =============================================================================
# STATE
# =============================================================================

## Profile data
var distances: PackedFloat32Array = PackedFloat32Array()
var elevations: PackedFloat32Array = PackedFloat32Array()
var slopes: PackedFloat32Array = PackedFloat32Array()
var terrain_zones: Array = []
var total_distance: float = 0.0

## Bounds
var min_elevation: float = 0.0
var max_elevation: float = 1000.0

## Waypoint distances
var waypoint_distances: Array[float] = []

## Hovered position
var hover_distance: float = -1.0


# =============================================================================
# INITIALIZATION
# =============================================================================

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


# =============================================================================
# DATA
# =============================================================================

func set_profile_data(data: Dictionary) -> void:
	distances = data.get("distances", PackedFloat32Array())
	elevations = data.get("elevations", PackedFloat32Array())
	slopes = data.get("slopes", PackedFloat32Array())
	terrain_zones = data.get("terrain_zones", [])
	total_distance = data.get("total_distance", 0.0)

	if elevations.size() > 0:
		min_elevation = elevations.min()
		max_elevation = elevations.max()

		# Add some padding
		var range_val := max_elevation - min_elevation
		min_elevation -= range_val * 0.1
		max_elevation += range_val * 0.1

	queue_redraw()


func set_waypoint_distances(waypoints: Array[float]) -> void:
	waypoint_distances = waypoints
	queue_redraw()


func clear() -> void:
	distances.clear()
	elevations.clear()
	slopes.clear()
	terrain_zones.clear()
	waypoint_distances.clear()
	total_distance = 0.0
	queue_redraw()


# =============================================================================
# DRAWING
# =============================================================================

func _draw() -> void:
	var rect := get_rect()

	# Background
	draw_rect(Rect2(Vector2.ZERO, rect.size), Color(0.08, 0.08, 0.1, 0.95))

	if distances.size() < 2:
		_draw_empty_state(rect)
		return

	# Calculate graph area
	var graph_rect := Rect2(
		Vector2(padding, padding),
		Vector2(rect.size.x - padding * 2, rect.size.y - padding * 2 - zone_strip_height)
	)

	# Draw grid
	_draw_grid(graph_rect)

	# Draw terrain zone strip
	_draw_terrain_zones(Rect2(
		Vector2(padding, rect.size.y - padding - zone_strip_height),
		Vector2(graph_rect.size.x, zone_strip_height)
	))

	# Draw elevation fill
	_draw_elevation_fill(graph_rect)

	# Draw elevation line
	_draw_elevation_line(graph_rect)

	# Draw waypoint markers
	_draw_waypoint_markers(graph_rect)

	# Draw axes labels
	_draw_axes_labels(graph_rect)

	# Draw hover indicator
	if hover_distance >= 0:
		_draw_hover_indicator(graph_rect)


func _draw_empty_state(rect: Rect2) -> void:
	var font := ThemeDB.fallback_font
	var text := "Plan a route to see elevation profile"
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
	var pos := (rect.size - text_size) / 2
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(0.5, 0.5, 0.5))


func _draw_grid(rect: Rect2) -> void:
	# Horizontal grid lines
	for i in range(grid_lines_h + 1):
		var y := rect.position.y + rect.size.y * (float(i) / grid_lines_h)
		draw_line(
			Vector2(rect.position.x, y),
			Vector2(rect.position.x + rect.size.x, y),
			grid_color, 1.0
		)

	# Vertical grid lines
	for i in range(grid_lines_v + 1):
		var x := rect.position.x + rect.size.x * (float(i) / grid_lines_v)
		draw_line(
			Vector2(x, rect.position.y),
			Vector2(x, rect.position.y + rect.size.y),
			grid_color, 1.0
		)


func _draw_terrain_zones(rect: Rect2) -> void:
	if terrain_zones.size() == 0:
		return

	var zone_width := rect.size.x / terrain_zones.size()

	for i in range(terrain_zones.size()):
		var zone: int = terrain_zones[i]
		var color := _get_zone_color(zone)

		var zone_rect := Rect2(
			Vector2(rect.position.x + i * zone_width, rect.position.y),
			Vector2(zone_width + 1, rect.size.y)  # +1 to avoid gaps
		)

		draw_rect(zone_rect, color)


func _get_zone_color(zone: int) -> Color:
	match zone:
		GameEnums.TerrainZone.WALKABLE:
			return walkable_color
		GameEnums.TerrainZone.STEEP:
			return steep_color
		GameEnums.TerrainZone.SLIDEABLE:
			return steep_color
		GameEnums.TerrainZone.DOWNCLIMB:
			return downclimb_color
		GameEnums.TerrainZone.RAPPEL_REQUIRED:
			return rappel_color
		GameEnums.TerrainZone.CLIFF:
			return cliff_color
		_:
			return Color(0.3, 0.3, 0.3, 0.3)


func _draw_elevation_fill(rect: Rect2) -> void:
	var points := PackedVector2Array()
	var elev_range := max_elevation - min_elevation

	# Start at bottom left
	points.append(Vector2(rect.position.x, rect.position.y + rect.size.y))

	# Add elevation points
	for i in range(distances.size()):
		var x := rect.position.x + (distances[i] / total_distance) * rect.size.x
		var y := rect.position.y + rect.size.y - ((elevations[i] - min_elevation) / elev_range) * rect.size.y
		points.append(Vector2(x, y))

	# End at bottom right
	points.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))

	if points.size() >= 3:
		draw_colored_polygon(points, fill_color)


func _draw_elevation_line(rect: Rect2) -> void:
	var points := PackedVector2Array()
	var elev_range := max_elevation - min_elevation

	for i in range(distances.size()):
		var x := rect.position.x + (distances[i] / total_distance) * rect.size.x
		var y := rect.position.y + rect.size.y - ((elevations[i] - min_elevation) / elev_range) * rect.size.y
		points.append(Vector2(x, y))

	if points.size() >= 2:
		draw_polyline(points, elevation_color, 2.0, true)


func _draw_waypoint_markers(rect: Rect2) -> void:
	var elev_range := max_elevation - min_elevation

	for wp_dist in waypoint_distances:
		var x := rect.position.x + (wp_dist / total_distance) * rect.size.x

		# Find elevation at this distance
		var elev := _get_elevation_at_distance(wp_dist)
		var y := rect.position.y + rect.size.y - ((elev - min_elevation) / elev_range) * rect.size.y

		# Draw vertical line
		draw_line(
			Vector2(x, rect.position.y),
			Vector2(x, rect.position.y + rect.size.y),
			Color(waypoint_color.r, waypoint_color.g, waypoint_color.b, 0.5),
			1.0
		)

		# Draw marker
		draw_circle(Vector2(x, y), 6, waypoint_color)
		draw_circle(Vector2(x, y), 4, Color(0, 0, 0))


func _draw_axes_labels(rect: Rect2) -> void:
	var font := ThemeDB.fallback_font
	var font_size := 11

	# Elevation labels (left side)
	for i in range(grid_lines_h + 1):
		var elev := max_elevation - (max_elevation - min_elevation) * (float(i) / grid_lines_h)
		var y := rect.position.y + rect.size.y * (float(i) / grid_lines_h)

		draw_string(font, Vector2(5, y + 4), "%.0fm" % elev,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, label_color)

	# Distance labels (bottom)
	for i in range(grid_lines_v + 1):
		var dist := total_distance * (float(i) / grid_lines_v)
		var x := rect.position.x + rect.size.x * (float(i) / grid_lines_v)

		var label := ""
		if dist >= 1000:
			label = "%.1fkm" % (dist / 1000)
		else:
			label = "%.0fm" % dist

		draw_string(font, Vector2(x - 15, rect.position.y + rect.size.y + zone_strip_height + 15),
			label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, label_color)


func _draw_hover_indicator(rect: Rect2) -> void:
	if hover_distance < 0 or total_distance <= 0:
		return

	var x := rect.position.x + (hover_distance / total_distance) * rect.size.x
	var elev := _get_elevation_at_distance(hover_distance)
	var elev_range := max_elevation - min_elevation
	var y := rect.position.y + rect.size.y - ((elev - min_elevation) / elev_range) * rect.size.y

	# Vertical line
	draw_line(
		Vector2(x, rect.position.y),
		Vector2(x, rect.position.y + rect.size.y + zone_strip_height),
		Color(1, 1, 1, 0.5), 1.0
	)

	# Point
	draw_circle(Vector2(x, y), 5, Color(1, 1, 1))

	# Info box
	var font := ThemeDB.fallback_font
	var info := "%.0fm | %.0fm" % [hover_distance, elev]
	var box_size := Vector2(80, 20)
	var box_pos := Vector2(x - box_size.x / 2, y - box_size.y - 10)

	draw_rect(Rect2(box_pos, box_size), Color(0, 0, 0, 0.8))
	draw_string(font, box_pos + Vector2(5, 14), info,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


func _get_elevation_at_distance(dist: float) -> float:
	if distances.size() == 0:
		return 0.0

	# Find surrounding points and interpolate
	for i in range(distances.size() - 1):
		if distances[i + 1] >= dist:
			var t := (dist - distances[i]) / maxf(0.001, distances[i + 1] - distances[i])
			return lerpf(elevations[i], elevations[i + 1], t)

	return elevations[-1]


# =============================================================================
# INPUT
# =============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var local_pos := (event as InputEventMouseMotion).position
		_update_hover(local_pos)

	elif event is InputEventMouseButton:
		var button_event := event as InputEventMouseButton
		if button_event.button_index == MOUSE_BUTTON_LEFT and button_event.pressed:
			if hover_distance >= 0:
				position_clicked.emit(hover_distance)


func _update_hover(local_pos: Vector2) -> void:
	var rect := get_rect()
	var graph_left := padding
	var graph_right := rect.size.x - padding
	var graph_width := graph_right - graph_left

	if local_pos.x >= graph_left and local_pos.x <= graph_right:
		hover_distance = ((local_pos.x - graph_left) / graph_width) * total_distance
		var elev := _get_elevation_at_distance(hover_distance)
		position_hovered.emit(hover_distance, elev)
	else:
		hover_distance = -1.0

	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hover_distance = -1.0
		queue_redraw()
