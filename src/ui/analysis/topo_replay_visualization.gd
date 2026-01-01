class_name TopoReplayVisualization
extends Control
## Interactive topo map replay visualization
## Shows the player's descent path with animated playhead and moment markers
##
## Design Philosophy:
## - Let players understand their journey
## - Highlight key moments without sensationalizing
## - Respect the weight of fatal outcomes

# =============================================================================
# SIGNALS
# =============================================================================

signal moment_selected(moment: Dictionary)
signal playback_complete()
signal close_requested()

# =============================================================================
# CONFIGURATION
# =============================================================================

## Animation duration for path drawing (seconds)
const PATH_DRAW_DURATION := 5.0

## Playhead size
const PLAYHEAD_RADIUS := 8.0

## Moment marker size
const MARKER_RADIUS := 6.0

## Timeline height
const TIMELINE_HEIGHT := 40.0

## Marker colors by type
const MARKER_COLORS := {
	"decision": Color(0.3, 0.5, 0.8, 0.9),
	"slide": Color(0.8, 0.6, 0.2, 0.9),
	"rope": Color(0.4, 0.7, 0.5, 0.9),
	"injury": Color(0.8, 0.4, 0.3, 0.9),
	"incident": Color(0.9, 0.5, 0.3, 0.9),
	"fatal": Color(0.7, 0.3, 0.3, 0.8),
}

# =============================================================================
# STATE
# =============================================================================

## Run context being visualized
var run_context: RunContext

## Recording data (if available)
var recording_data: Dictionary

## Path points in 2D (screen space)
var path_points_2d: PackedVector2Array

## Path points in 3D (world space)
var path_points_3d: PackedVector3Array

## Path timestamps
var path_timestamps: PackedFloat64Array

## Key moments
var moments: Array[Dictionary] = []

## Topo map texture
var topo_texture: ImageTexture

## Map bounds in world space
var map_bounds_min: Vector2
var map_bounds_max: Vector2

## Current playback state
var is_playing: bool = false
var playback_time: float = 0.0
var playback_speed: float = 1.0
var total_duration: float = 0.0

## Current playhead position
var playhead_position: Vector2 = Vector2.ZERO

## Selected moment index (-1 = none)
var selected_moment: int = -1

## Path draw progress (0-1 for initial animation)
var path_draw_progress: float = 0.0
var is_drawing_path: bool = false

# =============================================================================
# NODES
# =============================================================================

var background: ColorRect
var main_container: HBoxContainer
var map_panel: Panel
var map_display: Control
var info_panel: VBoxContainer
var timeline_container: Control
var play_button: Button
var speed_button: Button
var time_label: Label
var moments_list: VBoxContainer
var close_button: Button

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	visible = false
	_build_ui()


func _build_ui() -> void:
	# Background
	background = ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.05, 0.05, 0.08, 0.95)
	add_child(background)

	# Main container
	main_container = HBoxContainer.new()
	main_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_container.add_theme_constant_override("separation", 20)
	add_child(main_container)

	# Add margins
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)

	var inner_container := HBoxContainer.new()
	inner_container.add_theme_constant_override("separation", 30)
	margin.add_child(inner_container)

	# Left side - map panel
	_build_map_panel(inner_container)

	# Right side - info panel
	_build_info_panel(inner_container)


func _build_map_panel(parent: Control) -> void:
	var map_container := VBoxContainer.new()
	map_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_container.size_flags_stretch_ratio = 1.5
	map_container.add_theme_constant_override("separation", 10)
	parent.add_child(map_container)

	# Title
	var title := Label.new()
	title.text = "DESCENT PATH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.8))
	map_container.add_child(title)

	# Map display area
	map_panel = Panel.new()
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.3, 0.3, 0.35)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	map_panel.add_theme_stylebox_override("panel", style)
	map_container.add_child(map_panel)

	# Map drawing surface
	map_display = Control.new()
	map_display.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_display.draw.connect(_on_map_draw)
	map_display.gui_input.connect(_on_map_input)
	map_panel.add_child(map_display)

	# Timeline
	_build_timeline(map_container)


func _build_timeline(parent: Control) -> void:
	timeline_container = Control.new()
	timeline_container.custom_minimum_size = Vector2(0, TIMELINE_HEIGHT + 30)
	parent.add_child(timeline_container)

	# Controls row
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 10)
	timeline_container.add_child(controls)

	# Play/pause button
	play_button = Button.new()
	play_button.text = "Play"
	play_button.custom_minimum_size = Vector2(80, 30)
	play_button.pressed.connect(_on_play_pressed)
	controls.add_child(play_button)

	# Speed button
	speed_button = Button.new()
	speed_button.text = "1x"
	speed_button.custom_minimum_size = Vector2(50, 30)
	speed_button.pressed.connect(_on_speed_pressed)
	controls.add_child(speed_button)

	# Time label
	time_label = Label.new()
	time_label.text = "00:00 / 00:00"
	time_label.add_theme_font_size_override("font_size", 14)
	controls.add_child(time_label)

	# Timeline track
	var track := Control.new()
	track.custom_minimum_size = Vector2(0, TIMELINE_HEIGHT)
	track.position.y = 35
	track.set_anchors_preset(Control.PRESET_TOP_WIDE)
	track.draw.connect(_on_timeline_draw)
	track.gui_input.connect(_on_timeline_input)
	timeline_container.add_child(track)


func _build_info_panel(parent: Control) -> void:
	info_panel = VBoxContainer.new()
	info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_panel.add_theme_constant_override("separation", 15)
	parent.add_child(info_panel)

	# Title
	var title := Label.new()
	title.text = "KEY MOMENTS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.8))
	info_panel.add_child(title)

	# Moments list (scrollable)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_panel.add_child(scroll)

	moments_list = VBoxContainer.new()
	moments_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	moments_list.add_theme_constant_override("separation", 8)
	scroll.add_child(moments_list)

	# Close button
	close_button = Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(0, 40)
	close_button.pressed.connect(_on_close_pressed)
	info_panel.add_child(close_button)


func _process(delta: float) -> void:
	if not visible:
		return

	# Handle path drawing animation
	if is_drawing_path:
		path_draw_progress += delta / PATH_DRAW_DURATION
		if path_draw_progress >= 1.0:
			path_draw_progress = 1.0
			is_drawing_path = false
		map_display.queue_redraw()

	# Handle playback
	if is_playing and not is_drawing_path:
		playback_time += delta * playback_speed
		if playback_time >= total_duration:
			playback_time = total_duration
			is_playing = false
			play_button.text = "Play"
			playback_complete.emit()

		_update_playhead_position()
		_update_time_label()
		map_display.queue_redraw()


# =============================================================================
# VISUALIZATION SETUP
# =============================================================================

func show_visualization(context: RunContext, recording: Dictionary = {}) -> void:
	run_context = context
	recording_data = recording

	visible = true
	is_drawing_path = true
	path_draw_progress = 0.0
	playback_time = 0.0
	is_playing = false
	selected_moment = -1

	_extract_path_data()
	_extract_moments()
	_generate_topo_map()
	_populate_moments_list()

	_update_time_label()
	map_display.queue_redraw()


func hide_visualization() -> void:
	visible = false
	is_playing = false


func _extract_path_data() -> void:
	path_points_3d = run_context.path_history.duplicate()
	path_timestamps = run_context.path_timestamps.duplicate()

	if path_timestamps.size() > 0:
		total_duration = path_timestamps[path_timestamps.size() - 1]
	else:
		total_duration = run_context.elapsed_time

	# Convert to 2D after map is generated
	path_points_2d.clear()


func _extract_moments() -> void:
	moments.clear()

	# Add decisions
	for decision in run_context.decisions:
		var moment := {
			"type": "decision",
			"subtype": decision.get("type", "unknown"),
			"time": decision.get("game_time", 0.0),
			"position": decision.get("position", Vector3.ZERO),
			"label": _get_decision_label(decision),
			"details": decision.get("details", {}),
		}
		moments.append(moment)

	# Add incidents
	for incident in run_context.incidents:
		var incident_type: String = incident.get("type", "unknown")
		var moment := {
			"type": "incident" if incident_type != "fatal_fall" else "fatal",
			"subtype": incident_type,
			"time": incident.get("game_time", 0.0),
			"position": incident.get("position", Vector3.ZERO),
			"label": _get_incident_label(incident),
			"details": incident,
		}
		moments.append(moment)

	# Sort by time
	moments.sort_custom(func(a, b): return a["time"] < b["time"])


func _get_decision_label(decision: Dictionary) -> String:
	var dtype: String = decision.get("type", "unknown")
	match dtype:
		"start_slide":
			return "Started sliding"
		"deploy_rope":
			return "Deployed rope"
		"start_downclimb":
			return "Began downclimbing"
		"self_arrest":
			return "Self-arrest attempt"
		"rest":
			return "Stopped to rest"
		_:
			return "Decision point"


func _get_incident_label(incident: Dictionary) -> String:
	var itype: String = incident.get("type", "unknown")
	match itype:
		"hard_landing":
			return "Hard landing"
		"fall_injury":
			return "Injury from fall"
		"collapse":
			return "Collapsed from exhaustion"
		"terminal_slide":
			return "Lost control of slide"
		"fatal_fall":
			return "Fatal fall"
		"exposure":
			return "Exposure"
		_:
			return "Incident"


func _generate_topo_map() -> void:
	# Get terrain service for topo generation
	var terrain_service = ServiceLocator.get_service("TerrainService")
	if terrain_service == null:
		return

	map_bounds_min = terrain_service.terrain_bounds_min
	map_bounds_max = terrain_service.terrain_bounds_max

	# Generate topo map
	var topo_generator := TopoMapGenerator.new()
	var chunks := terrain_service.get_all_chunks()
	var map_data := topo_generator.generate_map(chunks, map_bounds_min, map_bounds_max)

	# Render to texture
	var resolution := Vector2i(600, 600)
	var image := topo_generator.render_to_image(map_data, resolution)
	topo_texture = ImageTexture.create_from_image(image)

	# Convert 3D path to 2D screen coordinates
	_convert_path_to_2d()


func _convert_path_to_2d() -> void:
	path_points_2d.clear()

	for point in path_points_3d:
		var screen_pos := _world_to_screen(Vector2(point.x, point.z))
		path_points_2d.append(screen_pos)


func _world_to_screen(world_pos: Vector2) -> Vector2:
	var map_size := map_display.size
	var bounds_size := map_bounds_max - map_bounds_min

	if bounds_size.x == 0 or bounds_size.y == 0:
		return Vector2.ZERO

	var normalized := (world_pos - map_bounds_min) / bounds_size
	return normalized * map_size


func _populate_moments_list() -> void:
	# Clear existing
	for child in moments_list.get_children():
		child.queue_free()

	# Add moment entries
	for i in moments.size():
		var moment := moments[i]
		var entry := _create_moment_entry(i, moment)
		moments_list.add_child(entry)


func _create_moment_entry(index: int, moment: Dictionary) -> Control:
	var container := HBoxContainer.new()
	container.add_theme_constant_override("separation", 10)

	# Time
	var time_label := Label.new()
	time_label.text = _format_time(moment["time"])
	time_label.custom_minimum_size = Vector2(50, 0)
	time_label.add_theme_font_size_override("font_size", 12)
	time_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	container.add_child(time_label)

	# Color indicator
	var indicator := ColorRect.new()
	indicator.custom_minimum_size = Vector2(4, 20)
	indicator.color = _get_moment_color(moment)
	container.add_child(indicator)

	# Label
	var label := Label.new()
	label.text = moment["label"]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 13)
	container.add_child(label)

	# Make clickable
	var button := Button.new()
	button.flat = true
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.pressed.connect(func(): _on_moment_clicked(index))
	container.add_child(button)

	return container


func _get_moment_color(moment: Dictionary) -> Color:
	var mtype: String = moment.get("type", "decision")
	var subtype: String = moment.get("subtype", "")

	if mtype == "fatal":
		return MARKER_COLORS["fatal"]
	elif mtype == "incident":
		return MARKER_COLORS["incident"]
	elif subtype == "start_slide":
		return MARKER_COLORS["slide"]
	elif subtype == "deploy_rope":
		return MARKER_COLORS["rope"]
	else:
		return MARKER_COLORS["decision"]


# =============================================================================
# DRAWING
# =============================================================================

func _on_map_draw() -> void:
	if topo_texture == null:
		return

	# Draw topo map
	map_display.draw_texture_rect(topo_texture, Rect2(Vector2.ZERO, map_display.size), false)

	# Draw path (with progress animation)
	_draw_path()

	# Draw moment markers
	_draw_moment_markers()

	# Draw playhead
	_draw_playhead()


func _draw_path() -> void:
	if path_points_2d.size() < 2:
		return

	# Calculate how many points to draw based on progress
	var points_to_draw := int(path_points_2d.size() * path_draw_progress)
	points_to_draw = maxi(points_to_draw, 2)

	# Draw the path
	for i in range(points_to_draw - 1):
		var from := path_points_2d[i]
		var to := path_points_2d[i + 1]

		# Color gradient based on progress
		var alpha := 0.7 if i < points_to_draw - 10 else 0.9
		var color := Color(0.9, 0.7, 0.3, alpha)

		map_display.draw_line(from, to, color, 2.5)


func _draw_moment_markers() -> void:
	for i in moments.size():
		var moment := moments[i]
		var world_pos := Vector2(moment["position"].x, moment["position"].z)
		var screen_pos := _world_to_screen(world_pos)

		# Only draw if path has reached this point
		var moment_progress := moment["time"] / maxf(total_duration, 0.1)
		if moment_progress > path_draw_progress and is_drawing_path:
			continue

		var color := _get_moment_color(moment)
		var radius := MARKER_RADIUS

		# Highlight selected
		if i == selected_moment:
			radius *= 1.5
			map_display.draw_circle(screen_pos, radius + 3, Color(1, 1, 1, 0.5))

		# Draw marker
		map_display.draw_circle(screen_pos, radius, color)
		map_display.draw_arc(screen_pos, radius, 0, TAU, 16, Color(1, 1, 1, 0.7), 1.5)


func _draw_playhead() -> void:
	if is_drawing_path or path_points_2d.is_empty():
		return

	# Draw playhead at current position
	map_display.draw_circle(playhead_position, PLAYHEAD_RADIUS, Color(1.0, 0.95, 0.9, 0.9))
	map_display.draw_arc(playhead_position, PLAYHEAD_RADIUS, 0, TAU, 16, Color(0.2, 0.2, 0.25), 2.0)

	# Draw direction indicator if moving
	if is_playing and playback_time < total_duration - 0.1:
		var next_pos := _get_position_at_time(playback_time + 0.5)
		if next_pos.distance_to(playhead_position) > 5:
			var dir := (next_pos - playhead_position).normalized()
			var arrow_end := playhead_position + dir * 15
			map_display.draw_line(playhead_position, arrow_end, Color(1, 1, 1, 0.7), 2.0)


func _on_timeline_draw() -> void:
	var track := timeline_container.get_child(1)  # Timeline track
	var size := track.size

	# Background
	track.draw_rect(Rect2(0, 10, size.x, 20), Color(0.15, 0.15, 0.18))

	# Progress bar
	var progress := playback_time / maxf(total_duration, 0.1)
	track.draw_rect(Rect2(0, 10, size.x * progress, 20), Color(0.4, 0.5, 0.6, 0.8))

	# Moment markers on timeline
	for moment in moments:
		var moment_progress := moment["time"] / maxf(total_duration, 0.1)
		var x := size.x * moment_progress
		var color := _get_moment_color(moment)
		track.draw_line(Vector2(x, 8), Vector2(x, 32), color, 2.0)

	# Playhead
	var playhead_x := size.x * progress
	track.draw_rect(Rect2(playhead_x - 2, 5, 4, 30), Color(1, 1, 1, 0.9))


# =============================================================================
# PLAYBACK CONTROL
# =============================================================================

func _update_playhead_position() -> void:
	playhead_position = _get_position_at_time(playback_time)


func _get_position_at_time(time: float) -> Vector2:
	if path_timestamps.is_empty() or path_points_2d.is_empty():
		return Vector2.ZERO

	# Find surrounding timestamps
	for i in range(path_timestamps.size() - 1):
		if path_timestamps[i + 1] >= time:
			var t := (time - path_timestamps[i]) / maxf(path_timestamps[i + 1] - path_timestamps[i], 0.01)
			t = clampf(t, 0.0, 1.0)
			return path_points_2d[i].lerp(path_points_2d[i + 1], t)

	return path_points_2d[path_points_2d.size() - 1]


func _update_time_label() -> void:
	var current := _format_time(playback_time)
	var total := _format_time(total_duration)
	time_label.text = "%s / %s" % [current, total]


func _format_time(seconds: float) -> String:
	var mins := int(seconds) / 60
	var secs := int(seconds) % 60
	return "%02d:%02d" % [mins, secs]


func _on_play_pressed() -> void:
	if is_drawing_path:
		# Skip to end of path animation
		path_draw_progress = 1.0
		is_drawing_path = false
		map_display.queue_redraw()
		return

	is_playing = not is_playing
	play_button.text = "Pause" if is_playing else "Play"

	if is_playing and playback_time >= total_duration:
		playback_time = 0.0


func _on_speed_pressed() -> void:
	# Cycle through speeds
	if playback_speed == 1.0:
		playback_speed = 2.0
	elif playback_speed == 2.0:
		playback_speed = 4.0
	else:
		playback_speed = 1.0

	speed_button.text = "%dx" % int(playback_speed)


func _on_timeline_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var track := timeline_container.get_child(1)
			var relative_x := event.position.x / track.size.x
			playback_time = relative_x * total_duration
			_update_playhead_position()
			_update_time_label()
			map_display.queue_redraw()


func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			# Check if clicking on a moment marker
			for i in moments.size():
				var moment := moments[i]
				var world_pos := Vector2(moment["position"].x, moment["position"].z)
				var screen_pos := _world_to_screen(world_pos)

				if event.position.distance_to(screen_pos) < MARKER_RADIUS * 2:
					_on_moment_clicked(i)
					return


func _on_moment_clicked(index: int) -> void:
	selected_moment = index
	var moment := moments[index]

	# Jump to moment time
	playback_time = moment["time"]
	_update_playhead_position()
	_update_time_label()
	map_display.queue_redraw()

	moment_selected.emit(moment)


func _on_close_pressed() -> void:
	close_requested.emit()


# =============================================================================
# INPUT
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()

	if event.is_action_pressed("ui_accept"):
		_on_play_pressed()
		get_viewport().set_input_as_handled()
