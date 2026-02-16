class_name MapCheckOverlay
extends Control
## Map check overlay during paused gameplay
## Shows topo map with current position and route
##
## Design Philosophy:
## - Map is a tool, not omniscience
## - Shows what you would know from a real map
## - Position may have uncertainty in poor conditions

# =============================================================================
# SIGNALS
# =============================================================================

signal close_requested()

# =============================================================================
# CONFIGURATION
# =============================================================================

const POSITION_UPDATE_INTERVAL := 0.5
const UNCERTAINTY_BASE := 10.0  # meters
const UNCERTAINTY_STORM := 50.0  # meters in storm

# =============================================================================
# STATE
# =============================================================================

## Current run context
var run_context: RunContext

## Terrain service reference
var terrain_service: TerrainService

## Topo map generator
var topo_generator: TopoMapGenerator

## Current player position
var player_position: Vector3 = Vector3.ZERO

## Position uncertainty radius
var uncertainty_radius: float = 10.0

## Map image texture
var map_texture: ImageTexture

## Map data
var map_data: TopoMapGenerator.TopoMapData

## Is overlay visible
var is_showing: bool = false

# =============================================================================
# NODES
# =============================================================================

var background: ColorRect
var map_container: Control
var map_display: TextureRect
var position_marker: Control
var route_overlay: Control
var info_panel: PanelContainer
var close_button: Button

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	topo_generator = TopoMapGenerator.new()

	ServiceLocator.get_service_async("TerrainService", func(ts):
		terrain_service = ts
	)

	_build_ui()


func _build_ui() -> void:
	# Dark background
	background = ColorRect.new()
	background.name = "Background"
	background.color = Color(0.05, 0.05, 0.08, 0.9)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	# Main layout
	var main := HBoxContainer.new()
	main.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.add_theme_constant_override("separation", 0)
	add_child(main)

	# Map container (left, larger)
	map_container = Control.new()
	map_container.name = "MapContainer"
	map_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_container.size_flags_stretch_ratio = 3.0
	main.add_child(map_container)

	# Map display
	map_display = TextureRect.new()
	map_display.name = "MapDisplay"
	map_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_display.expand_mode = TextureRect.EXPAND_KEEP_ASPECT_CENTERED
	map_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_container.add_child(map_display)

	# Route overlay (drawn on top of map)
	route_overlay = Control.new()
	route_overlay.name = "RouteOverlay"
	route_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	route_overlay.draw.connect(_on_route_overlay_draw)
	map_container.add_child(route_overlay)

	# Position marker
	position_marker = Control.new()
	position_marker.name = "PositionMarker"
	position_marker.custom_minimum_size = Vector2(20, 20)
	position_marker.draw.connect(_on_position_marker_draw)
	map_container.add_child(position_marker)

	# Info panel (right side)
	_create_info_panel(main)

	# Header with title and close
	var header := HBoxContainer.new()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_bottom = 60
	add_child(header)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 15)
	header.add_child(margin)

	var header_content := HBoxContainer.new()
	margin.add_child(header_content)

	var title := Label.new()
	title.text = "MAP CHECK"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	header_content.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_content.add_child(spacer)

	close_button = Button.new()
	close_button.text = "Close [ESC]"
	close_button.custom_minimum_size = Vector2(120, 40)
	close_button.pressed.connect(_on_close_pressed)
	header_content.add_child(close_button)


func _create_info_panel(parent: Control) -> void:
	info_panel = PanelContainer.new()
	info_panel.name = "InfoPanel"
	info_panel.custom_minimum_size = Vector2(280, 0)
	parent.add_child(info_panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.95)
	info_panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	info_panel.add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 70)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "InfoContent"
	content.add_theme_constant_override("separation", 15)
	margin.add_child(content)


# =============================================================================
# SHOW/HIDE
# =============================================================================

func show_overlay() -> void:
	if is_showing:
		return

	is_showing = true
	visible = true

	run_context = GameStateManager.get_current_run()
	_update_player_position()
	_generate_map()
	_update_info_panel()

	# Fade in
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.2)


func hide_overlay() -> void:
	if not is_showing:
		return

	is_showing = false

	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.2)
	tween.tween_callback(func(): visible = false)


# =============================================================================
# MAP GENERATION
# =============================================================================

func _generate_map() -> void:
	if terrain_service == null:
		return

	# Get terrain bounds
	var bounds_min := terrain_service.terrain_bounds_min
	var bounds_max := terrain_service.terrain_bounds_max

	# Generate topo map data
	var chunks := terrain_service.get_all_chunks()
	map_data = topo_generator.generate_map(chunks, bounds_min, bounds_max)

	# Render to image
	var resolution := Vector2i(800, 800)
	var image := topo_generator.render_to_image(map_data, resolution)

	# Create texture
	map_texture = ImageTexture.create_from_image(image)
	map_display.texture = map_texture

	# Update overlays
	route_overlay.queue_redraw()
	_update_position_marker()


func _update_player_position() -> void:
	if run_context == null:
		return

	player_position = run_context.position

	# Calculate uncertainty based on conditions
	uncertainty_radius = UNCERTAINTY_BASE

	if run_context.current_weather == GameEnums.WeatherState.STORM or run_context.current_weather == GameEnums.WeatherState.WHITEOUT:
		uncertainty_radius = UNCERTAINTY_STORM
	elif run_context.current_weather == GameEnums.WeatherState.SNOW or run_context.current_weather == GameEnums.WeatherState.DETERIORATING:
		uncertainty_radius = UNCERTAINTY_BASE * 2

	_update_position_marker()


func _update_position_marker() -> void:
	if map_data == null:
		return

	# Convert world position to map coordinates
	var map_pos := _world_to_map(Vector2(player_position.x, player_position.z))

	# Position the marker
	position_marker.position = map_pos - position_marker.size / 2
	position_marker.queue_redraw()


func _world_to_map(world_pos: Vector2) -> Vector2:
	if map_data == null:
		return Vector2.ZERO

	var map_size := map_display.size
	var bounds_size := map_data.bounds_max - map_data.bounds_min

	var normalized := (world_pos - map_data.bounds_min) / bounds_size
	return normalized * map_size


func _map_to_world(map_pos: Vector2) -> Vector2:
	if map_data == null:
		return Vector2.ZERO

	var map_size := map_display.size
	var bounds_size := map_data.bounds_max - map_data.bounds_min

	var normalized := map_pos / map_size
	return map_data.bounds_min + normalized * bounds_size


# =============================================================================
# DRAWING
# =============================================================================

func _on_position_marker_draw() -> void:
	var center := position_marker.size / 2

	# Uncertainty circle
	var uncertainty_pixels := (uncertainty_radius / (map_data.bounds_max.x - map_data.bounds_min.x)) * map_display.size.x if map_data else 20
	position_marker.draw_arc(center, uncertainty_pixels, 0, TAU, 32, Color(0.3, 0.6, 0.9, 0.3), 2.0)

	# Position dot
	position_marker.draw_circle(center, 8, Color(0.3, 0.6, 0.9, 0.9))
	position_marker.draw_circle(center, 5, Color(0.5, 0.8, 1.0, 1.0))

	# Direction indicator (if moving)
	if run_context and run_context.velocity.length() > 0.5:
		var dir := Vector2(run_context.velocity.x, run_context.velocity.z).normalized()
		var arrow_end := center + dir * 20
		position_marker.draw_line(center, arrow_end, Color(0.5, 0.8, 1.0), 3.0)


func _on_route_overlay_draw() -> void:
	if run_context == null or map_data == null:
		return

	# Draw planned route if available
	var planned_route = run_context.get_meta("planned_route", PackedVector3Array())
	if planned_route.size() >= 2:
		var points := PackedVector2Array()
		for wp in planned_route:
			var map_pos := _world_to_map(Vector2(wp.x, wp.z))
			points.append(map_pos)

		route_overlay.draw_polyline(points, Color(0.9, 0.4, 0.3, 0.6), 3.0)

	# Draw traveled path
	var traveled_path = run_context.get_meta("traveled_path", PackedVector3Array())
	if traveled_path.size() >= 2:
		var points := PackedVector2Array()
		for pos in traveled_path:
			var map_pos := _world_to_map(Vector2(pos.x, pos.z))
			points.append(map_pos)

		route_overlay.draw_polyline(points, Color(0.3, 0.8, 0.4, 0.7), 2.0)

	# Draw start position
	if run_context.start_elevation > 0:
		var start := Vector2(player_position.x, player_position.z)  # Would need actual start pos
		# Draw start marker


# =============================================================================
# INFO PANEL
# =============================================================================

func _update_info_panel() -> void:
	var content := info_panel.get_node("ScrollContainer/MarginContainer/InfoContent")
	if content == null:
		return

	# Clear existing
	for child in content.get_children():
		child.queue_free()

	if run_context == null:
		return

	# Position section
	_add_section_header(content, "Current Position")
	_add_info_row(content, "Elevation", "%.0fm" % run_context.current_elevation)

	var descent := run_context.start_elevation - run_context.current_elevation
	_add_info_row(content, "Descended", "%.0fm" % descent)

	var remaining := run_context.current_elevation - run_context.target_elevation
	_add_info_row(content, "Remaining", "%.0fm" % remaining)

	# Uncertainty note
	if uncertainty_radius > UNCERTAINTY_BASE:
		var note := Label.new()
		note.text = "Position uncertain due to conditions"
		note.add_theme_font_size_override("font_size", 11)
		note.add_theme_color_override("font_color", Color(0.8, 0.6, 0.3))
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(note)

	# Separator
	content.add_child(HSeparator.new())

	# Time section
	_add_section_header(content, "Time")
	_add_info_row(content, "Elapsed", _format_time(run_context.real_time_elapsed))
	_add_info_row(content, "Current Time", "%.0f:00" % run_context.current_time)

	var daylight := maxf(0, 18.0 - run_context.current_time)
	_add_info_row(content, "Daylight Left", "~%.1fh" % daylight)

	# Separator
	content.add_child(HSeparator.new())

	# Conditions section
	_add_section_header(content, "Conditions")
	var weather := GameEnums.WeatherState.keys()[run_context.current_weather]
	_add_info_row(content, "Weather", weather.capitalize())

	var wind := GameEnums.WindStrength.keys()[run_context.current_wind]
	_add_info_row(content, "Wind", wind.capitalize())

	# Separator
	content.add_child(HSeparator.new())

	# Route memory section
	var save_manager := ServiceLocator.get_service("SaveManager") as SaveManager
	if save_manager:
		var route_memory := save_manager.get_route_memory()
		var familiarity := route_memory.get_familiarity_at_position(
			run_context.mountain_id,
			player_position
		)

		_add_section_header(content, "Familiarity")
		if familiarity > 0.7:
			_add_info_row(content, "Area", "Well known")
		elif familiarity > 0.3:
			_add_info_row(content, "Area", "Somewhat familiar")
		else:
			_add_info_row(content, "Area", "Unknown territory")

		var hazards := route_memory.get_known_hazards(run_context.mountain_id)
		if hazards.size() > 0:
			_add_info_row(content, "Known hazards", str(hazards.size()))


func _add_section_header(parent: Control, text: String) -> void:
	var header := Label.new()
	header.text = text
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", Color(0.8, 0.78, 0.75))
	parent.add_child(header)


func _add_info_row(parent: Control, label_text: String, value_text: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 13)
	value.add_theme_color_override("font_color", Color(0.9, 0.88, 0.85))
	row.add_child(value)


func _format_time(seconds: float) -> String:
	var hours := int(seconds / 3600)
	var minutes := int(fmod(seconds, 3600) / 60)
	var secs := int(fmod(seconds, 60))

	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, secs]
	else:
		return "%d:%02d" % [minutes, secs]


# =============================================================================
# INPUT
# =============================================================================

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("open_map"):
		_on_close_pressed()
		get_viewport().set_input_as_handled()


func _on_close_pressed() -> void:
	close_requested.emit()
	hide_overlay()
	GameStateManager.exit_map_check()
